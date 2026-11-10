"""Deterministic nutrition facts engine (Phase 3 §2).

The model may name foods; this module maps confirmed mass to nutrients with
per-100g arithmetic, separates confirmed from estimated mass, and emits a
confidence band. It never invents weight, oil or sauce content.
"""
from __future__ import annotations

import hashlib
import os
import json
import re
from dataclasses import dataclass
from pathlib import Path
from datetime import date
from typing import Any, Iterable

ENGINE_VERSION = "nutrition.per100g.v1"
SOURCE_PRIORITY = {"user_confirmed": 4, "label": 3, "database": 2, "estimate": 1}
SOURCE_BAND = {"user_confirmed": 0.02, "label": 0.0, "database": 0.05, "estimate": 0.15}
TRUSTED_SOURCE = "FIXTURE_CN_FOOD"
_CATALOG: dict[str, dict] | None = None
MACROS = ("protein", "carbs", "fat")


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


def _text(value: Any, maximum: int = 100) -> str:
    if not isinstance(value, str):
        return ""
    return value.strip()[:maximum]


def _normalize_name(name: str) -> str:
    return re.sub(r"[\s\u3000（）()\-_/]+", "", name or "").casefold()


@dataclass(frozen=True)
class FoodItemResult:
    name: str
    source_kind: str
    edible_grams: float | None
    nutrients: dict[str, float | None]
    low: dict[str, float | None]
    high: dict[str, float | None]
    confidence: float
    basis: str
    flags: tuple[str, ...]
    source_ref: str | None
    per_100g: dict[str, float] | None = None
    source_database: str | None = None
    source_version: str | None = None


def _per_100g(item: dict[str, Any]) -> dict[str, float] | None:
    raw = item.get("per_100g") or item.get("label_per_100g")
    if not isinstance(raw, dict):
        return None
    values: dict[str, float] = {}
    for key in ("calories",) + MACROS:
        if key not in raw:
            return None
        value = _number(raw.get(key), 0, 10000 if key == "calories" else 2000)
        if value is None:
            return None
        values[key] = value
    return values


def _catalog() -> dict[str, dict]:
    global _CATALOG
    if _CATALOG is None:
        root = Path(__file__).resolve().parent
        path = Path(os.environ.get('BOJI_FOOD_CATALOG_PATH') or root / 'food-catalog-production.json')
        raw = json.loads(path.read_text(encoding='utf-8'))
        entries = raw.get('foods', []) if isinstance(raw, dict) else raw
        supplemental = root / 'food-catalog-tfda130.json'
        if supplemental.exists():
            entries = json.loads(supplemental.read_text(encoding='utf-8')).get('foods', []) + entries
        aliases = json.loads((root / 'food-aliases-zh.json').read_text(encoding='utf-8'))
        catalog = {}
        for original in entries:
            entry = dict(original)
            entry['aliases'] = list(entry.get('aliases') or []) + aliases.get(entry['food_id'], [])
            for name in [entry.get('name_zh') or entry.get('name', '')] + entry['aliases']:
                key = _normalize_name(name)
                if key:
                    catalog[key] = entry
        _CATALOG = catalog
    return _CATALOG


def match_food(name: str, food_id: str | None = None) -> dict | None:
    """Both identity and catalog ID must agree; model IDs cannot rename foods."""
    entry = _catalog().get(_normalize_name(name))
    if entry is None or (food_id and entry.get('food_id') != food_id):
        return None
    return entry


def search_foods(query, limit=8):
    query = _text(query, 120)
    if not query:
        raise ValueError('food_query_required')
    exact = _catalog().get(_normalize_name(query))
    candidates = [exact] if exact else []
    seen = {exact['food_id']} if exact else set()
    words = _normalize_name(query).split()
    for name, entry in _catalog().items():
        if entry['food_id'] not in seen and all(word in name for word in words):
            candidates.append(entry)
            seen.add(entry['food_id'])
            if len(candidates) >= max(1, min(20, int(limit))):
                break
    return {'query': query, 'candidates': candidates, 'requires_identity_confirmation': True,
            'note': '数据库是参考成分；食材、做法、可食质量仍需确认，不能等同照片实测。'}


