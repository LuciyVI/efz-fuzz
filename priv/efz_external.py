#!/usr/bin/env python3
"""Linux external campaign owner. Target code is never imported or executed here.

Worker protocol v1: u32 length, u8 type/u32 generation/u64 run, fixed payloads.
No ETF, JSON, module names, arbitrary terms or decompression on the worker wire.
JSON is only our own bounded on-disk metadata / trusted C launcher's evidence.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid

MAX_INPUT = 1048576
MAX_FRAME = MAX_INPUT + 65536 + 59
PHASES = {1: "calibration", 2: "mutation", 3: "verification", 4: "reproduction"}
OUTCOMES = ["ok", "crash", "exit", "timeout", "infrastructure"]


class ProtocolError(Exception):
    pass


def digest(b):
    return hashlib.sha256(b).hexdigest()


def encode(kind, generation, run=0, payload=b""):
    b = struct.pack("!BIQ", kind, generation, run) + payload
    return struct.pack("!I", len(b)) + b


class Decoder:
    def __init__(self):
        self.buffer = bytearray()
        self.since = None

    def feed(self, data):
        # Callers read at most 4096 bytes; reject length at the first 4 bytes.
        if len(data) > 4096:
            raise ProtocolError("read_chunk_limit")
        self.buffer.extend(data)
        rows = []
        while len(self.buffer) >= 4:
            n = struct.unpack_from("!I", self.buffer)[0]
            if not 13 <= n <= MAX_FRAME:
                raise ProtocolError("frame_length")
            if len(self.buffer) < n + 4:
                break
            b = bytes(self.buffer[4:n + 4])
            del self.buffer[:n + 4]
            rows.append(b)
            if len(rows) > 64:
                raise ProtocolError("frame_rate")
        if self.buffer:
            if self.since is None:
                self.since = time.monotonic()
        else:
            self.since = None
        return rows


def fsync_dir(p):
    fd = os.open(p, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def mkdir(p):
    p = Path(p)
    if not p.exists():
        mkdir(p.parent)
        p.mkdir()
        fsync_dir(p.parent)


def packed(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def write_sync(path, b):
    with open(path, "xb") as f:
        f.write(b)
        f.flush()
        os.fsync(f.fileno())


def atomic(path, value):
    path = Path(path)
    tmp = path.with_name(".tmp-" + uuid.uuid4().hex)
    write_sync(tmp, packed(value))
    os.replace(tmp, path)
    fsync_dir(path.parent)


def read_json(path, limit=65536):
    with open(path, "rb") as f:
        b = f.read(limit + 1)
    if len(b) > limit:
        raise ValueError("metadata_limit")
    # Local files are not executable configuration; prohibit pathological nesting.
    if b.count(b"{") + b.count(b"[") > 512:
        raise ValueError("metadata_nesting_limit")
    return json.loads(b)


def load_run(path):
    path = Path(path)
    manifest = read_json(path / "manifest.json")
    if set(manifest) not in [{"artifact.input", "artifact.external.json"}, {"artifact.input", "artifact.external.json", "artifact.recipe"}]:
        raise ValueError("manifest_schema")
    values = {}
    for name, limit in [("artifact.input", MAX_INPUT), ("artifact.external.json", 65536)] + ([("artifact.recipe", 65536)] if "artifact.recipe" in manifest else []):
        with open(path / name, "rb") as f:
            b = f.read(limit + 1)
        if len(b) > limit or manifest[name] != {"size": len(b), "sha256": digest(b)}:
            raise ValueError("artifact_integrity")
        values[name] = b
    m = read_json(path / "artifact.external.json")
    if m["format_version"] != 1 or m["input_sha256"] != digest(values["artifact.input"]):
        raise ValueError("artifact_version_or_digest")
    return m, values["artifact.input"]


def validated_result(path):
    value = read_json(Path(path) / "result.json", 16384)
    checksum = value.pop("sha256")
    if checksum != digest(packed(value)) or not isinstance(value.get("classification"), str):
        raise ValueError("result_integrity")
    return value


class Journal:
    def __init__(self, out, campaign, max_bytes):
        self.root = Path(out) / "external-runs"
        mkdir(self.root)
        self.campaign = campaign
        self.max_bytes = max_bytes
        self.bytes = 0
        self.recovered = 0
        # Bounded discovery; interrupted runs never become inferred native crashes.
        count = 0
        for folder in self.root.iterdir():
            if not folder.is_dir() or folder.name.startswith("."):
                continue
            for run in folder.iterdir():
                if run.name == "configuration.json":
                    continue
                count += 1
                if count > 100000:
                    raise ValueError("journal_scan_limit")
                if run.name.startswith("."):
                    continue  # Never issued: uncommitted staging is not a run.
                m, b = load_run(run)
                self.bytes += len(b) + 16384 + ((run / "artifact.recipe").stat().st_size if (run / "artifact.recipe").exists() else 0)
                if not (run / "result.json").exists():
                    auth = (run / "authorized.json").exists()
                    self.finish(run, {"classification": "interrupted_unknown" if auth else "interrupted_prepared",
                                      "execution_proven": False, "campaign_id": m["campaign_id"], "run_id": m["run_id"]})
                    self.recovered += 1
                else:
                    validated_result(run)
        self.dir = self.root / campaign
        mkdir(self.dir)

    def prepare(self, run, raw, meta, recipe=b""):
        self.bytes += len(raw) + len(recipe) + 16384
        if self.bytes > self.max_bytes:
            raise OSError("journal_byte_budget")
        dest = self.dir / str(run)
        stage = self.dir / (".tmp-" + uuid.uuid4().hex)
        stage.mkdir()
        files = {"artifact.input": raw, "artifact.external.json": packed(meta)}
        if recipe:
            files["artifact.recipe"] = recipe
        for name, b in files.items():
            write_sync(stage / name, b)
        write_sync(stage / "manifest.json", packed({name: {"size": len(b), "sha256": digest(b)} for name, b in files.items()}))
        fsync_dir(stage)
        os.rename(stage, dest)
        fsync_dir(self.dir)
        return dest

    @staticmethod
    def authorize(path):
        atomic(path / "authorized.json", {"permission_recorded": True, "execution_proven": False})

    @staticmethod
    def finish(path, result):
        final = path / "result.json"
        result = dict(result)
        result.pop("sha256", None)
        if final.exists():
            if validated_result(path) != result:
                raise ValueError("conflicting_finalization")
            return
        atomic(final, dict(result, sha256=digest(packed(result))))


def options(argv):
    p = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    p.add_argument("--parent", type=int, required=True, help=argparse.SUPPRESS)
    p.add_argument("--ebin", required=True, help=argparse.SUPPRESS)
    p.add_argument("--otp", required=True, help=argparse.SUPPRESS)
    p.add_argument("--erts", required=True, help=argparse.SUPPRESS)
    p.add_argument("--supervised", action="store_true")
    for flag in ["target", "out", "artifacts"]:
        p.add_argument("--" + flag, required=True)
    for flag in ["seeds", "corpus-dir", "external-finding"]:
        p.add_argument("--" + flag)
    p.add_argument("--code-path", action="append", default=[])
    for flag, default, low, high in [
        ("timeout", 100, 0, 3600000), ("max-iterations", 1000, 0, 1000000),
        ("max-input-bytes", 4096, 0, MAX_INPUT), ("restart-budget", 8, 0, 128),
        ("supervised-runs", 10000, 1, 100000), ("campaign-ms", 3600000, 1, 86400000),
        ("startup-ms", 10000, 100, 60000), ("ipc-grace-ms", 1000, 100, 10000),
        ("journal-bytes", 268435456, 4096, 1073741824), ("reproduce-runs", 1, 1, 16)]:
        def integer(s, lo=low, hi=high):
            n = int(s)
            if not lo <= n <= hi:
                raise argparse.ArgumentTypeError("out of range")
            return n
        p.add_argument("--" + flag, type=integer, default=default)
    p.add_argument("--mutation", choices=["random", "staged"], default="staged")
    p.add_argument("--coverage-policy", choices=["diagnostic", "strict"], default="diagnostic")
    p.add_argument("--corpus-build-policy", choices=["reject", "recalibrate"], default="reject")
    p.add_argument("--runtime-diagnostics", action="store_true")
    for flag in ["runtime-runs", "verification-budget", "sample-interval"]:
        p.add_argument("--" + flag, type=int)
    # Reject duplicate scalars instead of argparse's last-wins behavior.
    flags = [x for x in argv if x.startswith("--") and x != "--code-path"]
    if len(set(flags)) != len(flags):
        p.error("duplicate option")
    a = p.parse_args(argv)
    if not a.seeds and not a.corpus_dir and not a.external_finding:
        p.error("--seeds, --corpus-dir or --external-finding required")
    if a.external_finding and (a.seeds or a.corpus_dir):
        p.error("external reproduction uses only its verified raw input; do not add seeds/corpus")
    if any(getattr(a, x) is not None for x in ["runtime_runs", "verification_budget", "sample_interval"]) and not a.runtime_diagnostics:
        p.error("runtime options require --runtime-diagnostics")
    for key, lo, hi in [("runtime_runs", 1, 16), ("verification_budget", 0, 1000000), ("sample_interval", 1, 10000)]:
        v = getattr(a, key)
        if v is not None and not lo <= v <= hi:
            p.error("invalid " + key)
    return a


class Supervisor:
    def __init__(self, a):
        self.a = a
        self.out = Path(a.out).absolute()
        mkdir(self.out)
        self.lock = open(self.out / ".external-lock", "a+b")
        fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.campaign = uuid.uuid4().hex
        self.started = time.monotonic()
        self.end = self.started + a.campaign_ms / 1000
        self.generation = 0
        self.run = 0
        self.mutations = 0
        self.verifications = 0
        self.commit_seconds = 0.0
        self.quarantine = set()
        self.events = []
        self.findings = []
        self.helper = None
        self.sock = None
        self.pending = None
        self.parent = os.pidfd_open(a.parent)
        # open_port can insert erl_child_setup. Acquire the CLI pidfd first,
        # then require a live response from that port owner. Buffered pre-start
        # bytes cannot substitute for this challenge, closing PID reuse races.
        print("EFZ_PARENT_READY", flush=True)
        if not select.select([sys.stdin.buffer], [], [], 2)[0] or os.read(0, 4) != b"ACK\n":
            raise ValueError("parent_handshake")
        self.files = sorted(set(str(p.absolute()) for d in [a.ebin, a.artifacts] + a.code_path
                                for p in Path(d).iterdir() if p.is_file() and p.suffix in [".beam", ".efz-manifest", ".so"]))
        if len(self.files) > 1024 or not self.files:
            raise ValueError("identity_file_limit")
        self.identity = self.file_identity()
        self.config = digest(packed({k: v for k, v in vars(a).items() if k not in ["parent", "ebin"]}))
        self.journal = Journal(self.out, self.campaign, a.journal_bytes)
        atomic(self.journal.dir / "configuration.json", {"format_version": 1,
            "config_identity": self.config, "file_identity": self.identity,
            "files": self.files, "parameters": vars(a)})
        self.replay = None
        if a.external_finding:
            self.replay, raw = load_run(a.external_finding)
            self.replay_expected = validated_result(a.external_finding)
            if self.replay_expected["classification"] not in ["native_vm_crash", "worker_hard_timeout", "worker_unexpected_exit"]:
                raise ValueError("not_external_finding")
            if self.replay["file_identity"] != self.identity or self.replay["harness"] != a.target:
                raise ValueError("replay_identity_mismatch")
            recorded_timeout = self.replay["timeout_ms"]
            if type(recorded_timeout) is not int or not 0 <= recorded_timeout <= 3600000:
                raise ValueError("replay_timeout")
            a.timeout = recorded_timeout
            recorded_limit = self.replay["max_input_bytes"]
            if type(recorded_limit) is not int or not len(raw) <= recorded_limit <= MAX_INPUT:
                raise ValueError("replay_input_limit")
            a.max_input_bytes = recorded_limit
            seed = self.out / "reproduction-seed" / self.campaign
            mkdir(seed)
            write_sync(seed / (self.campaign + ".input"), raw)
            fsync_dir(seed)
            a.seeds = str(seed)
            a.corpus_dir = str(self.out / "reproduction-corpus" / self.campaign)
            a.max_iterations = 0
            a.verification_budget = 0 if a.runtime_diagnostics else None

    def file_identity(self):
        h = hashlib.sha256()
        for name in self.files:
            fhash = hashlib.sha256()
            with open(name, "rb") as f:
                for b in iter(lambda: f.read(65536), b""):
                    fhash.update(b)
            h.update(fhash.digest())
        return h.hexdigest()

    def event(self, kind, **kw):
        self.events.append({"event": kind, "generation": self.generation, **kw})
        self.events = self.events[-256:]

    def args(self):
        a = self.a
        args = []
        for key in ["target", "artifacts", "timeout", "max_input_bytes", "mutation", "coverage_policy", "corpus_build_policy"]:
            args += ["--" + key.replace("_", "-"), str(getattr(a, key))]
        args += ["--out", str(self.out / ("worker-" + str(self.generation))),
                 "--corpus-dir", a.corpus_dir or str(self.out / "corpus"),
                 "--max-iterations", str(max(0, a.max_iterations - self.mutations))]
        if a.seeds:
            args += ["--seeds", a.seeds]
        for path in a.code_path:
            args += ["--code-path", path]
        if a.runtime_diagnostics:
            args += ["--runtime-diagnostics"]
        for key in ["runtime_runs", "verification_budget", "sample_interval"]:
            if getattr(a, key) is not None:
                value = getattr(a, key)
                if key == "verification_budget":
                    value = max(0, value - self.verifications)
                args += ["--" + key.replace("_", "-"), str(value)]
        if a.runtime_diagnostics and a.verification_budget is None:
            args += ["--verification-budget", str(max(0, 1000 - self.verifications))]
        return args

    def send(self, kind, run=0, payload=b""):
        self.sock.settimeout(1)
        self.sock.sendall(encode(kind, self.generation, run, payload))

    def frame(self, b):
        kind, gen, run = struct.unpack("!BIQ", b[:13])
        body = b[13:]
        if gen != self.generation:
            raise ProtocolError("generation")
        if kind == 1 and self.state == "STARTING" and run == 0:
            if len(body) < 74 or body[:4] != b"EFZ1" or body[4:36].hex() != self.identity or body[36:68] != self.worker_config:
                raise ProtocolError("handshake_identity_or_version")
            pid = struct.unpack("!I", body[68:72])[0]
            n = body[72]
            if n > 32 or len(body) < 74 + n:
                raise ProtocolError("otp_length")
            m = body[73 + n]
            if m > 32 or len(body) != 74 + n + m or pid != self.worker_pid:
                raise ProtocolError("erts_or_pid")
            self.otp = body[73:73 + n].decode("ascii")
            self.erts = body[74 + n:].decode("ascii")
            if (self.otp, self.erts) != (self.a.otp, self.a.erts):
                raise ProtocolError("otp_erts_mismatch")
            self.state = "SETUP"
            self.send(11)
        elif kind == 2 and self.state == "SETUP" and run == 0 and not body:
            self.state = "READY"
            self.deadline = time.monotonic() + self.a.startup_ms / 1000
            self.event("ready", pid=self.worker_pid, otp=self.otp, erts=self.erts)
            self.send(11)
        elif kind == 3 and self.state == "READY" and run == 0 and len(body) >= 46:
            phase, timeout = struct.unpack("!BI", body[:5])
            h = body[5:37].hex()
            size, recipe_size, recipe_status = struct.unpack("!IIB", body[37:46])
            if size > self.a.max_input_bytes or recipe_size > 65536 or len(body) != 46 + size + recipe_size or recipe_status > 2:
                raise ProtocolError("prepare_lengths")
            raw, recipe = body[46:46 + size], body[46 + size:]
            if bool(recipe) != (recipe_status == 1):
                raise ProtocolError("recipe_status")
            if recipe and (len(recipe) < 43 or recipe[:5] != b"EFZR\x01" or recipe[41:43] == b"\x83P"
                           or recipe[41] != 131 or struct.unpack("!I", recipe[5:9])[0] != len(recipe) - 41
                           or recipe[9:41] != hashlib.sha256(recipe[41:]).digest()):
                raise ProtocolError("recipe_envelope")
            if phase not in PHASES or timeout != self.a.timeout or len(raw) > self.a.max_input_bytes or h != digest(raw):
                raise ProtocolError("prepare_schema")
            if self.run >= self.a.supervised_runs or (phase == 2 and self.mutations >= self.a.max_iterations):
                self.send(12)
                self.stop_reason = "budget_completed"
                return
            self.state = "PREPARING"
            self.run += 1
            self.mutations += int(phase == 2)
            self.verifications += int(phase == 3)
            meta = {"format_version": 1, "campaign_id": self.campaign, "run_id": self.run,
                    "generation": self.generation, "phase": "reproduction" if self.replay else PHASES[phase],
                    "input_size": len(raw), "input_sha256": h, "harness": self.a.target,
                    "file_identity": self.identity, "config_identity": self.config, "otp": self.otp,
                    "erts": self.erts, "timeout_ms": timeout, "worker_pid": self.worker_pid,
                    "supervisor_pid": os.getpid(), "launcher_parent_pid": self.a.parent,
                    "worker_config_identity": self.worker_config.hex(),
                    "max_input_bytes": self.a.max_input_bytes,
                    "recipe_status": ["not_available", "saved", "metadata_limit"][recipe_status]}
            commit_start = time.monotonic()
            path = self.journal.prepare(self.run, raw, meta, recipe)
            self.pending = (path, meta)
            self.journal.authorize(path)
            self.commit_seconds += time.monotonic() - commit_start
            self.state = "EXECUTING"
            # CLI P0 policy uses two 50ms memory helpers; guardian cleanup is
            # 1000ms. Absolute deadline, never extended by logs/traffic.
            memory_grace = 100 if self.a.runtime_diagnostics else 0
            self.deadline = time.monotonic() + (timeout + 1000 + memory_grace + self.a.ipc_grace_ms) / 1000
            self.send(10, self.run, bytes.fromhex(h))
        elif kind == 4 and self.state == "EXECUTING" and run == self.run and len(body) == 4:
            outcome, target, dirty, timeout = body
            if outcome > 4 or target > 4 or dirty > 1 or timeout > 3:
                raise ProtocolError("result_schema")
            self.state = "FINALIZING"
            path, meta = self.pending
            result = {"classification": "dirty_recycle" if dirty else "execution_result",
                      "outcome": OUTCOMES[outcome], "target_outcome": OUTCOMES[target],
                      "timeout_class": [None, "timeout_busy", "timeout_waiting", "timeout_unknown"][timeout],
                      "run_id": run, "generation": self.generation, "runner_reusable": not dirty}
            self.journal.finish(path, result)
            self.event("result", input_sha256=meta["input_sha256"], **result)
            self.pending = None  # Once finalized, later worker death cannot rewrite it.
            self.state = "READY"
            self.deadline = time.monotonic() + self.a.startup_ms / 1000
            self.send(11, run)
            if dirty:
                self.quarantine.add(meta["input_sha256"])
                self.stop_reason = "dirty_recycle"
                self.state = "RECYCLING"
                self.kill_after = time.monotonic() + 0.5
        elif kind == 5 and self.state in ["READY", "SETUP", "RECYCLING"] and run == 0 and len(body) == 1 and body[0] in [0, 1, 2]:
            self.done = body[0]
            self.send(11)
            self.state = "STOPPING"
            self.deadline = time.monotonic() + 1
        else:
            raise ProtocolError("unexpected_or_duplicate_message")

    def stop_helper(self):
        if self.helper and self.helper.poll() is None:
            try:
                self.helper.stdin.write(b"K")
                self.helper.stdin.flush()
            except BrokenPipeError:
                pass

    def generation_run(self, sock_path):
        self.generation += 1
        if self.file_identity() != self.identity:
            raise ValueError("build_changed")
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(sock_path)
        listener.listen(1)
        helper = Path(__file__).resolve().with_name("efz_vm_launcher")
        worker_args = self.args()
        self.worker_config = hashlib.sha256(b"".join(struct.pack("!I", len(s.encode())) + s.encode() for s in worker_args)).digest()
        args = [str(helper), str(os.getpid()), shutil.which("erl"), "+S", "4:4", "-noshell", "-noinput",
                "-pa", str(Path(self.a.ebin).absolute()), "-s", "efz_external_worker", "main", "-extra",
                sock_path, str(self.generation), self.identity,
                ",".join(sorted(self.quarantine)) if not self.replay else "",
                str(len(self.files)), *self.files, "--", *worker_args]
        env = dict(os.environ, ERL_CRASH_DUMP="/dev/null", ERL_CRASH_DUMP_SECONDS="0")
        env.pop("EFZ_EXTERNAL_REQUIRED", None)
        self.helper = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
        self.sock = None
        self.state, self.done, self.stop_reason = "STARTING", None, None
        self.kill_after = 0
        self.worker_pid = None
        self.deadline = time.monotonic() + self.a.startup_ms / 1000
        decoder, status_buffer, evidence = Decoder(), bytearray(), None
        eof = False
        kill_at = None
        try:
            while True:
                now = time.monotonic()
                if now >= self.end:
                    self.stop_reason = self.stop_reason or "campaign_deadline"
                if now >= self.deadline and self.stop_reason is None:
                    self.stop_reason = "worker_hard_timeout" if self.state == "EXECUTING" else "startup_or_idle_timeout"
                if decoder.since is not None and now - decoder.since > 1:
                    self.stop_reason = self.stop_reason or "worker_protocol_failure"
                if self.stop_reason and kill_at is None and now >= self.kill_after:
                    self.stop_helper()
                    kill_at = now
                if kill_at and now - kill_at > 5:
                    raise RuntimeError("launcher_termination_unconfirmed")
                watches = [self.parent]
                if self.helper.stdout:
                    watches.append(self.helper.stdout)
                if self.sock is None and not eof:
                    watches.append(listener)
                elif not eof:
                    watches.append(self.sock)
                ready, _, _ = select.select(watches, [], [], 0.02)
                if self.parent in ready:
                    self.stop_reason = "supervisor_parent_death"
                    self.stop_helper()
                if listener in ready:
                    self.sock, _ = listener.accept()
                    # Peer credentials must be the launched OS process.
                    pid, uid, _ = struct.unpack("3i", self.sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                    if uid != os.getuid():
                        raise ProtocolError("peer_uid")
                    self.peer_pid = pid
                if self.helper.stdout in ready:
                    chunk = os.read(self.helper.stdout.fileno(), 4096)
                    if not chunk:
                        self.helper.stdout.close()
                        self.helper.stdout = None
                    status_buffer.extend(chunk)
                    if len(status_buffer) > 10000:
                        raise ProtocolError("launcher_frame_limit")
                    while b"\n" in status_buffer:
                        line, _, rest = status_buffer.partition(b"\n")
                        status_buffer = bytearray(rest)
                        row = json.loads(line)
                        if "pid" in row:
                            self.worker_pid = row["pid"]
                            self.event("launched", **row)
                        else:
                            evidence = row
                if self.sock in ready and not eof:
                    data = self.sock.recv(4096)
                    if not data:
                        eof = True
                        if decoder.buffer:
                            self.stop_reason = self.stop_reason or "worker_protocol_failure"
                    else:
                        try:
                            for b in decoder.feed(data):
                                if self.worker_pid is None or self.peer_pid != self.worker_pid:
                                    raise ProtocolError("peer_pid")
                                if self.stop_reason in [None, "dirty_recycle"]:
                                    self.frame(b)
                        except (ProtocolError, UnicodeError, struct.error) as exc:
                            self.event("protocol_error", detail=str(exc))
                            self.stop_reason = "worker_protocol_failure"
                # Wait-status and stream EOF are distinct. Drain the final RESULT
                # before classification even when wait-status arrives first.
                if evidence is not None and (eof or self.sock is None):
                    break
                if self.helper.poll() is not None and self.helper.stdout is None and evidence is None:
                    raise RuntimeError("launcher_failed_without_wait_status")
            self.helper.wait(timeout=3)
            if not evidence["cleanup_confirmed"]:
                raise RuntimeError("launcher_cleanup_unconfirmed_no_restart")
            self.event("terminated", state=self.state, initiated_by=self.stop_reason, **evidence)
            if self.pending:
                path, meta = self.pending
                reason = self.stop_reason
                if reason is None:
                    reason = "native_vm_crash" if evidence["signal"] else "worker_unexpected_exit"
                self.journal.finish(path, {"classification": reason, "termination": evidence,
                    "initiated_by": self.stop_reason, "state": self.state, "execution_proven": False,
                    "attribution": "VM termination associated with authorized run; root cause unproven"})
                self.findings.append(str(path))
                index = self.out / "crashes" / "external"
                mkdir(index)
                atomic(index / (self.campaign + ".json"), {"format_version": 1,
                    "campaign_id": self.campaign, "representatives": self.findings,
                    "replay": "scripts/replay.escript --external-finding DIRECTORY --target LOCAL --artifacts LOCAL --out DIR"})
                self.quarantine.add(meta["input_sha256"])
                self.pending = None
            return self.stop_reason or ("completed" if self.done == 0 else "worker_unexpected_exit")
        finally:
            self.stop_helper()
            if self.helper:
                self.helper.wait(timeout=5)
            if self.sock:
                self.sock.close()
            listener.close()
            os.unlink(sock_path)

    def run_campaign(self):
        status = "failed"
        with tempfile.TemporaryDirectory(prefix="efz-ipc-") as ipc:
            for attempt in range(self.a.restart_budget + 1):
                status = self.generation_run(str(Path(ipc) / "control"))
                if status in ["budget_completed", "campaign_deadline", "supervisor_parent_death"]:
                    break
                if self.replay:
                    if self.generation >= self.a.reproduce_runs:
                        break
                elif status == "completed":
                    break
                # Startup/config/identity failures never get an endless restart.
                if not any(e["event"] == "ready" and e["generation"] == self.generation for e in self.events):
                    break
                if self.done in [1, 2] and status != "dirty_recycle":
                    break
                if attempt == self.a.restart_budget:
                    status = "restart_budget_exhausted"
                    break
                select.select([self.parent], [], [], min(0.05 * (attempt + 1), 0.5))
        result = {"format_version": 1, "campaign_id": self.campaign, "supervisor_pid": os.getpid(),
                  "cli_pid": self.a.parent, "status": status, "generations": self.generation,
                  "executions": self.run, "mutation_executions": self.mutations, "verification_executions": self.verifications,
                  "wall_seconds": time.monotonic() - self.started, "events": self.events,
                  "durable_prepare_seconds": self.commit_seconds,
                  "findings": self.findings, "quarantine": sorted(self.quarantine),
                  "recovered_interrupted": self.journal.recovered, "file_identity": self.identity}
        if self.replay:
            expected = self.replay_expected
            rows = [validated_result(Path(p)) for p in self.findings]
            def matches(row):
                if row["classification"] != expected["classification"]:
                    return False
                if expected["classification"] == "native_vm_crash":
                    return row["termination"]["signal"] == expected["termination"]["signal"]
                if expected["classification"] == "worker_unexpected_exit":
                    return row["termination"]["exit_code"] == expected["termination"]["exit_code"]
                return True
            observed = sum(matches(row) for row in rows)
            incomplete = self.run != self.a.reproduce_runs or any(row["classification"] in
                ["worker_protocol_failure", "supervisor_parent_death", "campaign_deadline"] for row in rows)
            result["reproduction"] = {"observed": observed, "requested": self.a.reproduce_runs,
                                      "completed": self.run,
                                      "status": "observed" if observed else "inconclusive" if incomplete else "not_observed"}
        atomic(self.out / "external-report.json", result)
        print(json.dumps({"status": status, "report": str(self.out / "external-report.json"), "runs": self.run}))
        return 0 if status in ["completed", "budget_completed"] or self.replay else 1


def main():
    if sys.platform != "linux" or not hasattr(os, "pidfd_open"):
        print("EFZ supervised mode requires Linux pidfd and Python 3.9+", file=sys.stderr)
        return 2
    a = options(sys.argv[1:])
    try:
        return Supervisor(a).run_campaign()
    except (OSError, ValueError, RuntimeError, ProtocolError, subprocess.TimeoutExpired) as exc:
        print("EFZ external infrastructure: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
