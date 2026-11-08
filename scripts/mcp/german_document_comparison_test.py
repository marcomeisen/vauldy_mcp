#!/usr/bin/env python3
"""Scoring invariants and optional integrity checks against synthetic artifacts."""
import json,os
from pathlib import Path
import tempfile,unittest
from german_document_comparison import contains,normalize,md_tables,predicted_tables,evaluate

class ScoringTests(unittest.TestCase):
    def test_markup_is_normalized_without_repairing_umlauts_or_amounts(self):
        self.assertEqual(normalize('**Empfänger:** Jörg Müller'), 'Empfänger: Jörg Müller')
        self.assertEqual(normalize('<!-- image -->\n**Titel**'),'Titel')
        self.assertFalse(contains('Empfaenger: Jorg Muller','Empfänger: Jörg Müller'))
        self.assertFalse(contains('Beitrag: 82.47 EUR','Beitrag: 82,47 EUR'))

    def test_dates_keep_their_field_roles_and_values_keep_boundaries(self):
        self.assertFalse(contains('Geburtsdatum: 03.11.2026','Untersuchungsdatum: 03.11.2026'))
        self.assertFalse(contains('Aktenzeichen: AB-12345','Aktenzeichen: AB-1234'))

    def test_table_text_is_not_reordered_to_match_the_reference(self):
        text='| Fach | Note |\n|---|---|\n| Deutsch | gut |\n| Mathematik | ausreichend |'
        grid=md_tables(text)[0]
        self.assertEqual(grid,[['Fach','Note'],['Deutsch','gut'],['Mathematik','ausreichend']])
        self.assertNotEqual(grid,[['Fach','Note'],['Deutsch','ausreichend'],['Mathematik','gut']])

    def test_native_and_html_rowspans_keep_cell_positions(self):
        p={'text':'','markdown':'<table><tr><th>Art</th><th>Wert</th></tr><tr><td rowspan="2">A</td><td>1</td></tr><tr><td>2</td></tr></table>'}
        self.assertEqual(predicted_tables(p,'glm')[0],[['Art','Wert'],['A','1'],['A','2']])
        p={'tables':[{'data':{'num_rows':2,'num_cols':2,'table_cells':[{'start_row_offset_idx':0,'start_col_offset_idx':0,'row_span':2,'text':'A'},{'start_row_offset_idx':0,'start_col_offset_idx':1,'text':'1'},{'start_row_offset_idx':1,'start_col_offset_idx':1,'text':'2'}]}}]}
        self.assertEqual(predicted_tables(p,'docling-py')[0],[['A','1'],['A','2']])

FIXTURES=Path(os.environ['VAULDY_GERMAN_CORPUS_ROOT']) if os.environ.get('VAULDY_GERMAN_CORPUS_ROOT') else None
@unittest.skipUnless(FIXTURES and FIXTURES.is_dir(),'Explicit synthetic fixture root required')
class IntegrityTests(unittest.TestCase):
    def stage(self,root):
        (root/'source').symlink_to(FIXTURES/'source',target_is_directory=True)
        corpus=root/'corpus/frozen';(corpus/'pdf').mkdir(parents=True)
        for p in (FIXTURES/'corpus/frozen/pdf').glob('*.pdf'):(corpus/'pdf'/p.name).symlink_to(p)
        for name in ['manifest.json','requests.json','pages']:(corpus/name).symlink_to(FIXTURES/'corpus/frozen'/name,target_is_directory=name=='pages')
        (root/'results/apple').mkdir(parents=True)
        for p in (FIXTURES/'results/apple').glob('*.json'):(root/'results/apple'/p.name).symlink_to(p)

    def stage_other_results(self,root):
        for name in ['docling-py','docling-rs','glm','glm-table-mode']:
            (root/'results'/name).symlink_to(FIXTURES/'results'/name,target_is_directory=True)
        (root/'corpus/table-crops').symlink_to(FIXTURES/'corpus/table-crops',target_is_directory=True)
        (root/'renders').symlink_to(FIXTURES/'renders',target_is_directory=True)
        (root/'logs').symlink_to(FIXTURES/'logs',target_is_directory=True)
        (root/'results/jev-rendered.json').symlink_to(FIXTURES/'results/jev-rendered.json')
        (root/'results/jev').mkdir()
        path=root/'results/jev/report.json';path.write_text((FIXTURES/'results/jev/report.json').read_text());return path

    def test_changed_pdf_is_rejected_before_quality_scoring(self):
        with tempfile.TemporaryDirectory(prefix='vauldy-pdf-tamper-') as tmp:
            root=Path(tmp);self.stage(root);p=root/'corpus/frozen/pdf/doc-001.pdf';p.unlink();p.write_bytes(b'changed synthetic PDF')
            with self.assertRaisesRegex(AssertionError,'Frozen PDF changed'):evaluate(root)

    def test_lost_physical_page_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix='vauldy-page-loss-') as tmp:
            root=Path(tmp);self.stage(root);p=root/'results/apple/doc-003.json';data=json.loads(p.read_text());data['pages'].pop();p.unlink();p.write_text(json.dumps(data))
            with self.assertRaisesRegex(AssertionError,'Physical page coverage lost'):evaluate(root)

    def test_verifier_score_for_other_text_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix='vauldy-jev-text-') as tmp:
            root=Path(tmp);self.stage(root);path=self.stage_other_results(root);data=json.loads(path.read_text());data['cases'][0]['textSHA256']='0'*64;path.write_text(json.dumps(data))
            with self.assertRaisesRegex(AssertionError,'Jev score text binding changed'):evaluate(root)

    def test_invalid_verifier_probability_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix='vauldy-jev-probability-') as tmp:
            root=Path(tmp);self.stage(root);path=self.stage_other_results(root);data=json.loads(path.read_text());data['cases'][0]['probability']=1.1;path.write_text(json.dumps(data))
            with self.assertRaisesRegex(AssertionError,'Invalid Jev probability'):evaluate(root)

if __name__=='__main__':unittest.main()
