#!/usr/bin/env python3
"""Explicit USB-only, finite LocalScribe DVT collector. No dependency imports at import time."""
import argparse
import asyncio
import base64
import contextlib
import json
import logging
import math
import os
import re
import signal
import sys

FIELDS = ('gpuDevicePercent', 'gpuRendererPercent', 'gpuTilerPercent', 'displayFPS',
          'systemCPUPercent', 'systemCPUCoresPercent', 'appCPUPercent', 'appMemoryBytes')
SYSTEM_ATTRIBUTES = ('cpuUsage',)

class CollectorError(Exception):
    pass

def number(value):
    if not isinstance(value, (int, float)) or isinstance(value, bool) or value < 0:
        return None
    try:
        return value if math.isfinite(value) else None
    except OverflowError:
        return None

def percent(value):
    value = number(value)
    return value if value is not None and value <= 100 else None

def decode_pairing_code(code):
    if not isinstance(code, str) or len(code) > 2048 or not code.startswith('LSM1-'):
        raise CollectorError('Invalid pairing code. Copy a fresh code from the iPhone.')
    def decode(text):
        if not re.fullmatch(r'[A-Za-z0-9_-]+', text):
            raise ValueError()
        return base64.b64decode(text + '=' * (-len(text) % 4), altchars=b'-_', validate=True)
    try:
        payload = json.loads(decode(code[5:]))
        if set(payload) != {'version', 'port', 'token'} or type(payload['version']) is not int or payload['version'] != 1:
            raise ValueError()
        if type(payload['port']) is not int or not 1024 <= payload['port'] <= 65535:
            raise ValueError()
        if not isinstance(payload['token'], str) or len(decode(payload['token'])) != 32:
            raise ValueError()
        return payload
    except (ValueError, TypeError, KeyError):
        raise CollectorError('Invalid pairing code. Copy a fresh code from the iPhone.') from None

def validate_environment():
    if os.environ.get('USBMUXD_SOCKET_ADDRESS') not in (None, '', '/var/run/usbmuxd'):
        raise CollectorError('Custom usbmux sockets are disabled. Unset USBMUXD_SOCKET_ADDRESS.')
    if any(os.environ.get(key) for key in ('PYMOBILEDEVICE3_USERSPACE_TCP_RELAY', 'PMD3_USERSPACE_TCP_RELAY')):
        raise CollectorError('TCP tunnel relay is disabled. Unset PYMOBILEDEVICE3_USERSPACE_TCP_RELAY.')

def decode_sysmon(row, pid, process_attributes, system_attributes):
    result = {key: None for key in FIELDS}
    if not isinstance(row, dict):
        return result
    processes = row.get('Processes')
    if isinstance(processes, dict):
        values = processes.get(pid, processes.get(str(pid)))
        if isinstance(values, (list, tuple)) and len(values) == len(process_attributes):
            attrs = dict(zip(process_attributes, values))
            cpu = number(attrs.get('cpuUsage'))
            result['appCPUPercent'] = cpu * 100 if cpu is not None else None
            memory = number(attrs.get('physFootprint'))
            result['appMemoryBytes'] = int(memory) if memory is not None else None
    usage = row.get('SystemCPUUsage')
    enabled = row.get('EnabledCPUs', row.get('CPUCount'))
    if type(enabled) is int and enabled == 0:
        enabled = row.get('CPUCount')
    if isinstance(usage, dict):
        # The Load schema reports percent summed across enabled cores.
        total = number(usage.get('CPU_TotalLoad'))
        if total is None:
            user, system = number(usage.get('CPU_UserLoad')), number(usage.get('CPU_SystemLoad'))
            if user is not None and system is not None:
                total = user + system
        if total is not None and type(enabled) is int and enabled > 0:
            result['systemCPUPercent'] = percent(total / enabled)
        elif 'CPU_User' in usage and 'CPU_System' in usage:
            # This separate schema uses normalized fractions, never Load units.
            user, system = number(usage.get('CPU_User')), number(usage.get('CPU_System'))
            if user is not None and system is not None:
                result['systemCPUPercent'] = percent((user + system) * 100)
    cores = row.get('PerCPUUsage')
    if isinstance(cores, (list, tuple)) and cores:
        values = []
        for core in cores:
            value = percent(core.get('CPU_TotalLoad')) if isinstance(core, dict) else None
            if value is None and isinstance(core, dict):
                user, system = number(core.get('CPU_UserLoad')), number(core.get('CPU_SystemLoad'))
                if user is not None and system is not None:
                    value = percent(user + system)
            values.append(value)
        if all(value is not None for value in values):
            result['systemCPUCoresPercent'] = values
    elif isinstance(row.get('CPUUsage'), (list, tuple)) and row['CPUUsage']:
        fractions = [number(value) for value in row['CPUUsage']]
        if all(value is not None and value <= 1 for value in fractions):
            result['systemCPUCoresPercent'] = [value * 100 for value in fractions]
    return result

