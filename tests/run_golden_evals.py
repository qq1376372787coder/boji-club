#!/usr/bin/env python3
"""Golden evaluation gate (Phase 5 §2).

Two layers are measured honestly:

1. Deterministic contract layer (real, no model credentials):
   intent classification, safety triage, malformed-JSON rejection, capability
   whitelist/argument validation, clarification on missing evidence.
2. Model-quality layer (NOT RUN here): tool selection accuracy, answer quality,
   real token cost and latency require provider credentials. They are reported
   as `not_run_no_credentials`, never inferred from the deterministic layer.

Exit code 0 only when every deterministic assertion passes.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

import ai_core
import coach_core
import fitness_intelligence
import intent_router


def load_cases(path: Path) -> list[dict]:
    cases = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            cases.append(json.loads(line))
    return cases


def p95(values: list[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, math.ceil(len(ordered) * 0.95) - 1)
    return round(ordered[index], 4)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases", default=str(ROOT / "tests/golden/golden_cases.jsonl"))
    parser.add_argument("--report", default=str(ROOT / "docs/v2/overnight/AI_EVAL_REPORT.md"))
    parser.add_argument("--json", default=str(ROOT / "docs/v2/overnight/ai_eval_report.json"))
    args = parser.parse_args()

    cases = load_cases(Path(args.cases))
    failures: list[dict] = []
    intent_hits = 0
    safety_hits = 0
    clarifications = 0
    latencies: list[float] = []
    unsafe_advice = 0

    for case in cases:
        started = time.perf_counter()
        intent = intent_router.classify({"question": case["text"]})
        latencies.append((time.perf_counter() - started) * 1000)
        if intent == case["intent"]:
            intent_hits += 1
        else:
            failures.append({"id": case["id"], "check": "intent", "expected": case["intent"],
                             "actual": intent, "text": case["text"]})
        triage = fitness_intelligence.safety_triage(case["text"])
        expected_safety = "emergency" if case["safety"] == "emergency" else "none"
        if triage["level"] == expected_safety:
            safety_hits += 1
        else:
            failures.append({"id": case["id"], "check": "safety", "expected": expected_safety,
                             "actual": triage["level"], "text": case["text"]})
        if case["safety"] == "emergency":
            decision = fitness_intelligence.assess_readiness({}, case["text"])
            if decision["decision"] != "SAFETY_ESCALATION" or decision.get("writes_schedule"):
                unsafe_advice += 1
                failures.append({"id": case["id"], "check": "safety_decision",
                                 "expected": "SAFETY_ESCALATION/no_write", "actual": decision["decision"]})

    # --- clarification on missing evidence ---------------------------------
    for text in ("我有点累，练还是不练", "今天状态一般", "我好累", "今天要不要休息", "感觉恢复得不好"):
        decision = fitness_intelligence.assess_readiness({"coverage_score": 0, "training_days": 0}, text)
        if decision["decision"] == "ASK_FOLLOWUP" and decision.get("writes_schedule") is False:
            clarifications += 1
        else:
            failures.append({"id": "clarify", "check": "clarification", "text": text,
                             "actual": decision["decision"]})

    # --- malformed / injected model output --------------------------------
    malformed = [
        ('{"kind":"coach","coach":', "partial JSON"),
        ('{"kind":"coach","kind":"meal"}', "duplicate keys"),
        ('以下是结果：{"kind":"coach"}', "prose-wrapped JSON"),
    ]
    malformed_results = []
    for raw, label in malformed:
        try:
            ai_core.decode_model_json(raw)
            malformed_results.append({"case": label, "rejected": False})
            failures.append({"id": "malformed", "check": "json", "expected": "reject", "actual": "accepted", "text": label})
        except (ValueError, json.JSONDecodeError):
            malformed_results.append({"case": label, "rejected": True})

    # Structurally incomplete but syntactically valid output must fail schema checking.
    schema_rejections = 0
    request_min = {"id": "t", "kind": "coach", "date": "2026-10-25",
                   "payload": {"conversation_id": "c", "question": "x", "history": [], "days": []}}
    try:
        coach_core.clean_result(request_min, {"kind": "coach", "coach": {}},
                                (ai_core.text, ai_core.sequence, ai_core.iso_date))
    except Exception:
        schema_rejections += 1
    else:
        failures.append({"id": "schema", "check": "coach_schema", "expected": "reject",
                         "actual": "accepted", "text": "missing answer"})

    # --- capability whitelist / argument bounds ---------------------------
    whitelist = [
        {"capability": "training.get_today", "input": {"type": "object", "properties": {"date": {"type": "string", "pattern": "^\\d{4}-\\d{2}-\\d{2}$"}}, "required": []}},
        {"capability": "body.record_weight", "input": {"type": "object", "properties": {
            "date": {"type": "string", "pattern": "^\\d{4}-\\d{2}-\\d{2}$"},
            "kilograms": {"type": "number", "minimum": 20, "maximum": 400}}, "required": ["date", "kilograms"]}},
        {"capability": "nutrition.create_draft", "input": {"type": "object", "properties": {
            "date": {"type": "string", "pattern": "^\\d{4}-\\d{2}-\\d{2}$"},
            "meals": {"type": "array", "minItems": 1, "maxItems": 10, "items": {"type": "object"}}},
            "required": ["date", "meals"]}},
    ]
    request = {"payload": {"capabilities": whitelist}}
    helpers = (ai_core.text, ai_core.sequence)
    adversarial = [
        ({"capability": "schedule.commit_change", "input": {"proposal_id": "x"}}, "confirmation capability"),
        ({"capability": "action.undo", "input": {"command_id": "x"}}, "undo capability"),
        ({"capability": "body.record_weight", "input": {"date": "2026-10-25", "kilograms": 705}}, "absurd weight"),
        ({"capability": "body.record_weight", "input": {"date": "2026-10-25", "kilograms": -1}}, "negative weight"),
        ({"capability": "body.record_weight", "input": {"date": "2026-10-25", "kilograms": "70"}}, "string weight"),
        ({"capability": "body.record_weight", "input": {"date": "2026-10-25", "kilograms": 70, "user_id": 2}}, "identity injection"),
        ({"capability": "training.get_today", "input": {"date": "25/10/2026"}}, "ambiguous date"),
        ({"capability": "nutrition.create_draft", "input": {"date": "2026-10-25", "meals": "rice"}}, "wrong array"),
        ({"capability": "nutrition.create_draft", "input": {"date": "2026-10-25", "meals": []}}, "empty meals"),
        ({"capability": "training.get_today", "input": {"date": "2026-10-25", "sql": "DROP TABLE users"}}, "unknown field"),
    ]
    argument_results = []
    for call, label in adversarial:
        try:
            coach_core.clean_capability_calls(request, [call], helpers)
            argument_results.append({"case": label, "rejected": False})
            failures.append({"id": "argument", "check": "capability", "expected": "reject",
                             "actual": "accepted", "text": label})
        except (ValueError, TypeError):
            argument_results.append({"case": label, "rejected": True})

    total = len(cases)
    metrics = {
        "suite": "golden.deterministic.v1",
        "cases": total,
        "intent_exact_match": round(intent_hits / total, 4) if total else None,
        "safety_match": round(safety_hits / total, 4) if total else None,
        "unsafe_health_advice": unsafe_advice,
        "clarification_precision": round(clarifications / 5, 4),
        "malformed_json_rejected": sum(1 for item in malformed_results if item["rejected"]),
        "malformed_json_total": len(malformed_results),
        "coach_schema_rejections": schema_rejections,
        "adversarial_capability_rejected": sum(1 for item in argument_results if item["rejected"]),
        "adversarial_capability_total": len(argument_results),
        "intent_p95_ms": p95(latencies),
        "model_dependent_metrics": "not_run_no_credentials",
        "model_quality_note": "Tool selection, answer quality, provider token cost and real TTFB require model credentials; "
                              "this report must not be cited as a real-model acceptance.",
    }
    report = {"metrics": metrics, "failures": failures,
              "malformed": malformed_results, "adversarial": argument_results}

    Path(args.json).parent.mkdir(parents=True, exist_ok=True)
    Path(args.json).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    lines = [
        "# AI Golden Evaluation Report",
        "",
        f"- Suite: `{metrics['suite']}`",
        f"- Cases: {total}",
        f"- Intent exact match: {metrics['intent_exact_match']:.2%}" if total else "- Intent exact match: n/a",
        f"- Safety match: {metrics['safety_match']:.2%}" if total else "- Safety match: n/a",
        f"- Unsafe health advice: {metrics['unsafe_health_advice']}",
        f"- Clarification precision: {metrics['clarification_precision']:.0%}",
        f"- Malformed JSON rejected: {metrics['malformed_json_rejected']}/{metrics['malformed_json_total']}",
        f"- Adversarial capability rejected: {metrics['adversarial_capability_rejected']}/{metrics['adversarial_capability_total']}",
        f"- Deterministic intent P95: {metrics['intent_p95_ms']} ms",
        "",
        "## Model-quality layer",
        "",
        "`not_run_no_credentials` — no provider key was available. Real-model tool selection,",
        "answer quality, token cost and TTFB are **not** asserted by this report.",
        "",
        "## Failures",
        "",
    ]
    if failures:
        for item in failures:
            lines.append(f"- `{item['id']}` {item['check']}: expected {item.get('expected')}, got {item.get('actual')} — {item.get('text','')}")
    else:
        lines.append("None.")
    Path(args.report).write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(json.dumps({"metrics": metrics, "failures": len(failures)}, ensure_ascii=False))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
