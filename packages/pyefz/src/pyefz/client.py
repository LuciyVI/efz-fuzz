import concurrent.futures
from collections import deque
import hashlib
import itertools
import math
import os
from pathlib import Path
import secrets
import select
import shutil
import signal
import subprocess
import threading
import time

from .errors import (BadConfig, Cancelled, EFZError, ProtocolError, RequestTimeout,
                     RuntimeUnavailable, remote_error)
from .protocol import (MAX_BATCH, MAX_BATCH_BYTES, MAX_INPUT, decode_bytes,
                       encode_bytes, frame, read_frame)
from .results import MutationResult, SavedResults


def _json_value(value, depth=0):
    if depth > 20:
        raise BadConfig("Configuration nesting limit")
    if isinstance(value, (bytes, bytearray, memoryview)):
        return encode_bytes(value)
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, dict):
        if not all(isinstance(key, str) for key in value):
            raise BadConfig("Configuration keys must be strings")
        return {key: _json_value(item, depth + 1) for key, item in value.items()}
    if isinstance(value, (tuple, list)):
        return [_json_value(item, depth + 1) for item in value]
    if value is None or isinstance(value, (str, bool, int, float)):
        return value
    raise BadConfig("Unsupported configuration value")


def _limit(value):
    if type(value) is not int or not 0 <= value <= MAX_INPUT:
        raise BadConfig("max_input_bytes must be in 0..1048576")
    return value


def _seed(value):
    if value is None:
        return [secrets.randbits(64) for _ in range(3)]
    if (not isinstance(value, (tuple, list)) or len(value) != 3 or
            any(type(item) is not int or not 0 <= item < 2 ** 64 for item in value)):
        raise BadConfig("seed must contain three unsigned 64-bit integers")
    return list(value)


def _mutation_args(data, provider, seed, request, maximum):
    maximum = _limit(maximum)
    encoded = encode_bytes(data)
    if len(data) > maximum:
        raise BadConfig("Input exceeds max_input_bytes")
    request = dict(request or {})
    if seed is not None and "seed" in request:
        raise BadConfig("Specify seed once")
    request["seed"] = _seed(request.get("seed") if seed is None else seed)
    return {"input": encoded, "provider": _json_value(provider),
            "request": _json_value(request), "max_input_bytes": maximum}


def _mutation_result(value, original, maximum, *, raise_error):
    if not isinstance(value, dict):
        raise ProtocolError("Invalid mutation result")
    runtime = value.get("runtime")
    if runtime is not None and not isinstance(runtime, dict):
        raise ProtocolError("Invalid mutation runtime metrics")
    status = value.get("status")
    if status == "changed":
        data = decode_bytes(value.get("input"), maximum)
        if data == original:
            raise ProtocolError("Provider reported an unchanged input as changed")
        original_hash, output_hash = (hashlib.sha256(raw).hexdigest() for raw in (original, data))
        if value.get("input_sha256") != original_hash or value.get("output_sha256") != output_hash:
            raise ProtocolError("Mutation checksum mismatch")
        return MutationResult(status, data=data, recipe=value.get("recipe"),
                              input_sha256=original_hash, output_sha256=output_hash,
                              runtime=runtime)
    if status == "skipped":
        return MutationResult(status, reason=value.get("reason"), runtime=runtime)
    if status == "error":
        error = remote_error(value.get("error"))
        if raise_error:
            raise error
        return MutationResult(status, error=error, runtime=runtime)
    raise ProtocolError("Unknown mutation result status")


class MutationCall:
    """One submitted mutation that can be awaited or cancelled by request ID."""

    def __init__(self, client, request_id, future, deadline, decode):
        self._client = client
        self.request_id = request_id
        self._future = future
        self._deadline = deadline
        self._decode = decode

    def result(self, timeout=None):
        if timeout is not None and (not isinstance(timeout, (int, float)) or
                                    isinstance(timeout, bool) or not math.isfinite(timeout) or
                                    timeout < 0):
            raise BadConfig("timeout must be nonnegative seconds or None")
        remaining = None if timeout is None else float(timeout)
        if self._deadline is not None:
            left = max(0.0, self._deadline - time.monotonic())
            remaining = left if remaining is None else min(remaining, left)
        try:
            value = self._future.result(timeout=remaining)
        except concurrent.futures.TimeoutError as exc:
            # ProviderTimeout is a remote, completed outcome and subclasses
            # TimeoutError too. Preserve its more specific public type.
            if self._future.done():
                raise
            self._client._forget(self.request_id)
            raise RequestTimeout("Mutation exceeded its client deadline") from exc
        finally:
            if self._future.done():
                self._client._forget(self.request_id)
        return self._decode(value)

    def cancel(self, *, timeout="default"):
        if self._future.done():
            return {"status": "not_running"}
        return self._client._call("cancel", {"target_id": self.request_id}, timeout=timeout)


