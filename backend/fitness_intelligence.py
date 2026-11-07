"""Deterministic fitness rules (Phase 3 §1).

The LLM may explain, but comparability, coverage, readiness and progression
thresholds live here. Every function is pure and versioned; unknown or
insufficient data returns an explicit unknown/insufficient result instead of a
zero or an optimistic recommendation.

These rules are advisory only. They do not modify schedules, records or
medical advice, and they are not a substitute for professional review.
"""
from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass, asdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable

FEATURE_VERSION = "fitness.features.v1"
READINESS_RULE_VERSION = "fitness.readiness.v1"
PROGRESSION_RULE_VERSION = "fitness.progression.confirmed_sessions_v2"
RULE_SOURCE = {
    "title": "ACSM Progression models in resistance training for healthy adults (2009)",
    "url": "https://doi.org/10.1249/MSS.0b013e3181915670",
    "doi": "10.1249/MSS.0b013e3181915670",
    "evidence_grade": "consensus_pending_expert_review",
    "reviewed_at": None,
    "expert_approval_required": True,
}

_EQUIPMENT_BASIS = (
    ("史密斯", "machine"),
    ("器械", "machine"),
    ("绳索", "cable"),
    ("拉力", "cable"),
    ("弹力", "band"),
    ("杠铃", "barbell"),
    ("哑铃", "dumbbell"),
    ("壶铃", "kettlebell"),
    ("徒手", "bodyweight"),
    ("自重", "bodyweight"),
    ("引体", "bodyweight"),
    ("辅助", "assistance"),
)

RED_FLAGS = (
    ("chest_pain", r"胸[痛疼]|胸(?:部|口|前区).{0,4}(疼|痛|闷|紧|压)|胸闷|chest\s*pain|chest\s*tight"),
    ("syncope", r"晕厥|昏倒|晕倒|眼前发黑|失去意识|faint|passed\s*out|black(?:ed)?\s*out"),
    ("dyspnea", r"呼吸困难|喘不上气|喘不过来|喘不过气|严重气促|气喘|(?:喘|呼吸).{0,8}(?:厉害|困难|急促)|(?:说不出|无法说|不能说).{0,4}(?:整句|完整)|不能呼吸|shortness\s*of\s*breath|can'?t\s*breathe|difficulty\s*breathing"),
    ("palpitations", r"心跳.{0,4}(快|加速|乱)|心悸|心慌|palpitation|heart\s*racing"),
    ("acute_injury", r"剧痛|急性.{0,4}(伤|损伤)|骨折|脱臼|扭伤.{0,4}肿|severe\s*(?:pain|injury)|fracture"),
    ("fever", r"发热|发烧|高烧|体温.{0,3}(38|39|40)|fever"),
    ("numbness", r"麻木|放射性.{0,3}痛|大小便失禁|numbness|radiating\s*pain"),
)
# Only a denial adjacent to the symptom counts. An unrelated “没休息好”
# must not suppress chest pain later in the same sentence.
_CLAUSE_BREAK = re.compile(r"[，,。.!！?？;；\n]|但是|不过|可是|但|\bbut\b|\bhowever\b", re.I)
_NEGATION = re.compile(
    r"(?:(?:没有|没|未|无|否认|不)(?:(?:出现|感到|感觉|发生|存在|明显|任何|持续|剧烈|胸部|胸口|胸|关节|肌肉|过|再|了|很))*"
    r"|\b(?:no|not|without|denies|deny)(?:\s+(?:any|have|having|experiencing|experience|a|current|significant))*)\s*$", re.I)
_DOUBLE_NEGATION = re.compile(r"(?:不是|并非|并不是|不能说|不能排除|不排除).{0,8}(?:没有|没|未|无|不)|\bnot\s+(?:without|free\s+of)\b", re.I)


