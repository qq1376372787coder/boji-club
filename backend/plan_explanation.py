"""Plan evidence is built from validated input/output; prose can never veto a valid plan."""
import re
from datetime import date

TOPICS = ('goal', 'schedule', 'selection', 'volume', 'body', 'progression')
TITLES = ('这轮先解决什么', '为什么这样安排训练日', '为什么选择这些动作',
          '组次与顺序怎么理解', '身体资料怎样参与', '接下来怎样调整')

# Numerical evidence is rendered separately. A prose quantity must agree with
# validated inputs or prescription; it cannot manufacture measurements/loads.
UNSUPPORTED = re.compile(
    r'体脂(?:率)?(?:高|低|为|是|超过)|身体年龄|基础代谢(?:率)?(?:为|是)|'
    r'你(?:的)?(?:体态|姿态|代谢|恢复能力|心肺功能).{0,8}(?:差|弱|低|异常)|'
    r'你(?:属于|是)(?:肥胖|超重|偏瘦)|保证.{0,8}(?:安全|增肌|减脂)|'
    r'治愈|诊断为|必须减肥|必须增重|摆烂|废物|肥猪|竹竿|代码|字段|```|'
    r'(?:起始|首次|建议|推荐|采用|使用|设置|加到|加至|负重).{0,12}[0-9０-９零〇一二两三四五六七八九十百千]+公斤|'
    r'[0-9０-９零〇一二两三四五六七八九十百千]+\s*(?:至|到|[-~～—])\s*[0-9０-９零〇一二两三四五六七八九十百千]+')
QUANTITY = re.compile(r'(?<![第零〇一二两三四五六七八九十百千0-9０-９])([0-9０-９]+(?:[.．][0-9０-９]+)?|[零〇一二两三四五六七八九十百千]+(?:点[零〇一二三四五六七八九]+)?)\s*(分钟|公斤|厘米|千卡|天|次|组|秒|岁)')
CN_DIGITS = dict(zip('零〇一二两三四五六七八九', (0, 0, 1, 2, 2, 3, 4, 5, 6, 7, 8, 9)))


def quantity_number(value):
    if re.fullmatch(r'[0-9０-９.．]+', value):
        return float(value.translate(str.maketrans('０１２３４５６７８９．', '0123456789.')))
    whole, _, fraction = value.partition('点')
    if not any(c in whole for c in '十百千'):
        return float(''.join(str(CN_DIGITS[c]) for c in whole) + ('.' + ''.join(str(CN_DIGITS[c]) for c in fraction) if fraction else ''))
    total, digit = 0, 0
    for c in whole:
        if c in CN_DIGITS:
            digit = CN_DIGITS[c]
        else:
            total += (digit or 1) * {'十':10, '百':100, '千':1000}[c]
            digit = 0
    return total + digit + (float('0.' + ''.join(str(CN_DIGITS[c]) for c in fraction)) if fraction else 0)


def clean_prose(value, fallback, allowed_quantities=None, min_chars=20):
    if not isinstance(value, str):
        return fallback
    value = value.strip()
    if not min_chars <= len(value) <= 650 or not re.search(r'[\u4e00-\u9fff]', value):
        return fallback
    if UNSUPPORTED.search(value) or any(ord(c) < 32 and c not in '\n\t' for c in value):
        return fallback
    quantities = allowed_quantities or {}
    for match in QUANTITY.finditer(value):
        if match.start() > 0 and value[match.start()-1] in '负-−﹣－':
            return fallback
        allowed = quantities.get(match[2], set())
        prefix, suffix = value[max(0, match.start()-12):match.start()], value[match.end():match.end()+10]
        if match[2] == '天' and (re.search(r'(?:恢复|休息|间隔|空档)[^，。；！？\n]{0,3}$', prefix) or re.match(r'\s*(?:的)?(?:恢复|休息|空档)', suffix)):
            allowed = quantities.get('_recovery_days', set())
        if match[2] == '次' and re.search(r'(?:每周|本轮|这轮)(?:训练)?$', prefix):
            allowed = quantities.get('_frequency', set())
        if quantity_number(match[1]) not in allowed:
            return fallback
    # Every Arabic number needs a checked quantity/unit; English/code is not
    # rationale prose. Numerical checking is a guardrail, not semantic proof.
    if re.search(r'[0-9０-９A-Za-z]', QUANTITY.sub('', value)):
        return fallback
    return value


