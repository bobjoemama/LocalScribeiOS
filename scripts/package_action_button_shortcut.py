#!/usr/bin/env python3
"""Check the shipped shortcut, or explicitly re-sign its reviewed source with Apple."""
import argparse
import copy
import json
import plistlib
import struct
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'scripts/shortcuts/LocalScribe Action Button.wflow'
SIGNED = ROOT / 'Resources/shortcuts/LocalScribe Action Button.shortcut'


def run(*args, input=None):
    return subprocess.run(args, input=input, capture_output=True, check=True).stdout


def decode_signed(path):
    data = path.read_bytes()
    if data[:4] != b'AEA1':
        raise ValueError('Shortcut is not an Apple signed archive')
    profile, size = struct.unpack_from('<II', data, 4)
    if profile != 0:
        raise ValueError('Shortcut is not a sign-only archive')
    auth = plistlib.loads(data[12:12 + size])
    leaf = auth['SigningCertificateChain'][0]
    with tempfile.TemporaryDirectory(prefix='localscribe-shortcut-check-') as temp:
        directory = Path(temp)
        cert = directory / 'leaf.der'
        cert.write_bytes(leaf)
        pem = run('openssl', 'x509', '-inform', 'DER', '-in', str(cert), '-pubkey', '-noout')
        public = run('openssl', 'pkey', '-pubin', '-outform', 'DER', input=pem)
        # DER SubjectPublicKeyInfo for prime256v1, followed by the public EC point.
        prefix = bytes.fromhex('3059301306072a8648ce3d020106082a8648ce3d030107034200')
        if public[:len(prefix)] != prefix or len(public) != len(prefix) + 65:
            raise ValueError('Signing certificate does not have a P-256 public key')
        key = directory / 'leaf-public.hex'
        key.write_text('hex:' + public[len(prefix):].hex())
        payload = directory / 'payload.aa'
        run('aea', 'decrypt', '-i', str(path), '-o', str(payload), '-sign-pub', str(key))
        extracted = directory / 'extracted'
        extracted.mkdir()
        run('aa', 'extract', '-i', str(payload), '-d', str(extracted))
        files = list(extracted.glob('*.wflow'))
        if len(files) != 1:
            raise ValueError('Expected exactly one workflow in signed archive')
        return plistlib.loads(files[0].read_bytes())


def check_recipe(workflow):
    actions = workflow['WFWorkflowActions']
    if len(actions) != 5:
        raise ValueError('Expected one intent, If, Copy, Otherwise and End If')
    intent, condition, copy, otherwise, end = actions
    descriptor = intent['WFWorkflowActionParameters']['AppIntentDescriptor']
    assert intent['WFWorkflowActionIdentifier'] == descriptor['BundleIdentifier'] + '.' + descriptor['AppIntentIdentifier']
    assert descriptor['AppIntentIdentifier'] == 'ToggleDictationShortcut'
    result_uuid = intent['WFWorkflowActionParameters']['UUID']
    params = condition['WFWorkflowActionParameters']
    assert condition['WFWorkflowActionIdentifier'] == 'is.workflow.actions.conditional'
    assert params['WFCondition'] == 100 and params['WFControlFlowMode'] == 0
    attachment = params['WFInput']['Variable']
    assert params['WFInput']['Type'] == 'Variable'
    assert attachment['WFSerializationType'] == 'WFTextTokenAttachment'
    assert attachment['Value']['Type'] == 'ActionOutput'
    assert attachment['Value']['OutputUUID'] == result_uuid
    assert copy['WFWorkflowActionIdentifier'] == 'is.workflow.actions.setclipboard'
    assert copy['WFWorkflowActionParameters']['WFInput'] == attachment
    assert copy['WFWorkflowActionParameters']['WFLocalOnly'] is True
    for action, mode in [(otherwise, 1), (end, 2)]:
        assert action['WFWorkflowActionIdentifier'] == 'is.workflow.actions.conditional'
        tail = action['WFWorkflowActionParameters']
        assert tail['WFControlFlowMode'] == mode
        assert tail['GroupingIdentifier'] == params['GroupingIdentifier']
    assert workflow['WFWorkflowImportQuestions'] == []
    return descriptor


