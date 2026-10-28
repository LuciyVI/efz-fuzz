#!/usr/bin/env python3
"""EFZ terminal monitor; standard-library only, snapshots never execute code."""
import argparse
from collections import deque
import curses
import json
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def clean(value):
    return ''.join(c if c.isprintable() else '?' for c in str(value))


def chart(values, width):
    values = list(values)[-max(1, width):]
    high = max(values, default=0) or 1
    blocks = '▁▂▃▄▅▆▇█'
    return ''.join(blocks[min(7, max(0, int(v / high * 7)))] for v in values)


def input_lines(last, offset=0, limit=8):
    if not last:
        return ['Waiting for a completed execution…']
    raw = bytes.fromhex(last.get('preview_hex', ''))
    rows = []
    for i in range(offset, min(len(raw), offset + limit * 16), 16):
        chunk = raw[i:i + 16]
        text = ''.join(chr(b) if 32 <= b < 127 else '.' for b in chunk)
        rows.append(f'{i:04x}  {chunk.hex(" "):<47}  {text}')
    return rows or ['<empty input>']


def provider_lines(snapshot):
    """Bounded presentation of observed provider configuration and counters."""
    provider = snapshot.get('provider')
    if not isinstance(provider, dict):
        return ['Mode       native', 'Transport  none', 'Worker     none']
    stats = snapshot.get('provider_stats', {})
    if not isinstance(stats, dict):
        stats = {}
    options = provider.get('options', {})
    if not isinstance(options, dict):
        options = {}

    def label(value):
        return clean(value)[:80]

    def count(mapping, key):
        value = mapping.get(key)
        return f'{value:,}' if type(value) is int and value >= 0 else '?'

    weights = provider.get('weights')
    if isinstance(weights, dict):
        weight_text = ' '.join(f'{name}={count(weights, name)}' for name in ('native', 'erlamsa'))
    elif isinstance(weights, list):
        # The original bridge presents Erlang tuples as bounded text. Display
        # that text directly; the viewer never parses or evaluates Erlang terms.
        weight_text = ' '.join(
            f'{label(item[0])}={label(item[1])}' if isinstance(item, (list, tuple)) and len(item) == 2
            else label(item) for item in weights[:2])
    else:
        weight_text = 'unavailable'
    rows = [
        f'Mode       {label(provider.get("mode", "unavailable"))}',
        f'Transport  {label(provider.get("transport", "disposable"))}',
        f'Profile    {label(options.get("profile", "unavailable"))}',
        f'Strategy   {label(options.get("strategy", "unavailable"))}',
        f'Weights    {weight_text}',
        f'Requests {count(stats, "requests")} · changed {count(stats, "changed")}',
        f'Skips {count(stats, "skips")} · fallback {count(stats, "fallbacks")}',
        f'Errors {count(stats, "errors")} · timeout {count(stats, "timeouts")}',
        f'Cancelled  {count(stats, "cancelled")}',
    ]
    session = stats.get('session', {})
    if not isinstance(session, dict):
        session = {}
    rows.append('Worker {} · VM starts {} · recycles {} · requests {}'.format(
        label(session.get('state', 'disabled')),
        count(session, 'vm_starts'), count(session, 'restarts'),
        count(session, 'completed_requests')))
    phase = stats.get('phase_us', {})
    request_samples = phase.get('request_total_us', []) if isinstance(phase, dict) else []
    request_samples = sorted(v for v in request_samples[:1024]
                             if type(v) is int and v >= 0) if isinstance(request_samples, list) else []
    if request_samples:
        p50 = request_samples[(len(request_samples) - 1) * 50 // 100] / 1000
        p95 = request_samples[(len(request_samples) - 1) * 95 // 100] / 1000
        rows.append(f'Request p50/p95 {p50:.2f}/{p95:.2f} ms · n={len(request_samples)}')
    samples = stats.get('latency_us', [])
    samples = sorted(value for value in samples[:1024]
                     if type(value) is int and value >= 0) if isinstance(samples, list) else []
    if samples:
        # These are a bounded provider-request sample, not target latencies or
        # percentiles over every request in an unlimited campaign.
        p50 = samples[(len(samples) - 1) * 50 // 100] / 1000
        p95 = samples[(len(samples) - 1) * 95 // 100] / 1000
        rows += [f'Latency sample {len(samples)} · dropped {count(stats, "latency_samples_dropped")}',
                 f'ms p50 {p50:.2f} · p95 {p95:.2f}']
    else:
        rows += ['Latency sample unavailable', 'ms p50 ? · p95 ?']
    rows.append('Discoveries / retained')
    for source in ('native', 'erlamsa'):
        discoveries = stats.get('discoveries', {})
        retained = stats.get('retained', {})
        discoveries = discoveries if isinstance(discoveries, dict) else {}
        retained = retained if isinstance(retained, dict) else {}
        rows.append(f'{source} {count(discoveries, source)} / {count(retained, source)}')
    reasons = stats.get('skip_reasons', {})
    rows.append('Skip reasons (up to 4)')
    if isinstance(reasons, dict):
        observed = [(str(key), value) for key, value in reasons.items()
                    if type(value) is int and value >= 0]
        observed.sort(key=lambda item: (-item[1], item[0]))
        rows += [f'{label(key)}: {value:,}' for key, value in observed[:4]] or ['None recorded']
    else:
        rows.append('Unavailable')
    return rows


class Samples:
    def __init__(self):
        self.rate = deque(maxlen=120)
        self.coverage = deque(maxlen=120)
        self.previous = None

    def update(self, snap):
        elapsed = snap.get('elapsed_ms', 0)
        stats = snap.get('stats', {})
        count = stats.get('executions', 0) + stats.get('calibrations', 0)
        if self.previous:
            old_ms, old_count = self.previous
            if elapsed <= old_ms:
                return
            self.rate.append(max(0, count - old_count) * 1000 / (elapsed - old_ms))
        self.coverage.append(snap.get('coverage_count', 0))
        self.previous = elapsed, count


def read_snapshot(directory):
    path = directory / 'snapshot.json'
    if path.stat().st_size > 1024 * 1024:
        raise ValueError('Snapshot exceeds 1 MiB')
    snap = json.loads(path.read_text())
    if snap.get('schema_version') != 1:
        raise ValueError('Unsupported snapshot schema')
    return snap


def screen(stdscr, directory, process=None):
    try:
        curses.curs_set(0)
        curses.use_default_colors()
    except curses.error:
        pass
    stdscr.timeout(150)
    if curses.has_colors():
        curses.init_pair(1, curses.COLOR_CYAN, -1)
    accent = curses.color_pair(1) | curses.A_BOLD
    snap, error = {}, ''
    samples = Samples()
    pinned = None
    offset = 0
    last_read = 0
    sample_changed = time.monotonic()
    sample_stamp = None
    show_provider = False

    def put(y, x, text, attr=0):
        h, w = stdscr.getmaxyx()
        if 0 <= y < h and 0 <= x < w - 1:
            try:
                stdscr.addnstr(y, x, clean(text), w - x - 1, attr)
            except curses.error:
                pass

    while True:
        if time.monotonic() - last_read >= .5:
            try:
                snap = read_snapshot(directory)
                samples.update(snap)
                stamp = (snap.get("elapsed_ms"), snap.get("status"))
                if stamp != sample_stamp:
                    sample_changed = time.monotonic()
                    sample_stamp = stamp
                error = ''
            except (OSError, ValueError, TypeError) as exc:
                error = str(exc)
            last_read = time.monotonic()
        h, w = stdscr.getmaxyx()
        stdscr.erase()
        stats = snap.get('stats', {})
        provider = provider_lines(snap)
        bridge_status = process.poll() if process is not None else None
        status = snap.get('status', 'waiting')
        if bridge_status is not None and (bridge_status != 0 or status in ('running', 'waiting')):
            status = f'BRIDGE EXIT {bridge_status}; see campaign.log'
        put(0, 1, f"EFZ / {snap.get('target', 'campaign')}     {status}     "
            f"{snap.get('elapsed_ms', 0) / 1000:.1f}s", accent)
        if w < 90 or h < 26:
            put(3, 1, 'Resize to at least 90 columns × 26 rows. Campaign continues.')
        else:
            split = max(34, min(46, w // 3))
            for y in range(2, h - 3):
                put(y, split, '│')
            left_width = split - 3
            if provider and show_provider:
                put(2, 1, 'MUTATION PROVIDER', accent)
                for row, line in enumerate(provider, 4):
                    if row < h - 3:
                        put(row, 1, line[:left_width])
            else:
                rate = samples.rate[-1] if samples.rate else 0
                put(2, 1, f'EXECUTIONS / SECOND    {rate:.1f}', accent)
                put(4, 1, chart(samples.rate, left_width))
                covered, total = snap.get('coverage_count', 0), snap.get('coverage_total', 0)
                coverage = f'{covered} {snap.get("coverage_unit", "units")}'
                if total:
                    coverage += f' / {total} ({covered / total:.0%})'
                put(6, 1, 'COVERAGE  ' + coverage, accent)
                put(8, 1, chart(samples.coverage, left_width))
                limit = snap.get('max_iterations', '∞')
                if limit == 'infinity':
                    limit = '∞'
                put(10, 1, f"Mutations   {stats.get('executions', 0):,} / {limit}")
                put(11, 1, f"Calibration {stats.get('calibrations', 0):,}")
                put(12, 1, f"Corpus      {snap.get('corpus_size', 0):,}")
                put(13, 1, f"Findings    {stats.get('unique_crashes', 0)} unique / {stats.get('crashes', 0)} events")
                counts = snap.get('outcomes', {})
                for row, key, label in [(15, 'returned', 'Returned value'), (16, 'codec_rejected', 'Codec rejected'),
                                        (17, 'target_rejected', 'Target rejected'), (18, 'exception', 'Exceptions'),
                                        (19, 'timeout', 'Timeouts')]:
                    put(row, 1, f'{label:<17} {counts.get(key, 0):,}')
                if provider:
                    current_provider = snap.get('provider', {})
                    mode_name = current_provider.get('mode', 'native') if isinstance(current_provider, dict) else 'native'
                    put(21, 1, ('Provider · ' + str(mode_name))[:left_width], accent)
                    put(22, 1, provider[4][:left_width])
            last = pinned if pinned is not None else snap.get('last')
            preview_size = len((last or {}).get("preview_hex", "")) // 2
            offset = min(offset, max(0, (preview_size - 1) // 16 * 16))
            x = split + 2
            source = (last or {}).get('mutation_source')
            source_text = f' · {source}' if source else ''
            put(2, x, 'INPUT · ' + ('PINNED' if pinned is not None else 'LAST COMPLETED') + source_text, accent)
            if last:
                put(3, x, f"{last['bytes']} bytes · {last['phase']} · parent #{last['parent']}")
                put(4, x, 'Preview: first 512 bytes' if last.get('truncated') else 'HEX / ASCII')
            for row, line in enumerate(input_lines(last, offset, max(1, min(8, h - 18))), 6):
                put(row, x, line)
            put(h - 11, x, 'OUTCOME', accent)
            if last:
                put(h - 10, x, last.get('outcome_class', 'unknown'))
                put(h - 9, x, last.get('outcome', ''))
            functions = (last or {}).get('functions', [])
            scope = 'LAST EXECUTION'
            if not functions and pinned is None:
                functions = snap.get('covered_functions', [])
                scope = 'CUMULATIVE COVERAGE'
            put(h - 7, x, 'FUNCTIONS · ' + scope, accent)
            for row, func in enumerate(functions[:3] or ['Unavailable for this backend / no probes reached'], h - 6):
                put(row, x, func)
        controls = 'Space Freeze input   ↑↓ Scroll   s Stop + save   q Detach'
        if provider:
            controls += '   p Provider' if not show_provider else '   p Overview'
        put(h - 2, 1, controls, accent)
        age = time.monotonic() - sample_changed
        stale = f'Sample unchanged {age:.0f}s; worker may be busy · ' if age > 2 and status == 'running' else ''
        put(h - 1, 1, error or (stale + str(directory)))
        stdscr.refresh()
        key = stdscr.getch()
        if key in (ord('q'), ord('Q')):
            return
        if provider and key in (ord('p'), ord('P')):
            show_provider = not show_provider
        if key in (ord('s'), ord('S')):
            try:
                (directory / 'stop.request').touch(exist_ok=True)
            except OSError as exc:
                error = str(exc)
        if key == ord(' '):
            pinned = None if pinned is not None else snap.get('last')
            offset = 0
        if key == curses.KEY_DOWN:
            offset = min(496, offset + 16)
        if key == curses.KEY_UP:
            offset = max(0, offset - 16)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--config', type=Path, help='Launch a trusted Erlang campaign map')
    mode.add_argument('--demo', action='store_true', help='Instrument and run the bundled demonstration target')
    mode.add_argument('--attach', type=Path, help='Monitor an existing TUI output directory')
    parser.add_argument('--continuous', action='store_true', help='Run the demo without an execution limit')
    parser.add_argument('--out', type=Path, help='New output directory for --config')
    parser.add_argument('--code-path', type=Path, action='append', default=[])
    args = parser.parse_args()
    if args.continuous and not args.demo:
        parser.error('--continuous applies to --demo; set max_iterations => infinity in your config')
    if (args.config or args.demo) and not args.out:
        parser.error('--config / --demo require --out')
    if args.attach and (args.out or args.code_path):
        parser.error('--out / --code-path apply only to --config')
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        parser.error('An interactive terminal is required')
    process = None
    directory = (args.out or args.attach).resolve()
    if args.config or args.demo:
        if args.config and not args.config.is_file():
            parser.error('Config file does not exist')
        try:
            directory.mkdir(parents=True, exist_ok=False)
        except FileExistsError:
            parser.error('Output directory must be new')
        command = ['escript', str(ROOT / 'scripts/tui_bridge.escript'), ('--demo-continuous' if args.continuous else '--demo') if args.demo else str(args.config.resolve()),
                   str(directory), *(str(p.resolve()) for p in args.code_path)]
        with (directory / 'campaign.log').open('w') as log:
            process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True, stdin=subprocess.DEVNULL)
    elif not directory.is_dir():
        parser.error('Attach directory does not exist')
    try:
        curses.wrapper(screen, directory, process)
    except KeyboardInterrupt:
        pass
    print(f'Monitor closed. Campaign output: {directory}')
    if process is not None and process.poll() is None:
        print(f'Campaign continues (PID {process.pid}); reattach with --attach {directory}')


if __name__ == '__main__':
    main()