def _volume_grams(item: dict[str, Any], unit: str, amount: float | None) -> tuple[float | None, list[str]]:
    flags: list[str] = []
    explicit_value = item.get('edible_grams')
    if explicit_value is None:
        explicit_value = item.get('grams')
    explicit = _number(explicit_value, .01, 5000)
    if explicit is not None:
        return explicit, flags
    if unit in ('g', '克'):
        return amount, flags
    if unit not in ('ml', '毫升'):
        return None, ['portion_requires_mass']
    density = _number(item.get("density_g_per_ml"), 0.1, 10)
    if amount is None or density is None:
        return None, ["volume_requires_density"]
    return round(amount * density, 2), flags


def compute_item(item: dict[str, Any], default_source: str = "estimate", use_catalog: bool = True) -> FoodItemResult:
    if not isinstance(item, dict):
        raise ValueError("invalid_food_item")
    name = _text(item.get("name"), 100)
    if not name:
        raise ValueError("food_name_required")
    flags: list[str] = []
    explicit_food_id = _text(item.get("food_id"), 80) or None
    trusted = match_food(name, explicit_food_id) if (use_catalog or explicit_food_id) else None
    unit = _text(item.get("unit") or "g", 10)
    mass = item.get("edible_grams")
    if mass is None:
        mass = item.get("grams")
    raw_amount = _number(mass if mass is not None else item.get("amount"), 0, 5000)
    volume_item = item
    if trusted is not None and unit in ("ml", "毫升") and not item.get("density_g_per_ml"):
        volume_item = dict(item)
        volume_item["density_g_per_ml"] = trusted.get("density_g_per_ml")
    grams, volume_flags = _volume_grams(volume_item, unit, raw_amount)
    flags.extend(volume_flags)
    per_100g = None
    source_database = None
    source_version = None
    source_ref = None
    source_kind = _text(item.get("source_kind") or item.get("source") or default_source, 30)
    manual = _per_100g(item)
    if item.get("user_confirmed") is True and manual is not None:
        per_100g = manual
        source_kind = "user_confirmed"
        source_database = "USER_CONFIRMED"
        source_version = "user"
        source_ref = _text(item.get("source_ref"), 80) or "user_confirmed"
    elif item.get("label_verified") is True and manual is not None:
        per_100g = manual
        source_kind = "label"
        source_database = "VERIFIED_LABEL"
        source_version = _text(item.get("source_version"), 40) or "label"
        source_ref = _text(item.get("source_ref"), 80) or None
    elif trusted is not None:
        per_100g = dict(trusted["per_100g"])
        source_database = trusted.get("source_database")
        source_version = trusted.get("source_version")
        source_ref = trusted.get("food_id")
        source_kind = "database"
    else:
        per_100g = manual
        source_kind = "estimate"
        if item.get("source_kind") in ("database", "label") or item.get("source") in ("database", "label"):
            flags.append("source_unverified")
        source_ref = _text(item.get("source_ref") or item.get("food_id"), 80) or None
    if per_100g is not None and grams is not None:
        basis = "per_100g"
        nutrients = {key: round(per_100g[key] * grams / 100.0, 2) for key in per_100g}
        band = SOURCE_BAND[source_kind]
        if item.get('amount_confirmed') is False:
            band = max(band, 0.20)
            flags.append('portion_estimated')
    else:
        reported = item.get("reported_totals")
        if isinstance(reported, dict):
            nutrients = {}
            for key in ("calories",) + MACROS:
                value = _number(reported.get(key), 0, 10000 if key == "calories" else 2000)
                if value is None:
                    raise ValueError("reported_total_incomplete")
                nutrients[key] = round(value, 2)
            basis = "reported_total"
            # These totals are model/user estimates, not arithmetic from the
            # catalog when edible mass is unknown.
            source_kind = 'estimate'
            source_database = source_version = None
            band = .20
            flags.append("portion_total_not_per_100g")
        elif volume_flags:
            # Volume without density: keep identity/amount, but nutrition is
            # unknown until the user supplies a density or a trusted source.
            basis = "volume" if unit in ('ml', '毫升') else 'unknown_mass'
            nutrients = {key: None for key in ("calories",) + MACROS}
            band = 0.5
            flags.append("nutrition_unknown")
        else:
            raise ValueError("edible_grams_and_per_100g_required")
    low = {key: (None if value is None else round(max(0.0, value * (1 - band)), 2)) for key, value in nutrients.items()}
    high = {key: (None if value is None else round(value * (1 + band), 2)) for key, value in nutrients.items()}
    if nutrients["calories"] is not None and nutrients["calories"] > 50:
        energy = 4 * ((nutrients["protein"] or 0) + (nutrients["carbs"] or 0)) + 9 * (nutrients["fat"] or 0)
        ratio = nutrients["calories"] / energy if energy > 0 else 0
        if energy > 0 and not 0.5 <= ratio <= 1.8:
            raise ValueError("inconsistent_nutrient_energy")
        if 0.5 <= ratio <= 1.8 and abs(nutrients["calories"] - energy) > max(80, energy * 0.35):
            flags.append("macro_energy_mismatch")
    if source_kind == "estimate" and not item.get("preparation") and re.search(r"炒|煎|炸|拌|卤|红烧|咖喱|汤|酱", name):
        flags.append("added_fat_or_sauce_unknown")
    confidence = round(max(0.05, min(1.0, 1.0 - band)), 2)
    return FoodItemResult(
        name=name, source_kind=source_kind, edible_grams=grams, nutrients=nutrients,
        low=low, high=high, confidence=confidence, basis=basis, flags=tuple(sorted(set(flags))),
        source_ref=source_ref, per_100g=per_100g,
        source_database=source_database, source_version=source_version,
    )

