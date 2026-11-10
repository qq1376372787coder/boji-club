"""Weekly review: minimized input, optional private images, conservative plan validation."""
import base64
import datetime as dt
import re
import unicodedata


def clean_request(payload, date, helpers):
    text, number, sequence, iso_date, validate_request = helpers
    end = iso_date(date)
    profile = payload['profile']
    cleaned_profile = {k: text(profile[k], 120) for k in ('goal', 'experience', 'venue', 'focus')}
    cleaned_profile.update(age=number(profile['age'], 13, 100, True), height=number(profile['height'], 50, 250), weight=number(profile['weight'], 20, 400))
    cleaned_profile.update(
        gender=text(profile.get('gender', ''), 20, True),
        equipment=text(profile.get('equipment', ''), 200, True),
        equipmentOther=text(profile.get('equipmentOther', ''), 200, True),
        sessionMinutes=number(profile.get('sessionMinutes', 45), 15, 180, True),
        limitations=text(profile.get('limitations', ''), 500, True),
        trainingDays=sorted({number(day, 1, 7, True) for day in sequence(profile.get('trainingDays', []), 7)}),
        homeTrainingDays=sorted({number(day, 1, 7, True) for day in sequence(profile.get('homeTrainingDays', []), 7)}),
    )
    from ai_core import clean_profile_context
    cleaned_profile.update(clean_profile_context(profile))
    survey = payload['survey']
    clean_survey = {k: text(survey.get(k, ''), 500, True) for k in ('fatigue', 'pain', 'difficulty', 'diet', 'notes')}
    clean_survey['days'] = number(survey['days'], 1, 7, True)
    fallback_days=list(dict.fromkeys(cleaned_profile['trainingDays'] + [1,3,5,2,4,6,7]))[:clean_survey['days']]
    clean_survey['trainingDays'] = sorted({number(day,1,7,True) for day in sequence(fallback_days if survey.get('trainingDays') is None else survey['trainingDays'],7)})
    if len(clean_survey['trainingDays']) != clean_survey['days']:
        raise ValueError('training day count differs from selected weekdays')
    for key, low, high in [('weight', 20, 400), ('waist', 30, 250), ('bodyFat', 2, 75)]:
        clean_survey[key] = None if survey.get(key) is None else number(survey[key], low, high)
    clean_survey['bodyFatSource'] = text(survey.get('bodyFatSource', ''), 100, True)
    if clean_survey['bodyFat'] is not None and not clean_survey['bodyFatSource'].strip():
        raise ValueError('body fat requires measured source')
    days = []
    seen = set()
    for row in sequence(payload['days'], 7):
        day = iso_date(row['date'])
        if not 0 <= (end-day).days < 7 or day in seen:
            raise ValueError('review range')
        seen.add(day)
        record = validate_request({'kind': 'report', 'date': row['date'], 'payload': row['payload']})
        days.append({'date': row['date'], **record['payload']})
    upcoming = []
    for row in sequence(payload.get('upcoming', []), 7):
        day = iso_date(row['date'])
        if not 1 <= (day-end).days <= 7:
            raise ValueError('future range')
        record = validate_request({'kind': 'report', 'date': row['date'], 'payload': {'exercises': row['exercises'], 'meals': []}})
        upcoming.append({'date': row['date'], 'exercises': record['payload']['exercises']})
    photos = []
    for photo in sequence(payload.get('photos', []), 6):
        if cleaned_profile['age'] < 18:
            raise ValueError('adult photos only')
        label = text(photo['label'], 60)
        encoded = text(photo['image_base64'], 750000)
        data = base64.b64decode(encoded, validate=True)
        if not 50 <= len(data) <= 550000 or not data.startswith(b'\xff\xd8\xff'):
            raise ValueError('invalid photo')
        photos.append({'label': label, 'image_base64': encoded})
    history = []
    for row in sequence(payload.get('history', []), 8):
        prior = iso_date(row['date'])
        if prior >= end:
            raise ValueError('history date')
        history.append({'date': row['date'], 'weight': None if row.get('weight') is None else number(row['weight'],20,400), 'waist': None if row.get('waist') is None else number(row['waist'],30,250)})
    target = payload.get('nutritionTarget')
    cleaned_target = None
    if target is not None:
        from ai_core import nutrition_context
        context = nutrition_context(target)
        if context.get('generalGuidanceOnly') is True:
            cleaned_target = context
        else:
            cleaned_target = {key: number(target[key], 0, 10000) for key in ('caloriesMin', 'caloriesMax', 'proteinMin', 'proteinMax', 'fatMin', 'fatMax')}
            cleaned_target['meals'] = number(target.get('meals', 3), 1, 8, True)
            cleaned_target.update(context)
    if cleaned_profile['age'] < 18 or cleaned_profile.get('nutritionContext', '普通成人') != '普通成人':
        cleaned_target = {'generalGuidanceOnly': True}
    clean = {'profile': cleaned_profile, 'survey': clean_survey, 'days': days, 'upcoming': upcoming, 'photos': photos, 'history': history, 'nutritionTarget': cleaned_target}
    if "review_version" in payload: clean.update(review_readiness(payload, clean, end))
    if 'coaching_version' in payload: clean['coaching_version'] = number(payload['coaching_version'], 1, 1, True)
    if 'analysis_version' in payload:
        clean['analysis_version'] = number(payload['analysis_version'], 2, 2, True)
    return clean


