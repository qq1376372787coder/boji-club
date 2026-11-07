"""Deterministic Fitness & Nutrition Metrics Engine.
Strictly adheres to:
1. Pure calculation with zero model hallucinations.
2. Missing data returns None, never 0.
3. Total volume = sum(weight * reps) for valid completion sets without duration.
"""
from __future__ import annotations
from typing import Any, Optional
import math


def compute_daily_metrics(
    date_str: str,
    exercises: list[dict[str, Any]],
    meals: list[dict[str, Any]],
    body_weight_kg: Optional[float] = None,
    body_fat_pct: Optional[float] = None,
    waist_cm: Optional[float] = None,
    health: Optional[dict[str, Any]] = None,
    meals_complete: bool = False,
    workout_sessions: Optional[list[dict[str, Any]]] = None,
) -> dict[str, Any]:
    """Compute deterministic daily metrics from raw logs."""
    # Training
    completed_sets = 0
    total_volume_kg = 0.0
    timed_seconds = 0
    completed_exercise_names = set()

    for ex in exercises:
        name = ex.get("name", "").strip()
        ex_completed = False
        for s in ex.get("sets", []):
            is_done = s.get("completed") is True
            duration = s.get("durationSeconds")
            reps = s.get("reps") or 0
            weight = s.get("weight") or 0.0

            valid_completion = is_done and (duration > 0 if duration is not None else reps > 0)
            if valid_completion:
                completed_sets += 1
                ex_completed = True
                if duration is not None:
                    timed_seconds += int(duration)
                elif weight > 0 and reps > 0:
                    total_volume_kg += float(weight) * float(reps)

        if ex_completed and name:
            completed_exercise_names.add(name)

    # Calculate duration
    active_duration_minutes: Optional[int] = None
    if workout_sessions:
        confirmed_sessions = [s for s in workout_sessions if s.get("confirmed") is True or s.get("savedAt") is not None]
        total_sec = sum(s.get("active_duration_seconds", 0) for s in confirmed_sessions)
        if total_sec > 0:
            active_duration_minutes = round(total_sec / 60)
        elif timed_seconds > 0:
            active_duration_minutes = round(timed_seconds / 60)
    elif timed_seconds > 0:
        active_duration_minutes = round(timed_seconds / 60)

    sessions_count = len(workout_sessions) if workout_sessions else (1 if completed_sets > 0 else 0)

    # Nutrition
    has_meals = len(meals) > 0
    total_cal = 0.0
    total_protein = 0.0
    total_carbs = 0.0
    total_fat = 0.0
    unknown_meals = 0

    if has_meals:
        for m in meals:
            if m.get("nutrition_known") is False:
                unknown_meals += 1
                continue
            total_cal += float(m.get("calories") or 0.0)
            total_protein += float(m.get("protein") or 0.0)
            total_carbs += float(m.get("carbs") or 0.0)
            total_fat += float(m.get("fat") or 0.0)

    nutrition_metrics = {
        "calories": round(total_cal, 1) if has_meals else None,
        "protein": round(total_protein, 1) if has_meals else None,
        "carbs": round(total_carbs, 1) if has_meals else None,
        "fat": round(total_fat, 1) if has_meals else None,
        "data_complete": bool(meals_complete),
        "unknown_meals": unknown_meals,
    }

    # Body
    body_metrics = {
        "weight_kg": float(body_weight_kg) if body_weight_kg is not None else None,
        "body_fat_pct": float(body_fat_pct) if body_fat_pct is not None else None,
        "waist_cm": float(waist_cm) if waist_cm is not None else None,
    }

    # Health / Activity
    steps: Optional[float] = None
    active_energy: Optional[float] = None
    if health and isinstance(health, dict):
        steps_val = health.get("steps")
        if isinstance(steps_val, dict):
            steps = steps_val.get("value")
        elif isinstance(steps_val, (int, float)):
            steps = float(steps_val)

        energy_val = health.get("activeEnergy")
        if isinstance(energy_val, dict):
            active_energy = energy_val.get("value")
        elif isinstance(energy_val, (int, float)):
            active_energy = float(energy_val)

    activity_metrics = {
        "steps": steps,
        "active_energy_kcal": active_energy,
    }

    # Warnings
    data_warnings: list[str] = []
    if has_meals and not meals_complete:
        data_warnings.append("全天饮食尚未标记确认完成，当前摄入不代表全天总值。")
    if unknown_meals > 0:
        data_warnings.append(f"有 {unknown_meals} 道餐食缺少明确营养参数，未计入能量合计。")
    if completed_sets == 0 and not has_meals and body_weight_kg is None:
        data_warnings.append("当日尚无登记完成的训练、饮食或测量记录。")

    return {
        "date": date_str,
        "training": {
            "sessions": sessions_count,
            "duration_minutes": active_duration_minutes,
            "completed_exercises": len(completed_exercise_names),
            "completed_sets": completed_sets,
            "total_volume_kg": round(total_volume_kg, 1),
        },
        "nutrition": nutrition_metrics,
        "body": body_metrics,
        "activity": activity_metrics,
        "data_warnings": data_warnings,
    }


