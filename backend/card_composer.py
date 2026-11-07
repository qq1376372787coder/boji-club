"""Deterministic read-only card composition for the V2 card protocol (schema v1).

The model may only REQUEST a card type; every payload field is computed here
from the validated request context (days + upcoming). Unknown request types are
dropped, duplicates removed, and missing data produces an explicit empty state
- never a guess. Cards ride inside the existing coach job result, so the
account proxy and job transport need no protocol change.

Envelope contract (mirrored by iOS BojiClub/AICards.swift):
  card_id / card_type / schema_version / title / payload / actions[] /
  evidence_refs[] / created_at / expires_at
Payloads are per-type and validated below before leaving this module.
"""
import datetime as dt
import json
import uuid
from zoneinfo import ZoneInfo

CARD_SCHEMA_VERSION = 1
READONLY_CARD_TYPES = ('today_training', 'training_progress', 'insight')
# Phase 3 §4: AI-drafted record proposals. Unlike read-only cards the MODEL
# supplies the content here; it is strictly validated below (shape, bounds,
# date == request date) and re-validated again by the proposals endpoint when
# the client confirms. Invalid drafts are dropped, never guessed around.
DRAFT_CARD_TYPES = ('meal_draft', 'weight_entry')
MAX_CARDS = 2
MAX_DRAFT_MEALS = 3
CARD_ACTIONS = {
    'start_training': '开始训练',
    'view_plan': '查看计划',
    'create_plan': '创建安排',
    'view_records': '查看记录',
}
DRAFT_CARD_ACTIONS = {
    'confirm_proposal': '确认记录',
    'dismiss_proposal': '不采用',
}
MEAL_CATEGORIES = ('早餐', '午餐', '晚餐', '加餐')

def _zone(name):
    try:
        return ZoneInfo(name)
    except Exception:
        return ZoneInfo('Asia/Shanghai')

def _stamp(moment):
    return moment.isoformat(timespec='seconds')

def _envelope(conversation, card_type, title, payload, actions, evidence_refs, request):
    zone = _zone(request['payload'].get('timeZone', 'Asia/Shanghai'))
    day = dt.date.fromisoformat(request['date'])
    created = dt.datetime.now(zone)
    anchor_day = max(day, created.date())
    expires = dt.datetime.combine(anchor_day + dt.timedelta(days=1), dt.time.min, tzinfo=zone)
    identity = f"boji/card/{conversation}/{card_type}"
    card_id = 'card-' + uuid.uuid5(uuid.NAMESPACE_URL, identity).hex[:20]
    return {
        'card_id': card_id,
        'card_type': card_type,
        'schema_version': CARD_SCHEMA_VERSION,
        'title': title,
        'payload': payload,
        'actions': [{'action_id': key, 'label': CARD_ACTIONS[key], 'kind': 'navigate'} for key in actions],
        'evidence_refs': evidence_refs,
        'created_at': _stamp(created),
        'expires_at': _stamp(expires),
    }

def _today_training(request, conversation):
    """Today's planned exercises come from the submitted day context: the coach
    request's `upcoming` window only covers strictly future days (1-7 ahead),
    while today's arrangement - started or not - lives in days[today]."""
    date = request['date']
    today = next((row for row in request['payload'].get('days', []) if row['date'] == date), None)
    exercises = (today or {}).get('payload', {}).get('exercises') or []
    if not exercises:
        return _envelope(conversation, 'today_training', '今日训练', {
            'date': date, 'empty': True, 'reason': 'no_planned_session',
            'hint': '今天没有已安排的训练。可以安排一次，或把今天留给恢复。',
        }, ['create_plan'], [], request)
    total_sets = sum(len(ex['sets']) for ex in exercises)
    minutes = max(15, min(150, total_sets * 3))
    return _envelope(conversation, 'today_training', '今日训练', {
        'date': date,
        'display_name': '今日训练安排',
        'exercise_count': len(exercises),
        'total_sets': total_sets,
        'estimated_minutes': minutes,
        'estimation_basis': f'按 {total_sets} 组、每组约 3 分钟估算',
    }, ['start_training', 'view_plan'], [f'day/{date}'], request)

