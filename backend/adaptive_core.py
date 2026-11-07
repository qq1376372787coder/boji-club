"""Strict parameter-only proposals against the exact submitted future plan."""
import copy
import datetime as dt
import uuid

def clean_upcoming(raw, date, helpers):
    text, number, sequence, iso_date = helpers
    start = iso_date(date)
    rows=[]; seen=set()
    for session in sequence(raw, 7):
        key=iso_date(session['date'])
        if not 1 <= (key-start).days <= 7 or key in seen: raise ValueError('proposal outside future window')
        seen.add(key); exercises=[]
        for ex in sequence(session['exercises'],30,1):
            sets=[]; units=set()
            for item in sequence(ex['sets'],50,1):
                duration=item.get('durationSeconds');units.add(duration is not None)
                sets.append({'weight':number(item.get('weight') or 0,0,2000),
                    'reps':0 if duration is not None else number(item['reps'],1,1000,True),
                    **({'durationSeconds':number(duration,1,21600,True)} if duration is not None else {})})
            if len(units)!=1: raise ValueError('mixed proposal units')
            value={'name':text(ex['name'],100),'muscle':text(ex['muscle'],100),'sets':sets}
            for field in ['library_id','library_query','custom_id','custom_unit']:
                if ex.get(field) is not None: value[field]=text(ex[field],100)
            if value.get('custom_id'):value['custom_id']=str(uuid.UUID(value['custom_id']))
            if ex.get('rest_seconds') is not None: value['rest_seconds']=number(ex['rest_seconds'],0,3600,True)
            exercises.append(value)
        rows.append({'date':key.isoformat(),'label':text(session['label'],100),'exercises':exercises})
    return sorted(rows,key=lambda s:s['date'])

def supported_increase(payload, movement, value, before):
    if before<=0 or value>before+max(2.5,before*0.05):return False
    identity='custom_id' if movement.get('custom_id') else 'library_id'
    if not movement.get(identity):return False
    observed=set();sessions=set()
    for day in payload.get('days',[]):
        data=day['payload'];confirmed={s['id'] for s in data.get('workout_sessions',[]) if s.get('confirmed')}
        matching=[ex for ex in data['exercises'] if ex.get(identity)==movement[identity] and ex.get('session_id') in confirmed]
        # Repeated variants within one session cannot be paired by name/order.
        for ex in matching:
            if sum(other.get('session_id')==ex.get('session_id') for other in matching)!=1:continue
            if len(ex['sets'])!=len(movement['sets']):continue
            session=next((s for s in data.get('workout_sessions',[]) if s['id']==ex.get('session_id')),None)
            baseline=(session or {}).get('executionBaseline')
            if not baseline or not ex.get('exercise_id'):continue
            targets=[s for s in baseline.get('sets',[]) if s.get('exerciseID')==ex['exercise_id']]
            actual_by_id={s.get('id'):s for s in ex['sets'] if s.get('id')}
            if len(targets)!=len(movement['sets']) or len(actual_by_id)!=len(ex['sets']):continue
            if any(t.get('unit')!='reps' or t.get('targetWeight') is None or t.get('targetReps') is None for t in targets):continue
            if set(actual_by_id)!={t['id'] for t in targets}:continue
            if any(t['targetWeight']!=(future.get('weight') or 0) for t,future in zip(targets,movement['sets'])):continue
            if any(actual_by_id[t['id']]['reps']<future['reps'] for t,future in zip(targets,movement['sets'])):continue
            if all(actual_by_id[t['id']].get('completed') is True and actual_by_id[t['id']].get('durationSeconds') is None and actual_by_id[t['id']]['weight']==t['targetWeight'] and actual_by_id[t['id']]['reps']>=t['targetReps'] for t in targets):
                observed.add(day['date']);sessions.add(ex['session_id'])
    return len(observed)>=2 and len(sessions)>=2

