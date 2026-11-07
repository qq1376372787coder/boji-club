"""Deterministic Fitness / Nutrition / Personal engine tests (Phase 3).

These run without a model, database or network. They assert the safety
invariants that must hold even if the LLM misbehaves.
"""
from __future__ import annotations

import sys
import os
from unittest.mock import patch
import unittest
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))

import fitness_intelligence as fitness
import nutrition_engine as nutrition
import personal_intelligence as personal
import food_core


class FitnessEngineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.variants = fitness.load_variants()

    def test_equipment_variants_are_never_merged(self):
        barbell = self.variants["0025"]      # 平板杠铃卧推
        smith = self.variants["0748"]        # 平板史密斯卧推
        dumbbell = self.variants["0289"]     # 平板哑铃卧推
        self.assertEqual(barbell.canonical_id, smith.canonical_id)
        self.assertFalse(fitness.comparability(barbell, smith)["comparable"])
        self.assertEqual(fitness.comparability(barbell, smith)["reason"], "different_equipment")
        self.assertFalse(fitness.comparability(barbell, dumbbell)["comparable"])
        self.assertTrue(fitness.comparability(barbell, barbell)["comparable"])

    def test_unknown_variant_is_not_guessed(self):
        result = fitness.comparability(None, self.variants["0025"])
        self.assertFalse(result["comparable"])
        self.assertEqual(result["reason"], "unknown_variant")

    def test_bodyweight_variant_keeps_its_own_basis(self):
        pullup = self.variants["0652"]
        self.assertEqual(pullup.name_zh, "引体向上")
        self.assertEqual(pullup.weight_basis, "bodyweight")

    def test_feature_window_uses_real_dates_and_coverage(self):
        records = []
        for offset, load in ((10, 40.0), (5, 45.0), (0, 50.0)):
            records.append({
                "date": (date(2026, 10, 25) - timedelta(days=offset)).isoformat(),
                "exercise_variant_id": "0025",
                "record_id": f"session-{offset}",
                "sets": [{"weight": load, "reps": 8, "completed": True, "record_id": f"set-{offset}"}],
            })
        records.append({"date": "2026-08-01", "exercise_variant_id": "0025",
                        "sets": [{"weight": 90, "reps": 8, "completed": True}]})
        features = fitness.training_features(records, self.variants, as_of=date(2026, 10, 25), window_days=28)
        self.assertEqual(features["window_start"], "2026-09-28")
        self.assertEqual(features["observed_days"], 3)
        self.assertEqual(features["training_days"], 3)
        self.assertAlmostEqual(features["coverage_score"], 3 / 28, places=3)
        variant = features["variants"][0]
        self.assertEqual(variant["max_load"], 50.0)
        self.assertEqual(variant["weight_trend"], "increasing")
        self.assertIn("set-0", features["source_record_ids"])

    def test_empty_window_reports_unknown_not_zero(self):
        features = fitness.training_features([], self.variants, as_of=date(2026, 10, 25))
        self.assertEqual(features["observed_days"], 0)
        self.assertIsNone(features["data_freshness_days"])
        self.assertEqual(features["data_quality"], "insufficient")
        self.assertIsNone(features["variants"][0]["max_load"] if features["variants"] else None)

    def test_red_flags_escalate_before_any_training_advice(self):
        result = fitness.assess_readiness({"coverage_score": 1, "training_days": 1}, "我胸口疼还想练胸")
        self.assertEqual(result["decision"], "SAFETY_ESCALATION")
        self.assertEqual(result["triage"]["level"], "emergency")
        self.assertFalse(result["writes_schedule"])
        self.assertFalse(result["auto_apply"])

    def test_fatigue_without_data_asks_instead_of_clearing_training(self):
        result = fitness.assess_readiness({"coverage_score": 0, "training_days": 0}, "我有点累")
        self.assertEqual(result["decision"], "ASK_FOLLOWUP")
        self.assertFalse(result["writes_schedule"])

    def test_readiness_is_advice_only(self):
        rest = fitness.assess_readiness({"coverage_score": 0.9, "training_days": 5, "completed_sets": 60})
        self.assertEqual(rest["decision"], "CONSIDER_REST")
        self.assertFalse(rest["writes_schedule"])
        reduced = fitness.assess_readiness({"coverage_score": 0.6, "training_days": 3, "completed_sets": 20})
        self.assertEqual(reduced["decision"], "CONSIDER_MODIFIED")
        normal = fitness.assess_readiness({"coverage_score": 0.8, "training_days": 2, "completed_sets": 12})
        self.assertEqual(normal["decision"], "TRAIN_AS_PLANNED")
        for value in (rest, reduced, normal):
            self.assertFalse(value["auto_apply"])
            self.assertFalse(value["writes_schedule"])

    def test_progression_requires_comparable_evidence_and_effort(self):
        variant = self.variants["0025"]
        pain = fitness.progression_advisory(variant, [], pain_reported=True)
        self.assertEqual(pain["decision"], "SAFETY_TRIAGE")
        unknown = fitness.progression_advisory(None, [])
        self.assertEqual(unknown["decision"], "INSUFFICIENT_EVIDENCE")
        short = fitness.progression_advisory(variant, [{"weight": 40, "reps": 10, "completed": True}] * 2,
                                             effort_acceptable=True)
        self.assertEqual(short["decision"], "INSUFFICIENT_EVIDENCE")
        no_effort = fitness.progression_advisory(variant, [{"weight": 40, "reps": 10, "completed": True}] * 3,
                                                 effort_acceptable=None)
        self.assertEqual(no_effort["decision"], "HOLD_CURRENT_LOAD")
        missed = fitness.progression_advisory(variant, [{"weight": 40, "reps": 5, "completed": True}] * 3,
                                              target_reps=8, effort_acceptable=True)
        self.assertEqual(missed["decision"], "HOLD_CURRENT_LOAD")

    def test_progression_is_bounded_and_never_auto_applies(self):
        variant = self.variants["0025"]
        result = fitness.progression_advisory(
            variant, [{"weight": 100, "reps": 10, "completed": True, "session_id": "session-" + str(i // 2)} for i in range(4)],
            target_reps=8, effort_acceptable=True)
        self.assertEqual(result["decision"], "MAY_SUGGEST_SMALL_PROGRESSION")
        self.assertLessEqual(result["suggested_increment_kg"], 2.5)
        self.assertFalse(result["auto_apply"])
        self.assertEqual(result["recommended_action"], "PROPOSE_ONLY")


class NutritionEngineTests(unittest.TestCase):
    def setUp(self):
        # Explicit fixture arithmetic tests; production uses licensed USDA data.
        self.catalog_env = patch.dict(os.environ, {'BOJI_FOOD_CATALOG_PATH': str(Path(__file__).resolve().parents[1] / 'backend/food-catalog.json')})
        self.catalog_env.start()
        nutrition._CATALOG = None

    def tearDown(self):
        self.catalog_env.stop()
        nutrition._CATALOG = None

    def test_per_100g_math_and_range(self):
        result = nutrition.compute_meal([{
            "name": "鸡胸肉", "edible_grams": 150, "source_kind": "user_confirmed",
            "user_confirmed": True,
            "per_100g": {"calories": 165, "protein": 31, "carbs": 0, "fat": 3.6},
        }], category="午餐", on_date="2026-10-25")
        self.assertEqual(result["totals"]["protein"], 46.5)
        self.assertEqual(result["totals"]["calories"], 247.5)
        self.assertEqual(result["items"][0]["basis"], "per_100g")
        self.assertLess(result["range"]["low"]["calories"], result["totals"]["calories"])
        self.assertGreater(result["range"]["high"]["calories"], result["totals"]["calories"])
        self.assertEqual(result["confidence_band"], "high")
        self.assertFalse(result["auto_save"])

    def test_missing_mass_is_rejected(self):
        with self.assertRaises(ValueError):
            nutrition.compute_item({"name": "米饭", "source_kind": "estimate",
                                    "per_100g": {"calories": 130, "protein": 2.6, "carbs": 28, "fat": 0.3}})

    def test_inconsistent_energy_is_rejected(self):
        with self.assertRaises(ValueError):
            nutrition.compute_item({"name": "错误数据", "edible_grams": 100, "source_kind": "database",
                                    "per_100g": {"calories": 900, "protein": 1, "carbs": 1, "fat": 1}})

    def test_reported_total_is_flagged_not_treated_as_per_100g(self):
        result = nutrition.compute_item({"name": "包装酸奶", "source_kind": "label",
                                         "reported_totals": {"calories": 120, "protein": 6, "carbs": 12, "fat": 4}})
        self.assertEqual(result.basis, "reported_total")
        self.assertIn("portion_total_not_per_100g", result.flags)
        self.assertIsNone(result.edible_grams)

    def test_confirmed_and_estimated_mass_stay_separate(self):
        result = nutrition.compute_meal([
            {"name": "米饭", "edible_grams": 200, "source_kind": "user_confirmed", "user_confirmed": True,
             "per_100g": {"calories": 130, "protein": 2.6, "carbs": 28, "fat": 0.3}},
            {"name": "自制炒青菜", "edible_grams": 150, "source_kind": "estimate",
             "per_100g": {"calories": 80, "protein": 2, "carbs": 6, "fat": 5}},
        ], category="午餐", on_date="2026-10-25")
        self.assertEqual(result["confirmed_mass_g"], 200)
        self.assertEqual(result["estimated_mass_g"], 150)
        self.assertIn("mixed_confirmed_and_estimated_mass", result["flags"])
        self.assertTrue(result["requires_user_confirmation"])
        self.assertEqual(result["confidence_band"], "low")

    def test_unknown_oil_is_flagged_not_invented(self):
        result = nutrition.compute_item({"name": "红烧肉", "edible_grams": 100, "source_kind": "estimate",
                                         "per_100g": {"calories": 400, "protein": 14, "carbs": 5, "fat": 38}})
        self.assertIn("added_fat_or_sauce_unknown", result.flags)

    def test_draft_fingerprint_is_stable_and_mass_sensitive(self):
        base = {"name": "米饭", "edible_grams": 200, "source_kind": "user_confirmed",
                "per_100g": {"calories": 130, "protein": 2.6, "carbs": 28, "fat": 0.3}}
        a = nutrition.compute_meal([base], category="午餐", on_date="2026-10-25", photo_hash="abc")
        b = nutrition.compute_meal([base], category="午餐", on_date="2026-10-25", photo_hash="abc")
        c = nutrition.compute_meal([{**base, "edible_grams": 210}], category="午餐",
                                   on_date="2026-10-25", photo_hash="abc")
        self.assertEqual(a["draft_fingerprint"], b["draft_fingerprint"])
        self.assertNotEqual(a["draft_fingerprint"], c["draft_fingerprint"])

    def test_food_rename_recomputes_from_trusted_source(self):
        original = nutrition.compute_meal([{
            "name": "米饭", "edible_grams": 200, "unit": "g", "source_kind": "user_confirmed",
            "per_100g": {"calories": 116, "protein": 2.6, "carbs": 25.9, "fat": 0.3},
        }], category="午餐", on_date="2026-10-25")
        amended = nutrition.amendment_of(original, {"items": [{"name": "鸡胸肉"}]})
        self.assertEqual(amended["items"][0]["name"], "鸡胸肉")
        self.assertEqual(amended["items"][0]["source_database"], "FIXTURE_CN_FOOD")
        self.assertNotEqual(amended["totals"], original["totals"], "new food identity must not keep old nutrients")
        self.assertTrue(amended["requires_user_confirmation"])
        self.assertIn("food_identity_changed", amended["flags"])
        self.assertNotEqual(amended["draft_fingerprint"], original["draft_fingerprint"])

    def test_unknown_food_identity_keeps_nutrition_unknown(self):
        original = nutrition.compute_meal([{
            "name": "米饭", "edible_grams": 200, "unit": "g", "source_kind": "user_confirmed",
            "per_100g": {"calories": 116, "protein": 2.6, "carbs": 25.9, "fat": 0.3},
        }], category="午餐", on_date="2026-10-25")
        amended = nutrition.amendment_of(original, {"items": [{"name": "自制酱料"}]})
        self.assertIsNone(amended["totals"]["calories"])
        self.assertFalse(amended["totals_complete"])
        self.assertTrue(amended["requires_user_confirmation"])
        self.assertIn("identity_changed_needs_rematch", amended["flags"])

    def test_fingerprint_includes_confirmed_nutrient_observation(self):
        base = {"name": "自定义餐", "edible_grams": 100, "unit": "g", "user_confirmed": True,
                "per_100g": {"calories": 100, "protein": 10, "carbs": 5, "fat": 2}}
        first = nutrition.compute_meal([base], category="午餐", on_date="2026-10-25")
        second = nutrition.compute_meal([{**base, "per_100g": {"calories": 120, "protein": 10, "carbs": 5, "fat": 2}}],
                                        category="午餐", on_date="2026-10-25")
        self.assertNotEqual(first["draft_fingerprint"], second["draft_fingerprint"])
        self.assertNotEqual(first["totals"], second["totals"])

    def test_volume_requires_density_and_trusted_density(self):
        unknown = nutrition.compute_item({"name": "自制汤", "amount": 250, "unit": "ml",
                                          "source_kind": "estimate",
                                          "per_100g": {"calories": 30, "protein": 1, "carbs": 2, "fat": 1}})
        self.assertEqual(unknown.basis, "volume")
        self.assertIsNone(unknown.nutrients["calories"])
        self.assertIn("volume_requires_density", unknown.flags)
        milk = nutrition.compute_item({"name": "牛奶", "amount": 250, "unit": "ml"})
        self.assertIsNotNone(milk.edible_grams)
        self.assertAlmostEqual(milk.edible_grams, 257.5, places=1)
        self.assertEqual(milk.source_database, "FIXTURE_CN_FOOD")

    def test_model_declared_source_is_not_trusted(self):
        item = nutrition.compute_item({"name": "未知食物", "edible_grams": 100, "unit": "g",
                                       "source_kind": "database",
                                       "per_100g": {"calories": 100, "protein": 10, "carbs": 5, "fat": 2}})
        self.assertEqual(item.source_kind, "estimate")
        self.assertIn("source_unverified", item.flags)

    def test_food_core_propagates_source_and_uncertainty(self):
        def text(value, maximum=200, allow_empty=False): return str(value)[:maximum]
        def number(value, low=0, high=1e9, integer=False): return float(value)
        def sequence(value, maximum, minimum=0): return list(value)
        result = {"kind": "meal", "is_food": True, "name": "米饭", "components": [{
            "name": "米饭", "food_id": "fixture-rice-cooked", "amount": 200, "unit": "g", "basis": "visible",
            "calories": 1, "protein": 1, "carbs": 1, "fat": 1}]}
        cleaned = food_core.clean_food(result, [], (text, number, sequence))
        component = cleaned["components"][0]
        self.assertEqual(component["calories"], 232.0)
        self.assertEqual(component["sourceDatabase"], "FIXTURE_CN_FOOD")
        self.assertEqual(component["sourceKind"], "database")
        soup = {"kind": "meal", "is_food": True, "name": "自制汤", "components": [{
            "name": "自制汤", "amount": 250, "unit": "ml", "basis": "visible",
            "calories": 10, "protein": 1, "carbs": 1, "fat": 1}]}
        cleaned_soup = food_core.clean_food(soup, [], (text, number, sequence))
        self.assertIn("volume_requires_density", cleaned_soup["components"][0]["uncertaintyFlags"])
        self.assertTrue(cleaned_soup["requiresReview"])

    def test_food_core_uses_engine_when_per_100g_is_present(self):
        def text(value, maximum=200, allow_empty=False): return str(value)[:maximum]
        def number(value, low=0, high=1e9, integer=False): return float(value)
        def sequence(value, maximum, minimum=0): return list(value)
        result = {"kind": "meal", "is_food": True, "name": "测试鸡肉", "components": [{
            "name": "测试鸡肉", "amount": 150, "unit": "g", "basis": "visible",
            "calories": 1, "protein": 1, "carbs": 1, "fat": 1,
            "source_kind": "database",
            "per_100g": {"calories": 165, "protein": 31, "carbs": 0, "fat": 3.6},
        }]}
        cleaned = food_core.clean_food(result, [], (text, number, sequence))
        component = cleaned["components"][0]
        self.assertEqual(component["calories"], 247.5, "model totals are replaced by per-100g math")
        self.assertIn("source_unverified", component["uncertaintyFlags"])
        self.assertEqual(component["nutritionEngine"], nutrition.ENGINE_VERSION)
        self.assertEqual(cleaned["calories"], 247.5)

    def test_food_core_rejects_invalid_per_100g_evidence(self):
        def text(value, maximum=200, allow_empty=False): return str(value)[:maximum]
        def number(value, low=0, high=1e9, integer=False): return float(value)
        def sequence(value, maximum, minimum=0): return list(value)
        result = {"kind": "meal", "is_food": True, "name": "错误", "components": [{
            "name": "错误", "amount": 100, "unit": "g", "basis": "visible",
            "calories": 100, "protein": 1, "carbs": 1, "fat": 1,
            "per_100g": {"calories": 900, "protein": 1, "carbs": 1, "fat": 1},
        }]}
        with self.assertRaises(ValueError):
            food_core.clean_food(result, [], (text, number, sequence))

    def test_amendment_produces_a_new_version(self):
        original = nutrition.compute_meal([{
            "name": "米饭", "edible_grams": 200, "source_kind": "user_confirmed",
            "per_100g": {"calories": 130, "protein": 2.6, "carbs": 28, "fat": 0.3},
        }], category="午餐", on_date="2026-10-25")
        amended = nutrition.amendment_of(original, {"items": [{"name": "糙米饭"}]})
        self.assertEqual(amended["items"][0]["name"], "糙米饭")
        self.assertEqual(amended["amends"], original["draft_fingerprint"])
        self.assertNotEqual(amended["draft_fingerprint"], original["draft_fingerprint"])

    def test_amendment_keeps_user_confirmed_values_without_grams_change_of_identity(self):
        # B-01 regression: editing grams of a user-confirmed meal must not replace
        # the confirmed per-100g evidence with a catalog value or downgrade it.
        original = nutrition.compute_meal([{
            "name": "米饭", "edible_grams": 100, "unit": "g", "user_confirmed": True,
            "per_100g": {"calories": 80, "protein": 3, "carbs": 12, "fat": 2},
            "source_ref": "my_label",
        }], category="午餐", on_date="2026-10-25")
        self.assertEqual(original["items"][0]["source_kind"], "user_confirmed")
        amended = nutrition.amendment_of(original, {"items": [{"edible_grams": 150}]})
        item = amended["items"][0]
        self.assertEqual(item["source_kind"], "user_confirmed")
        self.assertEqual(item["per_100g"]["calories"], 80)
        self.assertEqual(item["source_ref"], "my_label")
        self.assertEqual(amended["confirmed_mass_g"], 150)
        self.assertEqual(amended["estimated_mass_g"], 0)

    def test_amendment_keeps_label_verified_source(self):
        original = nutrition.compute_meal([{
            "name": "自制酱料", "edible_grams": 100, "unit": "g", "label_verified": True,
            "per_100g": {"calories": 133, "protein": 31, "carbs": 0, "fat": 1},
        }], category="午餐", on_date="2026-10-25")
        amended = nutrition.amendment_of(original, {"items": [{"edible_grams": 200}]})
        item = amended["items"][0]
        self.assertEqual(item["source_kind"], "label")
        self.assertEqual(item["per_100g"]["calories"], 133)

    def test_amendment_rename_still_invalidates_confirmed_evidence(self):
        # A changed identity invalidates the old evidence on purpose: the catalog
        # re-match wins and the draft needs fresh confirmation.
        original = nutrition.compute_meal([{
            "name": "米饭", "edible_grams": 100, "unit": "g", "user_confirmed": True,
            "per_100g": {"calories": 80, "protein": 3, "carbs": 12, "fat": 2},
        }], category="午餐", on_date="2026-10-25")
        amended = nutrition.amendment_of(original, {"items": [{"name": "糙米饭"}]})
        self.assertNotEqual(amended["items"][0]["source_kind"], "user_confirmed")


class PersonalIntelligenceTests(unittest.TestCase):
    def now(self):
        return datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)

    def test_user_correction_supersedes_tentative_hypothesis(self):
        existing = personal.MemoryItem("training.time", "ai_hypothesis", "常在晚上训练", "tentative", 0.5)
        incoming = personal.MemoryItem("training.time", "preference", "我更喜欢早上训练", "confirmed", 0.9,
                                       [{"type": "user_message", "id": "m1"}], source="user")
        decision = personal.resolve_memory(existing, incoming, now=self.now())
        self.assertEqual(decision["action"], "supersede")
        self.assertEqual(decision["item"].supersedes, "training.time")

    def test_hypothesis_cannot_confirm_or_replace_confirmed_fact(self):
        hypothesis = personal.MemoryItem("goal", "ai_hypothesis", "可能想增肌", "confirmed", 0.9)
        self.assertEqual(personal.resolve_memory(None, hypothesis)["action"], "reject")
        existing = personal.MemoryItem("goal", "profile_fact", "保持体重", "confirmed", 0.9, source="user")
        incoming = personal.MemoryItem("goal", "ai_hypothesis", "想增肌", "tentative", 0.7)
        self.assertEqual(personal.resolve_memory(existing, incoming, now=self.now())["action"], "reject")

    def test_older_evidence_does_not_overwrite_newer(self):
        old = personal.MemoryItem("goal", "profile_fact", "增肌", "confirmed", 0.9,
                                  valid_from=self.now())
        incoming = personal.MemoryItem("goal", "profile_fact", "减脂", "confirmed", 0.9,
                                       valid_from=self.now() - timedelta(days=5))
        self.assertEqual(personal.resolve_memory(old, incoming, now=self.now())["action"], "reject")

    def test_retraction_wins(self):
        existing = personal.MemoryItem("goal", "profile_fact", "增肌", "confirmed", 0.9)
        incoming = personal.MemoryItem("goal", "profile_fact", "", "retracted", 1.0, source="user")
        self.assertEqual(personal.resolve_memory(existing, incoming, now=self.now())["action"], "supersede")

    def test_context_only_includes_requested_kinds_and_consent(self):
        items = [
            personal.MemoryItem("goal", "profile_fact", "增肌", "confirmed", 0.9),
            personal.MemoryItem("habit", "behavior_feature", "晚上训练", "confirmed", 0.8),
            personal.MemoryItem("pain", "ai_hypothesis", "膝痛", "tentative", 0.6),
        ]
        selected = personal.context_memories(items, needs=("profile_fact", "behavior_feature"),
                                             consent={"behavior": False}, now=self.now())
        self.assertEqual([item["key"] for item in selected], ["goal"])
        selected = personal.context_memories(items, needs=("profile_fact", "behavior_feature"),
                                             consent={"behavior": True}, now=self.now())
        self.assertEqual({item["key"] for item in selected}, {"goal", "habit"})

    def test_rank_puts_safety_first_and_suppresses_bad_evidence(self):
        candidates = [
            {"insight_id": "i1", "kind": "training", "subject_id": "s1", "confidence": 0.9,
             "evidence_refs": ["a", "b", "c"], "data_quality": "sufficient_for_advisory",
             "created_at": self.now().isoformat()},
            {"insight_id": "i2", "kind": "safety", "subject_id": "s2", "confidence": 0.6,
             "evidence_refs": ["red-flag"], "data_quality": "verified", "created_at": self.now().isoformat()},
            {"insight_id": "i3", "kind": "nutrition", "subject_id": "s3", "confidence": 0.9,
             "evidence_refs": [], "data_quality": "sufficient_for_advisory"},
            {"insight_id": "i4", "kind": "nutrition", "subject_id": "s4", "confidence": 0.9,
             "evidence_refs": ["x"], "data_quality": "insufficient"},
        ]
        result = personal.rank_insights(candidates, now=self.now())
        self.assertEqual(result["selected"][0]["insight_id"], "i2")
        reasons = {entry["insight_id"]: entry["reason"] for entry in result["suppressed"]}
        self.assertEqual(reasons["i3"], "no_evidence")
        self.assertEqual(reasons["i4"], "insufficient_quality")

    def test_rank_dedupes_and_cools_down(self):
        candidates = [
            {"insight_id": "a", "kind": "training", "subject_id": "bench", "confidence": 0.8,
             "evidence_refs": ["x"], "data_quality": "sufficient_for_advisory",
             "created_at": self.now().isoformat()},
            {"insight_id": "b", "kind": "training", "subject_id": "bench", "confidence": 0.7,
             "evidence_refs": ["y"], "data_quality": "sufficient_for_advisory",
             "created_at": self.now().isoformat()},
        ]
        result = personal.rank_insights(candidates, now=self.now())
        self.assertEqual([entry["insight_id"] for entry in result["selected"]], ["a"])
        self.assertEqual(result["suppressed"][0]["reason"], "duplicate_kind_subject")

        history = {"a": {"last_shown_at": (self.now() - timedelta(hours=2)).isoformat(),
                         "kind": "training", "subject_id": "bench"}}
        cooled = personal.rank_insights(candidates, now=self.now(), history=history)
        self.assertEqual(cooled["selected"], [])
        self.assertIn("kind_cooldown", {entry["reason"] for entry in cooled["suppressed"]})

    def test_rank_daily_cap_and_dismissal_penalty(self):
        candidates = [
            {"insight_id": "a", "kind": "training", "subject_id": "s1", "confidence": 0.9,
             "evidence_refs": ["x"], "data_quality": "sufficient_for_advisory",
             "created_at": self.now().isoformat()},
            {"insight_id": "b", "kind": "nutrition", "subject_id": "s2", "confidence": 0.8,
             "evidence_refs": ["y"], "data_quality": "sufficient_for_advisory",
             "created_at": self.now().isoformat()},
        ]
        history = {"x1": {"last_shown_at": self.now().isoformat()},
                   "x2": {"last_shown_at": self.now().isoformat()}}
        capped = personal.rank_insights(candidates, now=self.now(), history=history, max_per_day=2)
        self.assertEqual(capped["selected"], [])
        self.assertIn("daily_frequency_cap", {entry["reason"] for entry in capped["suppressed"]})

        dismissed = {"a": {"last_shown_at": (self.now() - timedelta(days=4)).isoformat(),
                           "dismissed_count": 2}}
        ranked = personal.rank_insights(candidates, now=self.now(), history=dismissed)
        scores = {entry["insight_id"]: entry["score"] for entry in ranked["selected"]}
        self.assertGreater(scores["b"], scores["a"], "two dismissals must lower the rank")


if __name__ == "__main__":
    unittest.main(verbosity=2)
