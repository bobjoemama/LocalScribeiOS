import json
import signal
import sys
import time

if '--list-usb' in sys.argv:
    print(json.dumps([{'udid': 'FIXTURE-USB', 'name': 'Fixture iPhone'}]), flush=True)
    sys.exit(0)
mode = sys.stdin.readline().strip()
print(json.dumps({'type': 'status', 'state': 'metricsUnavailable'}), flush=True)
if mode == 'diagnostic':
    print('Phone authentication failed. Keep LocalScribe open and copy a fresh pairing code.', file=sys.stderr, flush=True)
    print(json.dumps({'type': 'status', 'state': 'failed'}), flush=True)
    sys.exit(1)
if mode == 'private-diagnostic':
    print('token=LSM1-SECRET /Users/private/model.trace private transcript', file=sys.stderr, flush=True)
    sys.exit(1)
if mode == 'oversized-diagnostic':
    print('X' * 100000, file=sys.stderr, flush=True)
    print('Invalid pairing code. Copy a fresh code from the iPhone.', file=sys.stderr, flush=True)
    sys.exit(1)
if mode == 'graphics-unavailable':
    print(json.dumps({'type': 'status', 'state': 'graphicsUnavailable'}), flush=True)
    print(json.dumps({'type': 'status', 'state': 'collecting'}), flush=True)
if mode == 'exit':
    sys.exit(0)
if mode == 'ignore-term':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
time.sleep(60)