def display_number(value):
    return format(float(value), '.12g')


def build_explanation(profile, sessions, raw=None, movement_categories=None,
                      base_sessions=None, purpose_map=None):
    """Called only after core has validated/canonicalized profile and sessions.

    When a 14/28-day plan repeats a validated base week, program facts are
    rebuilt from the full sessions. The model prose is re-checked against the
    full-cycle quantities, so a stale "this round has N sessions" sentence is
    replaced by the verified full-cycle fallback instead of being published.
    """
    raw = raw if isinstance(raw, dict) else {}
    base = base_sessions if isinstance(base_sessions, list) and base_sessions else sessions
    weeks = len(sessions) // len(base) if base and len(sessions) % len(base) == 0 else 1
    multi_week = weeks > 1
    base_movements = sum(len(s['exercises']) for s in base)
    base_sets = sum(len(e['sets']) for s in base for e in s['exercises'])
    dates = [s['date'] for s in sessions]
    movements = sum(len(s['exercises']) for s in sessions)
    sets = sum(len(e['sets']) for s in sessions for e in s['exercises'])
    timed = sum('durationSeconds' in v for s in sessions for e in s['exercises'] for v in e['sets'])
    # Generated movement IDs have already been resolved against the approved
    # catalog. Its classification is stronger evidence than a model's label.
    categories = movement_categories or {}
    muscles = list(dict.fromkeys(categories.get(e.get('library_id'), e['muscle']) for s in sessions for e in s['exercises']))
    background = f"{profile['age']} 岁 · {display_number(profile['height'])} 厘米 · {display_number(profile['weight'])} 公斤"
    minutes = profile.get('sessionMinutes', 45)
    focus = profile.get('focus') or '未指定重点部位'
    venue = profile['venue']
    equipment = '标准健身房器械' if venue == '健身房' else (profile.get('equipment') or '未填写')
    if profile.get('equipmentOther') and venue != '健身房':
        equipment += '、' + profile['equipmentOther']
    schedule_basis = (f"基础周 {len(base)} 个训练日；本周期共 {len(sessions)} 个训练日（{weeks} 周）。日期：{'、'.join(dates)}"
                      if multi_week else
                      f"本轮 {len(sessions)} 个训练日；你填写的单次可用时间 {minutes} 分钟。日期：{'、'.join(dates)}")
    volume_basis = (f"基础周 {base_movements} 项动作、{base_sets} 组；本周期共 {movements} 项动作、{sets} 组，其中 {timed} 组按秒记录。后续周沿用基础周结构且不自动加量；具体组次见每堂课"
                    if multi_week else
                    f"本轮共 {movements} 项动作、{sets} 组，其中 {timed} 组按秒记录；具体组次见每堂课")
    bases = [f"目标：{profile['goal']}；重点：{focus}；经验：{profile['experience']}",
             schedule_basis,
             f"场地：{venue}；器械条件：{equipment}；计划实际覆盖：{'、'.join(muscles)}",
             volume_basis,
             background + '；来源：生成时填写的个人资料',
             '调整依据：实际完成的训练、组间记录、主观难度、疲劳与不适反馈']
    schedule_default = (
        f"这份说明覆盖完整 {weeks} 周：基础周 {len(base)} 课；本周期共 {len(sessions)} 课、{sets} 组。第二周起沿用基础周的动作与组次，不自动加量。训练日期来自你选择的训练日；单次可用时间是安排参考，不是已经测得的训练时长。"
        if multi_week else
        '训练日期来自你选择的训练日，具体安排只覆盖本轮允许的日期。单次可用时间是安排参考，不是已经测得的训练时长；实际耗时还会受到组间休息、器械等待和动作熟悉程度影响。')
    defaults = [
        f"你选择了“{profile['goal']}”，并把“{focus}”列为重点。请结合下方每堂课核对这轮动作是否符合你的目标。训练经验作为个人背景参考，首次执行后的真实反馈仍然决定这份安排是否适合继续。",
        schedule_default,
        '下方列出的动作是这轮实际采用的内容。场地与器械条件用于限制可选动作，居家课堂只采用已登记条件支持的动作。动作顺序以每堂课的列表为准，使用前仍请核对器械与个人限制。',
        ('基础周与后续周动作相同，组次不自动递增。计划中的每组都区分按次和按秒；新方案没有替你猜起始负重，请在实际训练时按能力填写。完成情况和难度反馈会帮助后续复盘。'
         if multi_week else
         '计划中的每组都区分按次和按秒，计时动作的秒数表示动作持续时间。新方案没有替你猜起始负重，请在实际训练时按能力填写。计划组次是待执行安排，完成情况和难度反馈会帮助后续复盘。'),
        '年龄、身高和体重来自生成时的自填资料，作为个人背景参考。当前没有完整的体脂、体态与体能评估，无法据此证明某个动作或固定负重最适合你。身体数字不能替代真实训练反馈。',
        '先按照这轮计划记录实际完成情况，再在周期结束后复盘。后续是否继续原方案、调整动作或训练量，需要结合完成度、难度与恢复反馈，由你核对后采用；不会仅凭资料里的身体数字自动加量。'
    ]
    if profile.get('limitations'):
        bases[4] += '；你填写的限制：' + profile['limitations']
        defaults[4] += '你填写了训练限制，请在执行前逐项核对；这份说明不代表已完成专业评估。'
    context = profile.get('nutritionContext', '普通成人')
    activity = profile.get('dailyActivity', '主要久坐')
    bases[4] += '；特殊背景：' + context + '；日常活动：' + activity
    if context != '普通成人' or profile['age'] < 18:
        defaults[4] += '你的身体背景需要单独核对专业人员的训练建议，不能把普通成人的减脂或强度标准直接套用；这份安排不是医学评估。'
    gaps = {(date.fromisoformat(b) - date.fromisoformat(a)).days - 1
            for a, b in zip(sorted(dates), sorted(dates)[1:])}
    quantities = [{}, {}, {},
                  {'组':{len(e['sets']) for s in sessions for e in s['exercises']},
                   '次':{v['reps'] for s in sessions for e in s['exercises'] for v in e['sets'] if v['reps'] > 0},
                   '秒':{v['durationSeconds'] for s in sessions for e in s['exercises'] for v in e['sets'] if 'durationSeconds' in v}},
                  {'岁':{profile['age']}, '厘米':{profile['height']}, '公斤':{profile['weight']}}, {}]
    background_quantities = {'岁':{profile['age']}, '厘米':{profile['height']}, '公斤':{profile['weight']},
                             '分钟':{minutes}, '天':{len(sessions)}, '_frequency':{len(sessions)}, '_recovery_days':gaps}
    quantities = [{**background_quantities, **specific} for specific in quantities]
    sections = [dict(id=key, title=title, basis=basis,
                     detail=clean_prose(raw.get(key), fallback, checked))
                for key, title, basis, fallback, checked in zip(TOPICS, TITLES, bases, defaults, quantities)]
    raw_purposes = raw.get('sessions')
    by_date = {}
    if isinstance(raw_purposes, list) and len(raw_purposes) <= max(7, len(base)):
        for item in raw_purposes:
            if not isinstance(item, dict) or item.get('date') not in dates:
                continue
            if item['date'] in by_date:
                by_date[item['date']] = None
            else:
                by_date[item['date']] = item
    purpose_map = purpose_map if isinstance(purpose_map, dict) else {}
    purpose_quantities = {'天':{len(sessions)}, '组':{sets}, '_frequency':{len(sessions)}}
    purposes = []
    for index, session in enumerate(sessions):
        ids = [e.get('library_id') for e in session['exercises']]
        item = by_date.get(session['date'])
        # A purpose must refer to this exact class, in its canonical movement order.
        value = item.get('purpose') if item and item.get('exercise_ids') == ids else purpose_map.get(session['date'])
        names = '、'.join(e['name'] for e in session['exercises'])
        fallback = f"本堂安排了{names}。按列表顺序执行并记录实际完成情况，负重由你在训练时填写；这是原方案的课堂安排，调整动作后请重新核对。"
        if multi_week and index >= len(base):
            base_date = base[index % len(base)]['date']
            base_item = by_date.get(base_date)
            base_ids = [e.get('library_id') for e in base[index % len(base)]['exercises']]
            base_value = base_item.get('purpose') if base_item and base_item.get('exercise_ids') == base_ids else purpose_map.get(base_date)
            if base_value:
                value = '沿用基础周的课堂目的：' + base_value
                fallback = '沿用基础周的课堂目的。' + fallback
            else:
                value = None
        purposes.append(dict(date=session['date'], purpose=clean_prose(value, fallback,
                      allowed_quantities=purpose_quantities, min_chars=8)))
    summary = [f"围绕“{profile['goal']}”安排，重点偏好为“{focus}”。",
               (f"基础周 {len(base)} 课；本周期共 {len(sessions)} 课、{sets} 组。第二周起沿用基础周，不自动加量。"
                if multi_week else
                f"按你选定的日期安排 {len(sessions)} 堂课，单次时间参考 {minutes} 分钟。"),
               f"按“{venue}”的器械条件选动作；新方案负重留给实际训练时填写。"]
    return dict(version=1,
                summary=summary,
                sections=sections, sessions=purposes)