def clean_proposal(request, raw, helpers):
    text, sequence, iso_date = helpers
    if raw is None: return None
    payload=request['payload']; upcoming=payload.get('upcoming',[])
    if not upcoming or payload.get('proposal_allowed') is not True: raise ValueError('proposal not enabled')
    days={row['date']:row for row in upcoming}; changes=[]; seen=set()
    for item in sequence(raw.get('changes'),6,1):
        day=iso_date(item['date']).isoformat();ex=item['exercise'];group=item.get('set');field=item['field'];value=item['value']
        if day not in days or type(ex) is not int or not 0<=ex<len(days[day]['exercises']): raise ValueError('invented movement')
        movement=days[day]['exercises'][ex]
        if field=='rest_seconds':
            if group is not None: raise ValueError('rest belongs to movement')
            before=movement.get(field)
            if type(value) is not int or not 0<=value<=3600: raise ValueError('invalid rest')
        else:
            if type(group) is not int or not 0<=group<len(movement['sets']): raise ValueError('invented group')
            original=movement['sets'][group];before=original.get(field)
            if field=='weight':
                if original.get('durationSeconds') is not None or type(value) not in (int,float) or not 0<=value<=2000: raise ValueError('invalid load')
                if value>before and not supported_increase(payload,movement,value,before):raise ValueError('unproven load increase')
            elif field in ('reps','durationSeconds'):
                if (field=='durationSeconds') != (original.get('durationSeconds') is not None): raise ValueError('unit mutation')
                if type(value) is not int or not 1<=value<=(21600 if field=='durationSeconds' else 1000): raise ValueError('invalid target')
                if value>before*1.2+1: raise ValueError('excessive target increase')
            else: raise ValueError('unsupported parameter')
        key=(day,ex,group,field)
        if key in seen or before==value: raise ValueError('duplicate or unchanged proposal')
        seen.add(key)
        changes.append({'date':day,'exercise':ex,**({'set':group} if group is not None else {}),'field':field,'value':value,'reason':text(item['reason'],400)})
    return {'version':1,'changes':changes,'baseline':copy.deepcopy(upcoming)}

def clean_schedule_proposal(request, raw, helpers):
    """Validate a model-declared schedule intent against the submitted future window.

    The model only names from→to. The baseline is copied from the request, never produced by the model,
    so the client can confirm the same upcoming sessions it showed the user.
    """
    text, sequence, iso_date = helpers
    if raw is None: return None
    payload=request['payload']; upcoming=payload.get('upcoming',[])
    if not upcoming or payload.get('proposal_allowed') is not True: raise ValueError('schedule proposal not enabled')
    if not isinstance(raw, dict): raise ValueError('invalid schedule proposal')
    listed={row['date'] for row in upcoming}
    start=iso_date(request['date'])
    moves=[]; seen_from=set(); seen_to=set()
    for item in sequence(raw.get('moves'),7,1):
        if not isinstance(item, dict): raise ValueError('invalid schedule move')
        source=iso_date(item['from']).isoformat(); target=iso_date(item['to']).isoformat()
        if source not in listed: raise ValueError('schedule move outside upcoming plan')
        if not 1 <= (iso_date(target)-start).days <= 28: raise ValueError('schedule target outside future window')
        if source == target: raise ValueError('schedule move to same day')
        # A target that already owns a session would silently overwrite it, and
        # chaining moves onto another move's source makes the result order-dependent.
        if target in listed: raise ValueError('schedule target already has a session')
        if source in seen_from or target in seen_to or target in seen_from or source in seen_to:
            raise ValueError('duplicate schedule move')
        seen_from.add(source); seen_to.add(target)
        moves.append({'from':source,'to':target})
    if not moves: raise ValueError('empty schedule proposal')
    return {'version':1,'moves':moves,'baseline':copy.deepcopy(upcoming)}

PROPOSAL_RULE = '''
可选参数建议：upcoming仅为未来尚未开始的现有安排，proposal_allowed为true时才允许提出。没有明确证据时不给建议。只改现有动作现有组的weight/reps/durationSeconds或动作rest_seconds，不新增删除动作、不改变日期与计量单位。增加负重必须有至少两个不同日期的确认场次：相同library_id或custom_id、相同组数、各组相同重量且达到原次数，且不能混淆同场重复动作；最多增加原值5%或2.5kg中的较大者，不从自重0推算负重。说明是保守试探，不是力量增长的证明。次数/秒数最多在原值基础上加20%（向上最多1），仍应以保守、可执行为准；不要为了输出而凑建议。最多6项，每项reason说明引用日期与理由。身体限制、未成年或特殊背景不得返回参数处方。可在coach内增加proposal:{changes:[{date,exercise:从0开始的动作下标,set:从0开始的组下标,field,value,reason}]}；休息field=rest_seconds，不含set。没有建议省略proposal。仅为待确认建议，不能声称执行或保存。
日程调整：用户要求把未来某天的安排挪到另一天时，可在coach内增加schedule_proposal:{moves:[{from,to}]}，from必须是upcoming中列出的日期，to必须在请求日期后1—28天内的其它日期，最多7项，from与to分别不重复。不覆盖过去记录、不修改动作内容、不新增或删除训练。只声明待确认意图，不声称已经移动、执行或保存；没有明确请求时省略。
'''