class Client:
    """Own one local BEAM process, and at most one campaign.

    ``efz_root`` locates an already compiled EFZ checkout. ``runtime`` names the
    Erlang executable; it is passed an argv vector, never shell or Erlang code.
    Concurrent calls use correlated responses, so ``await_result`` can wait while
    another thread requests a graceful stop.
    """

    def __init__(self, efz_root, *, runtime="erl", profile="default", code_paths=(),
                 request_timeout=30.0, close_timeout=5.0):
        self.efz_root = Path(efz_root).resolve()
        if (not isinstance(profile, str) or not 0 < len(profile) <= 128 or
                any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-" for c in profile)):
            raise BadConfig("Invalid build profile")
        build = self.efz_root / "_build" / profile / "lib"
        ebin = build / "efz" / "ebin"
        if not (ebin / "efz_control.beam").is_file():
            raise RuntimeUnavailable("Compile EFZ with the control endpoint before starting pyefz")
        executable = shutil.which(os.fspath(runtime))
        if executable is None:
            raise RuntimeUnavailable("Erlang runtime executable was not found")
        self.runtime = str(Path(executable).resolve())
        paths = [ebin] + [p for p in sorted(build.glob("*/ebin")) if p != ebin]
        paths += [Path(p).resolve() for p in code_paths]
        if any(not p.is_dir() for p in paths):
            raise BadConfig("Code paths must be existing directories")
        for value in (request_timeout, close_timeout):
            if (not isinstance(value, (int, float)) or isinstance(value, bool) or
                    not math.isfinite(value) or value <= 0):
                raise BadConfig("Timeouts must be positive seconds")
        self.request_timeout = float(request_timeout)
        self.close_timeout = min(float(close_timeout), 30.0)
        self._lock = threading.Lock()
        self._write_lock = threading.Lock()
        self._close_lock = threading.Lock()
        self._pending = {}
        self._next_id = 1
        self._closed = self._closing = False
        self._failure = None
        self._campaign_started = False
        self._stderr = deque(maxlen=16)
        command = [self.runtime, "+S", "2:2", "-noshell", "-noinput"]
        for path in paths:
            command += ["-pa", str(path)]
        command += ["-s", "efz_control", "main"]
        try:
            self._process = self._launch(command)
            os.set_blocking(self._process.stdin.fileno(), False)
        except OSError as exc:
            raise RuntimeUnavailable(str(exc)) from exc
        self._reader = threading.Thread(target=self._read_responses, name="pyefz-reader", daemon=True)
        self._logs = threading.Thread(target=self._read_logs, name="pyefz-stderr", daemon=True)
        self._reader.start()
        self._logs.start()

    def _launch(self, command):
        return subprocess.Popen(command, cwd=self.efz_root, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                start_new_session=True, bufsize=0)

    @property
    def pid(self):
        return self._process.pid

    @property
    def diagnostics(self):
        return b"".join(tuple(self._stderr)).decode("utf-8", "replace")

    def _read_logs(self):
        try:
            while True:
                chunk = self._process.stderr.read(4096)
                if not chunk:
                    return
                self._stderr.append(chunk)
        except (OSError, ValueError):
            pass

    def _fail_pending(self, error):
        with self._lock:
            if self._failure is None:
                self._failure = error
            pending = list(self._pending.values())
            self._pending.clear()
        for future in pending:
            if not future.done():
                future.set_exception(error)

    def _read_responses(self):
        try:
            while True:
                response = read_frame(self._process.stdout)
                if (not isinstance(response, dict) or type(response.get("version")) is not int or
                        response.get("version") != 1 or
                        type(response.get("id")) is not int or
                        type(response.get("ok")) is not bool):
                    raise ProtocolError("Invalid response envelope")
                expected = {"version", "id", "ok", "result" if response["ok"] else "error"}
                if set(response) != expected:
                    raise ProtocolError("Unknown response fields")
                with self._lock:
                    if not 0 < response["id"] < self._next_id:
                        raise ProtocolError("Unexpected response ID")
                    future = self._pending.pop(response["id"], None)
                if future is None:  # A locally timed-out call may complete later.
                    continue
                if response["ok"]:
                    future.set_result(response["result"])
                else:
                    future.set_exception(remote_error(response["error"]))
        except EOFError:
            self._fail_pending(Cancelled("Runtime exited or closed the control channel"))
        except (OSError, ValueError, EFZError) as exc:
            self._fail_pending(exc if isinstance(exc, EFZError) else ProtocolError(str(exc)))

    def _call(self, operation, args=None, *, timeout="default"):
        request_id, future, deadline = self._begin_call(operation, args, timeout=timeout)
        try:
            remaining = None if deadline is None else max(0, deadline - time.monotonic())
            return future.result(timeout=remaining)
        except EFZError:
            # Remote provider deadlines must keep their own error type.
            raise
        except concurrent.futures.TimeoutError as exc:
            raise RequestTimeout("{} exceeded its client deadline".format(operation)) from exc
        finally:
            self._forget(request_id)

    def _begin_call(self, operation, args=None, *, timeout="default"):
        if timeout == "default":
            timeout = self.request_timeout
        if timeout is not None and (not isinstance(timeout, (int, float)) or isinstance(timeout, bool) or
                                    not math.isfinite(timeout) or timeout < 0):
            raise BadConfig("timeout must be nonnegative seconds or None")
        deadline = None if timeout is None else time.monotonic() + timeout
        with self._lock:
            if self._closed or (self._closing and operation not in ("request_stop", "close")):
                raise Cancelled("Client is closed")
            if self._failure is not None:
                raise self._failure
            if len(self._pending) >= 64:
                raise BadConfig("At most 64 concurrent requests are supported")
            request_id = self._next_id
            self._next_id += 1
            future = concurrent.futures.Future()
            self._pending[request_id] = future
        try:
            message = frame({"version": 1, "id": request_id, "op": operation, "args": args or {}})
            self._write_message(message, deadline)
            return request_id, future, deadline
        except (BrokenPipeError, OSError, ValueError) as exc:
            self._forget(request_id)
            if isinstance(exc, EFZError):
                raise
            raise Cancelled("Runtime control channel is closed") from exc
        except BaseException:
            self._forget(request_id)
            raise

    def _forget(self, request_id):
        with self._lock:
            self._pending.pop(request_id, None)

    def _mutation_call(self, operation, args, originals, maximum, timeout):
        request_id, future, deadline = self._begin_call(operation, args, timeout=timeout)
        def decode(value):
            if operation == "mutate":
                return _mutation_result(value, originals[0], maximum, raise_error=True)
            if not isinstance(value, dict) or set(value) != {"items"} or len(value["items"]) != len(originals):
                raise ProtocolError("Invalid batch response")
            return [_mutation_result(result, bytes(original), maximum, raise_error=False)
                    for result, original in zip(value["items"], originals)]
        return MutationCall(self, request_id, future, deadline, decode)

    def _write_message(self, message, deadline):
        remaining = None if deadline is None else max(0, deadline - time.monotonic())
        acquired = (self._write_lock.acquire() if remaining is None else
                    self._write_lock.acquire(timeout=remaining))
        if not acquired:
            raise RequestTimeout("Runtime write deadline exceeded")
        sent = False
        try:
            pending = memoryview(message)
            while pending:
                remaining = None if deadline is None else max(0, deadline - time.monotonic())
                if remaining == 0:
                    raise RequestTimeout("Runtime write deadline exceeded")
                _, writable, _ = select.select([], [self._process.stdin], [], remaining)
                if not writable:
                    raise RequestTimeout("Runtime write deadline exceeded")
                try:
                    written = os.write(self._process.stdin.fileno(), pending)
                except BlockingIOError:
                    continue
                sent = True
                pending = pending[written:]
        except RequestTimeout:
            if sent:
                self._fail_pending(ProtocolError("Partial request timed out; close this Client"))
            raise
        finally:
            self._write_lock.release()

    def start(self, config, *, out=None):
        if self._campaign_started:
            raise BadConfig("Use a separate Client for another campaign")
        if not isinstance(config, dict):
            raise BadConfig("Campaign configuration must be a dict")
        value = _json_value(config)
        if out is not None:
            value["out"] = str(Path(out).resolve())
        result = self._call("start", {"config": value})
        self._campaign_started = True
        return Campaign(self, result)

    def stats(self):
        return self._call("stats")

    def request_stop(self):
        return self._call("request_stop")

    stop = request_stop

    def await_result(self, timeout=None):
        if timeout is not None and (not isinstance(timeout, (int, float)) or isinstance(timeout, bool) or
                                    not math.isfinite(timeout) or timeout < 0):
            raise BadConfig("timeout must be nonnegative seconds or None")
        milliseconds = "infinity" if timeout is None else min(int(timeout * 1000), 86400000)
        return self._call("await_result", {"timeout_ms": milliseconds},
                          timeout=None if timeout is None else timeout + 1.0)

    wait = await_result

    def mutate(self, data, *, provider="native", seed=None, request=None,
               max_input_bytes=4096, timeout="default"):
        return self.mutate_async(data, provider=provider, seed=seed, request=request,
                                 max_input_bytes=max_input_bytes, timeout=timeout).result()

    def mutate_async(self, data, *, provider="native", seed=None, request=None,
                     max_input_bytes=4096, timeout="default"):
        encode_bytes(data)
        data = bytes(data)
        args = _mutation_args(data, provider, seed, request, max_input_bytes)
        return self._mutation_call("mutate", args, [data], max_input_bytes, timeout)

    def mutate_batch(self, inputs, *, provider="native", seeds=None, requests=None,
                     max_input_bytes=4096, timeout="default"):
        return self.mutate_batch_async(inputs, provider=provider, seeds=seeds,
            requests=requests, max_input_bytes=max_input_bytes, timeout=timeout).result()

    def mutate_batch_async(self, inputs, *, provider="native", seeds=None, requests=None,
                           max_input_bytes=4096, timeout="default"):
        inputs = list(itertools.islice(inputs, MAX_BATCH + 1))
        if not 0 < len(inputs) <= MAX_BATCH:
            raise BadConfig("A batch must contain 1..64 inputs")
        for data in inputs:
            encode_bytes(data)
        inputs = [bytes(data) for data in inputs]
        _limit(max_input_bytes)
        if len(inputs) * max_input_bytes > MAX_BATCH_BYTES:
            raise BadConfig("Batch output allowance exceeds 2 MiB")
        seeds = [None] * len(inputs) if seeds is None else list(itertools.islice(seeds, MAX_BATCH + 1))
        requests = [None] * len(inputs) if requests is None else list(itertools.islice(requests, MAX_BATCH + 1))
        if len(seeds) != len(inputs) or len(requests) != len(inputs):
            raise BadConfig("Each batch input must have its own seed/request entry")
        items = [_mutation_args(data, provider, seed, request, max_input_bytes)
                 for data, seed, request in zip(inputs, seeds, requests)]
        if sum(len(data) for data in inputs) > MAX_BATCH_BYTES:
            raise BadConfig("Batch inputs exceed 2 MiB")
        return self._mutation_call("mutate_batch", {"items": items}, inputs,
                                   max_input_bytes, timeout)

    def results(self, out=None, *, offset=0, limit=32):
        args = {"offset": offset, "limit": limit}
        if out is not None:
            args["out"] = str(Path(out).resolve())
        value = self._call("results", args)
        if not isinstance(value, dict) or set(value) != {"summary", "findings", "next_offset"}:
            raise ProtocolError("Invalid saved-results response")
        return SavedResults(**value)

    def raw_replay(self, input_path, *, target, artifacts, expect=None,
                   code_paths=(), timeout=100, max_input_bytes=None):
        args = {"input": str(Path(input_path).resolve()), "target": target,
                "artifacts": str(Path(artifacts).resolve()), "timeout": timeout,
                "code_paths": [str(Path(path).resolve()) for path in code_paths]}
        if expect is not None:
            args["expect"] = str(Path(expect).resolve())
        if max_input_bytes is not None:
            args["max_input_bytes"] = _limit(max_input_bytes)
        return self._call("raw_replay", args)

    def _reap(self, deadline):
        process = self._process
        try:
            process.wait(timeout=max(0, deadline - time.monotonic()))
            return
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=.5)
            return
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=2)

    def close(self):
        with self._close_lock:
            if self._closed:
                return
            self._closing = True
            deadline = time.monotonic() + self.close_timeout
            error = None
            try:
                if self._campaign_started:
                    self._call("request_stop", timeout=max(0, min(1.0, deadline - time.monotonic())))
                remaining = max(0, deadline - time.monotonic())
                self._call("close", {"timeout_ms": int(remaining * 1000)}, timeout=remaining)
            except EFZError as exc:
                error = exc
            finally:
                self._reap(deadline)
                self._closed = True
                self._fail_pending(Cancelled("Client closed"))
                for stream in (self._process.stdin, self._process.stdout, self._process.stderr):
                    try:
                        stream.close()
                    except OSError:
                        pass
                self._reader.join(timeout=.2)
                self._logs.join(timeout=.2)
            if error is not None:
                raise error

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        try:
            self.close()
        except EFZError:
            if exc_type is None:
                raise
        return False


class Campaign:
    def __init__(self, client, started):
        self.client = client
        self.started = started

    def stats(self):
        return self.client.stats()

    def request_stop(self):
        return self.client.request_stop()

    stop = request_stop

    def await_result(self, timeout=None):
        return self.client.await_result(timeout)

    wait = await_result

    def close(self):
        return self.client.close()