def _signal_negated(text, match):
    preceding = text[:match.start()]
    clauses = _CLAUSE_BREAK.split(preceding)
    prefix = clauses[-1]
    # Chest phrases may include the denial inside the regex match (胸口不痛).
    matched = match.group(0)
    internal = re.search(r"[疼痛闷紧压]", matched)
    if matched.startswith('胸') and internal:
        prefix += matched[:internal.start()]
    if _DOUBLE_NEGATION.search(prefix):
        return False
    if _NEGATION.search(prefix):
        return True
    following = text[match.end():]
    tail = _CLAUSE_BREAK.split(following)[0].strip()
    if re.fullmatch(r"(?:已经|现在|目前)?(?:没有|没了|消失了|已消失|不存在)(?:了)?", tail):
        return True
    # Suppress a past mention only with an explicit, immediate current denial.
    # “胸痛没有缓解” and “以前胸痛，今天又痛” remain warnings.
    if re.search(r"以前|之前|曾经|过去|\bpreviously\b|\bused to\b", prefix, re.I):
        after = _CLAUSE_BREAK.split(following)
        if len(after) > 1 and re.fullmatch(r"\s*(?:今天|现在|目前)(?:已经)?(?:没有|没了|无)(?:了)?\s*", after[1]):
            return True
    return False

_SEVERE = re.compile(
    r"(严重|非常|极度|厉害|无法|疼得|痛得|剧烈|severe|extreme|very).{0,10}"
    r"(疲|累|酸痛|疼痛|疼|痛|fatigue|tired|sore|pain)|"
    r"(疲|累|酸痛|疼痛|疼|痛|fatigue|tired|sore|pain).{0,10}"
    r"(严重|非常|极度|厉害|无法|剧烈|severe|extreme)", re.I)
_PAIN = re.compile(r"(酸痛|疼痛|疼|痛|pain|sore)", re.I)
_FATIGUE = re.compile(r"(疲|累|乏力|没劲|疲劳|tired|fatigue|exhaust)", re.I)


def _has_current_signal(pattern, question):
    return any(not _signal_negated(question, m) for m in pattern.finditer(question))


@dataclass(frozen=True)
class ExerciseVariant:
    variant_id: str
    canonical_id: str
    name_zh: str
    name_en: str
    equipment_zh: str
    weight_basis: str
    recording_unit: str
    source_id: str


_MOVEMENT_MODIFIERS = (
    "史密斯", "杠铃", "哑铃", "绳索", "器械", "辅助", "壶铃", "弹力带", "单臂", "双臂", "单侧", "双侧",
    "平板", "上斜", "下斜", "窄握", "宽握", "对握", "反握", "正握", "坐姿", "站姿", "俯身", "仰卧", "侧卧",
    "跪姿", "反向", "斜托", "直臂", "单腿",
)


def _normalize_name(name: str) -> str:
    value = re.sub(r"[\s\u3000（）()\-_/]+", "", name or "")
    return value.casefold()


def canonical_movement(name_zh: str) -> str:
    """Conservative movement grouping: strip equipment/angle modifiers only.

    Unknown names keep their own canonical key, so two unrelated exercises are
    never merged just because they share a substring.
    """
    value = _normalize_name(name_zh)
    stripped = value
    for token in _MOVEMENT_MODIFIERS:
        stripped = stripped.replace(token.casefold(), "")
    return "canon:" + (stripped or value)


def weight_basis_for(equipment_zh: str, name_zh: str = "") -> str:
    haystack = f"{equipment_zh or ''}{name_zh or ''}"
    for token, basis in _EQUIPMENT_BASIS:
        if token in haystack:
            return basis
    return "external" if equipment_zh else "unknown"