def compute_weekly_metrics(
    days_data: list[dict[str, Any]],
    previous_days_data: Optional[list[dict[str, Any]]] = None,
) -> dict[str, Any]:
    """Compute deterministic weekly aggregate metrics from 7-day data."""
    total_training_days = 0
    total_sessions = 0
    total_sets = 0
    total_volume_kg = 0.0
    total_duration_minutes = 0

    nutrition_complete_days = 0
    total_cals = 0.0
    total_protein = 0.0
    days_with_meals = 0

    weights: list[tuple[str, float]] = []

    for d in days_data:
        date_str = d.get("date", "")
        # Training summary
        totals = d.get("totals", {})
        sets_count = totals.get("completed_sets", 0)
        volume = totals.get("volume_kg", 0.0)
        if sets_count > 0:
            total_training_days += 1
            total_sets += sets_count
            total_volume_kg += volume

        sessions = d.get("workout_sessions", [])
        if sessions:
            total_sessions += len(sessions)
            total_duration_minutes += round(sum(s.get("active_duration_seconds", 0) for s in sessions) / 60)
        elif sets_count > 0:
            total_sessions += 1
            total_duration_minutes += round(totals.get("duration_seconds", 0) / 60)

        # Nutrition
        if d.get("meals"):
            days_with_meals += 1
            if d.get("meals_complete"):
                nutrition_complete_days += 1
            total_cals += totals.get("calories", 0.0)
            total_protein += totals.get("protein", 0.0)

        # Body weight
        w = d.get("body_weight_kg")
        if w is not None and w > 0:
            weights.append((date_str, float(w)))

    # Previous week comparison
    prev_volume_kg = 0.0
    volume_change_pct: Optional[float] = None
    if previous_days_data:
        for d in previous_days_data:
            prev_volume_kg += d.get("totals", {}).get("volume_kg", 0.0)
        if prev_volume_kg > 0:
            volume_change_pct = round(((total_volume_kg - prev_volume_kg) / prev_volume_kg) * 100, 1)

    # Weight trend analysis
    weights.sort(key=lambda x: x[0])
    start_weight = weights[0][1] if weights else None
    end_weight = weights[-1][1] if weights else None
    weight_change_kg = round(end_weight - start_weight, 2) if (start_weight and end_weight and len(weights) >= 2) else None

    weight_trend = "insufficient_data"
    if len(weights) >= 3:
        diffs = [weights[i][1] - weights[i-1][1] for i in range(1, len(weights))]
        if all(d > 0.1 for d in diffs):
            weight_trend = "increasing"
        elif all(d < -0.1 for d in diffs):
            weight_trend = "decreasing"
        elif max(abs(w[1] - start_weight) for w in weights) <= 0.3:
            weight_trend = "stable"
        else:
            weight_trend = "fluctuating"

    return {
        "training": {
            "training_days": total_training_days,
            "total_sessions": total_sessions,
            "total_duration_minutes": total_duration_minutes if total_duration_minutes > 0 else None,
            "total_completed_sets": total_sets,
            "total_volume_kg": round(total_volume_kg, 1),
            "volume_change_pct": volume_change_pct,
        },
        "nutrition": {
            "average_calories": round(total_cals / days_with_meals, 1) if days_with_meals > 0 else None,
            "average_protein": round(total_protein / days_with_meals, 1) if days_with_meals > 0 else None,
            "days_with_records": days_with_meals,
            "complete_days_count": nutrition_complete_days,
        },
        "body": {
            "start_weight_kg": start_weight,
            "end_weight_kg": end_weight,
            "weight_change_kg": weight_change_kg,
            "weight_trend": weight_trend,
            "samples_count": len(weights),
        },
        "is_sufficient_for_analysis": (total_training_days >= 1 or days_with_meals >= 2 or len(weights) >= 2),
    }