def messages(request, common, canonical):
    payload = request['payload']
    from ai_core import BODY_CONTEXT_RULE
    system = common + BODY_CONTEXT_RULE + '''
你在进行每周身体复盘。只分析cycle.start至cycle.endDate标明的实际周期，旧数据未带结束日期时以报告日期为结束日期；被新计划截短时不要补成七天，不用自然周替换日期范围，参考history长期测量趋势和upcoming未来七天原安排。
scope为training时，只做训练与恢复复盘：nutrition简洁说明本次未评估饮食、不判断全天摄入达标，不追问用户补齐饮食作为完成复盘条件。scope为combined时按readiness覆盖天数说明样本，只有meals_complete=true且营养值已知的日期可以对照全天饮食参考范围。
周报应回答：这一周做对了什么、哪些真实问题最影响目标、下周保持什么和改变什么、怎样验证改变。不要每天复述一遍再堆套话。计划完成率只能以cycle.plannedDates为分母；临时加练与原计划执行分开。未完成计划要先区分明确漏练与未登记，不用“计划三天实际两天”直接羞辱用户。
可比体重应按两段七天各至少三次实测算均值，说明跨度和次数；缺少完整饮食或趋势样本时不做自动热量调整。即使有趋势也不能断言变化全部来自脂肪或肌肉。下周建议先预览由用户确认，不把建议说成已经修改了计划。
严格禁止从照片推断体脂百分比、肌肉重量、肌肉增长量、疾病或身材评分。用户填入的bodyFat仅是用户自报测量值，必须标注来源，不得据照片校正它。
照片仅作自愿的衣着外观观察；仅单次照片不能判断变化。先在photoFeedback说明清晰度、遮挡、光线、角度和可比性；不可比时明确无法比较。身体遮挡部分不做判断，不要求脱衣。发现裸露敏感部位时不分析该图片，建议穿着合身不透明运动服重拍。
不要把一周内光线、站姿、衣服、充血差异描述成肌肉增长。照片只能作为辅助，训练表现、用户感受和多周测量趋势优先。
缺失饮食记录不等于没吃，缺失健康数据不按零计。运动热量不能加到全天活动能量；睡眠是自然日片段并集，不一定为整夜。
训练量包括计划与实际完成，明确区分。资料不足就decision=insufficient并sessions=[]，不为制造变化而改计划。无需调整时decision=keep,sessions=[]。
若用户报告疼痛，decision=insufficient,sessions=[]，建议停止诱发疼痛的动作并寻求合格专业评估，不作诊断或自动加量。
有充分依据且用户无疼痛时可以decision=adjust。sessions包含date之后1至7天的建议训练日；library_query必须是简短英文标准动作名，不得使用中文，不能包含过去或当天。每次2至6个熟悉、适合场地和器械的动作，每动作1至5组，静态保持动作使用durationSeconds为1至3600秒且reps=0；其他每组reps为1至30，weight一律null（用户确认重量）。每周训练日数等于survey.days，日期只能位于survey.trainingDays指定的星期。不能自行换训练星期；可训练星期数量不符时decision=insufficient。健身房可使用标准器械；在家只可使用equipment与equipmentOther列出的器械。两者都有时优先匹配homeTrainingDays的居家训练日，未指定固定居家日期时，按所选训练星期的排序交替安排健身房、居家，从健身房开始；每次按实际指定地点校验器械。
建议应小幅、可解释，组数、每组次数、每组秒数和总次数/秒数均不得超过本周实际完成的对应指标的120%；逐个同名动作检查上述指标，并沿用已完成记录中的动作中文名称；没有该动作及对应单位的已完成记录时，不提出新的自动调整。不安排激进增量或极端节食。每项说明与现有训练相比的原因；保持力量训练连续性，不随意替换全部动作。
输出JSON：{"kind":"weekly_review","summary":"周总结","training":"执行与表现","nutrition":"饮食记录分析","recovery":"身体感受与恢复","appearance":"有图时描述可观察外观与局限，无图时为空字符串","photoFeedback":["拍摄质量建议"],"decision":"keep或adjust或insufficient","reason":"调整或保持的证据与理由","notes":["缺失数据或提醒"],"sessions":[{"date":"YYYY-MM-DD","label":"安排及原因","exercises":[{"name":"动作中文名","muscle":"部位","library_query":"英文动作名","sets":[{"weight":null,"reps":10}]}]}]}。
summary 简洁概括最重要的发现，training、nutrition、recovery 只写与本次有关的要点；reason 简要解释下一步；有可比照片时 appearance 描述可见变化。每字段最多1500字。每个字段先给明确结论，再给具体日期、数字和依据，最后指出一项可执行的改进；不同字段不要重复。对比只限可比的真实记录，说明样本天数和缺失，不将少量测量或光线变化说成身体效果。reason 必须解释为什么保持/调整/证据不足，以及下周先做什么、如何检查，不为显得积极而改计划。无照片时appearance为空字符串、photoFeedback为空数组，本次仅分析训练、饮食和用户感受。notes和photoFeedback各最多8项。
'''
    system += "\n每日记录的body_weight_kg是该日实际测量，body_weight_history只列有测量的日期；多天输入可能重复带上同一段历史，必须按日期去重，不能算成多次测量。不得补齐漏记、用资料weight代替每日体重、把测量次数说成连续天数或用短期体重波动认定增肌减脂成果。问卷体重与每日测量分开引用，日期不同不能强行覆盖；趋势说明实际跨度与样本数量，数据不足就说明不足。"
    from ai_core import analysis_facts, candidate_prompt
    system += '\n' + candidate_prompt()
    if payload.get('coaching_version') == 1:
        system += "\n本次质量要求：JSON字段各自用完整段落，不缩成摘要。summary约180字；training至少350字；recovery至少250字；reason至少220字。每段都有输入依据、局限和对应行动，不用增加不存在的事实凑字。只输出规定字段，notes与photoFeedback为字符串数组。"
        if payload.get('scope') == 'training':
            system += "\n本次明确只做训练复盘。nutrition只写‘本次选择仅训练复盘，不评价饮食是否达标。’。其余字段及notes不得讨论餐食缺失、要求记录饮食、把饮食不完整作为不调整计划的原因。无体重、无照片、无健康授权均不是禁止沿用计划的理由。以已保存动作数据和自报感受给出训练判断，不要求用户凑第二个动作、增加训练日或称重来证明记录有效。"
        else:
            system += "\nnutrition至少300字，先讲已确认完整的日期，再分析真实营养数据与估计目标的关系；未确认日期不能据记录量判定实际摄入不足。"
    if payload.get('coaching_version') == 1:
        from ai_core import coaching_contract
        system += coaching_contract()
    content = [{'type':'text','text':canonical({'date':request['date'], **{k:v for k,v in payload.items() if k!='photos'}, '数据口径':analysis_facts(request)})}]
    for photo in payload['photos']:
        content.extend([{'type':'text','text':photo['label']}, {'type':'image_url','image_url':{'url':'data:image/jpeg;base64,'+photo['image_base64']}}])
    return [{'role':'system','content':system}, {'role':'user','content':content if payload['photos'] else content[0]['text']}]


