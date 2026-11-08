#!/usr/bin/env python3
"""Artifact-integrity tests; pass the completed synthetic benchmark root explicitly."""
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

from local_idp_comparison import evaluate

FIXTURES = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else None


@unittest.skipUnless(FIXTURES and FIXTURES.is_dir(), 'Explicit completed synthetic benchmark required')
class IntegrityTests(unittest.TestCase):
    def stage(self, root):
        (root/'source').symlink_to(FIXTURES/'source', target_is_directory=True)
        (root/'inputs').mkdir()
        for image in (FIXTURES/'inputs').glob('*.png'):
            (root/'inputs'/image.name).symlink_to(image)
        (root/'results').mkdir()
        for folder in (FIXTURES/'results').iterdir():
            if folder.name != 'jev':
                (root/'results'/folder.name).symlink_to(folder, target_is_directory=folder.is_dir())
        (root/'results/jev').mkdir()
        shutil.copyfile(FIXTURES/'results/jev/report.json', root/'results/jev/report.json')

    def test_changed_source_image_cannot_be_scored(self):
        with tempfile.TemporaryDirectory(prefix='vauldy-idp-tamper-') as tmp:
            root = Path(tmp); self.stage(root)
            image = root/'inputs/clean.png'; image.unlink(); image.write_bytes(b'changed synthetic image')
            with self.assertRaisesRegex(AssertionError, 'Frozen image changed: clean.png'):
                evaluate(root)

    def test_score_for_different_text_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix='vauldy-idp-score-') as tmp:
            root = Path(tmp); self.stage(root)
            path = root/'results/jev/report.json'; data = json.loads(path.read_text())
            data['cases'][0]['textSHA256'] = '0' * 64; path.write_text(json.dumps(data))
            with self.assertRaisesRegex(AssertionError, 'Score/text binding changed'):
                evaluate(root)


if __name__ == '__main__':
    unittest.main()
