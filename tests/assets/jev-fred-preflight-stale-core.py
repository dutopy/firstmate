#!/usr/bin/env python3
"""A deliberately stale shared-core stand-in for the wrapper boundary tests.

It exposes the same ``guard()``/``Verdict`` surface the real ``jev_decide`` core
exposes, but answers with whatever confidence ``FM_JV_STALE_CONFIDENCE`` names
(default ``nan``) and whatever class ``FM_JV_STALE_ROUTE`` names (default
``routine_reversible``). It never touches the network.

The pre-flight classifier tests point ``FM_JV_FRED_PREFLIGHT_CORE`` at this file
to prove that a stale core cannot push a non-finite or out-of-range confidence
past the wrapper boundary, independent of whatever the real shared core
currently does. The real core already refuses such a confidence, so this asset
is the only way to exercise the wrapper's own validation on its own.
"""
from __future__ import annotations

import os
from enum import Enum


class Verdict(str, Enum):
    PROCEED = "proceed"
    ASK_HUMAN = "ask_human"
    BLOCK = "block"


class _Decision:
    def __init__(self, verdict, confidence, route, reason="ok"):
        self.verdict = verdict
        self.confidence = confidence
        self.route = route
        self.reason = reason


def guard(unused_state, unused_criteria, **unused_kwargs):
    confidence = float(os.environ.get("FM_JV_STALE_CONFIDENCE", "nan"))
    route = os.environ.get("FM_JV_STALE_ROUTE", "routine_reversible")
    return _Decision(Verdict.PROCEED, confidence, route)


def ask(unused_state, unused_questions, **unused_kwargs):
    raise RuntimeError("the stale core never answers ask()")