def rebuild_explanation(profile, sessions, explanation, base_sessions, movement_categories=None):
    """Rebuild program facts and purposes after the base week was expanded."""
    if not isinstance(explanation, dict): return explanation
    raw = {item.get('id'): item.get('detail') for item in explanation.get('sections', [])
           if isinstance(item, dict) and item.get('id') in TOPICS}
    purposes = {item.get('date'): item.get('purpose') for item in explanation.get('sessions', [])
                if isinstance(item, dict) and isinstance(item.get('date'), str)}
    return build_explanation(profile, sessions, raw, movement_categories,
                             base_sessions=base_sessions, purpose_map=purposes)


PROMPT = '''
本请求需要在同一个JSON中添加 explanation，解释你选择这份真实方案的依据。
结构：{"goal":"目标与重点部位的选择理由","schedule":"训练日和休息安排的理由","selection":"所选动作及顺序的理由","volume":"组次与按秒动作的选择理由","body":"身体资料参与及其局限","progression":"后续调整需要哪些反馈","sessions":[{"date":"该堂课实际日期","exercise_ids":["该堂全部动作的library_id，保持顺序"],"purpose":"这堂课的目的"}]}。
每个说明段落用自然中文写清楚输入资料→本次选择→执行时如何核对，每段约七十至一百八十字；课堂目的简短。针对实际动作解释，不能只重复“个性化、科学、适合你”。
正文优先解释理由，不重复堆砌数值。若确需提及数量，必须与输入资料或本轮实际组次逐项一致；不能编造负重、休息时长或测量值，不写英文缩写。界面另有核验后的数值依据。不要杜撰用户历史、力量、恢复状况、体脂、体态、代谢或身体年龄。不按体重高低给用户贴身材标签，不承诺效果或安全，不给起始负重。
身高体重年龄是自填背景，不能声称它们证明某个动作最合适。重点依据真实目标、经验、所选训练日、可用时间、器械、限制与实际动作。新用户没有完成证据，不批评其出勤或努力；表达直接、细致、有温度，不羞辱身材。
所有说明只对应本轮原方案，sessions逐堂对应允许日期和实际动作。notes继续保留安全提醒，与安排依据分开。
输出前核对：explanation内goal、schedule、selection、volume、body、progression必须全部有完整段落，每段至少七十个汉字；分别回答理由、实际编排选择、用户如何验证，不得缩成一句泛泛结论。volume解释新手如何通过动作质量与真实难度核对组次，不复述具体组数或次数。schedule解释训练日与恢复空档的关系，不复述具体数量或日期。不要为凑长度虚构输入里没有的信息。
'''