def clean_result(request, result, helpers):
    text, number, sequence, iso_date = helpers
    if result['kind']!='weekly_review' or result['decision'] not in ('keep','adjust','insufficient'):
        raise ValueError('weekly shape')
    clean = {'kind':'weekly_review','decision':result['decision'], **{k:text(result[k],1500,allow_empty=(k=='appearance' and not request['payload']['photos'])) for k in ('summary','training','nutrition','recovery','appearance','reason')}}
    clean['notes']=[text(v,500) for v in sequence(result['notes'],8)]
    clean['photoFeedback']=[text(v,500) for v in sequence(result.get('photoFeedback',[]),8)]
    if not request['payload']['photos']:
        clean['appearance']='本次未提供照片，无法观察外观变化；请结合训练表现与测量趋势复盘。'
        clean['photoFeedback']=[]
    # Apply the same rule to every user-visible field, not just appearance.
    for key in ('summary','training','nutrition','recovery','appearance','reason'):
        clean[key] = sanitize_composition_text(clean[key], request['payload']['survey'])
    for key in ('notes','photoFeedback'):
        clean[key] = [sanitize_composition_text(v, request['payload']['survey']) for v in clean[key]]
    blocked_prescription = False
    generated_reason = False
    excluded_movement = False
    sessions=[]; seen=set(); end=iso_date(request['date'])
    venue_profile = {**request['payload']['profile'], 'trainingDays':request['payload']['survey']['trainingDays']}
    if request['payload']['survey']['pain']!='无疼痛':
        blocked_prescription = True
        clean['decision']='insufficient'; clean['reason']='你报告了疼痛或尚未明确疼痛状态，请先评估身体情况，本次不自动提出训练调整。'
        generated_reason = True
    if clean['decision']=='adjust':
        for session in sequence(result.get('sessions',[]),7,1):
            date=iso_date(session['date'])
            if not 1 <= (date-end).days <= 7 or date in seen: raise ValueError('unsafe plan date')
            if date.isoweekday() not in request['payload']['survey']['trainingDays']:
                raise ValueError('unselected weekly training day')
            seen.add(date); exercises=[]
            for exercise in sequence(session['exercises'],6,2):
                sets=[]
                for entry in sequence(exercise['sets'],5,1):
                    duration=None if entry.get('durationSeconds') is None else number(entry['durationSeconds'],1,3600,True)
                    sets.append({'weight':None,'reps':number(entry['reps'],1,30,True) if duration is None else 0,**({'durationSeconds':duration} if duration is not None else {})})
                query = text(exercise.get('library_query',''),100,True).strip()
                if any(ord(char) > 127 for char in query):
                    raise ValueError('library query must be English')
                from ai_core import home_movements, is_home_session, movement_reference, requires_duration, recommended_reference
                if recommended_reference(query) is None:
                    excluded_movement = True
                if requires_duration(query, exercise.get("name", "")) and any(s.get("durationSeconds") is None for s in sets):
                    raise ValueError("static hold requires durationSeconds")
                if is_home_session(venue_profile, date) and query.casefold() not in home_movements(request['payload']['profile']):
                    raise ValueError('unavailable home movement or equipment')
                exercises.append({'name':text(exercise['name'],100),'muscle':text(exercise['muscle'],100),'library_query':query,'library_id':movement_reference(query),'sets':sets})
            venue = '居家' if is_home_session(venue_profile, date) else '健身房'
            label = text(session['label'],270)
            if venue_profile['venue'] == '两者都有': label += ' · ' + venue
            sessions.append({'date':date.isoformat(),'label':label,'exercises':exercises})
        if len(sessions)!=request['payload']['survey']['days']: raise ValueError('frequency')
        # A weekly adjustment may only be justified by training the user
        # explicitly saved/confirmed, exactly like review_readiness. Legacy
        # requests have no confirmation flag and keep their historical baseline.
        modern = request['payload'].get('review_version') == 1
        evidence_days = request['payload']['days'] if not modern else [day for day in request['payload']['days'] if day.get('training_confirmed') is True]
        past_sets=sum(sum(s['completed'] and (s['durationSeconds']>0 if s.get('durationSeconds') is not None else s['reps']>0) for s in ex['sets']) for day in evidence_days for ex in day['exercises'])
        proposed=sum(len(ex['sets']) for day in sessions for ex in day['exercises'])
        completed_days=sum(any(s['completed'] and (s['durationSeconds']>0 if s.get('durationSeconds') is not None else s['reps']>0) for ex in day['exercises'] for s in ex['sets']) for day in evidence_days)
        past_units = completed_training_units(evidence_days)
        proposed_units = completed_training_units(sessions, proposed=True)
        excessive_units = any(proposed_units[key] > past_units[key] * 1.2 for key in ('reps', 'seconds'))
        excessive_set = any(proposed_units[key] > past_units[key] * 1.2 for key in ('max_reps', 'max_seconds'))
        past_actions = action_units(evidence_days)
        next_actions = action_units(sessions, proposed=True)
        excessive_action = any(name not in past_actions or any(values[key] > past_actions[name][key] * 1.2 for key in values) for name, values in next_actions.items())
        excessive_session = any(sum(s.get('durationSeconds', 0) for ex in day['exercises'] for s in ex['sets']) > request['payload']['profile']['sessionMinutes'] * 60 for day in sessions)
        if completed_days < 2 or not past_sets or proposed > past_sets * 1.2 or excessive_units or excessive_set or excessive_action or excessive_session:
            blocked_prescription = True
            clean['decision']='insufficient';sessions=[]
            clean['reason']=(
                f"暂不提供自动应用：本周实际登记了{completed_days}个有完成组的日期、{past_sets}组训练，"
                f"返回的候选安排含{proposed}组。训练日期数量、总组数、逐个同名动作的次数或秒数、单次安排长度中，至少一项缺少已完成基线或超出允许的小幅调整范围。"
                "这个判断针对候选安排，不代表你本周训练做得不好，也不把尚未登记的动作视为没练。"
                "建议中的新增动作不能借用其他动作的组数当作基线；下周可训练偏好与本周实际天数不同也不是资料冲突。"
                "先确认本周动作、组数、次数或持续秒数是否已经记齐；缺少相关动作记录时，先补充真实完成情况。"
                "本次未保存或自动应用候选安排，当前计划保持原样；补全记录后再复盘，并在计划比较页面逐日确认是否采用。"
            )
            generated_reason = True
    if excluded_movement:
        blocked_prescription = True
        clean['decision'] = 'insufficient'
        sessions = []
        clean['reason'] += ' 本次候选调整还包含推荐动作库之外的动作，未提供自动应用；原训练记录和原计划保留。请在动作库中手动选择替换动作。'
    from ai_core import analysis_text, validate_output_prose
    blocked_prescription = blocked_prescription or clean['decision'] != 'adjust'
    # If the structured candidate was blocked, its prose cannot still instruct
    # the user to perform the very same unconfirmed change. reason is included:
    # a "keep/insufficient" decision must not leak a dose prescription there.
    for key in ('summary','training','nutrition','recovery','appearance'):
        clean[key] = analysis_text(clean[key], blocked_prescription)
    if blocked_prescription and not generated_reason:
        clean['reason'] = analysis_text(clean['reason'], True)
    clean['notes'] = [analysis_text(note, blocked_prescription) for note in clean['notes']]
    for key in ('summary','training','nutrition','recovery','appearance','reason'):
        validate_output_prose(clean[key])
    for key in ('notes','photoFeedback'):
        for item in clean[key]:
            validate_output_prose(item)
    clean['sessions']=sessions
    from ai_core import validate_coaching
    validate_coaching(request, clean)
    return clean