def decode_graphics(row):
    if not isinstance(row, dict):
        return {}
    mapping = {'Device Utilization %': 'gpuDevicePercent', 'Renderer Utilization %': 'gpuRendererPercent',
               'Tiler Utilization %': 'gpuTilerPercent', 'CoreAnimationFramesPerSecond': 'displayFPS'}
    return {field: (number(row.get(key)) if field == 'displayFPS' else percent(row.get(key))) for key, field in mapping.items()}

def sample_payload(sequence, metrics):
    if type(sequence) is not int or not 0 < sequence < 2**64:
        raise CollectorError('Invalid metrics sequence.')
    if set(metrics) != set(FIELDS):
        raise CollectorError('Invalid metrics fields.')
    for key, value in metrics.items():
        if value is None:
            continue
        if key == 'systemCPUCoresPercent':
            if not isinstance(value, list) or not value or any(percent(item) is None for item in value):
                raise CollectorError('Invalid CPU core metrics.')
        elif key == 'appMemoryBytes':
            if type(value) is not int or not 0 <= value < 2**64:
                raise CollectorError('Invalid app memory metrics.')
        elif key in ('gpuDevicePercent', 'gpuRendererPercent', 'gpuTilerPercent', 'systemCPUPercent'):
            if percent(value) is None:
                raise CollectorError('Invalid utilization metrics.')
        elif number(value) is None:
            raise CollectorError('Invalid metrics values.')
    return {'type': 'sample', 'version': 1, 'sequence': sequence, **metrics}

async def send(writer, payload):
    writer.write(json.dumps(payload, allow_nan=False, separators=(',', ':')).encode() + b'\n')
    await writer.drain()

async def authenticate(reader, writer, token):
    await send(writer, {'type': 'authenticate', 'token': token})
    try:
        raw = await asyncio.wait_for(reader.readline(), 10)
        if not raw or len(raw) > 8192:
            raise ValueError()
        ready = json.loads(raw)
        if not isinstance(ready, dict):
            raise ValueError()
        pid = ready.get('appPID')
        if ready.get('type') != 'ready' or type(ready.get('version')) is not int or ready.get('version') != 1 or type(pid) is not int or not 0 < pid <= 2147483647:
            raise ValueError()
        return pid
    except (ValueError, asyncio.TimeoutError):
        raise CollectorError('Phone authentication failed. Keep LocalScribe open and copy a fresh pairing code.') from None

def status(state):
    print(json.dumps({'type': 'status', 'state': state}), flush=True)