def _band_from_items(results: list[FoodItemResult]) -> str:
    kinds = {item.source_kind for item in results}
    if kinds <= {"user_confirmed", "label"}:
        return "high"
    if "estimate" in kinds:
        return "low"
    return "moderate"


def compute_meal(items: Iterable[dict[str, Any]], *, category: str = "", on_date: str | None = None,
                 photo_hash: str | None = None) -> dict[str, Any]:
    results = [compute_item(item) for item in items]
    if not results:
        raise ValueError("empty_meal")
    totals = {key: (round(sum(item.nutrients[key] for item in results if item.nutrients[key] is not None), 2)
                    if all(item.nutrients[key] is not None for item in results) else None)
              for key in ("calories",) + MACROS}
    low = {key: (round(sum(item.low[key] for item in results if item.low[key] is not None), 2)
                if all(item.low[key] is not None for item in results) else None)
           for key in ("calories",) + MACROS}
    high = {key: (round(sum(item.high[key] for item in results if item.high[key] is not None), 2)
                 if all(item.high[key] is not None for item in results) else None)
            for key in ("calories",) + MACROS}
    confirmed = round(sum(item.edible_grams or 0 for item in results
                          if item.source_kind in ("user_confirmed", "label") and item.basis == "per_100g"), 2)
    estimated = round(sum(item.edible_grams or 0 for item in results
                          if item.source_kind not in ("user_confirmed", "label") and item.basis == "per_100g"), 2)
    flags = sorted({flag for item in results for flag in item.flags})
    if confirmed and estimated:
        flags.append("mixed_confirmed_and_estimated_mass")
    payload = {
        "engine_version": ENGINE_VERSION,
        "category": category if category in ("早餐", "午餐", "晚餐", "加餐") else "",
        "date": on_date,
        "items": [
            {
                "name": item.name, "source_kind": item.source_kind, "basis": item.basis,
                "edible_grams": item.edible_grams, "nutrients": item.nutrients,
                "range": {"low": item.low, "high": item.high},
                "confidence": item.confidence, "flags": list(item.flags),
                "source_ref": item.source_ref,
                "source_database": item.source_database,
                "source_version": item.source_version,
                "per_100g": item.per_100g,
            } for item in results
        ],
        "totals": totals,
        "range": {"low": low, "high": high},
        "confirmed_mass_g": confirmed,
        "estimated_mass_g": estimated,
        "confidence_band": _band_from_items(results),
        "flags": flags,
        "totals_complete": all(value is not None for value in totals.values()),
        "requires_user_confirmation": "estimate" in {item.source_kind for item in results} or bool(flags)
            or any(value is None for value in totals.values()),
        "auto_save": False,
        "computed_by": "deterministic_engine",
    }
    payload["draft_fingerprint"] = draft_fingerprint(payload, photo_hash=photo_hash)
    return payload