def load_variants(catalog_path: str | Path | None = None) -> dict[str, ExerciseVariant]:
    path = Path(catalog_path) if catalog_path else Path(__file__).resolve().parent / "exercise-catalog.json"
    raw = json.loads(path.read_text(encoding="utf-8"))
    variants: dict[str, ExerciseVariant] = {}
    for item in raw:
        stable_id = str(item.get("id") or "").strip()
        name_zh = str(item.get("name_zh") or "").strip()
        equipment = str(item.get("equipment_zh") or "").strip()
        if not stable_id or not name_zh:
            continue
        canonical = canonical_movement(name_zh)
        variants[stable_id] = ExerciseVariant(
            variant_id=stable_id,
            canonical_id=canonical,
            name_zh=name_zh,
            name_en=str(item.get("name") or ""),
            equipment_zh=equipment,
            weight_basis=weight_basis_for(equipment, name_zh),
            recording_unit=str(item.get("suggested_recording_unit") or "reps"),
            source_id="exercise-catalog:" + stable_id,
        )
    return variants


def comparability(a: ExerciseVariant | None, b: ExerciseVariant | None) -> dict[str, Any]:
    """Two records may share a weight trend only when variant AND basis match."""
    if a is None or b is None:
        return {"comparable": False, "reason": "unknown_variant",
                "detail": "动作未映射到动作库，不能与其他器械混算重量趋势。"}
    if a.variant_id == b.variant_id:
        return {"comparable": True, "reason": "same_variant"}
    if a.canonical_id != b.canonical_id:
        return {"comparable": False, "reason": "different_canonical",
                "detail": "不是同一动作，不能比较重量。"}
    if a.weight_basis != b.weight_basis or a.equipment_zh != b.equipment_zh:
        return {"comparable": False, "reason": "different_equipment",
                "detail": "同一动作的不同器械/负重口径不可合并为一条重量趋势。"}
    return {"comparable": False, "reason": "different_variant"}


def _parse_date(value: Any) -> date | None:
    if isinstance(value, date) and not isinstance(value, datetime):
        return value
    try:
        return datetime.fromisoformat(str(value)[:10]).date()
    except (TypeError, ValueError):
        return None


def _number(value: Any, low: float = 0, high: float = 1e6) -> float | None:
    if isinstance(value, bool) or value is None:
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if number != number or number < low or number > high:
        return None
    return number