async def stream_metrics(dvt, pid, process_attrs, system_attrs, reader, writer, sysmon_factory, graphics_factory,
                         interval=1.0, freshness=3.0, unavailable_timeout=15.0, setup_timeout=10.0):
    """Independent producers; the ticker never waits for a Sysmontap event."""
    latest = {}
    loop = asyncio.get_running_loop()
    def update(metrics):
        now = loop.time()
        for key, value in metrics.items():
            if key in FIELDS:
                latest[key] = (value, now)
    async def sysmon_loop():
        try:
            async with contextlib.AsyncExitStack() as stack:
                tap = await asyncio.wait_for(stack.enter_async_context(sysmon_factory(dvt, process_attrs, system_attrs, interval_ms=1000)), setup_timeout)
                async for row in tap:
                    decoded = decode_sysmon(row, pid, process_attrs, system_attrs)
                    # System and process rows arrive separately; update each row's own fields.
                    keys = ('appCPUPercent', 'appMemoryBytes') if isinstance(row, dict) and 'Processes' in row else ('systemCPUPercent', 'systemCPUCoresPercent')
                    update({key: decoded[key] for key in keys})
        except Exception:
            update({'appCPUPercent': None, 'appMemoryBytes': None, 'systemCPUPercent': None, 'systemCPUCoresPercent': None})
            status('sysmonUnavailable')
    async def graphics_loop():
        try:
            async with contextlib.AsyncExitStack() as stack:
                graphics = await asyncio.wait_for(stack.enter_async_context(graphics_factory(dvt)), setup_timeout)
                async for row in graphics:
                    update(decode_graphics(row))
        except Exception:
            update({key: None for key in ('gpuDevicePercent', 'gpuRendererPercent', 'gpuTilerPercent', 'displayFPS')})
            status('graphicsUnavailable')
    async def phone_closed():
        await reader.read(1)
        raise CollectorError('Phone connection ended. Start a new session in LocalScribe.')
    async def ticker():
        sequence = 0
        last_measurement = loop.time()
        unavailable = False
        while True:
            await asyncio.sleep(interval)
            now = loop.time()
            metrics = {key: latest[key][0] if key in latest and now - latest[key][1] <= freshness else None for key in FIELDS}
            if all(value is None for value in metrics.values()):
                if not unavailable:
                    status('metricsUnavailable')
                    unavailable = True
                if now - last_measurement >= unavailable_timeout:
                    raise CollectorError('No device measurements arrived. Check Developer Mode and Xcode device preparation, then reconnect.')
                continue
            last_measurement = now
            if unavailable or sequence == 0:
                status('collecting')
                unavailable = False
            sequence += 1
            await send(writer, sample_payload(sequence, metrics))
    tasks = [asyncio.create_task(coro()) for coro in (sysmon_loop, graphics_loop, phone_closed, ticker)]
    try:
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_EXCEPTION)
        for task in done:
            task.result()
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

async def collect(udid, pairing):
    validate_environment()
    from pymobiledevice3 import usbmux
    from pymobiledevice3.remote import userspace_tunnel
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
    from pymobiledevice3.services.dvt.instruments.sysmontap import Sysmontap
    from pymobiledevice3.services.dvt.instruments.graphics import Graphics
    device = await usbmux.select_device(udid=udid, connection_type='USB', usbmux_address='/var/run/usbmuxd')
    if device is None or device.serial != udid or device.connection_type != 'USB':
        raise CollectorError('The selected USB device is unavailable. Connect and trust it in Finder first.')
    sock = await device.connect(pairing['port'], usbmux_address='/var/run/usbmuxd')
    writer = None
    try:
        reader, writer = await asyncio.open_connection(sock=sock, limit=8192)
        pid = await authenticate(reader, writer, pairing['token'])
        status('connecting')
        async with userspace_tunnel.UserspaceRsdTunnel(serial=udid, autopair=False, remotepairing_fallback=False) as rsd:
            async with DvtProvider(rsd) as dvt:
                async with DeviceInfo(dvt) as info:
                    available_process = await info.sysmon_process_attributes()
                    available_system = await info.sysmon_system_attributes()
                process_attrs = [key for key in ('cpuUsage', 'physFootprint') if key in available_process]
                system_attrs = [key for key in SYSTEM_ATTRIBUTES if key in available_system]
                await stream_metrics(dvt, pid, process_attrs, system_attrs, reader, writer, Sysmontap, Graphics)
    finally:
        if writer is not None:
            writer.close()
            with contextlib.suppress(Exception):
                await asyncio.wait_for(writer.wait_closed(), 3)
        else:
            sock.close()

