"""Deterministic execution feedback, never a technique/intensity/health score."""
import re

STATUSES={'green':'执行到位','yellow':'还有提升空间','red':'优先调整','gray':'暂不评价'}
UUID=re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')

def valid_id(value):
    if not isinstance(value,str) or not UUID.fullmatch(value.lower()):raise ValueError('invalid execution baseline ID')
    return value.lower()

def clean_baseline(value,number):
    if not isinstance(value,dict):raise ValueError('invalid execution baseline version')
    number(value.get('version'),1,1,True)
    source=value.get('sets')
    if not isinstance(source,list) or not 1<=len(source)<=1500:raise ValueError('invalid execution baseline sets')
    seen=set();rows=[]
    for item in source:
        if not isinstance(item,dict):raise ValueError('invalid execution baseline set')
        sid=valid_id(item.get('id'));eid=valid_id(item.get('exerciseID'))
        if sid in seen:raise ValueError('duplicate execution baseline set')
        seen.add(sid)
        unit=item.get('unit')
        if unit not in ('time','reps'):raise ValueError('invalid execution baseline unit')
        seconds=item.get('targetSeconds')
        if unit=='time':seconds=number(seconds,1,21600,True)
        elif seconds is not None:raise ValueError('unexpected execution baseline time')
        row={'id':sid,'exerciseID':eid,'unit':unit,'targetSeconds':seconds}
        for field,high,integer in [('targetReps',1000,True),('targetWeight',2000,False),('targetRestSeconds',3600,True)]:
            if item.get(field) is not None:
                if unit!='reps' and field!='targetRestSeconds':raise ValueError('unexpected timed target load')
                row[field]=number(item[field],1 if field=='targetReps' else 0,high,integer)
        rows.append(row)
    result={'version':1,'capturedAt':number(value.get('capturedAt'),-978307200,10_000_000_000),'sets':rows}
    if value.get('restSeconds') is not None:result['restSeconds']=number(value['restSeconds'],0,3600,True)
    return result

def complete(item):return item.get('completed') is True and (item.get('durationSeconds',0)>0 if item.get('durationSeconds') is not None else item.get('reps',0)>0)

def feedback(status,reason,evidence,next_step):
    return {'version':1,'status':status,'reason':reason,'evidence':evidence[:8],'next_step':next_step}

def session_feedback(exercises,confirmed,baseline):
    actual=[s for e in exercises for s in e['sets']]
    done=sum(complete(s) for s in actual)
    if not actual:
        return feedback('gray','no_training',['这次训练没有可核对的动作组记录，不能据此判断实际是否训练。'],'先补充实际完成记录，再生成训练反馈。')
    if not confirmed:
        return feedback('gray','unconfirmed',[f'已登记完成{done}组，但这次训练尚未确认结束。'],'训练结束后先确认本次记录；进行中的训练不提前定性。')
    if baseline is None:
        return feedback('gray','missing_baseline',[f'已确认并登记完成{done}组；缺少首次开始记录时的目标对照。'],'继续保留这次记录。下一次开始训练时会保留目标，再评价执行情况。')
    targets=baseline['sets'];ids={s['id'] for s in targets}
    # IDs are essential: deletion or replacement must not manufacture 100% completion.
    current={s['id']:s for s in actual if s.get('id')}
    if len(current)!=len(actual) or not ids.issubset(current):
        return feedback('gray','adjusted_plan',[f'首次记录时有{len(targets)}组目标，本次已登记完成{done}组。','动作或组数已调整，当前记录不能直接替代最初目标作为评价依据。'],'核对调整原因和实际完成量；换动作、删组不自动扣评价，也不自动算原计划全部完成。')
    owners={s['id']:e.get('exercise_id') for e in exercises for s in e['sets'] if s.get('id')}
    if any(owners.get(s['id'])!=s['exerciseID'] for s in targets):
        return feedback('gray','adjusted_plan',['部分组缺少原动作归属，或已移到其他动作，不能作为原目标完整执行的依据。'],'先核对动作和组的归属，保留实际记录后再分析。')
    if any(('time' if current[s['id']].get('durationSeconds') is not None else 'reps')!=s['unit'] for s in targets):
        return feedback('gray','adjusted_plan',['部分组的记录方式由次数与时长相互转换，原目标已不能直接比较。'],'核对调整后的记录方式，下次开始前设定可执行的目标。')
    achieved=sum(complete(current[s['id']]) for s in targets)
    seconds=sum(s['targetSeconds'] or 0 for s in targets)
    actual_seconds=sum(min(current[s['id']].get('durationSeconds') or 0,s['targetSeconds'] or 0) for s in targets if s['unit']=='time' and complete(current[s['id']]))
    extra_done=sum(complete(s) for s in actual if s.get('id') not in ids)
    basis=[f'首次记录时的目标为{len(targets)}组，原目标中已完成并确认{achieved}组。']
    if seconds:basis.append(f'原计时目标合计{seconds}秒，按各组目标核对已登记{actual_seconds}秒；不含组间休息。')
    if extra_done:basis.append(f'另加的{extra_done}组已完成；新增组不会用来补足未完成的原目标。')
    count_ratio=achieved/len(targets)
    time_ratio=actual_seconds/seconds if seconds else 1
    if achieved==len(targets) and time_ratio>=.9:
        return feedback('green','target_completed',basis+['这里只肯定记录中的执行结果，不判断动作标准或实际用力程度。'],'先保持可持续的执行；是否增加次数、时长或负荷，结合实际难度和动作控制再决定。')
    all_timed=all(s['unit']=='time' for s in targets)
    if (len(targets)>=6 and count_ratio<.5) or (all_timed and seconds>=600 and time_ratio<.5):
        return feedback('red','large_gap',basis+['本次已确认结束，与首次记录的目标有较大差距。'],'先核对提前结束的原因。若目标不现实，下次开始前调整到可完成的范围；这次不补写未完成量。')
    return feedback('yellow','partial_completion',basis+['本次已确认结束，原目标仍有未完成的组或计时时长。'],'先明确未完成的原因，按实际情况补正记录或调整下次安排；不要为了变绿勾选没有完成的内容。')

