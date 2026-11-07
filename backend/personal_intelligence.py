"""Personal intelligence rules (Phase 3 §3): memory trust, insight ranking and
cooldowns. These are deterministic policy helpers used before any model text.

A model confidence number never decides a high-impact action; evidence quality,
confirmation status and safety ranking do.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable

MEMORY_RULE_VERSION = "personal.memory.v1"
INSIGHT_RULE_VERSION = "personal.insights.v1"

MEMORY_KINDS = {"profile_fact", "behavior_feature", "preference", "episode", "ai_hypothesis"}
MEMORY_STATUS = {"confirmed", "tentative", "retracted"}
TRUST_RANK = {"confirmed": 3, "tentative": 2, "retracted": 1}
KIND_RANK = {"profile_fact": 5, "preference": 4, "behavior_feature": 3, "episode": 2, "ai_hypothesis": 1}


def _parse(value: Any) -> datetime | None:
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


@dataclass
class MemoryItem:
    key: str
    kind: str
    value: str
    status: str = "tentative"
    confidence: float = 0.5
    evidence_refs: list[dict[str, Any]] = field(default_factory=list)
    valid_from: datetime | None = None
    last_verified_at: datetime | None = None
    expires_at: datetime | None = None
    source: str = "ai"
    supersedes: str | None = None

    def normalize(self) -> "MemoryItem":
        if self.kind not in MEMORY_KINDS:
            self.kind = "ai_hypothesis"
        if self.status not in MEMORY_STATUS:
            self.status = "tentative"
        self.confidence = max(0.0, min(1.0, float(self.confidence or 0)))
        return self

    def effective(self, now: datetime | None = None) -> bool:
        now = now or datetime.now(timezone.utc)
        if self.status == "retracted":
            return False
        if self.expires_at and self.expires_at <= now:
            return False
        if self.kind == "ai_hypothesis" and self.status == "tentative" and self.confidence < 0.4:
            return False
        return True


def resolve_memory(existing: MemoryItem | None, incoming: MemoryItem,
                   now: datetime | None = None) -> dict[str, Any]:
    """Decide whether a new memory may supersede the stored one."""
    now = now or datetime.now(timezone.utc)
    incoming = incoming.normalize()
    if incoming.kind == "ai_hypothesis" and incoming.status == "confirmed":
        return {"action": "reject", "reason": "hypothesis_cannot_self_confirm"}
    if existing is None:
        return {"action": "insert", "item": incoming}
    existing = existing.normalize()
    if incoming.status == "retracted":
        return {"action": "supersede", "item": incoming, "reason": "retraction"}
    if existing.status == "retracted":
        return {"action": "reject", "reason": "existing_retracted"}
    if incoming.key != existing.key:
        return {"action": "insert", "item": incoming, "reason": "different_key"}
    incoming_at = incoming.last_verified_at or incoming.valid_from
    existing_at = existing.last_verified_at or existing.valid_from
    if incoming_at and existing_at and incoming_at < existing_at:
        return {"action": "reject", "reason": "older_evidence"}
    if existing.status == "confirmed" and incoming.status != "confirmed" and incoming.source == "ai":
        return {"action": "reject", "reason": "confirmed_fact_needs_explicit_correction"}
    if TRUST_RANK[incoming.status] < TRUST_RANK[existing.status] and incoming.source == "ai":
        return {"action": "reject", "reason": "trust_downgrade"}
    if incoming.kind == "ai_hypothesis" and existing.kind != "ai_hypothesis":
        return {"action": "reject", "reason": "hypothesis_cannot_replace_fact"}
    merged_evidence = list(existing.evidence_refs)
    for ref in incoming.evidence_refs:
        if ref not in merged_evidence:
            merged_evidence.append(ref)
    incoming.evidence_refs = merged_evidence
    incoming.supersedes = existing.key
    return {"action": "supersede", "item": incoming, "reason": "newer_or_more_trusted"}


def context_memories(items: Iterable[MemoryItem], *, needs: Iterable[str] = ("preference", "profile_fact"),
                     consent: dict[str, bool] | None = None, maximum: int = 12,
                     now: datetime | None = None) -> list[dict[str, Any]]:
    """Minimal retrieval: only requested kinds, only effective items, no health
    categories without explicit consent."""
    now = now or datetime.now(timezone.utc)
    consent = consent or {}
    wanted = set(needs)
    out: list[MemoryItem] = []
    for item in items:
        if not item.effective(now) or item.kind not in wanted:
            continue
        if item.kind == "behavior_feature" and not consent.get("behavior", False):
            continue
        out.append(item)
    out.sort(key=lambda m: (TRUST_RANK[m.status], KIND_RANK[m.kind], m.confidence,
                            m.last_verified_at or m.valid_from or now), reverse=True)
    return [{"key": m.key, "kind": m.kind, "value": m.value, "status": m.status,
             "confidence": m.confidence, "evidence_refs": m.evidence_refs[:6],
             "last_verified_at": (m.last_verified_at or m.valid_from).isoformat()
             if (m.last_verified_at or m.valid_from) else None}
            for m in out[:maximum]]


def _candidate_score(candidate: dict[str, Any], now: datetime,
                     prefs: dict[str, float], history: dict[str, Any]) -> float:
    confidence = max(0.0, min(1.0, float(candidate.get("confidence") or 0)))
    evidence = min(1.0, len(candidate.get("evidence_refs") or []) / 3)
    created = _parse(candidate.get("created_at")) or now
    age_days = max(0.0, (now - created).total_seconds() / 86400)
    recency = max(0.0, 1.0 - age_days / 14)
    preference = max(0.0, min(1.0, float(prefs.get(candidate.get("kind"), 0.5))))
    dismissed = int(history.get("dismissed_count") or 0)
    ignored = int(history.get("ignored_count") or 0)
    penalty = min(0.6, dismissed * 0.25 + ignored * 0.05)
    quality = 1.0 if candidate.get("data_quality") in ("sufficient_for_advisory", "verified") else 0.2
    return round((confidence * 0.35 + evidence * 0.2 + recency * 0.2 + preference * 0.15) * quality - penalty, 4)


def rank_insights(candidates: Iterable[dict[str, Any]], *, now: datetime | None = None,
                  history: dict[str, dict[str, Any]] | None = None,
                  preferences: dict[str, float] | None = None,
                  max_per_day: int = 2, kind_cooldown_hours: int = 24,
                  subject_cooldown_hours: int = 72) -> dict[str, Any]:
    """Safety first, then evidence/recency preference; dedupe and cool down.

    Caps are applied *during* selection, so a batch can never exceed the daily
    quota. Cooldowns aggregate history across insight ids by (kind, subject),
    not just by the candidate's own id.
    """
    now = now or datetime.now(timezone.utc)
    history = history or {}
    preferences = preferences or {}
    max_per_day = max(0, int(max_per_day))
    today = now.date()
    shown_today = 0
    last_by_kind: dict[str, datetime] = {}
    last_by_subject: dict[tuple[str, str], datetime] = {}
    dismissed_by_subject: dict[tuple[str, str], int] = {}
    for value in history.values():
        if not isinstance(value, dict):
            continue
        shown = _parse(value.get("last_shown_at"))
        if shown and shown.date() == today:
            shown_today += 1
        kind = str(value.get("kind") or "")
        subject = str(value.get("subject_id") or "")
        if shown:
            if kind and (kind not in last_by_kind or shown > last_by_kind[kind]):
                last_by_kind[kind] = shown
            if kind and subject:
                key = (kind, subject)
                if key not in last_by_subject or shown > last_by_subject[key]:
                    last_by_subject[key] = shown
        if kind and subject:
            key = (kind, subject)
            dismissed_by_subject[key] = dismissed_by_subject.get(key, 0) + int(value.get("dismissed_count") or 0)

    suppressed: list[dict[str, Any]] = []
    scored: list[tuple[dict[str, Any], float, dict[str, Any]]] = []
    for candidate in candidates:
        if not isinstance(candidate, dict):
            continue
        insight_id = str(candidate.get("insight_id") or "")
        kind = str(candidate.get("kind") or "")
        subject = str(candidate.get("subject_id") or "")
        if not insight_id or not kind:
            suppressed.append({"insight_id": insight_id, "reason": "invalid_candidate"})
            continue
        if not candidate.get("evidence_refs"):
            suppressed.append({"insight_id": insight_id, "reason": "no_evidence"})
            continue
        if kind != "safety" and candidate.get("data_quality") in ("insufficient", "stale"):
            suppressed.append({"insight_id": insight_id, "reason": "insufficient_quality"})
            continue
        valid_until = _parse(candidate.get("valid_until"))
        if valid_until and valid_until <= now:
            suppressed.append({"insight_id": insight_id, "reason": "expired"})
            continue
        entry = dict(history.get(insight_id, {}) or {})
        entry["dismissed_count"] = dismissed_by_subject.get((kind, subject), 0) + int(entry.get("dismissed_count") or 0)
        score = _candidate_score(candidate, now, preferences, entry)
        scored.append((candidate, score, entry))

    # Safety first, then score. Ties keep input order for determinism.
    scored.sort(key=lambda item: (item[0].get("kind") == "safety", item[1]), reverse=True)
    selected: list[dict[str, Any]] = []
    seen_keys: set[tuple[str, str]] = set()
    remaining = max(0, max_per_day - shown_today)
    safety_selected = 0
    for candidate, score, _entry in scored:
        insight_id = str(candidate.get("insight_id") or "")
        kind = str(candidate.get("kind") or "")
        subject = str(candidate.get("subject_id") or "")
        key = (kind, subject)
        if key in seen_keys:
            suppressed.append({"insight_id": insight_id, "reason": "duplicate_kind_subject"})
            continue
        seen_keys.add(key)
        if kind == "safety":
            if safety_selected >= 1:
                suppressed.append({"insight_id": insight_id, "reason": "safety_already_selected"})
                continue
            safety_selected += 1
            selected.append({
                "insight_id": insight_id, "kind": kind, "subject_id": subject,
                "score": score, "confidence": candidate.get("confidence"),
                "safety": True, "rank_reason": "safety_first", "candidate": candidate,
            })
            continue
        by_kind = last_by_kind.get(kind)
        if by_kind and now - by_kind < timedelta(hours=kind_cooldown_hours):
            suppressed.append({"insight_id": insight_id, "reason": "kind_cooldown"})
            continue
        by_subject = last_by_subject.get(key)
        if by_subject and now - by_subject < timedelta(hours=subject_cooldown_hours):
            suppressed.append({"insight_id": insight_id, "reason": "subject_cooldown"})
            continue
        if remaining <= 0:
            suppressed.append({"insight_id": insight_id, "reason": "daily_frequency_cap"})
            continue
        remaining -= 1
        selected.append({
            "insight_id": insight_id, "kind": kind, "subject_id": subject,
            "score": score, "confidence": candidate.get("confidence"),
            "safety": False, "rank_reason": "evidence_recency_preference", "candidate": candidate,
        })
    return {"rule_version": INSIGHT_RULE_VERSION, "selected": selected,
            "suppressed": suppressed, "shown_today": shown_today,
            "remaining_today": remaining, "max_per_day": max_per_day, "auto_apply": False}
