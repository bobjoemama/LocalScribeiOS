#!/usr/bin/env python3
"""Offline interval summarizer for selected, public xctrace XML exports."""
import argparse
import json
import math
import os
import signal
from pathlib import Path
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET

MAX_XML_BYTES = 64 * 1024 * 1024
MAX_ELEMENTS = 1_000_000
SCHEMAS = {'ane-hw-intervals': 'ane', 'metal-gpu-intervals': 'gpu'}
ACTIVE = {'active', 'running', 'busy'}
INACTIVE = {'idle', 'inactive', 'off', 'waiting', 'blocked'}
XCTRACE = '/Applications/Xcode.app/Contents/Developer/usr/bin/xctrace'


def parse_xml(path):
    with Path(path).open('rb') as f:
        data = f.read(MAX_XML_BYTES + 1)
    if len(data) > MAX_XML_BYTES:
        raise ValueError('XML exceeds the 64 MiB import budget; export a shorter recording.')
    if b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper() or b'\x00' in data:
        raise ValueError('DTD, entity declarations and non-UTF-8 XML are unsupported.')
    root = ET.fromstring(data)
    if sum(1 for _ in root.iter()) > MAX_ELEMENTS:
        raise ValueError('XML has too many elements; export a shorter recording.')
    return root


def finite(value):
    n = float(value)
    if not math.isfinite(n):
        raise ValueError('Times must be finite.')
    return n


def union_ms(intervals, start, end):
    total = 0.0
    cursor = start
    for a, b in sorted(intervals):
        a, b = max(a, start), min(b, end)
        if b > max(a, cursor):
            total += b - max(a, cursor)
            cursor = b
    return total


def summarize(roots, start_ms, duration_ms):
    start_ms, duration_ms = finite(start_ms), finite(duration_ms)
    if start_ms < 0 or duration_ms <= 0 or not math.isfinite(start_ms + duration_ms):
        raise ValueError('Choose a nonnegative start and positive finite duration.')
    intervals = {'ane': [], 'gpu': []}
    seen = set()
    observed = set()
    coverage = {'ane': None, 'gpu': None}
    unavailable = ['ANE/GPU throughput utilization', 'Occupied GPU core count', 'Per-process ANE/GPU attribution']
    for root in roots:
        refs = {e.get('id'): e for e in root.iter() if e.get('id')}
        def resolve(e):
            visited = set()
            while e.get('ref'):
                key = e.get('ref')
                if key in visited or key not in refs:
                    raise ValueError('Invalid XML cell reference.')
                visited.add(key)
                e = refs[key]
            return e
        for table in root.iter():
            schema = table.find('schema')
            name = schema.get('name') if schema is not None else table.get('schema')
            if name not in SCHEMAS:
                continue
            kind = SCHEMAS[name]
            if schema is None:
                continue  # A TOC is not a data export.
            columns = [c.findtext('mnemonic') or c.get('mnemonic') for c in schema.findall('col')]
            if not {'start', 'duration', 'state'}.issubset(columns):
                raise ValueError(f'{name} lacks supported start/duration/state columns.')
            seen.add(name)
            for row in table.findall('row'):
                observed.add(kind)
                cells = list(row)
                if len(cells) != len(columns):
                    raise ValueError('Export row does not match its schema.')
                selected = {key: resolve(cells[columns.index(key)]) for key in ('start', 'duration', 'state')}
                state = selected['state']
                label = (state.get('fmt') or state.text or '').strip().casefold()
                if label not in ACTIVE | INACTIVE:
                    raise ValueError(f'{name} has an unrecognized state; do not infer activity from numeric state codes.')
                # xctrace start-time and duration raw values use nanoseconds. Reject other engineering types.
                if selected['start'].tag != 'start-time' or selected['duration'].tag != 'duration':
                    raise ValueError('Unsupported time engineering type.')
                a = finite(selected['start'].text) / 1_000_000
                d = finite(selected['duration'].text) / 1_000_000
                if a < 0 or d < 0 or not math.isfinite(a + d):
                    raise ValueError('Invalid interval.')
                bounds = coverage[kind]
                coverage[kind] = ((a, a + d) if bounds is None
                                  else (min(bounds[0], a), max(bounds[1], a + d)))
                if label in ACTIVE:
                    intervals[kind].append((a, a + d))
    report = {'schemaVersion': 1, 'provenance': 'trace-based (offline)', 'windowStartMs': start_ms,
              'durationMs': duration_ms, 'scope': 'trace-wide; not attributed to LocalScribe',
              'ane': None, 'gpu': None, 'sourceSchemas': sorted(seen), 'countersUnavailable': unavailable}
    for kind in intervals:
        bounds = coverage[kind]
        if kind not in observed:
            unavailable.append(f'{kind.upper()} active interval rows absent from export')
        elif start_ms < bounds[0] or start_ms + duration_ms > bounds[1]:
            unavailable.append(f'{kind.upper()} selected window extends beyond exported interval coverage')
        else:
            active = union_ms(intervals[kind], start_ms, start_ms + duration_ms)
            report[kind] = {'activeMs': active, 'dutyCyclePercent': 100 * active / duration_ms}
    if report['ane'] is None and report['gpu'] is None:
        raise ValueError('No supported counter covers the entire selected window; choose a window within exported interval coverage.')
    return report


