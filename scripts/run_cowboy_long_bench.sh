#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == "--backend" && "${2:-}" == "erlang_fuzzer" ]]; then
    shift 2
    exec python3 scripts/run_erlang_fuzzer_cowboy_bench.py "$@"
fi
rebar3 compile
exec escript scripts/cowboy_long_bench.escript "$@"
