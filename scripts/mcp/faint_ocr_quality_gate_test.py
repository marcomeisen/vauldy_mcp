"""Gate-policy tests with invented strings; these are NOT native OCR accuracy tests."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from faint_ocr_quality_gate import evaluate


class GatePolicyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='vauldy-faint-gate-')
        self.root = Path(self.temporary.name)
        self.truth = {f'{i}.png': [f'field-{i}-{j}' for j in range(3 if i < 9 else 2)] for i in range(35)}
        self.all_fields = [(name, value) for name, fields in self.truth.items() for value in fields]
        self.hashes = {}
        for name, fields in self.truth.items():
            source = ('synthetic gate test bytes ' + name).encode()
            (self.root / name).write_bytes(source)
            self.hashes[name] = hashlib.sha256(source).hexdigest()
            text = '\n'.join(value for n, value in self.all_fields[:52] if n == name)
            for suffix in ['.before.json', '.json']:
                self.write(name + suffix, {'text': text})
            self.write(name + '.diagnostics.json', {})
        self.manifest = {'truth': self.truth, 'sha256': self.hashes}

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, name, value):
        (self.root / name).write_text(json.dumps(value))

    def append(self, offset):
        name, value = self.all_fields[offset]
        file = self.root / (name + '.json')
        page = json.loads(file.read_text()); page['text'] += '\n' + value
        self.write(file.name, page)

    def test_fifty_two_is_no_go(self):
        self.assertEqual(evaluate(self.root, self.manifest)['qualityGate'], 'NO-GO')

    def test_fifty_three_can_pass_the_policy_only(self):
        self.append(52)
        self.assertEqual(evaluate(self.root, self.manifest)['qualityGate'], 'GO')

    def test_gain_cannot_hide_lost_evidence(self):
        self.append(52); self.append(53)
        name, value = self.all_fields[0]
        self.write(name + '.json', {'text': '\n'.join(self.truth[name][1:])})
        self.assertEqual(evaluate(self.root, self.manifest)['qualityGate'], 'NO-GO')

    def test_gain_cannot_hide_unexpected_words(self):
        self.append(52)
        name = self.all_fields[52][0]
        file = self.root / (name + '.json')
        self.write(file.name, {'text': json.loads(file.read_text())['text'] + '\nincorrect hallucinated addition'})
        self.assertEqual(evaluate(self.root, self.manifest)['qualityGate'], 'NO-GO')

    def test_frozen_input_cannot_be_substituted(self):
        self.append(52)
        (self.root / '0.png').write_bytes(b'replaced pixels')
        with self.assertRaises(ValueError): evaluate(self.root, self.manifest)


if __name__ == '__main__':
    unittest.main()
