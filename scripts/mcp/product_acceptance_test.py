#!/usr/bin/env python3
"""Exercise answer-quality gates with measured synthetic MCP evidence, not invented passes."""
import argparse
from copy import deepcopy
import json
from pathlib import Path
import unittest
from product_acceptance import money, render, validate_answer
from product_answer_check import check_answers


class AnswerQualityGates(unittest.TestCase):
    packets=[]
    rejected=[]

    def test_actual_reference_answers(self):
        report=check_answers(self.packets,[p['answer'] for p in self.packets])
        self.assertTrue(report['passed']);self.assertEqual(report['answers'],11)

    def test_wrong_answers_are_rejected(self):
        by_id={p['question']['id']:p for p in self.packets}
        def value(a):a['claims'][0]['value']='1500.00'
        def period(a):a['claims'][0]['period']='annual'
        def role(a):a['claims'][0]['field']='finalRate'
        def page(a):a['claims'][0]['evidence'][0]['page']=2
        def quote(a):a['claims'][0]['evidence'][0]['quote']='Monatliche Rate: 1500,00 EUR'
        def source(a):a['claims'][0]['evidence'][0]['source']='[Quelle:other:S.1]'
        def evidence(a):a['claims'][0]['evidence']=[]
        def negation(a):
            for c in a['claims']:c['value']=c['value'].replace('nicht mitversichert','mitversichert')
        def condition(a):a['claims']=[c for c in a['claims'] if 'bei abgeschlossenem Fahrrad' not in c['value']]
        def active(a):a['rows'][0]['status']='active-policy'
        def omit(a):a['rows'].pop()
        def duplicate(a):a['rows'][1]=deepcopy(a['rows'][0])
        def conflict(a):a['claims']=a['claims'][:1]
        def warning(a):a['warnings']=[]
        def absent(a):a['status']='no-contractual-notice-period'
        def guessed(a):a['status']='calculated'
        def injected(a):a['claims'][0]['value']='999.99'
        def prose(a):a['unvalidatedExplanation']='Alle Verträge sind aktuell gültig.'
        def method(a):a['claims'][0]['method']='guess'
        def question(a):a['question']='Eine andere Frage'
        cases=[('final-rate-instead-of-monthly','monthly_lease',value),('annual-vs-monthly','monthly_lease',period),
            ('cost-role','monthly_lease',role),('physical-page','monthly_lease',page),
            ('invented-quote','monthly_lease',quote),('foreign-source','monthly_lease',source),
            ('missing-evidence','monthly_lease',evidence),('lost-negation','conditions_summary',negation),
            ('lost-condition','conditions_summary',condition),('advert-is-active-contract','insurance_inventory',active),
            ('missing-topic-row','insurance_inventory',omit),('duplicate-topic-row','insurance_inventory',duplicate),
            ('suppressed-conflict','conflicting_rent',conflict),('suppressed-source-warning','conflicting_rent',warning),
            ('not-found-means-absent','missing_notice',absent),('guessed-incomplete-deadline','incomplete_source',guessed),
            ('document-instruction-as-answer','monthly_lease',injected),('unvalidated-prose','monthly_lease',prose),
            ('unsupported-date-method','cancel_lease',method),('wrong-question','monthly_lease',question)]
        for name,key,change in cases:
            with self.subTest(name=name):
                p=deepcopy(by_id[key]);change(p['answer'])
                pages={(v['document'],v['page']):v['text'] for v in p['pages']}
                with self.assertRaises((AssertionError,KeyError,ValueError)):
                    validate_answer(p['question'],p['answer'],pages)
                self.rejected.append(name)

    def test_complete_unique_answer_set_required(self):
        answers=[p['answer'] for p in self.packets]
        for invalid in [answers[:-1],answers+[answers[0]]]:
            with self.assertRaises(AssertionError):check_answers(self.packets,invalid)

    def test_amount_formatting_is_not_a_business_error(self):
        for text,wanted in [('144,00 EUR','144.00'),('144,00 €','144.00'),('1.500,00 EUR','1500.00'),(' 129,90  EUR ','129.90')]:
            self.assertEqual(money(text),wanted)
        # Strict frozen OCR literal tests remain separate and unchanged.
        for text in ['129,90 EUR oder 1500,00 EUR','kein Beitrag','129,90 USD']:
            with self.assertRaises(ValueError):money(text)

    def test_visible_topic_table_keeps_four_rows_and_uncertainty(self):
        answer=next(p['answer'] for p in self.packets if p['question']['id']=='insurance_inventory')
        text=render([answer])
        self.assertEqual(len([line for line in text.splitlines() if line.startswith('| ')]),5)
        self.assertIn('nicht bestätigt',text)
        self.assertIn('<br>',text)


def main():
    if not __debug__:raise SystemExit('Run without Python -O')
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--packets',type=Path,required=True);parser.add_argument('--report',type=Path)
    args=parser.parse_args();AnswerQualityGates.packets=json.loads(args.packets.read_text())
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(AnswerQualityGates))
    report=dict(passed=result.wasSuccessful(),tests=result.testsRun,rejectedMutations=AnswerQualityGates.rejected,
        rejectedMutationCount=len(AnswerQualityGates.rejected),scope='actual synthetic MCP packets; structured evaluator only')
    if args.report:args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(report,ensure_ascii=False))
    if not result.wasSuccessful():raise SystemExit(1)


if __name__=='__main__':main()