def evaluate(payload):
    exercises=payload.get('exercises',[])
    sessions=payload.get('workout_sessions')
    if not exercises:
        has_device_workout=bool((payload.get('health') or {}).get('workouts'))
        has_started_session=any(s.get('startedAt') or s.get('executionBaseline') for s in sessions or [])
        if payload.get('planned_training_day') is False and not has_device_workout and not has_started_session:
            return feedback('gray','rest_day',['保存的训练周期没有安排这一天训练；休息日不参加训练执行评价。'],'按计划休息；如果今天另外训练了，可以补充实际记录。')
        return feedback('gray','no_training',['没有可核对的动作组记录；未记录不等于没有训练。'],'如果今天练了，先补充实际记录；如果是休息日，不必为了获得颜色安排训练。')
    if not sessions:
        return session_feedback(exercises,payload.get('training_confirmed') is True,None)
    entries=[]
    for session in sessions:
        selected=[e for e in exercises if e.get('session_id')==session['id']]
        has_completion=any(complete(s) for e in selected for s in e['sets'])
        if not has_completion and not session.get('startedAt') and not session.get('executionBaseline'):continue
        entries.append(session_feedback(selected,session.get('confirmed') is True,session.get('executionBaseline')))
    if not entries:return feedback('gray','no_training',['没有可确认的训练执行记录。'],'先核对实际记录和训练归属。')
    if len(entries)==1:return entries[0]
    priority={'gray':3,'red':2,'yellow':1,'green':0}
    ordered=sorted(enumerate(entries),key=lambda pair:priority[pair[1]['status']],reverse=True)
    evidence=[f'第{i+1}次训练：{STATUSES[item["status"]]}。'+item['evidence'][0] for i,item in ordered[:7 if len(entries)>8 else 8]]
    if len(entries)>8:evidence.append(f'本日共{len(entries)}次已有执行记录的训练，以上优先列出需要核对的记录。')
    if any(e['status']=='gray' for e in entries):
        return feedback('gray','partial_context',evidence,'部分训练尚未确认或缺少可比目标，暂不给全天总体评价。先逐次核对记录，再生成反馈。')
    severity={'green':0,'yellow':1,'red':2}
    worst=max(entries,key=lambda e:severity[e['status']])
    return feedback(worst['status'],'multiple_sessions',evidence,worst['next_step'])

def prompt_basis(payload):
    result=evaluate(payload)
    return {'评价范围':'仅评价已记录的训练执行，不是动作技术、实际强度或健康诊断','固定结论':STATUSES[result['status']] if result['reason']!='rest_day' else '按计划休息','依据':result['evidence'],'下一步':result['next_step'],'约束':'颜色和状态由服务端按同一组事实确定。训练正文必须与此结论一致，不能自己重打分、重定颜色，不用未记全的饮食影响训练评价。'}

def model_payload(payload):
    """Keep measurements and session linkage, omit IDs/snapshots unnecessary for prose."""
    output=dict(payload)
    mapping={s['id']:f'第{i+1}次训练' for i,s in enumerate(payload.get('workout_sessions',[]))}
    baselines={s['id']:s.get('executionBaseline') for s in payload.get('workout_sessions',[])}
    exercises=[]
    for exercise in payload.get('exercises',[]):
        record={k:v for k,v in exercise.items() if k not in ('exercise_id','sets')}
        if 'session_id' in record:record['session_id']=mapping.get(record['session_id'],record['session_id'])
        record['sets']=[{k:v for k,v in s.items() if k!='id'} for s in exercise['sets']]
        baseline=baselines.get(exercise.get('session_id'))
        if baseline is not None:
            targets=[s for s in baseline['sets'] if s['exerciseID']==exercise.get('exercise_id')]
            if any('targetReps' in s or 'targetWeight' in s for s in targets) or 'restSeconds' in baseline:
                record['original_targets']=[{k:v for k,v in s.items() if k in ('unit','targetSeconds','targetReps','targetWeight','targetRestSeconds')} for s in targets]
        exercises.append(record)
    output['exercises']=exercises
    if 'workout_sessions' in payload:
        output['workout_sessions']=[{k:(mapping[s['id']] if k=='id' else v) for k,v in s.items() if k!='executionBaseline'} for s in payload['workout_sessions']]
        for source,record in zip(payload['workout_sessions'],output['workout_sessions']):
            baseline=source.get('executionBaseline')
            if baseline is not None and 'restSeconds' in baseline:
                record['original_rest_seconds']=baseline['restSeconds']
                record['original_target_sets']=len(baseline['sets'])
        if any('original_targets' in e for e in exercises):
            output['target_interpretation']='original_targets为这次开始时保留的原目标，sets为当前实际登记，不能相互覆盖。未提供的原目标保持未知。targetRestSeconds为各动作当时设置，original_rest_seconds为训练默认设置；两者仅为目标，不是实测休息时长；原重量0表示自重或未设置，不能推算实际负荷。不能仅凭目标差异断言动作质量、实际强度、力量增长或肌肉变化。'
    return output
