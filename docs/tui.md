# EFZ terminal dashboard

The optional Python/curses viewer combines a rolling execution-rate and coverage
chart with the last completed input in hex/ASCII and covered function names.
It requires Python 3 with curses, an interactive UTF-8 terminal and the normal
OTP/Rebar toolchain. No Python packages or web server are needed.

From the repository root:

```sh
rebar3 compile
python3 scripts/tui.py --demo --out _build/tui-demo-1
```

The demo instruments the bundled parser, runs 10,000 mutations and deliberately
contains artificial target exceptions. It does not test an external service.
Use a new output directory each time; existing results are never replaced.

For your own target, supply the same trusted Erlang campaign map accepted by
`efz:start/1`, including raw binary seeds and prepared artifact maps:

```sh
python3 scripts/tui.py --config campaign.term --out _build/tui-run-1 \
  --code-path harness-ebin
python3 scripts/tui.py --attach _build/tui-run-1
```

Repeat `--code-path` for dependencies or the optional Gleam build. Relative paths
inside campaign configuration resolve against the repository root. The launcher
overrides `monitoring` to true and `crash_dir` to OUTPUT/crashes; other campaign
settings, including durable corpus identity/policy, remain caller-controlled.
Campaign configuration is trusted local executable configuration, not a finding.
This launcher currently uses the ordinary single-VM execution mode, not the
external `--supervised` CLI protocol.

## Screen and controls

- Left: rolling primary execution rate (calibration + mutations), accumulated
  coverage, mutation budget, calibration count, corpus and finding statistics.
- Right: hex and ASCII for the last completed input, phase, parent, outcome and
  target functions. Input previews are capped at 512 bytes and labelled when
  truncated. Function lists are capped at 64 entries; the dashboard shows three.
- Space pins/unpins the input and its outcome/functions. Graphs keep updating.
- Up/down scroll the input preview in 16-byte rows.
- `q` or Ctrl-C closes only the viewer. The detached campaign continues; its PID
  and output path are printed. Reattach with `--attach OUTPUT`.
- Terminal resizing is supported. Below 90×26, a resize message replaces panels.
  Completion leaves the final result visible until the viewer is closed.

The background bridge writes snapshot.json atomically about twice per second,
plus campaign.log and the normal binary report.term at completion. A failed
bridge is reported in the launching viewer; details are in campaign.log.
To stop a detached campaign explicitly, send SIGTERM to the printed bridge PID.
This is process cancellation and does not promise a completed report; corpus
entries already durably admitted remain governed by EFZ's ordinary guarantees.
There are no interactive replay, minimization or finding-annotation controls in
this first dashboard version.

## Honest interpretation of the data

The input is the last **completed** execution, never a claimed live program
counter. For source-instrumented ETS coverage, its exact reached probes map to
functions in the supplied manifests. If per-execution functions are absent, the
unfrozen panel explicitly labels the fallback **cumulative coverage**. Native
line coverage without function manifests and coverage-disabled configurations
show unavailable function data rather than inventing a call stack. Live stack
sampling is not implemented.

Percentages are displayed only with a known manifest probe denominator. Native
coverage is labelled in lines; manual coverage in manual units. A zero/unavailable
denominator produces an absolute count only. Statistics are cumulative, whereas
graphs retain at most 120 sampled points. Rate is based on execution deltas over
snapshot time, not a claimed per-target latency distribution.

Outcome counters include calibration and primary mutations, excluding extra
runtime verification calls. `Returned value` does not imply semantic success.
Only explicit `{efz_term_input_rejected, Reason}`, `rejected`, and
`{rejected, Reason}` return conventions are classified as codec/target rejection.
Other returned errors remain returned values. Exceptions are not automatically
classified as real defects: expected parser throws still require a suitable
harness contract or review. EFZ's older `rejections` counter also includes
coverage-equivalent executions; it is not used as a parser-rejection count here.

## Integration and overhead

`monitoring => false` is the default. Only opt-in campaigns retain the bounded
input presentation and outcome counters. No RNG draws or target calls are added.
`efz_fuzzer:monitor_snapshot/0` is a version-1 read-only snapshot API: it returns a
cached sample and requests asynchronous refresh. At most one refresh is pending,
so a slow target does not block the coordinator or grow an unbounded poll queue.
The final sample is published before the campaign report. Opt-in preview
formatting, function mapping and sampled coverage materialization have overhead;
no zero-overhead claim is made.

## Validation

On OTP 27.3.4.1 / Rebar3 3.25.0:

- Default EUnit: 311 passed; full Gleam/XML-RPC EUnit: 377 passed.
- Common Test: 3 passed; xref and Dialyzer passed.
- Monitor integration verifies exact mutation-recipe and coverage equivalence
  with monitoring off/on, bounded previews, consistent final outcome totals,
  and a responsive snapshot API while the target is deliberately blocked.
- `python3 -m unittest discover -s test -p 'tui_test.py'`: 2 passed, covering rate
  sampling/history bounds, byte display and terminal control sanitization.
- A real pseudo-terminal run verified panel rendering, input pinning, narrow
  terminal fallback, resize recovery, quit and reattachment. Launching the demo
  and closing the viewer left its campaign running; it completed 10,000 mutations
  and reported 7/9 probes with `efz_example_parser:classify/1` visible.

These checks establish the supported single-VM dashboard behavior, not a
performance-neutral monitoring claim or support for every terminal emulator.
