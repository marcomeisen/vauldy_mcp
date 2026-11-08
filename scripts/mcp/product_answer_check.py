#!/usr/bin/env python3
"""Validate structured answers against saved synthetic MCP evidence and a fixed oracle.

This checks the supplied answer object, not arbitrary surrounding prose or a live LLM.
"""
import argparse
import json
from pathlib import Path
from product_acceptance import validate_answer


def check_answers(packets, answers):
    assert len({p['question']['id'] for p in packets})==len(packets),'Duplicate oracle IDs'
    expected={p['question']['id']:p for p in packets}
    assert len({a['id'] for a in answers})==len(answers),'Duplicate answer IDs'
    assert {a['id'] for a in answers}==set(expected),'Missing or unexpected answers'
    for answer in answers:
        packet=expected[answer['id']]
        pages={(p['document'],p['page']):p['text'] for p in packet['pages']}
        assert len(pages)==len(packet['pages']),'Duplicate evidence pages'
        validate_answer(packet['question'],answer,pages)
    return dict(passed=True,answers=len(answers),scope='structured answers only; no live ChatGPT test')


def main():
    if not __debug__:raise SystemExit('Run without Python -O: assertions are acceptance checks')
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('packets',type=Path)
    parser.add_argument('answers',type=Path,help='JSON array with exactly one structured answer per question')
    args=parser.parse_args()
    try:report=check_answers(json.loads(args.packets.read_text()),json.loads(args.answers.read_text()))
    except (AssertionError,KeyError,ValueError,TypeError) as error:
        print(json.dumps(dict(passed=False,error=str(error)),ensure_ascii=False));raise SystemExit(1)
    print(json.dumps(report,ensure_ascii=False))


if __name__=='__main__':main()
