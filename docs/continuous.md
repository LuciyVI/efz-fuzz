# Continuous fuzzing

The ordinary single-VM EFZ loop supports unbounded random and staged/Gleam
campaigns through `max_iterations => infinity`. Finite campaigns keep their
existing defaults, execution limits and exhaustion/idle-stop behavior.

```erlang
{ok, _} = efz:start(#{target => my_harness, seeds => [<<0>>],
    artifacts => Artifacts, mutation_mode => staged,
    max_iterations => infinity, corpus_dir => "out/corpus"}).
%% Later, from the controlling VM:
ok = efz:request_stop().
Report = efz:await(infinity).
stopped_by_user = maps:get(status, Report).
ok = efz:stop().
```

`request_stop/0` is asynchronous and idempotent. It stops scheduling after the
current target call/iteration, respecting its timeout and cleanup. `await/1`
returns the final report; `stop/0` remains application teardown and should follow
report retrieval. A campaign already finished keeps its original status/report.

For CLI campaigns:

```sh
escript scripts/fuzz.escript --config campaign.term --out out \
  --max-iterations infinity
# From another terminal:
touch out/stop.request
```

The CLI saves out/report.term and returns 0 for a requested stop unless an
existing failure or strict coverage-policy violation makes the report fail. Remove a stale
stop.request before reusing an output directory. The CLI's finite mode remains
unchanged. Ctrl-C/SIGTERM is process termination, not this orderly report-saving
protocol. The external `--supervised` launcher retains its separate finite run,
restart and deadline policies; this change does not remove those safeguards.

Continuous staged preparation appends havoc if the selected stages lack it and
computes the normal configuration/recipe identity from that effective plan.
Deterministic cursors are not reset. Idle exhaustion falls back to a real byte
mutation using the same state-threaded PRNG, with standard replay operations and
a `continuous_fallbacks` counter. A nonempty input is changed by one bit; an empty
input receives one byte. Staged infinity requires max_input_bytes > 0.

Corpus admission and persistence, semantic feedback, primary target execution,
cleanup and replay remain EFZ-owned. Gleam provider fallbacks and finite oracle
budgets remain unchanged. Nothing restarts or recalibrates the entire campaign
when a mutation sweep becomes idle. Infrastructure failures still stop it.

Continuous mode bounds the explanatory decision list at 1,024 entries and counts
dropped decisions; bounded recipe traces and runtime-check reports retain their
existing caps. Working corpus and genuinely distinct finding groups are not
pruned automatically, so memory and disk capacity still require planning.

See [TUI controls](tui.md#continuous-mode) for continuous demonstration and the
`s` stop-and-save key.

## Validation

- Default EUnit: 316 passed; full Gleam/XML-RPC EUnit: 383 passed.
- Common Test: 3 passed; xref and Dialyzer passed; Python TUI checks: 2 passed.
- Focused tests cover infinity configuration, replayable fallback for empty and
  nonempty parents, idle exhaustion without cursor reset, continued progress,
  repeatable stop requests and absence of executions after the final report.
- A real Gleam term/API provider runs continuously with guided feedback and a
  bounded oracle budget; a CLI test requests stop through stop.request and
  verifies exit 0 plus the saved report.
- A pseudo-terminal demo passed 11,000 mutations (11,183 at the final stop), then
  the `s` key saved report.term and froze the final execution count. A separate
  durable-demo run saved corpus input/metadata records and stopped cleanly after
  761 mutations.

Continuous operation is established by removing the execution cap and testing
progress/stop boundaries; these finite acceptance runs do not claim that an
infinite duration or unlimited storage has been tested.