def training_features(records: Iterable[dict[str, Any]], variants: dict[str, ExerciseVariant],
                      as_of: date | None = None, window_days: int = 28, *,
                      time_zone: str = "Asia/Shanghai", now: datetime | None = None) -> dict[str, Any]:
    """Deterministic window features. Missing values stay None, never 0."""
    from zoneinfo import ZoneInfo
    try:
        zone = ZoneInfo(time_zone)
    except (ValueError, TypeError, KeyError) as error:
        raise ValueError("invalid timeZone") from error
    instant = now or datetime.now(timezone.utc)
    if instant.tzinfo is None:
        raise ValueError("now must include a timezone")
    as_of = as_of or instant.astimezone(zone).date()
    window_days = max(7, min(56, int(window_days)))
    start = as_of - timedelta(days=window_days - 1)
    observed_days: set[date] = set()
    source_ids: list[str] = []
    per_variant: dict[str, dict[str, Any]] = {}
    unverified_sessions = 0
    for record in records:
        if not isinstance(record, dict):
            continue
        observed = _parse_date(record.get("date"))
        if observed is None or observed < start or observed > as_of:
            continue
        variant_id = str(record.get("exercise_variant_id") or record.get("library_id") or "")
        variant = variants.get(variant_id)
        sets = [s for s in (record.get("sets") or []) if isinstance(s, dict) and s.get("completed") is True]
        if not sets:
            continue
        if variant is None:
            unverified_sessions += 1
            continue
        bucket = per_variant.setdefault(variant_id, {
            "variant_id": variant_id, "name_zh": variant.name_zh, "weight_basis": variant.weight_basis,
            "equipment_zh": variant.equipment_zh, "sessions": 0, "completed_sets": 0,
            "session_dates": [], "loads_by_date": {}, "source_record_ids": [],
        })
        bucket["sessions"] += 1
        bucket["completed_sets"] += len(sets)
        bucket["session_dates"].append(observed.isoformat())
        observed_days.add(observed)
        for item in sets:
            load = _number(item.get("weight"), 0, 2000)
            reps = _number(item.get("reps"), 0, 1000)
            seconds = _number(item.get("duration_seconds", item.get("durationSeconds")), 0, 21600)
            if load is not None: bucket["loads_by_date"].setdefault(observed.isoformat(), []).append(load)
            source = item.get("record_id") or item.get("id") or record.get("record_id")
            if isinstance(source, str) and source:
                source_ids.append(source)
                bucket["source_record_ids"].append(source)
        if isinstance(record.get("record_id"), str):
            bucket["source_record_ids"].append(record["record_id"])

    for bucket in per_variant.values():
        by_date = bucket.pop("loads_by_date")
        loads = [value for day in sorted(by_date) for value in by_date[day]]
        bucket["max_load"] = max(loads) if loads else None
        bucket["last_session"] = max(bucket["session_dates"]) if bucket["session_dates"] else None
        bucket["weight_trend"] = "unknown" if len(loads) < 3 else (
            "increasing" if loads[-1] > loads[0] else "decreasing" if loads[-1] < loads[0] else "stable")
    coverage = round(min(1.0, len(observed_days) / window_days), 3)
    total_completed_sets = sum(bucket["completed_sets"] for bucket in per_variant.values())
    last_activity = max(observed_days).isoformat() if observed_days else None
    return {
        "feature_definition_version": FEATURE_VERSION,
        "window_start": start.isoformat(),
        "window_end": as_of.isoformat(),
        "window_days": window_days,
        "observed_days": len(observed_days),
        "training_days": len(observed_days),
        "completed_sets": total_completed_sets,
        "coverage_score": coverage,
        "data_freshness_days": (as_of - max(observed_days)).days if observed_days else None,
        "last_activity": last_activity,
        "source_record_ids": sorted(set(source_ids))[:200],
        "unverified_variant_sessions": unverified_sessions,
        "variants": sorted(per_variant.values(), key=lambda v: v["variant_id"]),
        "computed_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "data_quality": "sufficient_for_advisory" if coverage >= 0.25 and per_variant else "insufficient",
    }


def safety_triage(text: str) -> dict[str, Any]:
    """Red flags take priority over every training suggestion. Not a diagnosis.

    Handles common Chinese paraphrases, English phrases and simple negations
    (“没有胸痛”). Historical mentions are not enough to suppress a current
    warning when the sentence also contains a current cue; the conservative
    choice is to keep the warning unless it is explicitly negated.
    """
    if not text:
        return {"level": "none", "flags": [], "advice": None}
    flags = []
    for code, pattern in RED_FLAGS:
        for match in re.finditer(pattern, text, re.I):
            if _signal_negated(text, match):
                continue
            flags.append({"code": code, "pattern": pattern, "match": match.group(0)})
            break
    if not flags:
        return {"level": "none", "flags": [], "advice": None}
    return {
        "level": "emergency",
        "flags": flags,
        "advice": "你描述的症状需要优先排除急症。请停止训练并及时寻求医疗评估；这里不能判断病因，也不会据此调整训练计划。",
        "rule_version": "fitness.safety.v2",
    }


