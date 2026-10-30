"""Run from repository root: python3 -m unittest discover -s test -p '*supervisor_test.py' -v.
Native code is compiled, but is only ever loaded in launcher-owned BEAM VMs.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("external", ROOT / "priv/efz_external.py")
ex = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ex)


class ProtocolTests(unittest.TestCase):
    def test_fragmentation_and_multiple(self):
        packet = ex.encode(2, 7)
        d = ex.Decoder()
        result = []
        for byte in packet + packet:
            result += d.feed(bytes([byte]))
        self.assertEqual([packet[4:]] * 2, result)
        self.assertIsNone(d.since)

    def test_length_before_payload(self):
        for n in [0, 12, ex.MAX_FRAME + 1, 0xffffffff]:
            d = ex.Decoder()
            with self.assertRaises(ex.ProtocolError):
                d.feed(struct.pack("!I", n))
            self.assertLessEqual(len(d.buffer), 4)

    def supervisor(self):
        s = ex.Supervisor.__new__(ex.Supervisor)
        s.generation = 2
        s.run = 9
        s.state = "EXECUTING"
        s.events = []
        s.pending = (Path("unused"), {"input_sha256": "ab"})
        s.journal = mock.Mock()
        s.send = mock.Mock()
        s.a = mock.Mock(startup_ms=1000)
        return s

    def test_stale_duplicate_and_unsafe_terms(self):
        s = self.supervisor()
        for b in [ex.encode(4, 1, 9, bytes(4))[4:], ex.encode(4, 2, 8, bytes(4))[4:],
                  ex.encode(4, 2, 9, b"\x83P" + bytes(10))[4:],
                  ex.encode(4, 2, 9, bytes([9, 0, 0, 0]))[4:]]:
            with self.assertRaises(ex.ProtocolError):
                s.frame(b)
        s.journal.finish.assert_not_called()
        valid = ex.encode(4, 2, 9, bytes(4))[4:]
        s.frame(valid)
        self.assertIsNone(s.pending)
        self.assertEqual(s.state, "READY")
        with self.assertRaises(ex.ProtocolError):
            s.frame(valid)
        s.journal.finish.assert_called_once()

    def test_wrong_handshake(self):
        s = self.supervisor()
        s.state, s.identity = "STARTING", "00" * 32
        for prefix in [b"EFZ9", b"\x83Pxx", b"EFZ1"]:
            with self.assertRaises(ex.ProtocolError):
                s.frame(ex.encode(1, 2, payload=prefix + b"x" * 40)[4:])


class JournalTests(unittest.TestCase):
    def test_commit_recovery_idempotence(self):
        with tempfile.TemporaryDirectory() as tmp:
            j = ex.Journal(tmp, "first", 100000)
            meta = {"format_version": 1, "campaign_id": "first", "run_id": 1, "input_sha256": ex.digest(b"raw")}
            p = j.prepare(1, b"raw", meta)
            self.assertEqual(ex.load_run(p), (meta, b"raw"))
            j.authorize(p)
            next_j = ex.Journal(tmp, "second", 100000)
            self.assertEqual(next_j.recovered, 1)
            r = ex.read_json(p / "result.json")
            self.assertEqual(r["classification"], "interrupted_unknown")
            j.finish(p, r)
            with self.assertRaises(ValueError):
                j.finish(p, {"classification": "native_vm_crash"})
            self.assertEqual(ex.Journal(tmp, "third", 100000).recovered, 0)

    def test_write_failure_no_commit_and_prepared_not_native(self):
        with tempfile.TemporaryDirectory() as tmp:
            j = ex.Journal(tmp, "first", 100000)
            m = {"format_version": 1, "campaign_id": "first", "run_id": 1, "input_sha256": ex.digest(b"x")}
            with mock.patch.object(ex, "write_sync", side_effect=OSError("ENOSPC")):
                with self.assertRaises(OSError):
                    j.prepare(1, b"x", m)
            self.assertFalse((j.dir / "1").exists())
            p = j.prepare(1, b"x", m)
            ex.Journal(tmp, "second", 100000)
            self.assertEqual(ex.read_json(p / "result.json")["classification"], "interrupted_prepared")
            with open(p / "artifact.input", "wb") as f:
                f.write(b"bad")
            with self.assertRaises(ValueError):
                ex.load_run(p)

    def test_finalization_failure_and_checksum(self):
        with tempfile.TemporaryDirectory() as tmp:
            j = ex.Journal(tmp, "first", 100000)
            m = {"format_version": 1, "campaign_id": "first", "run_id": 1, "input_sha256": ex.digest(b"x")}
            p = j.prepare(1, b"x", m)
            j.authorize(p)
            with mock.patch.object(ex, "atomic", side_effect=OSError("EIO")):
                with self.assertRaises(OSError):
                    j.finish(p, {"classification": "execution_result"})
            self.assertEqual(ex.load_run(p)[1], b"x")
            self.assertFalse((p / "result.json").exists())
            ex.Journal(tmp, "second", 100000)
            self.assertEqual(ex.validated_result(p)["classification"], "interrupted_unknown")
            value = ex.read_json(p / "result.json")
            value["classification"] = "native_vm_crash"
            (p / "result.json").write_text(json.dumps(value))
            with self.assertRaises(ValueError):
                ex.Journal(tmp, "third", 100000)


class NativeIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = Path(tempfile.mkdtemp(prefix="p1-native-", dir=ROOT / "_build"))
        cls.plain = cls.base / "plain"
        cls.plain.mkdir()
        cls.artifacts = cls.base / "artifacts"
        cls.env = dict(os.environ, ERL_FLAGS="+S 4:4")
        cls.ebin = ROOT / "_build/default/lib/efz/ebin"
        subprocess.run(["make", "-C", "c_src"], cwd=ROOT, check=True, capture_output=True)
        subprocess.run(["erlc", "-o", str(cls.plain), "fixtures/external/efz_native_fixture.erl"], cwd=ROOT, check=True, env=cls.env)
        otp = subprocess.check_output(["erl", "+S", "4:4", "-noshell", "-eval", 'io:put_chars(code:root_dir()),halt().'], env=cls.env).decode()
        subprocess.run(["cc", "-shared", "-fPIC", "-O2", "-Wall", "-Wextra", "-Werror", "-I", otp + "/usr/include",
                        "-o", str(cls.plain / "efz_native_fixture.so"), "fixtures/external/efz_native_fixture.c"], cwd=ROOT, check=True)
        code = '{ok,_}=efz_instrument:compile("fixtures/external/efz_external_target.erl",#{modules=>[efz_external_target],source_root=>".",outdir=>"' + str(cls.artifacts) + '"}),halt().'
        subprocess.run(["erl", "+S", "4:4", "-noshell", "-pa", str(cls.ebin), "-eval", code], cwd=ROOT, check=True, env=cls.env)
        cls.startup_artifacts = cls.base / "startup-artifacts"
        code = '{ok,_}=efz_instrument:compile("fixtures/external/efz_external_startup.erl",#{modules=>[efz_external_startup],source_root=>".",outdir=>"' + str(cls.startup_artifacts) + '"}),halt().'
        subprocess.run(["erl", "+S", "4:4", "-noshell", "-pa", str(cls.ebin), "-eval", code], cwd=ROOT, check=True, env=cls.env)
        print("NATIVE_EVIDENCE=" + str(cls.base), flush=True)

    def campaign(self, mode, extra=(), env=None, script="fuzz.escript", seeds=True, startup=False):
        case = self.base / (mode + "-" + str(time.monotonic_ns()))
        case.mkdir()
        corpus = case / "seeds"
        corpus.mkdir()
        for i, b in enumerate([b"SAFE1", mode.encode(), b"SAFE2"]):
            (corpus / str(i)).write_bytes(b)
        marker = case / "executed"
        args = ["escript", str(ROOT / "scripts" / script)]
        if script == "fuzz.escript":
            args += ["--supervised"]
        args += list(extra)
        args += ["--target", "efz_external_startup" if startup else "efz_external_target", "--artifacts", str(self.startup_artifacts if startup else self.artifacts), "--code-path", str(self.plain), "--out", str(case / "out")]
        if seeds:
            args += ["--seeds", str(corpus), "--max-iterations", "0"]
        result = subprocess.run(args, cwd=ROOT, env=dict(self.env, EFZ_NATIVE_MARKER=str(marker), **(env or {})), capture_output=True, timeout=40)
        (case / "stdout").write_bytes(result.stdout)
        (case / "stderr").write_bytes(result.stderr)
        report = case / "out/external-report.json"
        r = ex.read_json(report) if report.exists() else None
        return result, r, case, marker

    def test_segv_and_abrt_recovery_and_replay(self):
        for mode, sig in [("SEGV", signal.SIGSEGV), ("ABRT", signal.SIGABRT)]:
            with self.subTest(mode=mode):
                p, r, case, marker = self.campaign(mode)
                self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
                self.assertEqual(r["generations"], 2)
                self.assertEqual(len(r["findings"]), 1)
                path = Path(r["findings"][0])
                meta, raw = ex.load_run(path)
                self.assertEqual(raw, mode.encode())
                self.assertEqual(meta["input_sha256"], ex.digest(raw))
                finding = ex.read_json(path / "result.json")
                self.assertEqual(finding["classification"], "native_vm_crash")
                self.assertEqual(finding["termination"]["signal"], sig)
                self.assertFalse(finding["termination"]["launcher_kill"])
                workers = [e["pid"] for e in r["events"] if e["event"] == "ready"]
                self.assertEqual(len(set(workers + [r["supervisor_pid"], r["cli_pid"]])), 4)
                self.assertIn((str(workers[1]) + " SAFE2").encode(), marker.read_bytes())
                self.assertIn((str(workers[1]) + " SAFE1").encode(), marker.read_bytes())
                # The existing corpus restore path, not supervisor-invented seeds.
                report = case / "out/worker-2/report.term"
                code = '{ok,B}=file:read_file("' + str(report) + '"),R=binary_to_term(B),#{restored_inputs:=3}=maps:get(corpus_restore,R),halt().'
                subprocess.run(["erl", "+S", "4:4", "-noshell", "-eval", code], env=self.env, check=True)
                replay, rr, _, _ = self.campaign("REPLAY", ["--external-finding", str(path), "--reproduce-runs", "2"], script="replay.escript", seeds=False)
                self.assertEqual(replay.returncode, 0, replay.stdout + replay.stderr)
                self.assertEqual(rr["reproduction"]["observed"], 2)

    def test_hang_dirty_exitcode_noise_timeout(self):
        for mode, category in [("HANG", "worker_hard_timeout"), ("DIRTY", "dirty_recycle"), ("EXIT139", "worker_unexpected_exit"), ("NOISE", None), ("WAIT", None), ("BUSY", None)]:
            with self.subTest(mode=mode):
                start = time.monotonic()
                p, r, _, marker = self.campaign(mode, ["--timeout", "50", "--runtime-diagnostics", "--verification-budget", "0", "--sample-interval", "5"])
                self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
                self.assertIn(b"SAFE2", marker.read_bytes())
                if mode == "HANG":
                    self.assertLess(time.monotonic() - start, 15)
                if mode == "DIRTY":
                    self.assertEqual(r["generations"], 2)
                    self.assertTrue(any(e.get("classification") == category for e in r["events"]))
                elif category:
                    f = ex.read_json(Path(r["findings"][0]) / "result.json")
                    self.assertEqual(f["classification"], category)
                    if mode == "EXIT139":
                        self.assertEqual(f["termination"]["signal"], 0)
                        self.assertEqual(f["termination"]["exit_code"], 139)
                    else:
                        self.assertTrue(f["termination"]["launcher_kill"])
                elif mode in ["WAIT", "BUSY"]:
                    expected = "timeout_waiting" if mode == "WAIT" else "timeout_busy"
                    self.assertTrue(any(e.get("timeout_class") == expected for e in r["events"]))
                elif mode == "NOISE":
                    term = [e for e in r["events"] if e["event"] == "terminated"][0]
                    self.assertGreater(term["log_bytes"], 4 * 1024 * 1024)
                    self.assertLessEqual(len(term["tail_hex"]), 8192)

    def test_write_failure_and_startup(self):
        p, _, _, marker = self.campaign("SAFE", ["--journal-bytes", "4096"])
        self.assertNotEqual(p.returncode, 0)
        self.assertFalse(marker.exists())
        p, r, _, marker = self.campaign("SAFE", env={"EFZ_NATIVE_STARTUP_CRASH": "1"}, startup=True)
        self.assertEqual(p.returncode, 1)
        self.assertEqual(r["generations"], 1)
        self.assertEqual(r["executions"], 0)
        self.assertEqual(r["findings"], [])
        self.assertFalse(marker.exists())
        self.assertFalse(any(e["event"] == "ready" for e in r["events"]))

    def test_supervisor_sigkill_reaps_hung_worker(self):
        for victim in ["cli", "controller"]:
            with self.subTest(victim=victim):
                case = self.base / ("kill-" + victim)
                case.mkdir()
                seeds = case / "seeds"
                seeds.mkdir()
                (seeds / "seed").write_bytes(b"HANG")
                marker = case / "executed"
                args = ["escript", str(ROOT / "scripts/fuzz.escript"), "--supervised", "--target", "efz_external_target",
                        "--artifacts", str(self.artifacts), "--code-path", str(self.plain), "--seeds", str(seeds),
                        "--out", str(case / "out"), "--max-iterations", "0", "--timeout", "30000"]
                p = subprocess.Popen(args, env=dict(self.env, EFZ_NATIVE_MARKER=str(marker)), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    end = time.monotonic() + 10
                    while not marker.exists() and time.monotonic() < end:
                        threading.Event().wait(0.01)
                    self.assertTrue(marker.exists(), "NIF entry barrier was not reached")
                    records = list((case / "out/external-runs").glob("*/*/artifact.external.json"))
                    self.assertEqual(len(records), 1)
                    m = ex.read_json(records[0])
                    worker, controller = m["worker_pid"], m["supervisor_pid"]
                    status = Path(f"/proc/{worker}/status").read_text()
                    launcher = int(next(line.split()[1] for line in status.splitlines() if line.startswith("PPid:")))
                    os.kill(p.pid if victim == "cli" else controller, signal.SIGKILL)
                    p.communicate(timeout=10)
                    end = time.monotonic() + 5
                    while any(Path(f"/proc/{pid}").exists() for pid in [worker, launcher, controller]) and time.monotonic() < end:
                        threading.Event().wait(0.01)
                    self.assertEqual([pid for pid in [worker, launcher, controller] if Path(f"/proc/{pid}").exists()], [])
                    print("PARENT_DEATH", victim, {"worker": worker, "launcher": launcher, "controller": controller}, flush=True)
                    # Recovery records uncertainty, not a fake native finding.
                    ex.Journal(case / "out", "recovered", 268435456)
                    self.assertEqual(ex.read_json(records[0].parent / "result.json")["classification"],
                                     "interrupted_unknown" if victim == "controller" else "supervisor_parent_death")
                finally:
                    if p.poll() is None:
                        p.kill()
                        p.communicate(timeout=10)

    def test_real_worker_waits_for_commit_permission(self):
        # Real BEAM + production executor, fake external owner withholds only RUN.
        case = self.base / "barrier"
        case.mkdir()
        seeds = case / "seeds"
        seeds.mkdir()
        (seeds / "seed").write_bytes(b"SAFE")
        marker = case / "executed"
        files = sorted(str(p.absolute()) for d in [self.ebin, self.artifacts, self.plain]
                       for p in d.iterdir() if p.suffix in [".beam", ".so", ".efz-manifest"])
        identity = hashlib.sha256(b"".join(hashlib.sha256(Path(p).read_bytes()).digest() for p in files)).hexdigest()
        with tempfile.TemporaryDirectory(prefix="efz-gate-") as tmp:
            path = str(Path(tmp) / "socket")
            server = socket.socket(socket.AF_UNIX)
            server.bind(path)
            server.listen(1)
            server.settimeout(10)
            args = [str(ROOT / "priv/efz_vm_launcher"), str(os.getpid()), shutil.which("erl"), "+S", "4:4", "-noshell", "-pa", str(self.ebin),
                    "-s", "efz_external_worker", "main", "-extra", path, "1", identity, "", str(len(files)), *files, "--",
                    "--target", "efz_external_target", "--artifacts", str(self.artifacts), "--code-path", str(self.plain),
                    "--seeds", str(seeds), "--out", str(case / "out"), "--max-iterations", "0"]
            p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=dict(self.env, EFZ_NATIVE_MARKER=str(marker)))
            conn = None
            try:
                conn, _ = server.accept()
                conn.settimeout(10)
                def recv():
                    header = conn.recv(4, socket.MSG_WAITALL)
                    n = struct.unpack("!I", header)[0]
                    self.assertLessEqual(n, ex.MAX_FRAME)
                    return conn.recv(n, socket.MSG_WAITALL)
                self.assertEqual(recv()[0], 1)
                conn.sendall(ex.encode(11, 1))
                self.assertEqual(recv()[0], 2)
                conn.sendall(ex.encode(11, 1))
                prepare = recv()
                self.assertEqual(prepare[0], 3)
                self.assertFalse(marker.exists())
                # No RUN: neither execution nor any further frame is allowed.
                conn.settimeout(0.1)
                with self.assertRaises(socket.timeout):
                    conn.recv(1)
                self.assertFalse(marker.exists())
                raw = prepare[59:]
                self.assertEqual(raw, b"SAFE")
                j = ex.Journal(case, "barrier", 100000)
                meta = {"format_version": 1, "campaign_id": "barrier", "run_id": 1, "input_sha256": ex.digest(raw)}
                record = j.prepare(1, raw, meta)
                j.authorize(record)
                conn.sendall(ex.encode(10, 1, 1, hashlib.sha256(raw).digest()))
                conn.settimeout(10)
                self.assertEqual(recv()[0], 4)
                self.assertIn(b"SAFE", marker.read_bytes())
            finally:
                p.stdin.close()
                p.wait(timeout=5)
                p.stdout.close()
                if conn:
                    conn.close()
                server.close()

    def test_restart_budget(self):
        p, r, _, _ = self.campaign("SEGV", ["--restart-budget", "0"])
        self.assertEqual(p.returncode, 1)
        self.assertEqual(r["status"], "restart_budget_exhausted")
        self.assertEqual(r["generations"], 1)


if __name__ == "__main__":
    unittest.main()
