"""Benchmark safeguards and coordinate tests, without neural model inference."""
import argparse
import json
import math
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
from paddle_ocr_comparison import candidate_lines, prepare_image, run


class PaddleComparisonTests(unittest.TestCase):
    def test_scaled_polygons_keep_physical_source_coordinates(self):
        result={'rec_texts':['Beitrag: 82,47 EUR'],'rec_scores':[0.97],
                'rec_polys':[[[10,20],[40,20],[40,30],[10,30]]]}
        before=candidate_lines(result,100,100)
        scaled={**result,'rec_polys':[[[x*3,y*3] for x,y in polygon] for polygon in result['rec_polys']]}
        self.assertEqual(before,candidate_lines(scaled,300,300))
        self.assertEqual(before[0]['bounds'],[0.1,0.7,0.3,0.1])
        self.assertEqual(before[0]['text'],'Beitrag: 82,47 EUR')

    def test_invalid_observations_do_not_gain_confidence(self):
        with self.assertRaises(ValueError):
            candidate_lines({'rec_texts':['x'],'rec_scores':[],'rec_polys':[]},10,10)
        for score in [math.nan,-0.1,1.1]:
            with self.assertRaises(ValueError):
                candidate_lines({'rec_texts':['x'],'rec_scores':[score],'rec_polys':[[[0,0],[1,1]]]},10,10)

    def test_controller_keeps_virtual_environment_and_home(self):
        with tempfile.TemporaryDirectory(prefix='vauldy-paddle-controller-') as directory:
            root=Path(directory);python=root/'venv-python';python.symlink_to(sys.executable)
            args=argparse.Namespace(root=root,fixtures=root/'fixtures',output=root/'output',manifest=root/'manifest',python=python)
            original_home=os.environ.get('HOME')
            with patch('paddle_ocr_comparison.subprocess.run',return_value=types.SimpleNamespace(returncode=0)) as execute:
                self.assertEqual(run(args),0)
                command=execute.call_args.args[0]
                self.assertEqual(command[3],str(python.absolute()))
                self.assertNotEqual(command[3],str(python.resolve()))
                env=execute.call_args.kwargs['env']
                self.assertEqual(env.get('HOME'),original_home)
                self.assertEqual(env['PADDLE_PDX_CACHE_HOME'],str(root.resolve()/'paddlex-cache'))

    def test_preparation_preserves_original_bytes_and_pixel_values(self):
        from PIL import Image
        with tempfile.TemporaryDirectory(prefix='vauldy-paddle-pixels-') as directory:
            root=Path(directory);source=root/'source.png';target=root/'target.png'
            image=Image.new('L',(2,2));image.putdata([0,64,128,255]);image.save(source)
            original=source.read_bytes();prepare_image(source,target,'scale3')
            self.assertEqual(source.read_bytes(),original)
            with Image.open(target) as enlarged:
                self.assertEqual(enlarged.size,(6,6))
                self.assertEqual([enlarged.getpixel((x,y)) for y in range(6) for x in range(6)],
                    [0]*3+[64]*3+[0]*3+[64]*3+[0]*3+[64]*3+[128]*3+[255]*3+[128]*3+[255]*3+[128]*3+[255]*3)


if __name__=='__main__':unittest.main()
