# pyefz

Localized quick references: [Русский](../../docs/i18n/ru/packages/pyefz/README.md) · [Español](../../docs/i18n/es/packages/pyefz/README.md) · [简体中文](../../docs/i18n/zh-CN/packages/pyefz/README.md).

`pyefz` controls an explicitly selected local EFZ build through an owned Erlang
process. It uses the Python standard library and requires Python 3.9+, OTP 27+
and a POSIX system with `/dev/stdin` and `/dev/stdout`. It does not bundle or
download EFZ, Erlang, Gleam, or the Erlamsa core.

From the EFZ checkout:

```sh
rebar3 compile
python3 -m pip install ./packages/pyefz
```

This complete native smoke example runs from that compiled checkout and keeps
the selected EFZ/runtime paths explicit:

```sh
EFZ_LOCAL_ROOT="$PWD" EFZ_LOCAL_RUNTIME="$(command -v erl)" python3 - <<'PY'
import os
from pyefz import Client

with Client(os.environ["EFZ_LOCAL_ROOT"], runtime=os.environ["EFZ_LOCAL_RUNTIME"]) as efz:
    result = efz.mutate(bytes(range(256)), seed=(17, 23, 41))
    assert result.changed and len(result.data) == 256
    print(result.output_sha256)
PY
```

The SDK launches Erlang with an argument vector and a fixed entrypoint. The
transport is versioned, length-prefixed JSON with explicit base64 byte fields.
It accepts no Erlang expression, term file, arbitrary callback, or network
address. Target and dependency directories are trusted executable local code.
Choose `efz_root`, `runtime`, `code_paths`, and any provider `core_path` accordingly.
Paths within campaign JSON resolve against `efz_root`; absolute paths avoid
dependence on working directories.

```python
from pyefz import Client

with Client("/absolute/path/to/efz", runtime="/absolute/path/to/erl") as efz:
    result = efz.mutate(b"a\x00b\xff", seed=(17, 23, 41))
    if result.changed:
        print(result.data, result.output_sha256)
    else:
        print("Skipped:", result.reason)
```

Standalone mutation calls only the mutation provider. It never starts a target
or campaign. `native`, `erlamsa` and `hybrid` are provider modes, independently
selected from campaign `mutation_mode` (`random`/`staged`) and `gleam_layer`.
An enabled campaign provider requires staged mode. The default standalone
provider is native. A changed result always contains different bytes; a skip
contains a reason and no claimed candidate.

```python
provider = {
    "mode": "erlamsa",
    "core_path": "/trusted/erlamsa/core/_build/default/lib/erlamsa_core/ebin",
    "on_skip": "skip",
    "options": {"profile": "bytes"},
}
with Client("/absolute/path/to/efz") as efz:
    results = efz.mutate_batch(
        [b"one", b"two"], provider=provider,
        seeds=[(1, 2, 3), (4, 5, 6)],
        requests=[{"operator": "byte_flip"}, {"operator": "byte_insert"}],
    )
```

For repeated local mutations, opt into the persistent transport explicitly:

```python
from pyefz import Client

provider = {
    "mode": "erlamsa",
    "transport": "persistent",
    "core_path": "/absolute/path/to/efz/vendor/erlamsa",
    "timeout": 2000,
    "max_requests": 10000,
    "options": {"profile": "bytes"},
}
with Client("/absolute/path/to/efz", runtime="/absolute/path/to/erl") as efz:
    one = efz.mutate(b"first\x00input", provider=provider, seed=(17, 23, 41))
    two = efz.mutate(b"second input", provider=provider, seed=(29, 31, 37))
    batch = efz.mutate_batch(
        [b"batch one", b"batch two"], provider=provider,
        seeds=[(43, 47, 53), (59, 61, 67)],
    )
    print(one.runtime, two.runtime, batch[0].runtime)
```

One `Client` reuses one isolated provider VM for matching provider configuration.
Requests are serialized; no candidate is prefetched. Batch items retain their
own seed and result. A cancellation or provider fault ends that worker; the
next explicit mutation may create a newly checked worker. `max_requests` causes
an orderly recycle between items. Use `mutate_async()` or
`mutate_batch_async()` when a caller needs a cancellation handle, and always
close the client (the context manager does this).

Each batch item has its own seed/request and result. Omitting seeds generates
independent unsigned 64-bit triples. Explicit triples provide reproducibility.
Batches contain 1–64 items, with at most 2 MiB of input and 2 MiB of aggregate
output allowance. Per-item errors are retained as `result.error`; a failing
single mutation raises its typed exception. Limits apply before requests are
sent and again inside EFZ. A frame may contain at most 8 MiB of encoded JSON,
with nesting capped at 24.

One `Client` owns at most one campaign. Use a separate client for another
campaign or for raw replay. EFZ continues to own target timeouts, cleanup,
corpus admission, coverage, findings, and replay compatibility.