def draft_fingerprint(meal: dict[str, Any], *, photo_hash: str | None = None) -> str:
    """Stable identity for one reviewed draft; retries must not create a second entry."""
    identity = {
        "engine": ENGINE_VERSION,
        "date": meal.get("date"),
        "category": meal.get("category"),
        "photo_hash": photo_hash,
        "items": [
            {"name": _normalize_name(item.get("name", "")),
             "grams": item.get("edible_grams"), "source": item.get("source_kind"),
             "ref": item.get("source_ref"), "version": item.get("source_version"),
             "nutrients": item.get("nutrients"),
             "per_100g": item.get("per_100g")}
            for item in meal.get("items", [])
        ],
    }
    return hashlib.sha256(json.dumps(identity, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()


def amendment_of(original: dict[str, Any], corrections: dict[str, Any]) -> dict[str, Any]:
    """A correction creates a new version; the original facts stay referenced.

    Changing food identity invalidates the old nutrient evidence. If the new
    name/food_id cannot be matched to a trusted source, nutrition stays unknown
    and the draft requires user confirmation rather than silently keeping the
    previous food's values.
    """
    if not original.get("items"):
        raise ValueError("original_meal_required")
    merged = dict(original)
    items = [dict(item) for item in original["items"]]
    corrections_items = corrections.get("items")
    patches = corrections_items if isinstance(corrections_items, list) else []
    inputs = []
    identity_changed = False
    unknown_identity = False
    for index, item in enumerate(items):
        patch = patches[index] if index < len(patches) and isinstance(patches[index], dict) else {}
        old_name = _normalize_name(str(item.get("name") or ""))
        new_name = str(patch.get("name", item.get("name") or ""))
        new_key = _normalize_name(new_name)
        changed_identity = new_key != old_name
        if changed_identity:
            identity_changed = True
        source_kind = patch.get("source_kind", item.get("source_kind", "estimate"))
        trusted = match_food(new_name, patch.get("food_id") or item.get("food_id"))
        if changed_identity and trusted is None and not patch.get("per_100g"):
            # Do not carry the old food's per-100g evidence to a new identity.
            identity_changed = True
            unknown_identity = True
            inputs.append({"name": new_name, "source_kind": "estimate", "unknown_identity": True})
            continue
        per_100g = patch.get("per_100g") or (trusted["per_100g"] if trusted else item.get("per_100g"))
        grams = patch.get("edible_grams", patch.get("amount", item.get("edible_grams")))
        inputs.append({
            "name": new_name, "edible_grams": grams,
            "amount": patch.get("amount", grams), "unit": patch.get("unit", item.get("unit", "g")),
            "source_kind": source_kind, "per_100g": per_100g,
            "food_id": patch.get("food_id") or item.get("food_id"),
            "source_ref": patch.get("source_ref") or item.get("source_ref"),
            "density_g_per_ml": patch.get("density_g_per_ml", item.get("density_g_per_ml")),
        })
    known_inputs = [value for value in inputs if not value.get("unknown_identity")]
    if known_inputs:
        recomputed = compute_meal(known_inputs, category=merged.get("category", ""), on_date=merged.get("date"))
    else:
        recomputed = {"engine_version": ENGINE_VERSION, "category": merged.get("category", ""),
                      "date": merged.get("date"), "items": [],
                      "totals": {key: None for key in ("calories",) + MACROS},
                      "range": {"low": {key: None for key in ("calories",) + MACROS},
                                "high": {key: None for key in ("calories",) + MACROS}},
                      "confirmed_mass_g": 0, "estimated_mass_g": 0,
                      "confidence_band": "low", "flags": ["identity_changed_needs_rematch"],
                      "requires_user_confirmation": True, "auto_save": False,
                      "totals_complete": False, "computed_by": "deterministic_engine"}
    if unknown_identity:
        for item in inputs:
            if item.get("unknown_identity"):
                recomputed["items"].append({
                    "name": item["name"], "source_kind": "estimate", "basis": "unknown_identity",
                    "edible_grams": None, "nutrients": {key: None for key in ("calories",) + MACROS},
                    "range": {"low": None, "high": None}, "confidence": 0.05,
                    "flags": ["identity_changed_needs_rematch"], "source_ref": None,
                    "source_database": None, "source_version": None, "per_100g": None,
                })
        recomputed["totals_complete"] = False
        recomputed["requires_user_confirmation"] = True
        recomputed["flags"] = sorted(set(recomputed.get("flags", []) + ["identity_changed_needs_rematch"]))
    if any(item.get("edible_grams") is None for item in recomputed["items"]):
        recomputed["requires_user_confirmation"] = True
    if identity_changed:
        recomputed["requires_user_confirmation"] = True
        recomputed["flags"] = sorted(set(recomputed.get("flags", []) + ["food_identity_changed"]))
    recomputed["amends"] = original.get("draft_fingerprint")
    recomputed["amendment_reason"] = _text(corrections.get("reason"), 200) or "user_correction"
    recomputed["draft_fingerprint"] = draft_fingerprint(recomputed,
        photo_hash=corrections.get("photo_hash") or original.get("photo_hash"))
    return recomputed
