"""Exact affirmative intents. Reuses normal jobs, result validation and domain commands."""
MAP={'今天练什么':'training.get_today','今天训练安排':'training.get_today',
     '开始今天训练':'training.start_session','开始今天的训练':'training.start_session',
     '继续刚才训练':'training.start_session','恢复训练':'training.start_session',
     '结束训练':'training.finish_session','训练结束了':'training.finish_session',
     '我的俱乐部进度':'club.get_progress'}

def weight_input(question, default_unit='kg'):
    import re
    from decimal import Decimal, ROUND_HALF_UP
    # Anchored affirmative commands only; no quoted notes, corrections,
    # historical dates, estimates or a bare number without a weight context.
    patterns = [r'^(?:请|帮我|请帮我)?(?:记|记录|登记|保存)(?:一下)?(?:(?:今天|今日)(?:早上|早晨|上午|下午|晚上)?)?的?(体重)?\s*(\d{1,3}(?:\.\d{1,2})?)\s*(公斤|千克|kg|斤|磅|lb)?$',
                r'^(?:(?:今天|今日)(?:早上|早晨|上午|下午|晚上)?)?(体重)\s*(\d{1,3}(?:\.\d{1,2})?)\s*(公斤|千克|kg|斤|磅|lb)?[，, ]*(?:请)?(?:记录|登记|保存)(?:一下)?$']
    for pattern in patterns:
        match = re.fullmatch(pattern, question, re.I)
        if not match: continue
        label, value, unit = match.groups()
        if not label and not unit: return None
        unit = (unit or default_unit).lower()
        kg = Decimal(value) * (Decimal('0.5') if unit == '斤' else Decimal('0.45359237') if unit in ('磅','lb') else Decimal(1))
        return float(kg.quantize(Decimal('0.1'), rounding=ROUND_HALF_UP)) if 20 <= kg <= 400 else None
    return None

def result(request):
    import coach_core
    p=request['payload']
    if p.get('_fast_intent_enabled') is False or p.get('purpose','dialogue')!='dialogue' or p.get('_references') or p.get('images') or p.get('deep_analysis'):return None
    import nutrition_quick130
    food=nutrition_quick130.fast_result(request)
    if food is not None:return food
    question=p.get('question','').strip().rstrip('。！! \n')
    cap=MAP.get(question)
    kg=weight_input(question,(p.get('action_preferences') or {}).get('weight_unit','kg'))
    if kg is not None: cap='body.record_weight'
    if cap not in {x['capability'] for x in p.get('capabilities',[])}:return None
    text={
        'training.get_today':'这是今天的训练安排。',
        'training.start_session':'正在打开今天的训练；如果已经开始，会继续原来的训练。',
        'training.finish_session':'正在核对本次训练。有未登记的组时，会先请你确认保存范围。',
        'club.get_progress':'正在查看你的俱乐部进度。',
        'body.record_weight':'正在提交这次体重记录，请查看下方保存结果。',
    }[cap]
    value={'date':request['date'],'kilograms':kg} if cap=='body.record_weight' else {'date':request['date']} if cap.startswith('training.') else {}
    return {'kind':'coach','notes':[],'coach':{'answer':text,'source_ids':[x['id'] for x in coach_core.evidence(p)][:14],
        'actions':[],'capability_calls':[{'capability':cap,'input':value}]}}
