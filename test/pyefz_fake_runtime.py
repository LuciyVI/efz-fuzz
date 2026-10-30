"""Synthetic process fixture: framed replies, no Erlang or target execution."""
import hashlib
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "packages/pyefz/src"))
from pyefz.protocol import decode_bytes, encode_bytes, frame, read_frame

waiting = []


def reply(request, value=None, error=None):
    response = {"version": 1, "id": request["id"], "ok": error is None}
    response["result" if error is None else "error"] = value if error is None else error
    encoded = frame(response)
    # Force the client to handle fragmented length and body reads.
    for start in range(0, len(encoded), 7):
        sys.stdout.buffer.write(encoded[start:start + 7])
    sys.stdout.buffer.flush()


def error(request, code):
    reply(request, error={"code": code, "message": "synthetic " + code})


while True:
    try:
        request = read_frame(sys.stdin.buffer)
    except EOFError:
        break
    operation, args = request["op"], request["args"]
    if operation == "start":
        reply(request, {"status": "running", "out": args["config"].get("out")})
    elif operation == "stats":
        reply(request, {"status": "running", "stats": {"executions": 3}})
    elif operation == "await_result":
        if args["timeout_ms"] == 0:
            error(request, "request_timeout")
        else:
            waiting.append(request)
    elif operation == "request_stop":
        reply(request, {"status": "stop_requested"})
        for pending in waiting:
            reply(pending, {"schema_version": 1, "status": "stopped_by_user"})
        waiting.clear()
    elif operation in ("mutate", "mutate_batch"):
        items = args["items"] if operation == "mutate_batch" else [args]
        values = []
        for item in items:
            provider = item["provider"]
            if provider == "crash":
                os._exit(3)
            if provider == "hang":
                continue
            if provider in ("missing", "bad_config", "timeout", "provider_timeout", "cancelled"):
                code = {"missing": "provider_failure", "bad_config": "bad_config", "timeout": "request_timeout",
                        "provider_timeout": "provider_timeout", "cancelled": "cancelled"}[provider]
                if operation == "mutate":
                    error(request, code)
                    break
                values.append({"status": "error", "error": {"code": code, "message": "fixture"}})
                continue
            raw = decode_bytes(item["input"])
            if not raw:
                values.append({"status": "skipped", "reason": "fixture empty"})
                continue
            changed = raw if provider == "lie" else bytes([raw[0] ^ 1]) + raw[1:]
            values.append({"status": "changed", "input": encode_bytes(changed), "recipe": {"seed": item["request"]["seed"]},
                "input_sha256": hashlib.sha256(raw).hexdigest(), "output_sha256": hashlib.sha256(changed).hexdigest()})
        else:
            if values:
                reply(request, {"items": values} if operation == "mutate_batch" else values[0])
    elif operation == "close":
        if os.environ.get("PYEFZ_FAKE_CLOSE_HANG"):
            continue
        reply(request, {"status": "closed", "report": None})
        break
    elif operation == "results":
        reply(request, {"summary": None, "findings": [], "next_offset": None})
    else:
        error(request, "bad_config")