def sanitize_composition_text(value, survey):
    pattern = re.compile(r'(?:体脂(?:率|百分比)?|肌肉(?:量|重量|增长量)|body\s*fat|muscle\s*(?:mass|weight))[^。！？!?\n，,；;]{0,24}\d|\d[^。！？!?\n，,；;]{0,12}(?:[%％][^。！？!?\n，,；;]{0,12}(?:体脂|body\s*fat)|(?:公斤|千克|kg)[^。！？!?\n，,；;]{0,12}(?:肌肉|muscle))', re.I)
    pieces = re.split(r'(?<=[。！？!?\n])', value)
    out = []
    for sentence in pieces:
        if not pattern.search(sentence):
            out.append(sentence); continue
        measured = survey.get('bodyFat')
        source = survey.get('bodyFatSource', '').strip()
        photo_claim = re.search(r'照片|图中|目测|看起来|看图|photo|image|visual', sentence, re.I)
        muscle = re.search(r'肌肉(?:量|重量|增长量)|muscle', sentence, re.I)
        # A matching, explicitly sourced self-measurement may be reported unchanged.
        number_match = measured is not None and re.search(r'(?<![\d.])'+re.escape(f'{measured:g}')+r'(?:\.0+)?\s*[%％]',sentence)
        percentages = re.findall(r"(\d+(?:\.\d+)?)\s*[%％]", sentence)
        only_measured = bool(percentages) and all(float(v) == measured for v in percentages)
        if source and source in sentence and number_match and only_measured and not photo_claim and not muscle:
            out.append(sentence)
        else:
            out.append('照片无法可靠测量体脂或肌肉量；请以注明来源的实际测量及长期趋势为依据。')
    return ''.join(out)


