# DWARF/native coverage: feasibility checkpoint

Status: **DWARF direct backend not implemented** (2026-10-03). The safe
`otp_native_public` comparison backend uses documented OTP APIs only; see
[`dwarf-native-coverage-results.md`](dwarf-native-coverage-results.md).
ETS remains default and bitmap remains opt-in. This checkpoint
stops before reading VM memory because the current environment does not provide
a demonstrated way to pin the dynamically allocated coverage storage while it
is copied. The DWARF offsets below are observations about one binary, not a
usable coverage reader.

## EFZ integration boundary

`efz_config:valid_field/2` accepts `ets`, `ets_member`, `bitmap`, and
`otp_native_public`.
`efz_coverage` dispatches those backends. `efz_guardian:run/6` owns an
iteration's coverage context; `efz_feedback` decides novelty and global merge.
The Cowboy runner (`scripts/cowboy_long_bench.escript`) compiles four Cowboy
modules through `efz_instrument:compile/2` for ETS/bitmap, which inserts EFZ
structural probes. The public native path uses
`efz_cov_native_public:compile/2` with `line_coverage` and selects `line` mode
before loading those modules.
It represents executable lines, not EFZ clauses/outcomes, so absolute coverage
counts would not be comparable.

## Verified runtime and layout

Runtime: OTP 27, ERTS 15.0, x86-64 Linux. The active executable identified for
this investigation was
`beam.smp` from the Erlang/OTP 27.0 installation (ERTS 15.0).
Its SHA256 is
`dcc7fac32e6f401be539022fce3e15a3f92461600208a41f1e7bfe3ef9e5d98f`;
its ELF GNU build-id is `545a52682e29950d87511c488a8d0f31551f5ad2`.
The ELF contains `.debug_info` and is not stripped.

GDB's DWARF type query (`gdb -q -batch -ex 'ptype /o BeamCodeHeader'
<beam.smp>`) reports a 144-byte `BeamCodeHeader` with these fields:

| Field | Byte offset | DWARF type |
| --- | ---: | --- |
| `coverage_mode` | 80 | `Uint` |
| `coverage` | 88 | `void *` |
| `line_coverage_valid` | 96 | `byte *` |
| `loc_index_to_cover_id` | 104 | `Uint32 *` |
| `line_coverage_len` | 112 | `Uint` |

`Module` (`struct erl_module`) has `curr.code_hdr` at offset 32 and
`old.code_hdr` at offset 96 in this binary. These values must be rediscovered
for each exact executable; they must never be copied into another build's
runtime configuration. The OTP 27.0 source declares `coverage` as `void *`, so
the type alone does not define the allocation, array element type, or lifetime:
[OTP 27.0 `beam_code.h`](https://github.com/erlang/otp/blob/OTP-27.0/erts/emulator/beam/beam_code.h).
The module table source explicitly distinguishes lock-free lookup of the active
instance from separately protected old/staging instances:
[OTP 27.0 `module.c`](https://github.com/erlang/otp/blob/OTP-27.0/erts/emulator/beam/module.c).

`code:coverage_support/0` returns `true` here. A module compiled with
`[binary, line_coverage, debug_info]`, loaded after
`code:set_coverage_mode(line)`, yielded `[{3,false},{4,true}]`
after one branch execution through `code:get_coverage(line, Module)`; public
`code:reset_coverage(Module)` cleared it to two `false` entries. This checks
only the public OTP behavior. No direct read has been performed or compared.

## Why direct reading is blocked

DWARF describes where the `coverage` **pointer field** is inside an already
located `BeamCodeHeader`; it does not identify the heap address of a loaded
module's header or keep that object alive. PIE/ASLR also means ELF symbol
addresses are not process addresses. A read through `Module.curr.code_hdr` and
then `coverage` without using ERTS's code-index/thread-progress rules can race
with reload/purge and dereference freed memory. Comparing build-id and module
MD5 before the read does not close the check-to-use race.

Pure Erlang exposes coverage as Erlang terms through `code:get_coverage/2`, not
as a pinned pointer. A separate port cannot call the VM's internal module
lookup and has no code-loader synchronization; on this host
`/proc/sys/kernel/yama/ptrace_scope` is `1`, so a child cannot normally read
its parent BEAM through `/proc/<pid>/mem` either. An in-process NIF could in
principle call private ERTS routines, but a correct helper would need the
matching OTP source/build headers and a verified active-code-index lifetime
contract. Those prerequisites are absent here. Guessing offsets and calling
private symbols is not an acceptable substitute, even for a benchmark.

Consequently `otp_native_direct` is **not** added to `coverage_backend` or the
Cowboy runner. There is no direct-read correctness test, smoke test,
microbenchmark, or 15-minute command. Public-API measurements are recorded
separately; they do not prove that a DWARF helper would improve end-to-end
fuzzing throughput.

## Minimal reproducible setup for a safe continuation

1. Obtain the complete OTP **27.0 source matching this exact `beam.smp` build**
   and its build configuration. Keep the executable's SHA256/build-id in the
   layout artifact; fail closed if the running `/proc/<beam-pid>/exe` differs.
2. Build a minimal in-process, build-specific **read-only** helper using the
   actual ERTS coverage and code-loader definitions. It must acquire the active
   module instance under ERTS's documented thread-progress/code-index rules,
   validate mode, module identity and bounds, copy a bounded compact buffer,
   and release its pin before returning. Never retain ERTS pointers between
   calls. If this cannot be established from source, use a small ERTS accessor
   patch in the disposable research OTP build rather than an unsafe NIF.
3. Discover fields and sizes from that executable's DWARF at startup. Require
   the corresponding SHA256/build-id and refuse absent DWARF or a mismatch.
   Derive the coverage array's actual element type and indexing from the
   matching source; DWARF's `void *` is insufficient.
4. Prohibit/abort on target reload or code upgrade while a campaign is active.
   Prove that reset and read occur only after child-writer quiescence, including
   timeout and cleanup-failure cases.
5. First compare direct snapshots with `code:get_coverage(line, Module)` on a
   small `line_coverage` fixture across branches, repeated execution, reset,
   reload and invalid-layout tests. Only after that integrate the native mode
   into `efz_coverage`/`efz_guardian`, keeping EFZ feedback and corpus policy.
6. Keep the implemented OTP-public mode opt-in. Measure any later direct helper
   against it on the same line schema before offering a 900-second manual run.
   Keep ETS as default and report line-coverage counts separately from EFZ
   structural-probe counts.

Reproduce the public-API fixture in a disposable directory:

```sh
cat >/tmp/efz_dwarf_fixture.erl <<'EOF'
-module(efz_dwarf_fixture).
-export([run/1]).
run(0) -> zero;
run(N) when N > 0 -> X = N + 1, {positive, X}.
EOF
erl -noshell -eval '{ok,M,B}=compile:file("/tmp/efz_dwarf_fixture.erl",[binary,line_coverage,debug_info]), code:set_coverage_mode(line), {module,M}=code:load_binary(M,"/tmp/efz_dwarf_fixture.erl",B), io:format("before=~p~n",[code:get_coverage(line,M)]), efz_dwarf_fixture:run(1), io:format("after=~p~n",[code:get_coverage(line,M)]), ok=code:reset_coverage(M), io:format("reset=~p~n",[code:get_coverage(line,M)]), halt().'
```

The command is a public OTP baseline, **not** a DWARF reader.
