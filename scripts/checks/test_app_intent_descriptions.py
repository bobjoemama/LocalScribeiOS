"""Exercise generated App Intent description checks without modifying signed bundles."""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

SCRIPT = Path(__file__).resolve().parents[1] / 'package_action_button_shortcut.py'
SPEC = importlib.util.spec_from_file_location('shortcut_packaging', SCRIPT)
PACKAGING = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGING)

REJECTED = 'Finish this recording on your iPhone in the background. Your transcript is available in LocalScribe.'
FIXED = 'Finish this recording in the background. Your transcript is available in LocalScribe.'


def action(description):
    return {'descriptionMetadata': {'descriptionText': {'alternatives': [], 'key': description}, 'searchKeywords': []}}


class IntentDescriptionMetadataCheck(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='localscribe-intent-metadata-check-')
        self.addCleanup(self.temp.cleanup)
        self.bundle = Path(self.temp.name) / 'LocalScribe.app'
        self.widget = self.bundle / 'PlugIns/LocalScribeActivityWidget.appex'
        self.app_actions = {'StopLiveDictationIntent': action(FIXED)}
        self.write_widget({'StopLiveDictationIntent': action(FIXED)})

    def write_widget(self, actions):
        self.widget_metadata = self.widget / 'Metadata.appintents/extract.actionsdata'
        self.widget_metadata.parent.mkdir(parents=True, exist_ok=True)
        self.widget_metadata.write_text(json.dumps({'actions': actions}))

    def check(self):
        PACKAGING.check_app_intent_descriptions(self.bundle, self.app_actions)

    def test_rejects_both_app_and_widget_with_paths(self):
        self.app_actions['StopLiveDictationIntent'] = action(REJECTED)
        self.write_widget({'StopLiveDictationIntent': action(REJECTED)})
        with self.assertRaises(ValueError) as failure:
            self.check()
        message = str(failure.exception)
        self.assertEqual(message.count('prohibited description text'), 2)
        self.assertIn(f'{self.bundle}: intent StopLiveDictationIntent', message)
        self.assertIn(f'{self.widget}: intent StopLiveDictationIntent', message)
        self.assertEqual(message.count('descriptionMetadata.descriptionText.key:'), 2)

    def test_scans_all_description_string_leaves_case_insensitively(self):
        metadata = self.app_actions['StopLiveDictationIntent']['descriptionMetadata']
        metadata['descriptionText']['alternatives'] = [{'key': 'Use IPHONE'}]
        metadata['searchKeywords'] = ['iPhOnE']
        with self.assertRaises(ValueError) as failure:
            self.check()
        self.assertIn('descriptionMetadata.descriptionText.alternatives[0].key', str(failure.exception))
        self.assertIn('descriptionMetadata.searchKeywords[0]', str(failure.exception))

    def test_fixed_description_and_functional_names_pass(self):
        self.app_actions['ToggleDictationShortcut'] = action('Use Shortcuts with your Action Button and LocalScribe.')
        self.check()

    def test_missing_widget_metadata_fails(self):
        self.widget_metadata.unlink()
        with self.assertRaisesRegex(ValueError, 'LocalScribeActivityWidget.appex.*cannot read App Intent metadata'):
            self.check()

    def test_invalid_widget_json_fails(self):
        self.widget_metadata.write_text('{')
        with self.assertRaisesRegex(ValueError, 'cannot read App Intent metadata'):
            self.check()

    def test_empty_actions_fail(self):
        self.write_widget({})
        with self.assertRaisesRegex(ValueError, 'expected a nonempty actions object'):
            self.check()

    def test_missing_description_fails(self):
        self.app_actions['StopLiveDictationIntent'] = {}
        with self.assertRaisesRegex(ValueError, 'intent StopLiveDictationIntent: expected descriptionMetadata'):
            self.check()

    def test_invalid_description_text_schema_fails(self):
        self.app_actions['StopLiveDictationIntent']['descriptionMetadata']['descriptionText']['key'] = 17
        with self.assertRaisesRegex(ValueError, 'expected descriptionMetadata.descriptionText.key'):
            self.check()


if __name__ == '__main__':
    unittest.main()