def assess_readiness(facts: dict[str, Any], question: str = "") -> dict[str, Any]:
    """Advice only. Never returns a schedule write.

    Order: red flags → evidence sufficiency → severe symptoms → load. Empty
    calendar rows or a fixed freshness of 0 are not evidence of training.
    """
    triage = safety_triage(question)
    if triage["level"] == "emergency":
        return {"decision": "SAFETY_ESCALATION", "triage": triage, "reasons": ["安全分流优先"],
                "rule_version": READINESS_RULE_VERSION, "auto_apply": False, "writes_schedule": False,
                "confidence": "high", "evidence_refs": []}
    if facts.get('general_guidance_only') is True:
        return {'decision':'ASK_FOLLOWUP', 'triage':triage, 'auto_apply':False, 'writes_schedule':False,
                'rule_version':READINESS_RULE_VERSION, 'reasons':['特殊情况或基础资料不足，需结合专业评估，不直接套用普通成人训练建议。']}
    coverage = _number(facts.get("coverage_score"), 0, 1)
    training_days = _number(facts.get("training_days"), 0, 60)
    completed_sets = _number(facts.get("completed_sets"), 0, 10000)
    freshness = facts.get("data_freshness_days")
    freshness = _number(freshness, 0, 3650) if freshness is not None else None
    # Confirmed training facts are the minimum evidence. A day row with no
    # completed set and no saved session must not count as coverage.
    if training_days is None or training_days <= 0 or coverage is None or coverage < 0.15:
        return {"decision": "ASK_FOLLOWUP", "triage": triage,
                "reasons": ["近 7 天缺少可核对的已确认训练事实，不能据此判断恢复是否充分。"],
                "rule_version": READINESS_RULE_VERSION, "auto_apply": False, "writes_schedule": False,
                "confidence": "low", "evidence_refs": facts.get("source_record_ids", [])}
    if freshness is not None and freshness > 14:
        return {"decision": "ASK_FOLLOWUP", "triage": triage,
                "reasons": ["最近一次已确认训练距今较久，数据不足以判断当前恢复状态。"],
                "rule_version": READINESS_RULE_VERSION, "auto_apply": False, "writes_schedule": False,
                "confidence": "low", "evidence_refs": facts.get("source_record_ids", [])}
    if _has_current_signal(_PAIN, question):
        return {"decision": "ASK_FOLLOWUP", "triage": triage,
                "reasons": ["你提到了疼痛；训练建议不能判断疼痛原因，请先确认疼痛程度和诱因。"],
                "rule_version": READINESS_RULE_VERSION, "auto_apply": False, "writes_schedule": False,
                "confidence": "low", "evidence_refs": facts.get("source_record_ids", [])}
    if _has_current_signal(_SEVERE, question):
        return {"decision": "CONSIDER_REST", "triage": triage,
                "reasons": ["你描述了明显疲劳或不适；今天不建议按原计划加量。这只是训练建议，不构成医疗判断。"],
                "rule_version": READINESS_RULE_VERSION, "auto_apply": False, "writes_schedule": False,
                "confidence": "low", "evidence_refs": facts.get("source_record_ids", [])}
    if _has_current_signal(_FATIGUE, question) and (coverage < 0.5 or (completed_sets or 0) < 8):
        return {"decision": "ASK_FOLLOWUP", "triage": triage,
                "reasons": ["主观疲劳与现有记录不足以共同判断，请补充睡眠、疲劳持续时间和是否疼痛。"],
                "rule_version": READINESS_RULE_VERSION, "auto_apply": False, "writes_schedule": False,
                "confidence": "low", "evidence_refs": facts.get("source_record_ids", [])}
    if training_days >= 5 or (completed_sets or 0) >= 40:
        decision = "CONSIDER_REST"
        reasons = [f"近 7 天已训练 {int(training_days)} 天，恢复是计划的一部分。"]
    elif training_days >= 3:
        decision = "CONSIDER_MODIFIED"
        reasons = [f"近 7 天训练 {int(training_days)} 天，可保留主要动作并减少组数或重量。"]
    else:
        decision = "TRAIN_AS_PLANNED"
        reasons = [f"近 7 天训练 {int(training_days)} 天，记录覆盖度 {coverage:.0%}。"]
    reasons.append("以上仅依据已确认记录；没有评估疼痛或健康风险，也不会修改任何安排。")
    return {"decision": decision, "triage": triage, "reasons": reasons,
            "rule_version": READINESS_RULE_VERSION, "auto_apply": False, "writes_schedule": False,
            "confidence": "moderate" if coverage >= 0.5 else "low",
            "evidence_refs": facts.get("source_record_ids", []),
            "data_freshness_days": freshness}

