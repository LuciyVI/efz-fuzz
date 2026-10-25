# Cowboy: a small target for EFZ

**English** · [Русский](../../docs/i18n/ru/examples/cowboy/README.md) · [Español](../../docs/i18n/es/examples/cowboy/README.md) · [简体中文](../../docs/i18n/zh-CN/examples/cowboy/README.md) · [All languages](../../docs/i18n/README.md)

`efz_cowboy_target:run/1` accepts **query string bytes without the leading `?`**,
for example `<<"q=hello+world&edit">>`, and calls `cowboy_req:parse_qs/1`.
The result is `{ok, Pairs}` or `{invalid, qs | limit_reached}` for an expected
Cowboy rejection. The wrapper does not catch unexpected exceptions. Cowboy
itself converts its parser exceptions to `request_error`, so this harness tests
the public API with its error semantics rather than preserving every internal
cause.

For the newer eleven-target data-flow suite (request fields, routing, HTTP/1
body delivery, protocol and compression round trips), see
[Cowboy data-flow harnesses](../../docs/cowboy-harness-suite.md). It runs the same
targets with Gleam disabled, observation-only, and semantic-guided feedback,
using pinned dependencies from this repository and recording target coverage.

Execution is synchronous in the target process. A minimal Req containing the
`qs` field is used; no listener, connection or Cowboy application is started.
The scope is query string decoding in Cowboy/Cowlib. HTTP framing, headers,
sockets, routing, handlers and child processes are outside this scope.

## Running

From the **efz/** root, with a built sibling Cowboy checkout:

```sh
rebar3 compile
make -C ../cowboy
escript examples/cowboy/run.escript ../cowboy check
escript examples/cowboy/run.escript ../cowboy 500
```

The path in the current workspace contains `:`. Cowboy's `erlang.mk` cannot build
in such a path (`target pattern contains no '%'`). The verified workaround is a
separate copy in `/tmp`; the original checkout is preserved:

```sh
COWBOY_BUILD=$(mktemp -d /tmp/efz-cowboy.XXXXXX)
cp -a ../cowboy "$COWBOY_BUILD/cowboy"
make -C "$COWBOY_BUILD/cowboy"
rebar3 compile
escript examples/cowboy/run.escript "$COWBOY_BUILD/cowboy" check
escript examples/cowboy/run.escript "$COWBOY_BUILD/cowboy" 500
```

`make` downloads the dependencies pinned in Cowboy's Makefile. When the proxy was
unavailable in this environment, a build using direct access was verified:

```sh
env -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY \
    -u https_proxy -u http_proxy -u all_proxy make -C "$COWBOY_BUILD/cowboy"
```

For the separate long-running Cowboy HTTP/1 benchmark, Cowboy 2.19.0 is now pinned
in `rebar.config` and `rebar.lock`; its runner is described in
[`docs/cowboy-long-benchmark.md`](../../docs/cowboy-long-benchmark.md).
This older query string example continues to use a sibling Cowboy checkout and
runs in a fresh VM.

The runner automatically instruments the allowlist `[cowboy_req, cow_qs]` in
`_build/cowboy-targets`, verifies the BEAM/manifest and runs the standard executor.
The ordinary Cowboy artifacts are preserved. The Cowlib include directory is
passed for `cow_qs`. For `cowboy_req`, `strict => false` is used explicitly: in
the verified version, two list comprehensions (`filter_cookies/2`,
`kvlist_to_map/2`) are preserved without internal probes. They are not on the
`parse_qs/1` path; the limitations are printed during the build and recorded in
the manifest. Full coverage of all of Cowboy is not claimed.

The example uses staged mode, seed `{17,23,41}`, initial corpus `[<<>>]`,
`dictionary_insert`, `bitflip`, `havoc` stages and a 1024-byte input limit.
The execution-count argument accepts 1–100000 and defaults to 500. EFZ coverage
defaults are preserved: prepared validation + ETS. Expected parsing rejections
count as normal target completion, so their new probes can expand the corpus.
Report: `_build/cowboy-report.term`; unexpected crashes: `_build/cowboy-crashes/`.

## Local validation

Verified on OTP 27.0, Rebar3 3.25.0, Cowboy 2.19.0
(`79e3fb02b31d47af6e69e8f3ba18fba291a3072a`), Cowlib 2.20.0
(`c768a804565ff5b8178ed968a5921e469d6bd7b2`). `check` runs 14 EUnit checks:
empty input, repeated keys, percent decoding, zero/non-UTF-8 bytes, malformed
escapes, the 99/100/101-key boundary, exact matching of ETS/ets_member snapshots,
new execution refs and retention of `a=1` after a real dictionary mutation with
automatic coverage. These additional checks run with the `check` command,
separately from ordinary `rebar3 eunit`, and require the real Cowboy.

A local run of 500 mutation executions completed with: 1 seed execution,
20 discoveries, 480 rejections, 0 crashes/timeouts/infrastructure failures.
This is an observation on the stated build, not an expected constant for other
versions. The baseline `rebar3 compile` and `rebar3 eunit` passed: 62 EFZ tests.
