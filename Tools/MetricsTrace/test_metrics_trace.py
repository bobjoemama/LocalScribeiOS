import tempfile
import json
import subprocess
import sys
import os
import signal
import time
import unittest
from pathlib import Path
import xml.etree.ElementTree as ET
from unittest.mock import patch
import metrics_trace as m


def table(schema='ane-hw-intervals', rows=None):
    root = ET.Element('trace-query-result')
    node = ET.SubElement(root, 'node')
    definition = ET.SubElement(node, 'schema', name=schema)
    for name in ['start', 'duration', 'channel-name', 'state']:
        ET.SubElement(ET.SubElement(definition, 'col'), 'mnemonic').text = name
    for start, duration, state in rows or []:
        row = ET.SubElement(node, 'row')
        ET.SubElement(row, 'start-time').text = str(start * 1_000_000)
        ET.SubElement(row, 'duration').text = str(duration * 1_000_000)
        ET.SubElement(row, 'ane-event-name').text = 'PERSONAL CHANNEL MUST NOT APPEAR'
        ET.SubElement(row, 'gpu-state', fmt=state).text = '1'
    return root


class MetricsTraceTests(unittest.TestCase):
    def test_union_overlaps_and_window_clipping(self):
        report = m.summarize([table(rows=[(0, 20, 'Active'), (10, 30, 'Running'), (45, 30, 'Busy'), (0, 100, 'Idle')])], 5, 45)
        self.assertEqual(report['ane']['activeMs'], 40)
        self.assertAlmostEqual(report['ane']['dutyCyclePercent'], 100 * 40 / 45)
        self.assertIsNone(report['gpu'])
        self.assertNotIn('PERSONAL', str(report))
        self.assertEqual(report['provenance'], 'trace-based (offline)')

    def test_gpu_separate_and_idle_is_zero(self):
        report = m.summarize([table(rows=[(0, 100, 'Idle')]), table('metal-gpu-intervals', [(0, 20, 'Active'), (20, 80, 'Idle')])], 0, 100)
        self.assertEqual(report['ane']['activeMs'], 0)
        self.assertEqual(report['gpu']['dutyCyclePercent'], 20)

    def test_unknown_state_fails_instead_of_guessing_numeric_codes(self):
        with self.assertRaises(ValueError):
            m.summarize([table(rows=[(0, 20, '1')])], 0, 100)

    def test_no_supported_schema_and_toc_fail(self):
        for root in [table('gpu-performance-state-intervals'), table(), ET.fromstring('<trace-toc><run number="1"><data><table schema="ane-hw-intervals"/></data></run></trace-toc>')]:
            with self.assertRaises(ValueError):
                m.summarize([root], 0, 100)

    def test_references_and_cycle(self):
        root = table(rows=[(0, 20, 'Active'), (50, 20, 'Active')])
        states = list(root.iter('gpu-state'))
        states[0].set('id', '42')
        states[1].attrib.clear()
        states[1].set('ref', '42')
        self.assertEqual(m.summarize([root], 0, 70)['ane']['activeMs'], 40)
        states[0].set('ref', '42')
        with self.assertRaises(ValueError):
            m.summarize([root], 0, 100)

    def test_bad_times_and_windows(self):
        for start, duration in [(float('nan'), 10), (0, float('inf')), (0, -1)]:
            with self.assertRaises(ValueError):
                m.summarize([table(rows=[(start, duration, 'Active')])], 0, 100)
        for start, duration in [(0, 0), (-1, 10), (0, float('nan'))]:
            with self.assertRaises(ValueError):
                m.summarize([table()], start, duration)

    def test_xml_budgets_and_entity_rejection(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'trace.xml'
            for payload in [b'<!DOCTYPE x [<!ENTITY a "b">]><x>&a;</x>', b'<x>\x00</x>']:
                path.write_bytes(payload)
                with self.assertRaises(ValueError):
                    m.parse_xml(path)
            path.write_bytes(b'<x>long</x>')
            with patch.object(m, 'MAX_XML_BYTES', 4), self.assertRaises(ValueError):
                m.parse_xml(path)

    def test_discovery_only_allowlisted_generated_xpath(self):
        with tempfile.TemporaryDirectory() as folder:
            trace = Path(folder) / 'chosen.trace'
            trace.mkdir()
            toc = ET.fromstring('<trace-toc><run number="1"><data><table schema="ane-hw-intervals"/><table schema="private-data"/></data></run></trace-toc>')
            with patch.object(m, 'export', side_effect=[toc, table()]) as export:
                self.assertEqual(len(m.load_trace(trace)), 1)
                self.assertEqual(export.call_count, 2)
                self.assertEqual(export.call_args.args[3], '/trace-toc/run[@number="1"]/data/table[@schema="ane-hw-intervals"]')

    def test_cli_json_and_refusal_to_overwrite(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'source.xml'
            output = Path(folder) / 'metricsReport1.json'
            ET.ElementTree(table(rows=[(0, 50, 'Active'), (50, 50, 'Idle')])).write(source)
            command = [sys.executable, str(Path(m.__file__)), str(source), '--start-ms', '0',
                       '--duration-ms', '100', '--output', str(output)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(output.read_text())
            self.assertEqual(set(report), {'schemaVersion', 'provenance', 'windowStartMs', 'durationMs',
                                          'scope', 'ane', 'gpu', 'sourceSchemas', 'countersUnavailable'})
            self.assertEqual(report['ane']['dutyCyclePercent'], 50)
            first = output.read_bytes()
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(output.read_bytes(), first)

    def test_toc_run_number_cannot_inject_xpath(self):
        with tempfile.TemporaryDirectory() as folder:
            trace = Path(folder) / 'chosen.trace'
            trace.mkdir()
            toc = ET.fromstring('<trace-toc><run number="bad"><data><table schema="ane-hw-intervals"/></data></run></trace-toc>')
            with patch.object(m, 'export', return_value=toc) as export:
                with self.assertRaises(ValueError):
                    m.load_trace(trace)
                self.assertEqual(export.call_count, 1)

    def test_multiple_runs_are_not_combined(self):
        with tempfile.TemporaryDirectory() as folder:
            trace = Path(folder) / 'chosen.trace'
            trace.mkdir()
            toc = ET.fromstring('<trace-toc><run number="1"><data><table schema="ane-hw-intervals"/></data></run><run number="2"><data><table schema="metal-gpu-intervals"/></data></run></trace-toc>')
            with patch.object(m, 'export', return_value=toc) as export:
                with self.assertRaises(ValueError):
                    m.load_trace(trace)
                self.assertEqual(export.call_count, 1)

    def test_sigterm_stops_only_owned_export_child_and_cleans_temp(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            trace = folder / 'chosen.trace'
            trace.mkdir()
            marker = folder / 'child.json'
            output = folder / 'existing.json'
            output.write_text('preserve existing report')
            fake = folder / 'fake-xctrace'
            fake.write_text('#!' + sys.executable + '\nimport json, os, sys, time\n'
                            'from pathlib import Path\n'
                            'destination = sys.argv[sys.argv.index("--output") + 1]\n'
                            'Path(os.environ["METRICS_TEST_MARKER"]).write_text(json.dumps([os.getpid(), destination]))\n'
                            'time.sleep(60)\n')
            fake.chmod(0o700)
            bootstrap = ('import sys; sys.path.insert(0, sys.argv.pop(1)); '
                         'import metrics_trace as m; m.XCTRACE = sys.argv.pop(1); m.main()')
            command = [sys.executable, '-c', bootstrap, str(Path(m.__file__).parent), str(fake),
                       str(trace), '--start-ms', '0', '--duration-ms', '100', '--output', str(output)]
            env = dict(os.environ, METRICS_TEST_MARKER=str(marker))
            parent = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            child_pid = None
            try:
                deadline = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline and parent.poll() is None:
                    time.sleep(0.01)
                self.assertTrue(marker.exists(), 'Fake exporter did not start')
                child_pid, destination = json.loads(marker.read_text())
                parent.send_signal(signal.SIGTERM)
                _, error = parent.communicate(timeout=5)
                self.assertEqual(parent.returncode, 130, error)
                with self.assertRaises(ProcessLookupError):
                    os.kill(child_pid, 0)
                self.assertFalse(Path(destination).parent.exists())
                self.assertEqual(output.read_text(), 'preserve existing report')
            finally:
                if parent.poll() is None:
                    parent.kill()
                parent.communicate(timeout=5)
                if child_pid is not None:
                    try:
                        os.kill(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_window_past_recording_rejects_instead_of_reporting_zero(self):
        with self.assertRaisesRegex(ValueError, 'entire selected window'):
            m.summarize([table(rows=[(0, 20, 'Active')])], 1000, 100)

    def test_window_straddling_export_edges_rejects(self):
        root = table(rows=[(10, 20, 'Idle')])
        for start, duration in [(0, 20), (20, 20), (0, 40)]:
            with self.assertRaisesRegex(ValueError, 'entire selected window'):
                m.summarize([root], start, duration)
        report = m.summarize([root], 10, 20)
        self.assertEqual(report['ane']['activeMs'], 0)

    def test_counter_coverage_is_independent(self):
        ane = table(rows=[(0, 20, 'Active')])
        gpu = table('metal-gpu-intervals', [(1000, 100, 'Idle')])
        report = m.summarize([ane, gpu], 1000, 100)
        self.assertIsNone(report['ane'])
        self.assertEqual(report['gpu']['activeMs'], 0)
        self.assertIn('ANE selected window extends beyond exported interval coverage', report['countersUnavailable'])


if __name__ == '__main__':
    unittest.main()