PROGRESSION_POLICY_VERSION = "progression.policy.v1"


def max_load_increase(current_kg, *, ratio: float = 0.05, cap: float = 2.5,
                      ceiling_ratio: float = 0.10, step: float = 0.5) -> float:
    """单次可加重上限（kg）——**渐进策略的唯一真源**，两个入口共用。

    统一前的分歧（评估报告 P1-4）：
    - ``adaptive_core.supported_increase`` 用 ``max(2.5, 5%)``，小重量按固定值放行：
      5kg 允许加到 7.5kg（**+50%**）、20kg 允许到 22.5kg（+12.5%）；
    - ``progression_advisory`` 用 ``min(2.5, 5%)`` 且硬钳 ≤10%，小重量被压到 0 档：
      5kg 直接 HOLD。
    同一用户在两个入口得到**方向相反**的结论。

    统一口径（保守侧优先，取两者更严者）：
      1. ``raw = min(cap, current * ratio)`` —— 2.5kg 与 5% **取小**（原分歧点即把
         max 改成 min）；
      2. ``raw = min(raw, current * ceiling_ratio)`` —— 10% 硬顶作冗余保险；
      3. 向下取整到器械粒度 ``step``（0.5kg，与原 progression_advisory 的
         ``floor(x*2)/2`` 一致），保证两入口给出**同一个可执行重量**；
      4. 上限 ≤0 时返回 0，表示"当前重量下不应加重"——此时两个入口都必须回答
         "不加"，小重量场景（<10kg）走**次数进阶**（adaptive_core 既有的
         reps +20% 规则），而不是硬塞一个超比例的重量增量。

    结果恒满足 ``0 ≤ Δ ≤ min(2.5, 5%) 且 Δ/当前 ≤ 10%``。
    """
    try:
        current = float(current_kg)
    except (TypeError, ValueError):
        return 0.0
    if not math.isfinite(current) or current <= 0:
        return 0.0
    raw = min(cap, current * ratio)
    raw = min(raw, current * ceiling_ratio)
    if raw <= 0:
        return 0.0
    return round(max(0.0, math.floor(raw / step) * step), 2)