def _progress_days(request):
    """Confirmed training facts over the submitted window, computed not inferred."""
    days = request['payload'].get('days', [])
    rows = []
    for day in days:
        totals = day['payload'].get('totals') or {}
        sets = int(totals.get('completed_sets') or 0)
        sessions = sum(1 for s in day['payload'].get('workout_sessions', []) if s.get('confirmed'))
        if sets or sessions:
            rows.append({'date': day['date'], 'sets': sets, 'sessions': sessions})
    return rows

def _training_progress(request, conversation):
    rows = _progress_days(request)
    if not rows:
        return _envelope(conversation, 'training_progress', '近期训练进度', {
            'window_start': request['payload']['days'][0]['date'] if request['payload'].get('days') else request['date'],
            'window_end': request['date'],
            'training_days': 0, 'completed_sets': 0, 'confirmed_sessions': 0, 'empty': True,
            'hint': '这段时间还没有已确认的训练记录。',
        }, ['view_records'], [], request)
    return _envelope(conversation, 'training_progress', '近期训练进度', {
        'window_start': request['payload']['days'][0]['date'],
        'window_end': request['date'],
        'training_days': len(rows),
        'completed_sets': sum(row['sets'] for row in rows),
        'confirmed_sessions': sum(row['sessions'] for row in rows),
    }, ['view_records'], [f"day/{row['date']}" for row in rows[:14]], request)

def _insight(request, conversation):
    """Only a fact-backed rhythm note; omitted entirely when there is no data."""
    zone = _zone(request['payload'].get('timeZone', 'Asia/Shanghai'))
    today = dt.date.fromisoformat(request['date'])
    window = []
    for offset in range(7):
        key = (today - dt.timedelta(days=offset)).isoformat()
        day = next((row for row in request['payload'].get('days', []) if row['date'] == key), None)
        if day is None:
            continue
        totals = day['payload'].get('totals') or {}
        sets = int(totals.get('completed_sets') or 0)
        if sets:
            window.append({'date': key, 'sets': sets})
    if not window:
        return None
    sets = sum(row['sets'] for row in window)
    return _envelope(conversation, 'insight', '训练节奏', {
        'text': f'近 7 天已确认 {len(window)} 个训练日、共 {sets} 组。',
        'window_days': 7,
        'training_days': len(window),
        'completed_sets': sets,
        'evidence_dates': [row['date'] for row in window],
    }, ['view_records'], [f"day/{row['date']}" for row in window], request)

def _number(value, lo, hi):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if value != value or value in (float('inf'), float('-inf')) or not lo <= value <= hi:
        return None
    return round(float(value), 1)

def _draft_envelope(conversation, card_type, title, payload, request):
    zone = _zone(request['payload'].get('timeZone', 'Asia/Shanghai'))
    day = dt.date.fromisoformat(request['date'])
    created = dt.datetime.now(zone)
    anchor_day = max(day, created.date())
    expires = dt.datetime.combine(anchor_day + dt.timedelta(days=1), dt.time.min, tzinfo=zone)
    canonical = json.dumps([card_type, payload], sort_keys=True, ensure_ascii=False, separators=(',', ':'))
    card_id = 'card-' + uuid.uuid5(uuid.NAMESPACE_URL, f'boji/card/{conversation}/{canonical}').hex[:20]
    return {
        'card_id': card_id,
        'card_type': card_type,
        'schema_version': CARD_SCHEMA_VERSION,
        'title': title,
        'payload': payload,
        'actions': [{'action_id': key, 'label': DRAFT_CARD_ACTIONS[key], 'kind': 'confirm' if key == 'confirm_proposal' else 'dismiss'}
                    for key in ('confirm_proposal', 'dismiss_proposal')],
        'evidence_refs': [f"day/{request['date']}"],
        'created_at': _stamp(created),
        'expires_at': _stamp(expires),
    }

