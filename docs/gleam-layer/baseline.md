# P0 baseline

HEAD 79d76221c6bc5df30b80e6b0de947f3860f4fa4b; initial tracked/index diffs empty.
User requirement directory and zip preserved (hashes in the run artifacts).
Runtime: OTP 27.0, ERTS 15.0, Rebar3, +S 2:2, JIT x86_64 Linux.
Pinned Cowboy/Cowlib/Ranch commits are unchanged in rebar.lock.

Original `rebar3 compile`: exit 1 (unreachable configured proxy).
Scoped direct HTTPS dependency fetch + compile: exit 0. No global config changed.
Original EUnit/CT layout: failed before tests, because nested test target source
dirs become symlinks which collide with Rebar's copying of test/. Reproduced in
fresh /tmp/efz-native-baseline-20261007. Identical harness sources copied to a
nonoverlapping source dir there: EUnit exit 0, **260 passed**; CT exit 0,
**3 passed**. Main checkout implements this layout fix by moving the four
unchanged harness modules to examples/cowboy/targets and examples/engine. Original
_build/test is retained as _build/test-before-gleam-layout. No corpus deleted.

Before implementation, 200 actual staged executions of efz_example_target with
mutation seed {17,23,41} completed through EFZ. baseline.term and p0-trace.log
record the exact candidates, findings and outcomes. Baseline source snapshot
and runner: /tmp/efz-native-baseline-20261007 (git archive of the original HEAD;
only build source-dir layout differs). Ordinary compile requires no Gleam.

`efz_cov_native_public:preflight/1` verifies public OTP coverage capability and
mode, with no silent backend fallback. OTP 27 native storage is module scoped
(the installed kernel-10.0/src/code.erl, lines 270-296 and 2309-2312).
Existing EUnit tests cover ETS, ETS-member, bitmap and native backends. Native
line mode supports this VM; it cannot be combined with hit_count or manual.
Single campaign/single worker plus guardian cleanup barrier serializes online
intervals. Concurrent unmanaged target calls in this VM are outside that
contract. Gleam does not introduce a backend, parallel oracle or async observer.

P2 toolchain clarification (2026-10-08): the primary `erl` resolves through asdf
to `/home/fbogoslavskii/.asdf/installs/erlang/27.0`, ERTS 15.0. Its verified source
is `lib/kernel-10.0/src/code.erl` under that root. `/usr/bin/erl` independently
selects system OTP 27.3.4.13 / ERTS 15.2.7.9. P2 records both and repeats clean
off-build/tests on the same primary OTP 27.0 used for on-build
(`toolchain-paths.json` in the P2 run).
