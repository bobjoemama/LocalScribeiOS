import asyncio
import base64
import json
import math
import os
import unittest
from unittest.mock import patch
import collector


def code(payload=None):
    value = payload or {'version': 1, 'port': 43210, 'token': base64.urlsafe_b64encode(bytes(32)).decode().rstrip('=')}
    return 'LSM1-' + base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')

class DecodeTests(unittest.TestCase):
    def test_pairing_code(self):
        self.assertEqual(collector.decode_pairing_code(code())['port'], 43210)
        for value in ('LSM1-!', '', code({'version': True, 'port': 42, 'token': 'abc'})):
            with self.assertRaises(collector.CollectorError):
                collector.decode_pairing_code(value)

    def test_pid_filter_and_unknown(self):
        row = {'Processes': {42: [0.25, 4096], 77: [99, 99999]}}
        metrics = collector.decode_sysmon(row, 42, ['cpuUsage', 'physFootprint'], [])
        self.assertEqual(metrics['appCPUPercent'], 25)
        self.assertEqual(metrics['appMemoryBytes'], 4096)
        self.assertIsNone(metrics['gpuDevicePercent'])
        self.assertIsNone(collector.decode_sysmon(row, 43, ['cpuUsage', 'physFootprint'], [])['appCPUPercent'])

    def test_invalid_numbers_and_zero(self):
        for value in (True, -1, float('nan'), float('inf'), '10'):
            self.assertIsNone(collector.number(value))
        self.assertEqual(collector.decode_graphics({'Device Utilization %': 0})['gpuDevicePercent'], 0)
        self.assertIsNone(collector.decode_graphics({})['gpuDevicePercent'])

    def test_remote_usbmux_and_forced_tcp_rejected(self):
        for env in ({'USBMUXD_SOCKET_ADDRESS': 'host:27015'}, {'PYMOBILEDEVICE3_USERSPACE_TCP_RELAY': '1'}):
            with patch.dict(os.environ, env, clear=True):
                with self.assertRaises(collector.CollectorError):
                    collector.validate_environment()

class FakeWriter:
    def __init__(self):
        self.data = bytearray()
    def write(self, value):
        self.data.extend(value)
    async def drain(self):
        await asyncio.sleep(0)

class AsyncTests(unittest.IsolatedAsyncioTestCase):
    async def test_authentication(self):
        reader = asyncio.StreamReader()
        reader.feed_data(b'{"type":"ready","version":1,"appPID":42}\n')
        writer = FakeWriter()
        self.assertEqual(await collector.authenticate(reader, writer, 'secret'), 42)
        self.assertEqual(json.loads(writer.data), {'type': 'authenticate', 'token': 'secret'})

    async def test_authentication_rejects_bad_pid(self):
        reader = asyncio.StreamReader()
        reader.feed_data(b'{"type":"ready","version":1,"appPID":true}\n')
        with self.assertRaises(collector.CollectorError):
            await collector.authenticate(reader, FakeWriter(), 'secret')

    async def test_socket_wait_cancellation(self):
        reader = asyncio.StreamReader()
        task = asyncio.create_task(collector.authenticate(reader, FakeWriter(), 'secret'))
        await asyncio.sleep(0)
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task