def check_fixtures(source):
    expected_body = copy.deepcopy(source['WFWorkflowActions'][1:])
    expected_body[0]['WFWorkflowActionParameters']['WFInput']['Variable']['Value']['OutputName'] = 'Text'
    expected_body[1]['WFWorkflowActionParameters']['WFInput']['Value']['OutputName'] = 'Text'
    result_uuid = source['WFWorkflowActions'][0]['WFWorkflowActionParameters']['UUID']
    for name, text in [('Native Guard Empty', ''), ('Native Guard Nonempty', 'LocalScribe packaging fixture')]:
        fixture = plistlib.loads((SOURCE.parent / 'fixtures' / (name + '.wflow')).read_bytes())
        actions = fixture['WFWorkflowActions']
        assert actions[0] == {
            'WFWorkflowActionIdentifier': 'is.workflow.actions.gettext',
            'WFWorkflowActionParameters': {'UUID': result_uuid, 'WFTextActionText': text},
        }
        assert actions[1:] == expected_body, 'Fixture differs from shipped conditional/copy bindings'


def check_app(bundle, descriptor, require_bundled=False):
    info = plistlib.loads((bundle / 'Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == descriptor['BundleIdentifier'], 'App bundle ID differs'
    actions = json.loads((bundle / 'Metadata.appintents/extract.actionsdata').read_text())['actions']
    action = actions[descriptor['AppIntentIdentifier']]
    assert action['identifier'] == descriptor['AppIntentIdentifier']
    assert action['parameters'] == []
    assert action['title']['key'] == 'Dictate and Copy'
    assert action['outputType'] == {'primitive': {'wrapper': {'typeIdentifier': 0}}}, 'Intent must return String'
    assert action['openAppWhenRun'] is False
    entitlements = run('codesign', '-d', '--entitlements', ':-', str(bundle))
    if entitlements.strip():
        team = plistlib.loads(entitlements).get('com.apple.developer.team-identifier')
        if team:
            assert team == descriptor['TeamIdentifier'], 'Signed app team differs'
    bundled = bundle / 'shortcuts/LocalScribe Action Button.shortcut'
    if require_bundled or bundled.exists():
        assert bundled.read_bytes() == SIGNED.read_bytes(), 'Bundled shortcut differs from signed resource'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app-bundle', type=Path, help='Check exact compiled intent, bundle ID and signing team')
    parser.add_argument('--require-bundled', action='store_true', help='Also require the built app to include the exact signed resource')
    parser.add_argument('--sign', action='store_true', help='Submit only the static recipe to Apple iCloud for Anyone signing')
    args = parser.parse_args()
    if args.sign and args.require_bundled:
        parser.error("Re-sign before building; check the bundled resource after rebuilding")
    if args.require_bundled and not args.app_bundle:
        parser.error("--require-bundled requires --app-bundle")
    source = plistlib.loads(SOURCE.read_bytes())
    descriptor = check_recipe(source)
    check_fixtures(source)
    if args.app_bundle:
        check_app(args.app_bundle, descriptor, args.require_bundled)
    if args.sign:
        if not args.app_bundle:
            parser.error('--sign requires --app-bundle to validate the app action identity first')
        SIGNED.parent.mkdir(parents=True, exist_ok=True)
        run('shortcuts', 'sign', '--mode', 'anyone', '--input', str(SOURCE), '--output', str(SIGNED))
    decoded = decode_signed(SIGNED)
    assert decoded == source, 'Signed payload differs from reviewed source'
    check_recipe(decoded)
    print('PASS: signed payload matches reviewed five-action recipe and explicit output bindings')
    if args.app_bundle:
        print('PASS: compiled app intent result type, identity and signature match shortcut descriptor')
    if args.require_bundled:
        print('PASS: built app includes the exact signed shortcut resource')
    print('Apple import acceptance and physical iPhone execution require separate verification.')


if __name__ == '__main__':
    main()