def _meal_draft(request, conversation, payload):
    date = request['date']
    if not isinstance(payload, dict) or payload.get('date') != date:
        return None
    meals = payload.get('meals')
    if not isinstance(meals, list) or not 1 <= len(meals) <= MAX_DRAFT_MEALS:
        return None
    clean = []
    for meal in meals:
        if not isinstance(meal, dict):
            return None
        name = meal.get('name')
        category = meal.get('category')
        if not isinstance(name, str) or not name.strip() or len(name) > 100:
            return None
        if category not in MEAL_CATEGORIES:
            return None
        entry = {'name': name.strip(), 'category': category}
        for key, lo, hi in (('calories', 0, 10000), ('protein', 0, 2000), ('carbs', 0, 2000), ('fat', 0, 2000)):
            if key in meal and meal[key] is not None:
                value = _number(meal[key], lo, hi)
                if value is None:
                    return None
                entry[key] = value
        # Cap at 100 to match ai-proposals.php and capability-registry.php; a longer
        # portion would render on the card yet fail confirmation with no user recourse.
        if isinstance(meal.get('portion'),str): entry['portion']=meal['portion'][:100]
        entry['estimated']=meal.get('estimated') is not False
        entry['requiresReview']=bool(meal.get('requiresReview',True))
        if isinstance(meal.get('nutritionSources'),list):entry['nutritionSources']=[v[:100] for v in meal['nutritionSources'][:8] if isinstance(v,str)]
        clean.append(entry)
    return _draft_envelope(conversation, 'meal_draft', '待确认的饮食记录',
                           {'date': date, 'meals': clean}, request)

def _weight_entry(request, conversation, payload):
    date = request['date']
    if not isinstance(payload, dict) or payload.get('date') != date:
        return None
    kilograms = _number(payload.get('kilograms'), 20, 400)
    if kilograms is None:
        return None
    clean = {'date': date, 'kilograms': kilograms}
    for key, lo, hi in (('bodyFatPercentage', 0, 70), ('waistCircumferenceCM', 30, 300)):
        if key in payload and payload[key] is not None:
            value = _number(payload[key], lo, hi)
            if value is None:
                return None
            clean[key] = value
    return _draft_envelope(conversation, 'weight_entry', '待确认的体重记录', clean, request)

def compose(request, raw, helpers):
    """Turn validated model card requests into deterministic, data-backed cards."""
    text, sequence = helpers[0], helpers[1]
    if raw is None:
        return []
    # The prompt permits up to two read-only plus three proposal requests, so more
    # than MAX_CARDS total items is a normal model outcome, not a schema violation:
    # truncating must not destroy the whole coach answer (the draft path already
    # appends only while there is room). Malformed items are skipped like unknown
    # card types, never fail the run.
    requested = raw if isinstance(raw, list) else []
    requested = requested[:5]
    wanted = []
    draft_requests = []
    for item in requested:
        if not isinstance(item, dict):
            continue
        kind = text(item.get('type'), 40)
        if kind in DRAFT_CARD_TYPES:
            draft_requests.append((kind, item.get('payload')))
            continue
        if kind not in READONLY_CARD_TYPES:
            continue  # forward compatibility: unknown card types are dropped, never rendered
        if kind not in wanted:
            wanted.append(kind)
    conversation = request['payload']['conversation_id']
    cards = []
    for kind in wanted:
        if kind == 'today_training':
            cards.append(_today_training(request, conversation))
        elif kind == 'training_progress':
            cards.append(_training_progress(request, conversation))
        elif kind == 'insight':
            card = _insight(request, conversation)
            if card is not None:
                cards.append(card)
    for kind, draft_payload in draft_requests:
        card = _meal_draft(request, conversation, draft_payload) if kind == 'meal_draft' else _weight_entry(request, conversation, draft_payload)
        if card is not None and len(cards) < MAX_CARDS:
            cards.append(card)
    return cards

