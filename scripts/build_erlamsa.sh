#!/bin/sh
set -eu
# Explicit opt-in only. Never fetch, initialize or move a Git revision here.
efz_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
core_source=${ERLAMSA_SOURCE:-"$efz_root/vendor/erlamsa"}
if ! test -f "$core_source/core/rebar.config"; then
    echo 'Missing Erlamsa library. Initialize the pinned submodule, then build again.' >&2
    echo 'git submodule update --init --recursive -- vendor/erlamsa' >&2
    exit 1
fi
if test -n "$(git -C "$core_source" status --porcelain --untracked-files=normal)"; then
    echo 'Erlamsa source is dirty; commit or preserve changes before building.' >&2
    exit 1
fi
core_revision=$(git -C "$core_source" rev-parse HEAD)
# Rebar sets REBAR_BUILD_DIR for EFZ; do not leak it into the independent project.
(cd "$core_source/core" && REBAR_BUILD_DIR="$core_source/core/_build" rebar3 compile)
echo "EFZ Erlamsa core: $core_revision ($core_source/core/_build/default/lib/erlamsa_core/ebin)"
