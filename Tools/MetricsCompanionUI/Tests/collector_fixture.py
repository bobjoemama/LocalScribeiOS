import json
import signal
import sys
import time

if '--list-usb' in sys.argv:
    print(json.dumps([{'udid': 'FIXTURE-USB', 'name': 'Fixture iPhone'}]), flush=True)
    sys.exit(0)
mode = sys.stdin.readline().strip()
print(json.dumps({'type': 'status', 'state': 'metricsUnavailable'}), flush=True)
if mode == 'exit':
    sys.exit(0)
if mode == 'ignore-term':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
time.sleep(60)