async def list_usb():
    validate_environment()
    from pymobiledevice3 import usbmux
    devices = await usbmux.list_devices(usbmux_address='/var/run/usbmuxd')
    print(json.dumps([{'udid': device.serial, 'name': 'iPhone'} for device in devices if device.connection_type == 'USB']), flush=True)

async def probe(udid):
    validate_environment()
    from pymobiledevice3 import usbmux
    from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
    from pymobiledevice3.services.dvt.instruments.sysmontap import Sysmontap
    from pymobiledevice3.services.dvt.instruments.graphics import Graphics
    device = await usbmux.select_device(udid=udid, connection_type='USB', usbmux_address='/var/run/usbmuxd')
    if device is None or device.serial != udid or device.connection_type != 'USB':
        raise CollectorError('The selected USB device is unavailable.')
    report = {'type': 'capabilities', 'version': 1, 'processAttributes': [], 'systemAttributes': [], 'availableFields': []}
    async with UserspaceRsdTunnel(serial=udid, autopair=False, remotepairing_fallback=False) as rsd:
        async with DvtProvider(rsd) as dvt:
            async with DeviceInfo(dvt) as info:
                process_attrs = [key for key in ('cpuUsage', 'physFootprint') if key in await info.sysmon_process_attributes()]
                system_attrs = [key for key in SYSTEM_ATTRIBUTES if key in await info.sysmon_system_attributes()]
            report['processAttributes'] = process_attrs
            report['systemAttributes'] = system_attrs
            observed = set()
            async def sysmon():
                async with Sysmontap(dvt, [], system_attrs, interval_ms=1000) as tap:
                    async for row in tap:
                        metrics = decode_sysmon(row, -1, [], system_attrs)
                        observed.update(key for key, value in metrics.items() if value is not None)
            async def graphics():
                try:
                    async with Graphics(dvt) as stream:
                        async for row in stream:
                            observed.update(key for key, value in decode_graphics(row).items() if value is not None)
                except Exception:
                    pass
            tasks = [asyncio.create_task(sysmon()), asyncio.create_task(graphics())]
            try:
                await asyncio.sleep(3)
                # Sysmon setup errors are material; an unsupported graphics channel is optional.
                if tasks[0].done():
                    tasks[0].result()
            finally:
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
            report['availableFields'] = sorted(observed)
    print(json.dumps(report), flush=True)

async def run(udid=None, pairing=None, operation=None):
    task = asyncio.current_task()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, task.cancel)
    try:
        if operation is not None:
            await operation
        else:
            await collect(udid, pairing)
    finally:
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.remove_signal_handler(sig)

def main():
    parser = argparse.ArgumentParser(description='Collect LocalScribe metrics over explicit USB. Pairing code is read from stdin.')
    parser.add_argument('--udid')
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--list-usb', action='store_true')
    modes.add_argument('--probe', action='store_true')
    args = parser.parse_args()
    if not args.list_usb and (not args.udid or not re.fullmatch(r'[A-Za-z0-9-]{8,64}', args.udid)):
        parser.error('Invalid device identifier')
    logging.disable(logging.CRITICAL)
    try:
        validate_environment()
        if args.list_usb:
            asyncio.run(run(operation=list_usb()))
        elif args.probe:
            asyncio.run(run(operation=probe(args.udid)))
        else:
            pairing = decode_pairing_code(sys.stdin.readline(2049).strip())
            asyncio.run(run(args.udid, pairing))
    except (asyncio.CancelledError, KeyboardInterrupt):
        status('stopped')
        return 0
    except CollectorError as error:
        print(str(error), file=sys.stderr)
        status('failed')
        return 1
    except Exception:
        print('Metrics connection failed. Check USB trust, Developer Mode, iOS 17.4 or later, and Xcode device preparation. No automatic pairing or setup was attempted.', file=sys.stderr)
        status('failed')
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())