def completed_training_units(days, proposed=False):
    totals = {'reps':0, 'seconds':0, 'max_reps':0, 'max_seconds':0}
    for day in days:
        for ex in day['exercises']:
            for entry in ex['sets']:
                if not proposed and not entry.get('completed'):
                    continue
                timed = entry.get('durationSeconds') is not None
                key = 'seconds' if timed else 'reps'
                amount = entry['durationSeconds'] if timed else entry['reps']
                if amount <= 0: continue
                totals[key] += amount
                totals['max_'+key] = max(totals['max_'+key], amount)
    return totals


def action_units(days, proposed=False):
    groups = {}
    for day in days:
        for exercise in day['exercises']:
            name = ' '.join(unicodedata.normalize('NFKC', exercise['name']).casefold().split())
            groups.setdefault(name, []).append(exercise)
    return {name: completed_training_units([{'exercises': exercises}], proposed) for name, exercises in groups.items()}


def review_readiness(raw, clean, end, today=None):
    """Run before queue insertion and before any paid provider call."""
    from ai_core import AIError, iso_date, sequence, number, text
    from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
    modern = raw.get('review_version') == 1
    if 'review_version' in raw: number(raw['review_version'], 1, 1, True)
    scope = raw.get('scope', 'combined' if modern else 'training')
    if scope not in ('training', 'combined'): raise ValueError('invalid review scope')
    try: zone = ZoneInfo(text(raw.get('timeZone', 'Asia/Shanghai'), 100))
    except ZoneInfoNotFoundError: raise ValueError('invalid review time zone') from None
    today = today or dt.datetime.now(zone).date()
    if end >= today:
        raise AIError('weekly_not_ready', '本训练周期尚未结束。可以先看本地小结、安排下一周，周期结束后再复盘。')
    start = end - dt.timedelta(days=6)
    planned = []
    if modern:
        cycle = raw['cycle']
        start = iso_date(cycle['start'])
        if not 0 <= (end-start).days <= 6 or iso_date(cycle.get('endDate') or (start+dt.timedelta(days=6)).isoformat()) != end:
            raise ValueError('review cycle mismatch')
        planned = sequence(cycle['plannedDates'], 7)
        if len(set(planned)) != len(planned) or any(not start <= iso_date(d) <= end for d in planned): raise ValueError('invalid planned dates')
        expected = {(start+dt.timedelta(days=n)).isoformat() for n in range((end-start).days+1)}
        if {day['date'] for day in clean['days']} != expected: raise ValueError('all cycle days required')
        if any(not clean['survey'][key].strip() for key in ('fatigue','pain','difficulty')) or (scope == 'combined' and not clean['survey']['diet'].strip()):
            raise AIError('weekly_not_ready', '请先回答疲劳感、训练难度、疼痛情况及适用的饮食反馈。')
    training_days = sum(any(s['completed'] and (s.get('durationSeconds', 0) or s['reps']) > 0 for ex in day['exercises'] for s in ex['sets']) and (day.get('training_confirmed') is True if modern else True) for day in clean['days'])
    food_days = sum(bool(day['meals']) and day.get('meals_complete') is True and all(m.get('nutrition_known', True) for m in day['meals']) for day in clean['days'])
    needed = 1 if modern and len(planned) == 1 else 2
    if training_days < needed:
        raise AIError('weekly_not_ready', f'本周期至少需要 {needed} 个真实完成并保存的训练日，当前可用 {training_days} 天。先保留记录，也可以直接沿用计划。')
    if scope == 'combined' and food_days < 3:
        raise AIError('weekly_not_ready', f'综合复盘需要至少 3 天已确认记完且营养数据完整的饮食，当前 {food_days} 天；可以先选择训练复盘。')
    cycle_result = {'start':start.isoformat(),'plannedDates':planned}
    if modern and 'endDate' in raw['cycle']: cycle_result['endDate'] = end.isoformat()
    return {'scope':scope, 'cycle':cycle_result,
            'readiness':{'confirmedTrainingDays':training_days,'completeFoodDays':food_days,'requiredTrainingDays':needed},
            **({'review_version':1,'timeZone':str(zone)} if modern else {})}
