# Erlamsa provider performance and persistent sessions

The default mutation transport remains `disposable` for older configs and
one-shot requests. For a campaign or a `pyefz.Client` that makes repeated
Erlamsa requests, set `mutation_provider.transport` to `persistent`; the
measurements show that startup amortization pays off on repeated use. Persistent mode starts one
external Erlang VM, verifies it, and prepares one immutable core context at
session startup. Every mutation runs in a fresh request process inside that VM.
EFZ still owns source selection, seed assignment, feedback ordering, target
execution, corpus admission, replay, and campaign shutdown. There is one
in-flight provider request and no prefetch.

## Process lifecycle

The lifecycle controller is `efz_mutation_session`. It owns the private Unix
socket directory, framed socket, VM launcher port, session epoch, request
sequence, deadlines, and bounded runtime samples. The existing C launcher owns
the Erlang VM process group, descendant kill and reap; the Python bootstrap
keeps OTP's `erl_child_setup` parent relationship valid. The EFZ or SDK caller
owns the controller and monitors it.

The transitions are `starting -> accepting -> hello -> starting_handshake ->
ready -> busy -> ready`, with `recycling -> stopping -> cleaning_directory ->
starting` between requests. `close` uses `stopping -> down`. Startup errors,
owner death, request timeout, cancellation, malformed replies, and unexpected
VM death enter bounded failure cleanup and then `down`. A failed cleanup is an
infrastructure error. A request is correlated with both a random session epoch
and a monotonically increasing request number; a prior VM's late reply cannot
match the current request. The caller receives one terminal result. Failed or
cancelled requests are not retried.

Configuration is validated before the target starts. `startup_timeout` bounds
VM startup and the full source/build/runtime handshake; `timeout` is the
absolute monotonic deadline for one mutation; `cleanup_timeout` bounds orderly
shutdown before external termination and reaping; `max_requests` recycles only
between requests (default 10,000; range 1..1,000,000). There is no request queue:
a concurrent SDK operation receives `ProviderBusy`. During the short recycle
transition, at most one submitted request can wait under its original absolute
deadline. The controller does not use RSS as a hard quota and does not claim
that Erlang heap limits bound all VM or native allocations.

The handshake checks the clean pinned source revision, app and BEAM hashes,
loaded module names and MD5 fingerprints, OTP/ERTS identity, API versions,
normalized functional config, and immutable prepared context. No request
contains a module, function, code path, or load instruction. The worker uses
only the fixed `efz_provider_port:persistent_main/0` entrypoint; it never runs
target code. Each request rechecks the context identifier, loaded module
fingerprints, input/request limits, result shape, and output bound. The full
source/build identity is checked at startup and every recycle, not on the warm
request path.

## Configuration and commands

Build from a checkout that contains this branch:

```sh
git switch perf/erlamsa-persistent-worker
git submodule update --init --recursive
ERL_FLAGS='+S 2:2' rebar3 compile
```

The vendored fork is the version source. Initialization fetches the pinned
gitlink, not a moving branch. No second Rebar dependency fetches the same core.
The core must be checked out and available before enabling the provider; no
source download or compilation occurs on the mutation path.

For a campaign, put an Erlang map in `campaign.term` and pass its output path
with `--out` (the CLI's explicit flags override the corresponding config
fields):

```erlang
#{target => my_harness,
  artifacts => "/absolute/path/to/instrumented-beams",
  seeds => [<<"local fixture">>],
  mutation_mode => staged,
  mutation_provider => #{mode => hybrid,
      weights => [{native,70},{erlamsa,30}],
      core_path => "/absolute/path/to/efz-fuzz/vendor/erlamsa",
      transport => persistent, timeout => 2000,
      startup_timeout => 10000, cleanup_timeout => 3000,
      max_requests => 10000,
      options => #{profile => bytes, strategy => preserve}},
  mutation => #{seed => {17,23,41}, stages => [havoc]}}.
```

Run a finite or continuous campaign:

```sh
ERL_FLAGS='+S 2:2' escript scripts/fuzz.escript \
  --config campaign.term --out /absolute/path/to/out \
  --max-iterations 10000

ERL_FLAGS='+S 2:2' escript scripts/fuzz.escript \
  --config campaign.term --out /absolute/path/to/continuous-out \
  --max-iterations infinity
touch /absolute/path/to/continuous-out/stop.request
```

For a standalone raw-byte call, `scripts/mutate.escript` remains disposable.
Python callers can select persistent mode in the provider map and reuse one
client:

```python
from pyefz import Client

provider = {
    "mode": "erlamsa", "transport": "persistent",
    "core_path": "/absolute/path/to/efz-fuzz/vendor/erlamsa",
    "timeout": 2000, "max_requests": 10000,
    "options": {"profile": "bytes"},
}
with Client("/absolute/path/to/efz-fuzz", runtime="/absolute/path/to/erl") as efz:
    result = efz.mutate(b"a\x00b\xff", provider=provider, seed=(17,23,41))
    batch = efz.mutate_batch([b"one", b"two"], provider=provider,
        seeds=[(29,31,37), (43,47,53)])
```

`mutate_batch_async()` and `mutate_async()` return cancellation handles.
Cancellation fails the current worker closed; the following explicit call opens
and fully verifies a fresh worker. Context manager exit closes and reaps the
control and provider processes. Concurrent requests on one client are rejected
as busy rather than reordered.

Raw replay reads stored bytes and needs no provider. Regeneration requires the
same pinned core and functional provider/build identity; a mismatch is an
explicit error. Transport, epoch, process ID, timing, and recycle counters are
runtime evidence only and do not change recipe identity. Existing schema-5
artifacts remain readable and keep their old functional identity requirements.

## Measurements

`core_us` retains its prior meaning: elapsed time around the existing
`efz_erlamsa:mutate/3` wrapper. New fields separate `identity_check_us`,
`direct_core_mutation_us`, request/result validation, parent encode/send/decode,
request total, startup/handshake, and cleanup/recycle. Child intervals are
reported as durations; EFZ never subtracts timestamps from another OS process.
Warm request percentiles exclude startup and recycle, while campaign
throughput includes startup, scheduled recycle, orderly shutdown, and target
execution. The report retains bounded samples, sample counts, VM starts,
requests per VM, restarts, cancellations, timeouts, errors, and byte/frame
sizes. These timings overlap at IPC boundaries and are not expected to sum to
request total.

For the paired acceptance run, exact environment, commands, raw samples, and
limitations are in [performance validation](erlamsa-performance-validation.md)
and [machine-readable evidence](erlamsa-evidence/performance-persistent/).
The older [integration benchmark](erlamsa-benchmark.md) remains a separate
measurement of disposable transport and its original builds; it is not
byte-identical evidence for this performance branch.