def progression_advisory(variant: ExerciseVariant | None, sets: list[dict[str, Any]],
                         target_reps: int = 8, effort_acceptable: bool | None = None,
                         pain_reported: bool = False, increment_ratio: float = 0.05,
                         increment_cap: float = 2.5) -> dict[str, Any]:
    """Returns MAY_SUGGEST_SMALL_PROGRESSION only with comparable evidence."""
    if pain_reported:
        return {"decision": "SAFETY_TRIAGE", "rule_version": PROGRESSION_RULE_VERSION,
                "auto_apply": False, "reason": "有疼痛或红旗信号，先安全分流。"}
    if variant is None:
        return {"decision": "INSUFFICIENT_EVIDENCE", "rule_version": PROGRESSION_RULE_VERSION,
                "auto_apply": False, "reason": "动作未映射到动作库，不能比较重量。"}
    valid = [s for s in sets if isinstance(s, dict) and s.get("completed") is True]
    if len(valid) < 3:
        return {"decision": "INSUFFICIENT_EVIDENCE", "rule_version": PROGRESSION_RULE_VERSION,
                "auto_apply": False, "reason": "同一器械下有效完成组不足 3 组。"}
    loads = [n for n in (_number(s.get("weight"), 0, 2000) for s in valid) if n is not None]
    reps = [n for n in (_number(s.get("reps"), 0, 1000) for s in valid) if n is not None]
    if not loads or not reps or variant.recording_unit != "reps":
        return {"decision": "ASK_FOR_MISSING_DATA", "rule_version": PROGRESSION_RULE_VERSION,
                "auto_apply": False, "reason": "缺少可比的重量/次数记录，或该动作按时间记录。"}
    if effort_acceptable is not True:
        return {"decision": "HOLD_CURRENT_LOAD", "rule_version": PROGRESSION_RULE_VERSION,
                "auto_apply": False, "reason": "主观用力程度未确认，先保持当前负荷。"}
    last_reps = reps[-1]
    if last_reps < target_reps:
        return {"decision": "HOLD_CURRENT_LOAD", "rule_version": PROGRESSION_RULE_VERSION,
                "auto_apply": False, "reason": f"最近一组 {int(last_reps)} 次未达到目标 {target_reps} 次。"}
    sessions = {}
    for value in valid:
        identity = value.get('session_id')
        if isinstance(identity, str) and identity:
            sessions.setdefault(identity, []).append(value)
    if len(sessions) < 2:
        return {'decision': 'INSUFFICIENT_EVIDENCE', 'rule_version': PROGRESSION_RULE_VERSION,
                'auto_apply': False, 'reason': '需核对至少两场同一器械的已保存训练，单场完成组不足以判断进阶。'}
    recent = list(sessions.values())[-2:]
    # Completed sets may carry weight/reps as explicit nulls (mixed sessions);
    # float(None)/int(None) would raise. Compare only sets with known weights and
    # ask for data when a session has none to compare.
    weighted = [[s for s in session if _number(s.get('weight'), 0, 2000) is not None] for session in recent]
    if any(not session for session in weighted):
        return {'decision': 'ASK_FOR_MISSING_DATA', 'rule_version': PROGRESSION_RULE_VERSION,
                'auto_apply': False, 'reason': '最近两场中有已完成组缺少重量记录，先补全重量再判断进阶。'}
    current = max(float(_number(s.get('weight'), 0, 2000)) for s in weighted[-1])
    if current <= 0:
        return {'decision': 'ASK_FOR_MISSING_DATA', 'rule_version': PROGRESSION_RULE_VERSION,
                'auto_apply': False, 'reason': '当前外部负重不明确，不能按比例增加。'}
    for session in weighted:
        peak = max(float(_number(s.get('weight'), 0, 2000)) for s in session)
        work = [s for s in session if abs(float(_number(s.get('weight'), 0, 2000)) - current) < .01]
        if abs(peak - current) >= .01 or not work or any((_number(s.get('reps'), 0, 1000) or 0) < target_reps + 1 for s in work):
            return {'decision': 'HOLD_CURRENT_LOAD', 'rule_version': PROGRESSION_RULE_VERSION,
                    'auto_apply': False, 'reason': '最近两场尚未在相同工作负重下稳定超过目标次数，先保持并核对。'}
    # 统一渐进策略（progression.policy.v1）：上限由 max_load_increase 给出，
    # 与 adaptive_core.supported_increase 共用同一函数，两入口结论必然一致。
    increment = max_load_increase(current, ratio=increment_ratio, cap=increment_cap)
    if increment <= 0 or increment / current > .10:
        return {'decision': 'HOLD_CURRENT_LOAD', 'rule_version': PROGRESSION_RULE_VERSION,
                'auto_apply': False, 'reason': '现有记录无法支持合理的最小增量，请核对器械刻度并保持当前负荷。'}
    return {
        "decision": "MAY_SUGGEST_SMALL_PROGRESSION",
        "suggested_increment_kg": increment,
        "current_load_kg": current,
        "rule_version": PROGRESSION_RULE_VERSION,
        "auto_apply": False,
        "recommended_action": "PROPOSE_ONLY",
        "confidence_band": "moderate" if len(valid) >= 6 else "low",
        "reason": "最近两场同一器械、相同工作负重下超过目标次数；可选的小幅尝试，不自动应用，也不保证训练效果。",
        "source": RULE_SOURCE,
    }


def record_feature(record: dict[str, Any]) -> dict[str, Any]:
    """Small adapter used by tests and the internal endpoint."""
    return {key: record.get(key) for key in
            ("date", "exercise_variant_id", "sets", "record_id")}