```python
with Client("/absolute/path/to/efz", code_paths=["/trusted/harness-ebin"]) as efz:
    campaign = efz.start({
        "target": "my_harness",
        "artifacts": "/trusted/instrumented",
        "seeds": [b"first", b"\x00second"],
        "mutation_mode": "staged",
        "mutation_provider": "native",
        "mutation": {"seed": [17, 23, 41], "stages": ["havoc"]},
        "max_iterations": "infinity",
        "stop_after_no_new_coverage_seconds": 60,
        "timeout": 100,
    }, out="/absolute/path/to/new-output")
    print(campaign.stats())
    campaign.request_stop()  # also campaign.stop()
    report = campaign.await_result(timeout=10)  # also campaign.wait()
    saved = efz.results()
```

`await_result()` accepts seconds, or `None` to wait indefinitely. Other threads
can call `stats()` or `request_stop()` while it waits. A timed-out wait releases
the core waiter. Repeated stop requests are harmless and stop scheduling after
the current bounded target execution. Unsupported campaign keys and adapters
raise `BadConfig`. The JSON adapter supports the usual campaign scalar options,
raw seeds, artifact directories, corpus options, staged mutation options,
bounded runtime diagnostics, and the optional `efz_qs_adapter` Gleam example.
`stop_after_no_new_coverage_seconds` accepts 1..86400 and stops an active
mutation campaign when no new target coverage arrives for that interval.
The final report includes `coverage_idle` and status `stopped/no_new_coverage`.
For that example, use `profile="gleam"` and the trusted compiled Gleam code path,
then pass a `gleam_layer` map such as:

```python
gleam_layer = {
    "adapter": "efz_qs_adapter", "structured_fraction": 30,
    "feedback": "guided", "oracle": "inline", "oracle_budget": 8,
}
```

Completion atomically saves diagnostic `report.term` and a portable bounded
`report.json`. Python never decodes diagnostic ETF. `results(out=...)` returns
the JSON summary and a page of verified finding indexes; `next_offset` selects
the next page. Representative entries give raw `input`, `expect` and
`input_sha256` fields. `load_summary(out)` and `read_input(path, sha256=...)`
work without starting a runtime or loading a mutation provider.

```python
from pyefz import load_summary, read_input

summary = load_summary("/absolute/path/to/output")
raw = read_input("/absolute/path/to/artifact.input")
with Client("/absolute/path/to/efz") as efz:
    replay = efz.raw_replay(
        "/absolute/path/to/artifact.input", target="my_harness",
        artifacts="/trusted/instrumented", code_paths=["/trusted/harness-ebin"],
    )
```

Raw replay reads bounded authoritative bytes and the sibling `.replay`
expectation. The caller supplies executable code; the saved artifact never
selects it. EFZ checks the input hash and target/harness identities before
execution. Replay does not need the mutation provider that produced the input.

`close()` is idempotent. The context manager requests a graceful stop, waits
within `close_timeout` (default 5 seconds), closes the runtime, and reaps its
owned process. If graceful shutdown exceeds that deadline, it terminates the
owned process group, escalates to SIGKILL if needed, and raises
`RequestTimeout`. Completed reports are retrieved before normal teardown.
Context cleanup preserves an exception already raised by the body. There is
no implicit detached campaign; the TUI's detach behavior is a separate feature.

Catch `BadConfig`, `ProviderFailure`, `ProviderTimeout`, `RequestTimeout`, `Cancelled`,
`ProtocolError`, `StorageError` or `ReplayFailure` for distinct failure classes.
All inherit `EFZError`. `client.diagnostics` retains a bounded stderr tail.
`ProviderTimeout` also inherits `RequestTimeout`, but retains the
`provider_timeout` code. Invalid provider configuration is `BadConfig` before
target execution. A client transport deadline is `RequestTimeout`; an isolated
mutation worker deadline is `ProviderTimeout`.

Validation uses synthetic local fixtures:

```sh
PYTHONPATH=packages/pyefz/src PYEFZ_EFZ_ROOT="$PWD" \
PYEFZ_RUNTIME="$(command -v erl)" \
  python3 -m unittest discover -s packages/pyefz/test -p 'test_*.py' -v
```

Set `PYEFZ_CORE_PATH` to enable real core mutation checks. Set
`PYEFZ_ARTIFACTS`, `PYEFZ_TARGET`, and optionally `PYEFZ_CODE_PATHS` (separated
by the platform path separator) for a prebuilt synthetic campaign fixture.
Set `PYEFZ_PROFILE=gleam` when selecting that build. These checks never contact
an external service.

The `pyefz_cli_test.py` checks invoke the real standalone CLI from a foreign
working directory, compare generated bytes, reject mismatched provider
configuration, and regenerate saved bytes in a fresh VM. The raw replay SDK
test uses the simple parser fixture's explicit synthetic exception at `FF`;
it does not classify a third-party parser rejection as a defect.