class WireTests(unittest.TestCase):
    def test_load_percent_units_and_array(self):
        row = {'EnabledCPUs': 2, 'SystemCPUUsage': {'CPU_TotalLoad': 75},
               'PerCPUUsage': [{'CPU_TotalLoad': 25}, {'CPU_TotalLoad': 50}]}
        metrics = collector.decode_sysmon(row, 42, [], [])
        self.assertEqual(metrics['systemCPUPercent'], 37.5)
        self.assertEqual(metrics['systemCPUCoresPercent'], [25, 50])
        self.assertEqual(collector.sample_payload(1, metrics)['systemCPUCoresPercent'], [25, 50])

    def test_known_load_component_schema(self):
        metrics = collector.decode_sysmon({'EnabledCPUs': 0, 'CPUCount': 2,
            'SystemCPUUsage': {'CPU_UserLoad': 40, 'CPU_SystemLoad': 10},
            'PerCPUUsage': [{'CPU_UserLoad': 20, 'CPU_SystemLoad': 5}]}, 42, [], [])
        self.assertEqual(metrics['systemCPUPercent'], 25)
        self.assertEqual(metrics['systemCPUCoresPercent'], [25])

    def test_fraction_schema(self):
        metrics = collector.decode_sysmon({'SystemCPUUsage': {'CPU_User': .2, 'CPU_System': .1},
                                         'CPUUsage': [.1, .75]}, 42, [], [])
        self.assertAlmostEqual(metrics['systemCPUPercent'], 30)
        self.assertEqual(metrics['systemCPUCoresPercent'], [10, 75])

    def test_invalid_core_rejects_whole_array(self):
        for cores in ([{'CPU_TotalLoad': 101}], [{'CPU_TotalLoad': -1}], [True], []):
            self.assertIsNone(collector.decode_sysmon({'PerCPUUsage': cores}, 42, [], [])['systemCPUCoresPercent'])
        self.assertIsNone(collector.decode_sysmon({'CPUUsage': [.1, 2]}, 42, [], [])['systemCPUCoresPercent'])

    def test_wire_rejects_invalid_types_ranges(self):
        base = {key: None for key in collector.FIELDS}
        for key, value in [('systemCPUCoresPercent', 40), ('systemCPUCoresPercent', [101]),
                           ('gpuDevicePercent', 101), ('displayFPS', float('nan')),
                           ('appMemoryBytes', 1.5), ('appCPUPercent', True)]:
            with self.assertRaises(collector.CollectorError):
                collector.sample_payload(1, {**base, key: value})
        for seq in (True, 0, -1, 2**64):
            with self.assertRaises(collector.CollectorError):
                collector.sample_payload(seq, base)
        for value in (float('inf'), 10**1000):
            self.assertIsNone(collector.number(value))

class CleanupTests(unittest.IsolatedAsyncioTestCase):
    async def test_cancel_unwinds_phone_and_dvt_contexts(self):
        import types
        import sys
        entered, exited = [], []
        class Context:
            def __init__(self, name): self.name = name
            async def __aenter__(self):
                entered.append(self.name)
                return self
            async def __aexit__(self, *args): exited.append(self.name)
            async def sysmon_process_attributes(self): return ['cpuUsage', 'physFootprint']
            async def sysmon_system_attributes(self): return ['cpuUsage']
            def __aiter__(self): return self
            async def __anext__(self):
                await asyncio.Future()
        class Writer(FakeWriter):
            closed = False
            def close(self): self.closed = True
            async def wait_closed(self): pass
        writer = Writer()
        reader = asyncio.StreamReader()
        reader.feed_data(b'{"type":"ready","version":1,"appPID":42}\n')
        sock = types.SimpleNamespace(close=lambda: None)
        async def connect(*args, **kwargs): return sock
        device = types.SimpleNamespace(serial='DEVICEID', connection_type='USB', connect=connect)
        async def select_device(**kwargs): return device
        async def open_connection(**kwargs): return reader, writer
        usbmux = types.SimpleNamespace(select_device=select_device)
        module_defs = {
            'pymobiledevice3': {'usbmux': usbmux},
            'pymobiledevice3.remote': {'userspace_tunnel': types.SimpleNamespace(UserspaceRsdTunnel=lambda **kwargs: Context('tunnel'))},
            'pymobiledevice3.services.dvt.instruments.dvt_provider': {'DvtProvider': lambda rsd: Context('dvt')},
            'pymobiledevice3.services.dvt.instruments.device_info': {'DeviceInfo': lambda dvt: Context('info')},
            'pymobiledevice3.services.dvt.instruments.sysmontap': {'Sysmontap': lambda *args, **kwargs: Context('tap')},
            'pymobiledevice3.services.dvt.instruments.graphics': {'Graphics': lambda dvt: Context('graphics')},
        }
        modules = {}
        for name, attrs in module_defs.items():
            module = types.ModuleType(name)
            module.__dict__.update(attrs)
            modules[name] = module
        with patch.dict(sys.modules, modules), patch.dict(os.environ, {}, clear=True), patch.object(collector.asyncio, 'open_connection', open_connection), patch.object(collector, 'status'):
            task = asyncio.create_task(collector.collect('DEVICEID', {'port': 43210, 'token': 'secret'}))
            for _ in range(20):
                await asyncio.sleep(0)
                if 'graphics' in entered: break
            self.assertIn('tap', entered)
            task.cancel()
            with self.assertRaises(asyncio.CancelledError): await task
        self.assertTrue(writer.closed)
        self.assertEqual(exited[-2:], ['dvt', 'tunnel'])
        self.assertLess(exited.index('tap'), exited.index('dvt'))
        self.assertLess(exited.index('graphics'), exited.index('dvt'))
        self.assertIn('graphics', exited)


