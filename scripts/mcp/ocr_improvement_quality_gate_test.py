import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from ocr_improvement_quality_gate import evaluate


class ImprovementGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.manifest = dict(truth={}, sha256={})
        self.baseline = dict(inputHashes={}, pages={})
        for index in range(35):
            name = f'{index:02}.png'
            fields = [f'Field {index}:{j}' for j in range(3 if index < 9 else 2)]
            self.manifest['truth'][name] = fields
            (self.root / name).write_bytes(name.encode())
            self.manifest['sha256'][name] = hashlib.sha256(name.encode()).hexdigest()
        self.baseline['inputHashes'] = copy.deepcopy(self.manifest['sha256'])
        remaining = 52
        for name, fields in self.manifest['truth'].items():
            count = min(remaining, len(fields)); remaining -= count
            page = dict(text='\n'.join(fields[:count]), info=dict(needsReview=True))
            self.baseline['pages'][name] = page
            self.write(name, page)
        self.gain_name = next(n for n, f in self.manifest['truth'].items()
                              if len(self.baseline['pages'][n]['text'].splitlines()) < len(f))

    def write(self, name, page):
        for suffix in ['.json', '.fresh.json']:
            (self.root / (name + suffix)).write_text(json.dumps(page))

    def gain(self):
        page = copy.deepcopy(self.baseline['pages'][self.gain_name])
        fields = self.manifest['truth'][self.gain_name]
        extra = next(f for f in fields if f not in page['text'])
        page['text'] += ('\n' if page['text'] else '') + extra
        self.write(self.gain_name, page)
        return page

    def report(self):
        return evaluate(self.root, self.manifest, self.baseline)

    def test_requires_real_gain(self):
        self.assertEqual(self.report()['qualityGate'], 'NO-GO')
        self.gain()
        self.assertEqual(self.report()['qualityGate'], 'GO')

    def test_rejects_changed_input(self):
        self.gain(); (self.root / '00.png').write_bytes(b'changed')
        with self.assertRaises(ValueError): self.report()

    def test_history_does_not_replace_correct_current_fields(self):
        self.gain()
        previous = self.baseline['pages']['00.png']['text']
        self.write('00.png', dict(text='', info=dict(needsReview=True),
                   geometry=dict(lines=[dict(priorReadings=previous.splitlines())])))
        self.assertEqual(self.report()['qualityGate'], 'NO-GO')

    def test_rejects_unexpected_text_even_with_gain(self):
        page = self.gain(); page['text'] += '\nInvented content'
        self.write(self.gain_name, page)
        self.assertEqual(self.report()['qualityGate'], 'NO-GO')

    def test_fresh_must_accept_gain_and_incomplete_must_be_marked(self):
        page = self.gain()
        path = self.root / (self.gain_name + '.fresh.json')
        path.write_text(json.dumps(self.baseline['pages'][self.gain_name]))
        self.assertEqual(self.report()['qualityGate'], 'NO-GO')
        self.write(self.gain_name, page)
        self.write('34.png', dict(text='', info=dict(needsReview=False)))
        self.assertEqual(self.report()['qualityGate'], 'NO-GO')


if __name__ == '__main__': unittest.main()