def export(trace, destination, mode, expression=None):
    args = [XCTRACE, 'export', '--input', str(trace), '--output', str(destination), mode]
    if expression is not None:
        args.append(expression)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    # Never use a shell or accept executable/XPath arguments from the caller.
    with tempfile.TemporaryFile() as errors:
        deadline = time.monotonic() + 120
        # Defer SIGTERM across spawn until the child object is owned by finally.
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
        process = None
        try:
            process = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=errors, env=env)
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
            while process.poll() is None:
                if (time.monotonic() > deadline or os.fstat(errors.fileno()).st_size > MAX_XML_BYTES
                        or (destination.exists() and destination.stat().st_size > MAX_XML_BYTES)):
                    raise ValueError('xctrace export exceeded its time or size budget.')
                time.sleep(0.05)
            if process.returncode:
                raise ValueError('xctrace export failed; check the trace in Instruments locally.')
        finally:
            signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
            if process is not None:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=5)
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    return parse_xml(destination)


def load_trace(path):
    if not path.is_dir() or path.suffix != '.trace':
        raise ValueError('Select an existing .trace bundle or exported .xml file.')
    with tempfile.TemporaryDirectory(prefix='localscribe-metrics-') as folder:
        folder = Path(folder)
        toc = export(path, folder / 'toc.xml', '--toc')
        discovered = []
        for run in toc.findall('run'):
            number = run.get('number', '')
            if not number.isdecimal():
                raise ValueError('Invalid run number in table of contents.')
            for table in run.findall('./data/table'):
                schema = table.get('schema')
                if schema in SCHEMAS:
                    discovered.append((number, schema))
        if len({number for number, _ in discovered}) > 1:
            raise ValueError('Multiple recording runs found; export one chosen run to XML in Instruments.')
        if len(discovered) > 64:
            raise ValueError('Too many supported tables; select a shorter trace.')
        roots = []
        total_bytes = 0
        for i, (number, schema) in enumerate(sorted(set(discovered))):
            xpath = f'/trace-toc/run[@number="{number}"]/data/table[@schema="{schema}"]'
            destination = folder / f'metrics-{i}.xml'
            root = export(path, destination, '--xpath', xpath)
            total_bytes += destination.stat().st_size if destination.exists() else 0
            if total_bytes > MAX_XML_BYTES:
                raise ValueError('Combined exports exceed the 64 MiB import budget.')
            roots.append(root)
        return roots


def main():
    # Native helpers terminate this process on Stop/Quit. Unwind export's
    # finally block so only our own child is stopped and temporary XML is removed.
    def terminate(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, terminate)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--start-ms', required=True, type=float, help='Explicit trace-relative analysis window start')
    parser.add_argument('--duration-ms', required=True, type=float, help='Explicit analysis window duration')
    parser.add_argument('--output', required=True, type=Path, help='New metricsReport1 JSON file (never overwrites)')
    args = parser.parse_args()
    try:
        path = args.input.resolve(strict=True)
        roots = [parse_xml(path)] if path.suffix.lower() == '.xml' and path.is_file() else load_trace(path)
        report = summarize(roots, args.start_ms, args.duration_ms)
        payload = json.dumps(report, indent=2, allow_nan=False) + '\n'
        with args.output.open('x', encoding='utf-8') as f:
            f.write(payload)
    except KeyboardInterrupt:
        parser.exit(130, 'Import cancelled.\n')
    except (ValueError, OSError, ET.ParseError) as error:
        parser.exit(1, f'Import failed: {error}\n')


if __name__ == '__main__':
    main()
