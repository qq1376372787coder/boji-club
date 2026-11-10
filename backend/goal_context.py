"""Strict optional historical goal context; old clients keep their original payloads."""
import datetime as dt
import uuid

GOAL_CONTEXT_RULE = """
目标与方案证据：goal_context按实际日期提供已观察到的历史资料；profile为空表示当时目标未知，不能用顶层当前profile或今天体重倒填。历史profile.weight只是当时资料值，不是当日实测体重。goalChangedDuringDay为true时，一天内目标发生过变化，最后观察值不代表全天都按它执行，不跨目标拼成同一评价。planVersionID/planSource只表示当时保存的方案来源，不证明用户执行、效果或方案已调整。缺少旧目标版本时明确局限，不制造连续目标历史。制定新计划仍以顶层当前profile和明确提供的weight_reference为准，历史背景只用于解释，不覆盖当前用户选择。日报周报引用目标时标明对应日期；无当时nutritionTarget不能用今天参考量反推历史缺口。所有建议均等待用户预览确认，不能声称已更新日程。"""


def clean_goal_context(raw, request_date, kind, helpers, time_zone=None):
    text, number, sequence, iso_date, clean_profile_context = helpers
    if not isinstance(raw, dict) or type(raw.get('version')) is not int or raw['version'] != 1:
        raise ValueError('unsupported goal context')
    first, last = iso_date(raw['start']), iso_date(raw['end'])
    if not 0 <= (last-first).days < 28 or last > iso_date(request_date):
        raise ValueError('invalid goal context interval')
    if kind == 'report' and (first != last or last != iso_date(request_date)):
        raise ValueError('report goal context must belong to report date')
    if kind == 'weekly_review' and (iso_date(request_date)-first).days >= 7:
        raise ValueError('weekly goal context outside cycle')
    if kind == 'generate_plan':
        from zoneinfo import ZoneInfo
        today = dt.datetime.now(ZoneInfo(time_zone or 'Pacific/Kiritimati')).date()
        if last > today: raise ValueError('unobserved future goal context')
    rows = sequence(raw['days'], 28, 1)
    if len(rows) != (last-first).days + 1: raise ValueError('incomplete goal context interval')
    result = []
    for offset, row in enumerate(rows):
        key = iso_date(row['date'])
        if key != first + dt.timedelta(days=offset): raise ValueError('unordered or duplicate goal context date')
        changed = row['goalChangedDuringDay']
        if type(changed) is not bool: raise ValueError('invalid goal change flag')
        value = {'date': key.isoformat(), 'goalChangedDuringDay': changed}
        profile, identity = row.get('profile'), row.get('goalVersionID')
        if (profile is None) != (identity is None): raise ValueError('goal profile requires snapshot id')
        if profile is not None:
            if not isinstance(profile, dict): raise ValueError('invalid goal profile')
            identity = str(uuid.UUID(text(identity, 36)))
            clean = {k: text(profile[k], 120) for k in ('goal', 'experience', 'venue', 'focus')}
            clean.update(age=number(profile['age'], 13, 100, True), height=number(profile['height'], 50, 250), weight=number(profile['weight'], 20, 400), daysPerWeek=number(profile['daysPerWeek'], 1, 7, True))
            clean.update(clean_profile_context(profile))
            for field, limit in [('gender',20),('limitations',500),('equipment',200),('equipmentOther',200)]:
                if profile.get(field) is not None: clean[field] = text(profile[field], limit, True)
            value.update(goalVersionID=identity, profile=clean)
        else:
            if changed: raise ValueError('unknown goal cannot assert a change')
            value.update(goalVersionID=None, profile=None)
        plan, source = row.get('planVersionID'), row.get('planSource')
        if (plan is None) != (source is None): raise ValueError('plan source requires snapshot id')
        value.update(planVersionID=None if plan is None else text(plan,200), planSource=None if source is None else text(source,40))
        result.append(value)
    return {'version':1, 'start':first.isoformat(), 'end':last.isoformat(), 'days':result}