class TickerTests(unittest.IsolatedAsyncioTestCase):
    async def test_silent_sysmon_does_not_block_live_gpu_one_hz(self):
        exited = []
        class Silent:
            async def __aenter__(self): return self
            async def __aexit__(self, *args): exited.append('sysmon')
            def __aiter__(self): return self
            async def __anext__(self): await asyncio.Future()
        class Live(Silent):
            async def __aexit__(self, *args): exited.append('graphics')
            async def __anext__(self):
                await asyncio.sleep(.02)
                return {'Device Utilization %': 17, 'CoreAnimationFramesPerSecond': 30}
        writer = FakeWriter()
        reader = asyncio.StreamReader()
        with patch.object(collector, 'status'):
            task = asyncio.create_task(collector.stream_metrics(None, 42, [], [], reader, writer,
                lambda *args, **kwargs: Silent(), lambda dvt: Live()))
            await asyncio.sleep(2.15)
            task.cancel()
            with self.assertRaises(asyncio.CancelledError): await task
        samples = [json.loads(line) for line in writer.data.splitlines()]
        self.assertEqual(len(samples), 2)
        self.assertEqual([sample['sequence'] for sample in samples], [1, 2])
        self.assertTrue(all(sample['gpuDevicePercent'] == 17 for sample in samples))
        self.assertTrue(all(sample['appCPUPercent'] is None for sample in samples))
        self.assertCountEqual(exited, ['sysmon', 'graphics'])

    async def test_failed_sysmon_keeps_gpu_and_stale_gpu_expires(self):
        class Failing:
            async def __aenter__(self): raise RuntimeError('unsupported')
            async def __aexit__(self, *args): pass
        class Once:
            sent = False
            async def __aenter__(self): return self
            async def __aexit__(self, *args): pass
            def __aiter__(self): return self
            async def __anext__(self):
                if self.sent: await asyncio.Future()
                self.sent = True
                return {'Device Utilization %': 9}
        writer = FakeWriter()
        with patch.object(collector, 'status') as status:
            with self.assertRaisesRegex(collector.CollectorError, 'No device measurements'):
                await collector.stream_metrics(None, 42, [], [], asyncio.StreamReader(), writer,
                    lambda *args, **kwargs: Failing(), lambda dvt: Once(), interval=.01,
                    freshness=.035, unavailable_timeout=.06)
        samples = [json.loads(line) for line in writer.data.splitlines()]
        self.assertGreaterEqual(len(samples), 2)
        self.assertTrue(all(sample['gpuDevicePercent'] == 9 for sample in samples))
        self.assertIn(unittest.mock.call('sysmonUnavailable'), status.call_args_list)
        self.assertIn(unittest.mock.call('metricsUnavailable'), status.call_args_list)

    async def test_stream_setup_timeout_does_not_wait_forever(self):
        class Hung:
            async def __aenter__(self): await asyncio.Future()
            async def __aexit__(self, *args): pass
        with patch.object(collector, 'status'):
            with self.assertRaisesRegex(collector.CollectorError, 'No device measurements'):
                await collector.stream_metrics(None, 42, [], [], asyncio.StreamReader(), FakeWriter(),
                    lambda *args, **kwargs: Hung(), lambda dvt: Hung(), interval=.01,
                    unavailable_timeout=.05, setup_timeout=.02)

if __name__ == '__main__':
    unittest.main()
