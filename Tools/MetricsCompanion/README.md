# LocalScribe Metrics Companion collector

Optional Mac helper for the native companion in this folder. It connects to one explicitly selected, already trusted USB iPhone and sends numeric DVT metrics to LocalScribe's authenticated USB pipe. It does not launch apps, pair devices, mount developer images, restore devices, run privileged commands, or configure services.

Python 3.13 or 3.14 is required. `pymobiledevice3==11.23.0` and all transitive versions and artifact hashes are recorded in `uv.lock` and `requirements.lock`. Dependency installation must follow the reviewed dependency audit; resolution does not constitute an installation. Use the existing interpreter with `--no-python-downloads`. A wheel-only install should use the audited local wheel artifact for any upstream dependency that lacks an official wheel. Do not silently enable source builds.

After the audited environment exists:

```sh
.venv/bin/python collector.py --list-usb
.venv/bin/python collector.py --probe --udid DEVICE_ID
.venv/bin/python collector.py --udid DEVICE_ID
```

The collection command reads one pairing-code line from standard input. The native Mac UI supplies that line without including it in command arguments or logs. Do not paste pairing tokens into shell commands or recorded terminal sessions. The iPhone must keep LocalScribe open and have Developer Mode enabled, with device preparation completed using Xcode. The restricted userspace transport requires iOS 17.4 or later. Unsupported configurations fail without pairing or native-tunnel fallback.

The phone code is `LSM1-` followed by base64url JSON containing `version: 1`, `port`, and a base64url 32-byte token. The collector sends an authentication NDJSON message, expects `ready` with `version: 1` and `appPID`, then sends `sample` NDJSON with an increasing UInt64 `sequence`. Every sample contains nullable `gpuDevicePercent`, `gpuRendererPercent`, `gpuTilerPercent`, `displayFPS`, `systemCPUPercent`, `systemCPUCoresPercent`, `appCPUPercent`, and `appMemoryBytes`.

Only the authenticated app PID is decoded for process CPU and physical footprint. The minimal DVT process attributes are `cpuUsage` and `physFootprint`, filtered against device capabilities. Sysmontap emits system CPU usage separately. Normalized CPU fractions are converted to percent; app CPU can exceed 100%; each system CPU core is reported separately on a 0–100% scale. GPU counters are device-wide, and Core Animation FPS describes display activity. They do not identify LocalScribe's own GPU use. Missing, invalid, or stale values stay null; true reported zero stays zero.

Normal collection stdout contains only status JSON; stderr contains fixed actionable errors. Raw DVT events, other processes, and credentials are never printed. `--probe` samples only system/graphics streams for three seconds and prints supported allowlisted attribute names and available field names, without event payloads. `--list-usb` prints device identifiers for the local UI's explicit selection; it excludes network devices.

Custom usbmux endpoints and forced TCP relay configuration are rejected. The upstream userspace tunnel prefers a relay Unix socket in a private temporary directory; if Unix binding fails, upstream may use a loopback-only `127.0.0.1` relay. It never binds a LAN interface. The collector has no host network server of its own and does not advertise Bonjour. Closing the Mac helper sends SIGTERM, cancels streams, closes the phone pipe, and unwinds DVT and tunnel context managers. Nothing remains installed or running as a daemon.

Run dependency-free tests:

```sh
/opt/homebrew/bin/python3.13 -m unittest discover -s Tools/MetricsCompanion -v
```

Upstream API inspection used the exact [11.23.0 source](https://github.com/doronz88/pymobiledevice3/tree/v11.23.0), especially `remote/userspace_tunnel.py`, `usbmux.py`, and `services/dvt/instruments/{device_info,sysmontap,graphics,dvt_provider}.py`. Unit tests cover protocol validation, PID filtering, null/zero handling, forbidden transport overrides, and cancellation while waiting for phone authentication. They do not prove physical-device counter availability or cleanup of a live tunnel; that requires the separately authorized hardware session.

Upstream pymobiledevice3 is GPL-3.0-or-later; its complete license is retained in `pymobiledevice3-LICENSE.txt`. This source project keeps its existing Apache-2.0 license for original code, with dependency licensing separate. Preserve upstream source/license obligations when redistributing a combined runtime. The iPhone does not link this dependency.
