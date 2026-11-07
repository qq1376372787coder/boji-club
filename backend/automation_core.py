from __future__ import annotations
"""Prepare opt-in analyses from the latest cloud revision; never invent surveys."""
import datetime as dt
import hashlib
import json
import uuid
from zoneinfo import ZoneInfo

APPLE_EPOCH = 978307200

def source_revision(payload):
    """Short fingerprint of the source the analysis is built from (C07/B04).

    A changed source gets a new revision value, so a newer report version can be
    recorded while the earlier version stays available.
    """
    return hashlib.sha256(json.dumps(payload, ensure_ascii=False, sort_keys=True, default=str).encode()).hexdigest()[:16]

def identity(owner, mode, key):
    if mode=='daily':
        date=dt.date.fromisoformat(key);part=date.strftime('%Y%m%d');tail=f'{owner:016x}'
        return f'a170da11-{part[:4]}-{part[4:]}-{tail[:4]}-{tail[4:]}'
    return str(uuid.UUID(hashlib.sha256(f'club-auto-v1/{owner}/{mode}/{key}'.encode()).hexdigest()[:32]))

def revised_identity(owner, key, revision):
    """C07: a new report version for a changed source gets its own id.

    The original daily id (identity) is unchanged, so existing reports keep resolving.
    A revised id is derived from owner, date and source revision, so it cannot collide with the original.
    """
    digest=hashlib.sha256(f'club-auto-v2/{owner}/daily/{key}/{revision}'.encode()).hexdigest()[:32]
    return str(uuid.UUID(digest))

def valid_set(item):
    return item.get('completed') is True and (item.get('durationSeconds',0)>0 if item.get('durationSeconds') is not None else item.get('reps',0)>0)

def report_day(state, key, coverage, zone, only_session=None):
    day=state.get('days',{}).get(key,{})
    exercises=[]
    for exercise in day.get('exercises',[]):
        if only_session and (exercise.get('workoutSessionID') or '').lower()!=only_session: continue
        exercises.append({'name':exercise['name'][:100],'exercise_id':exercise['id'],
            **({'session_id':exercise['workoutSessionID']} if exercise.get('workoutSessionID') else {}),
            'sets':[{k:s[k] for k in ('id','weight','reps','completed','durationSeconds') if k in s} for s in exercise['sets']],**({'library_id':exercise['libraryID']} if exercise.get('libraryID') else {}),**({'custom_id':exercise['customExerciseID']} if exercise.get('customExerciseID') else {})})
    sessions=[s for s in (day.get('workoutSessions') or []) if not only_session or (s.get('id') or '').lower()==only_session]
    # Omit deleted/empty session shells, which cannot be analyzed as confirmations.
    relevant={(ex.get('session_id') or '').lower() for ex in exercises if any(valid_set(s) for s in ex['sets'])}
    # A filtered session with no valid set must not leave its exercises behind:
    # the validator would see an exercise session that has no session row.
    if any(ex.get('session_id') for ex in exercises):
        exercises=[ex for ex in exercises if not ex.get('session_id') or (ex.get('session_id') or '').lower() in relevant]
    sessions=[{k:s[k] for k in ('id','startedAt','endedAt','savedAt','executionBaseline','linkedDeviceWorkoutID','pauseIntervals') if k in s} for s in sessions if (s.get('id') or '').lower() in relevant]
    if any(ex.get('session_id') for ex in exercises):
        confirmed=bool(relevant) and relevant=={(s.get('id') or '').lower() for s in sessions} and all(s.get('savedAt') is not None for s in sessions)
    else:
        confirmed=any(valid_set(s) for ex in exercises for s in ex['sets']) and day.get('workoutSavedAt') is not None
    pending=any(s.get('startedAt') is not None and s.get('savedAt') is None for s in (day.get('workoutSessions') or []) if not only_session or (s.get('id') or '').lower()==only_session)
    if not day.get('workoutSessions') and day.get('workoutStartedAt') is not None and day.get('workoutSavedAt') is None:pending=True
    if pending:confirmed=False
    result={'exercises':exercises,'meals':[{**{k:m[k] for k in ('name','calories','protein','carbs','fat')},'nutrition_known':m.get('nutritionKnown') is not False} for m in day.get('meals',[])],
        'timeZone':zone,'coaching_version':1,'analysis_version':2,'training_feedback_version':1,
        'training_confirmed':confirmed,'meals_complete':bool(day.get('meals')) and coverage.get(key) is True,'_routing_version':2,'_automatic_pending_training':pending}
    if day.get('health') is not None:result['health']=day['health']
    if sessions: result['workout_sessions']=sessions
    elif day.get('linkedDeviceWorkoutID') and result.get('health') and any(valid_set(s) for ex in exercises for s in ex['sets']):
        if any(w.get('id')==day['linkedDeviceWorkoutID'] for w in result['health'].get('workouts',[])):result['workout_link']={'device_workout_id':day['linkedDeviceWorkoutID'],'confirmed_by_user':True}
    if (day.get('bodyWeight') or {}).get('kilograms') is not None: result['body_weight_kg']=day['bodyWeight']['kilograms']
    body=day.get('bodyWeight') or {}
    if body.get('bodyFatPercentage') is not None: result['body_fat_percentage']=body['bodyFatPercentage']
    if body.get('waistCircumferenceCM') is not None: result['waist_circumference_cm']=body['waistCircumferenceCM']
    if body.get('recordedAt') is not None: result['body_measurement_recorded_at']=body['recordedAt']
    if body.get('source') is not None: result['body_measurement_source']=body['source']
    result['nutritionTarget']=day.get('nutritionTarget') or {'generalGuidanceOnly':True}
    cycle=day.get('planCycle')
    if cycle: result['planned_training_day']=key in cycle.get('plannedDates',[])
    end=dt.datetime.combine(dt.date.fromisoformat(key)+dt.timedelta(days=1),dt.time(),ZoneInfo(zone)).timestamp()-APPLE_EPOCH
    all_goals=[g for d in state.get('days',{}).values() for g in (d.get('goalVersions') or [])]+state.get('automationGoalBaseline',[])
    goals=sorted({g['id']:g for g in all_goals if g.get('version')==1 and g['recordedAt']<end}.values(),key=lambda g:(g['recordedAt'],g['id']))
    latest=goals[-1] if goals else None
    row={'date':key,'goalVersionID':latest['id'] if latest else None,'profile':latest['profile'] if latest else None,'goalChangedDuringDay':False,'planVersionID':None,'planSource':None}
    if latest:
        start=dt.datetime.combine(dt.date.fromisoformat(key),dt.time(),ZoneInfo(zone)).timestamp()-APPLE_EPOCH
        changes=[g for g in goals if start<=g['recordedAt']<end]
        row['goalChangedDuringDay']=len(changes)>1 or (len(changes)==1 and any(g['recordedAt']<start for g in goals))
    result['goal_context']={'version':1,'start':key,'end':key,'days':[row]}
    return result

def shared_health_has_data(payload):
    """True when the user-confirmed health summary contains any analyzed value.

    Mirrors ai_core's report whitelist so an account that only shared health
    data is eligible for an automatic daily report (AUD-003/FIX-003).
    """
    health=payload.get('health')
    if not isinstance(health,dict): return False
    if health.get('workouts'): return True
    return any(health.get(key) is not None for key in
               ('steps','activeEnergy','heartRate','restingHeartRate','sleep','bodyMass',
                'bodyFatPercentage','leanBodyMass','height','bodyMassIndex','waistCircumference'))

def prepare(body, normalize, now=None, on_skip=None):
    owner=body['owner'];settings=body['settings'];state=body['state']
    # PHP's associative decoder re-encodes an empty object as []; accept only
    # the empty case, never reinterpret a nonempty list as account records.
    if state==[]:state={}
    if not isinstance(state,dict):raise ValueError('automation state must be object')
    days=state.get('days',{})
    if days==[]:days={}
    if not isinstance(days,dict):raise ValueError('automation dates must be object')
    state={**state,'days':days}
    if type(owner) is not int or owner<=0 or settings.get('version')!=1 or type(settings.get('enabled')) is not bool: raise ValueError('automation settings')
    if not settings['enabled']: return []
    for flag in ['daily','weekly','workout','partial']:
        if type(settings.get(flag)) is not bool: raise ValueError('automation flag')
    if type(settings.get('hour')) is not int or not 0<=settings['hour']<=23: raise ValueError('automation hour')
    zone=ZoneInfo(settings['zone']);current=dt.datetime.fromtimestamp(now,zone) if now is not None else dt.datetime.now(zone)
    enabled=float(settings['enabled_at']);today=current.date()
    if enabled>current.timestamp(): return []
    first=dt.datetime.fromtimestamp(enabled,zone).date()
    coverage=body.get('coverage',{}) if body.get('coverage_current') is True else {}
    if coverage==[]:coverage={}
    if not isinstance(coverage,dict):raise ValueError('automation coverage must be object')
    result=[]
    def append(mode,key,date,payload,client=None):
        client=client or identity(owner,mode,key)
        if client in body.get('known_ids',[]) or len(result)>=4:return
        request={'kind':'report' if mode=='daily' else 'coach','date':date,'payload':payload}
        from ai_core import AIError
        try:
            # Hash the normalized payload: the server stores and compares the same cleaned value.
            try:
                cleaned=normalize(request)
            except AIError as error:
                # A day with only a manual fat/waist measurement is already
                # gated above; allow the report payload through empty checks.
                if error.code!='empty_report': raise
                cleaned=normalize(request,allow_empty_report=True)
        except (AIError,ValueError,TypeError,KeyError):
            if on_skip:on_skip({'mode':mode,'date':date,'status':'context_unavailable'})
            return
        request['source_revision']=source_revision(cleaned['payload'])
        result.append({'client_id':client,'mode':mode,'key':key,'request':request})
    if settings['daily']:
        existing=body.get('existing_reports',[])
        # A dict maps date→source revision (C07). A bare list keeps the older behavior: any live report blocks the date.
        known_revisions=existing if isinstance(existing,dict) else {date:None for date in existing}
        for date in [today-dt.timedelta(days=1),today]:
            key=date.isoformat()
            if key in known_revisions and known_revisions[key] is None:continue
            if date<first or dt.datetime.combine(date,dt.time(settings['hour']),zone)>current: continue
            p=report_day(state,key,coverage,settings['zone'])
            if p['_automatic_pending_training']:continue
            actual=any(valid_set(s) for ex in p['exercises'] for s in ex['sets'])
            if not (actual or p['meals'] or p.get('body_weight_kg') or p.get('body_fat_percentage') is not None or p.get('waist_circumference_cm') is not None or shared_health_has_data(p)): continue
            if actual and not p['training_confirmed']: continue
            if not settings['partial'] and (not p['meals_complete'] or (p.get('planned_training_day') and not p['training_confirmed'])): continue
            from ai_core import AIError
            try:
                revision_now=source_revision(normalize({'kind':'report','date':key,'payload':p})['payload'])
            except (AIError,ValueError,TypeError,KeyError):
                if on_skip:on_skip({'mode':'daily','date':key,'status':'context_unavailable'})
                continue
            if key in known_revisions and known_revisions[key]==revision_now: continue
            existing=state.get('aiJobs',[])
            # A live report for this date with a different revision is an earlier version: a new revision is allowed (C07).
            if key not in known_revisions and any(j.get('result',{}).get('kind')=='report' and j.get('request',{}).get('date')==key for j in existing): continue
            # The original id is kept for the first report of a date; only a changed source takes the revised id.
            client=revised_identity(owner,key,revision_now) if key in known_revisions else None
            append('daily',key,key,p,client=client)
    def coach(mode,key,end,session=None):
        cid=identity(owner,mode,key)
        if cid in body.get('known_ids',[]) or len(result)>=4:return
        dates=[end-dt.timedelta(days=i) for i in reversed(range(14 if mode=='weekly' else 7))]
        days=[{'date':d.isoformat(),'payload':report_day(state,d.isoformat(),coverage,settings['zone'],session if d==end else None)} for d in dates if d.isoformat() in state.get('days',{})]
        if not days: return
        p={'version':1,'conversation_id':cid,'history':[],'days':days,'timeZone':settings['zone'],'purpose':mode,'_routing_version':2,
            'question':'生成本次确认训练解读，直白专业、适度幽默。只评价已登记完成和目标，不编造技术、恢复或力量增长；给下一次一个具体行动。' if mode=='workout' else '生成截至请求日期这七天的记录成长报告：训练、饮食覆盖、身体测量、值得肯定和需要改正的行为、下周一件事。此前额外七天只用于上一周对照，缺少可比数据就明确说明，不能把两周合并成一周。锐评有证据的行为，不代填主观感受，不把漏记当作没做。'}
        if mode=='weekly':p['review_scope']={'kind':'completedCalendarWeek','from':(end-dt.timedelta(days=6)).isoformat(),'to':end.isoformat(),'timeZone':settings['zone']}
        if session:p['source_session']=session
        append(mode,key,end.isoformat(),p)
    if settings['workout']:
        for key,day in sorted(state.get('days',{}).items()):
            date=dt.date.fromisoformat(key)
            if not 0<=(today-date).days<=1 or date<first:continue
            for session in (day.get('workoutSessions') or []):
                saved=session.get('savedAt')
                if saved is None or not enabled<=saved+APPLE_EPOCH<=current.timestamp():continue
                sid=session['id'].lower()
                if any(ex.get('workoutSessionID','').lower()==sid and any(valid_set(s) for s in ex['sets']) for ex in day.get('exercises',[])):coach('workout',sid,date,sid)
    if settings['weekly']:
        end=today-dt.timedelta(days=today.weekday()+1);start=end-dt.timedelta(days=6)
        if start>=first:
            rows=[report_day(state,(start+dt.timedelta(days=i)).isoformat(),coverage,settings['zone']) for i in range(7)]
            if sum(p['training_confirmed'] for p in rows)>=2 or sum(p['meals_complete'] for p in rows)>=3:coach('weekly',end.isoformat(),end)
    return result


# =====================================================================
# Data Integrity Engine (DI-001 through DI-031)
# =====================================================================
"""Data Integrity Engine for BOJI CLUB (Build 112 / 0.15.0).
Implements the 31 integrity rules (DI-001 through DI-031), stable issue models,
read-only detection across four trigger modes, and safe derived recalculations.
Raw facts (workouts, meals, weights, user choices) are strictly immutable.
"""
import copy
import dataclasses
import datetime as dt
import hashlib
import json
import re
import uuid
from typing import Any, Callable, Dict, List, Optional, Set, Tuple


@dataclasses.dataclass
class Issue:
    rule_id: str
    rule_version: str
    issue_id: str
    user_id: str
    aggregate_type: str
    aggregate_id: str
    source_version: str
    detected_at: str
    severity: str  # critical, high, medium, low, info
    repair_type: str  # D (derived safe), C (confirmation required), B (blocking invariant)
    status: str  # open, resolved, blocked, deferred, ignored
    evidence: Dict[str, Any]
    message: str
    operation_id: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


@dataclasses.dataclass
class ScanReport:
    scan_id: str
    trigger_type: str  # command_precheck, event_incremental, scheduled_batch, migration_dryrun
    started_at: str
    finished_at: str
    user_ids: List[str]
    rules_checked: List[str]
    rules_deferred: Dict[str, str]
    issues: List[Issue]
    open_issues_count: int
    summary_by_rule: Dict[str, int]
    summary_by_severity: Dict[str, int]
    summary_by_repair_type: Dict[str, int]

    def to_dict(self) -> Dict[str, Any]:
        d = dataclasses.asdict(self)
        d['issues'] = [i.to_dict() for i in self.issues]
        return d


@dataclasses.dataclass
class RepairLog:
    repair_id: str
    issue_id: str
    rule_id: str
    user_id: str
    aggregate_id: str
    source_version: str
    attempted_at: str
    success: bool
    action_taken: str
    details: Dict[str, Any]
    error: Optional[str] = None


def generate_issue_id(rule_id: str, user_id: str, aggregate_type: str, aggregate_id: str, source_version: str) -> str:
    raw = f"{rule_id}:{user_id}:{aggregate_type}:{aggregate_id}:{source_version}"
    return hashlib.sha256(raw.encode('utf-8')).hexdigest()[:16]


RULE_METADATA = {
    "DI-001": {"name": "Object Uniqueness", "repair_type": "B", "severity": "critical", "version": "1.0"},
    "DI-002": {"name": "Workout Session Active Mirror", "repair_type": "D", "severity": "medium", "version": "1.0"},
    "DI-003": {"name": "Confirmed Session Invariants", "repair_type": "B", "severity": "high", "version": "1.0"},
    "DI-004": {"name": "Historical / Started Workout Overwrite Protection", "repair_type": "B", "severity": "critical", "version": "1.0"},
    "DI-005": {"name": "Execution Baseline Immutability", "repair_type": "B", "severity": "high", "version": "1.0"},
    "DI-006": {"name": "Cycle Ownership Interval Consistency", "repair_type": "D", "severity": "medium", "version": "1.0"},
    "DI-007": {"name": "Cycle PlannedDates Derivation", "repair_type": "D", "severity": "medium", "version": "1.0"},
    "DI-008": {"name": "Same-day Mutual Exclusion Replacement", "repair_type": "B", "severity": "critical", "version": "1.0"},
    "DI-009": {"name": "Acyclic Version History", "repair_type": "B", "severity": "high", "version": "1.0"},
    "DI-010": {"name": "Operation Audit Traceability", "repair_type": "B", "severity": "medium", "version": "1.0"},
    "DI-011": {"name": "Transactional Outbox & Operation Atomicity", "repair_type": "D", "severity": "high", "version": "1.0"},
    "DI-012": {"name": "Consumer Watermark & Event Idempotency", "repair_type": "D", "severity": "high", "version": "1.0"},
    "DI-013": {"name": "Background Task Lease & Timeout Protection", "repair_type": "D", "severity": "medium", "version": "1.0"},
    "DI-014": {"name": "Meal Nutrition Structural Self-Consistency", "repair_type": "D", "severity": "medium", "version": "1.0"},
    "DI-015": {"name": "AI Food Recognition Placement Uniqueness", "repair_type": "C", "severity": "medium", "version": "1.0"},
    "DI-016": {"name": "Media Reference & Tombstone Integrity", "repair_type": "D", "severity": "high", "version": "1.0"},
    "DI-017": {"name": "Profile Single Authority vs Projection", "repair_type": "D", "severity": "high", "version": "1.0"},
    "DI-018": {"name": "Body Measurements vs Profile Target Separation", "repair_type": "B", "severity": "high", "version": "1.0"},
    "DI-019": {"name": "HealthKit Export Session Deduplication", "repair_type": "D", "severity": "medium", "version": "1.0"},
    "DI-020": {"name": "HealthKit Deletion & Anchor Pipeline", "repair_type": "D", "severity": "high", "version": "1.0"},
    "DI-021": {"name": "HealthKit Write-out Generation Guard", "repair_type": "B", "severity": "high", "version": "1.0"},
    "DI-022": {"name": "AI Context Envelope & Scope Boundaries", "repair_type": "B", "severity": "high", "version": "1.0"},
    "DI-023": {"name": "AI Execution Intent Hash Binding", "repair_type": "B", "severity": "critical", "version": "1.0"},
    "DI-024": {"name": "Report Archive Single Current Invariant", "repair_type": "D", "severity": "high", "version": "1.0"},
    "DI-025": {"name": "Confirmed Training Statistics Methodology", "repair_type": "D", "severity": "medium", "version": "1.0"},
    "DI-026": {"name": "Push Budget Category Contract & Invariants", "repair_type": "B", "severity": "high", "version": "1.0"},
    "DI-027": {"name": "Business Timezone & Date Boundaries", "repair_type": "B", "severity": "high", "version": "1.0"},
    "DI-028": {"name": "Membership Verified Entitlement Recomputation", "repair_type": "D", "severity": "high", "version": "1.0"},
    "DI-029": {"name": "Account Deletion Process Traceability", "repair_type": "B", "severity": "critical", "version": "1.0"},
    "DI-030": {"name": "Schema DDL & Migration Watermark Match", "repair_type": "B", "severity": "critical", "version": "1.0"},
    "DI-031": {"name": "Cross-Storage Backup & Watermark Consistency", "repair_type": "D", "severity": "critical", "version": "1.0"}
}


class DataIntegrityEngine:
    def __init__(self):
        self.rules = RULE_METADATA
        self.repair_logs: List[RepairLog] = []

    def scan(self, state: Dict[str, Any], trigger_type: str = "scheduled_batch") -> ScanReport:
        started_at = dt.datetime.now(dt.timezone.utc).isoformat()
        user_id = str(state.get("user_id") or state.get("owner") or "anonymous")
        source_version = str(state.get("revision") or state.get("version") or "v1")
        now_str = dt.datetime.now(dt.timezone.utc).isoformat()
        
        issues: List[Issue] = []
        rules_checked: List[str] = []
        rules_deferred: Dict[str, str] = {}

        # -------------------------------------------------------------
        # DI-001: Object uniqueness per account, type, ID
        # -------------------------------------------------------------
        rules_checked.append("DI-001")
        seen_exercises: Dict[str, str] = {}
        for day_str, day_data in state.get("days", {}).items():
            if not isinstance(day_data, dict):
                continue
            for ex in day_data.get("exercises", []):
                ex_id = str(ex.get("id") or "")
                if ex_id:
                    if ex_id in seen_exercises and seen_exercises[ex_id] != day_str:
                        iid = generate_issue_id("DI-001", user_id, "exercise", ex_id, source_version)
                        issues.append(Issue(
                            rule_id="DI-001", rule_version="1.0", issue_id=iid,
                            user_id=user_id, aggregate_type="exercise", aggregate_id=ex_id,
                            source_version=source_version, detected_at=now_str,
                            severity="critical", repair_type="B", status="open",
                            evidence={"duplicate_id": ex_id, "days": [seen_exercises[ex_id], day_str]},
                            message=f"Duplicate exercise ID {ex_id} reused across distinct dates."
                        ))
                    else:
                        seen_exercises[ex_id] = day_str

        # -------------------------------------------------------------
        # DI-002: Workout session active mirror consistency
        # -------------------------------------------------------------
        rules_checked.append("DI-002")
        for day_str, day_data in state.get("days", {}).items():
            if not isinstance(day_data, dict):
                continue
            sessions = day_data.get("workoutSessions", [])
            active_id = day_data.get("activeWorkoutSessionID")
            top_exercises = day_data.get("exercises")
            if sessions and active_id:
                active_sess = next((s for s in sessions if str(s.get("id")) == str(active_id)), None)
                if active_sess:
                    active_exs = active_sess.get("exercises", [])
                    if json.dumps(active_exs, sort_keys=True) != json.dumps(top_exercises, sort_keys=True):
                        iid = generate_issue_id("DI-002", user_id, "day", day_str, source_version)
                        issues.append(Issue(
                            rule_id="DI-002", rule_version="1.0", issue_id=iid,
                            user_id=user_id, aggregate_type="day", aggregate_id=day_str,
                            source_version=source_version, detected_at=now_str,
                            severity="medium", repair_type="D", status="open",
                            evidence={"active_session_id": active_id, "date": day_str},
                            message="Top-level day exercises mirror diverges from active workout session."
                        ))

        # -------------------------------------------------------------
        # DI-003: Confirmed session invariants
        # -------------------------------------------------------------
        rules_checked.append("DI-003")
        for day_str, day_data in state.get("days", {}).items():
            if not isinstance(day_data, dict):
                continue
            if day_data.get("training_confirmed"):
                exercises = day_data.get("exercises", [])
                completed_sets = 0
                for ex in exercises:
                    for s in ex.get("sets", []):
                        if s.get("completed"):
                            completed_sets += 1
                if completed_sets == 0 and len(exercises) > 0:
                    iid = generate_issue_id("DI-003", user_id, "day", day_str, source_version)
                    issues.append(Issue(
                        rule_id="DI-003", rule_version="1.0", issue_id=iid,
                        user_id=user_id, aggregate_type="day", aggregate_id=day_str,
                        source_version=source_version, detected_at=now_str,
                        severity="high", repair_type="B", status="open",
                        evidence={"date": day_str, "exercises_count": len(exercises), "completed_sets": 0},
                        message=f"Day {day_str} marked training_confirmed but contains 0 completed sets."
                    ))

        # -------------------------------------------------------------
        # DI-004: Protection of started/completed workouts
        # -------------------------------------------------------------
        rules_checked.append("DI-004")
        pending_plan = state.get("pending_plan_adoption")
        if pending_plan and isinstance(pending_plan, dict):
            for target_date, target_plan in pending_plan.get("days", {}).items():
                existing_day = state.get("days", {}).get(target_date, {})
                if existing_day.get("training_confirmed") or existing_day.get("executionBaseline"):
                    iid = generate_issue_id("DI-004", user_id, "plan_target", target_date, source_version)
                    issues.append(Issue(
                        rule_id="DI-004", rule_version="1.0", issue_id=iid,
                        user_id=user_id, aggregate_type="plan_target", aggregate_id=target_date,
                        source_version=source_version, detected_at=now_str,
                        severity="critical", repair_type="B", status="open",
                        evidence={"target_date": target_date, "conflict": "started_or_confirmed"},
                        message=f"Plan adoption attempts to overwrite started/confirmed workout on {target_date}."
                    ))

        # -------------------------------------------------------------
        # DI-005: executionBaseline immutability
        # -------------------------------------------------------------
        rules_checked.append("DI-005")
        for day_str, day_data in state.get("days", {}).items():
            if not isinstance(day_data, dict):
                continue
            baseline = day_data.get("executionBaseline")
            baseline_mod = day_data.get("executionBaselineModified")
            if baseline and baseline_mod:
                iid = generate_issue_id("DI-005", user_id, "day", day_str, source_version)
                issues.append(Issue(
                    rule_id="DI-005", rule_version="1.0", issue_id=iid,
                    user_id=user_id, aggregate_type="day", aggregate_id=day_str,
                    source_version=source_version, detected_at=now_str,
                    severity="high", repair_type="B", status="open",
                    evidence={"date": day_str, "modified": True},
                    message=f"Frozen executionBaseline on {day_str} was illegally mutated post-start."
                ))

        # -------------------------------------------------------------
        # DI-006: Cycle ownership interval consistency
        # -------------------------------------------------------------
        rules_checked.append("DI-006")
        cycle = state.get("planCycle")
        if cycle and isinstance(cycle, dict):
            start_date = cycle.get("startDate")
            end_date = cycle.get("endDate")
            if start_date and end_date:
                for day_str in cycle.get("plannedDates", []):
                    if day_str < start_date or day_str > end_date:
                        iid = generate_issue_id("DI-006", user_id, "cycle_date", day_str, source_version)
                        issues.append(Issue(
                            rule_id="DI-006", rule_version="1.0", issue_id=iid,
                            user_id=user_id, aggregate_type="cycle_date", aggregate_id=day_str,
                            source_version=source_version, detected_at=now_str,
                            severity="medium", repair_type="D", status="open",
                            evidence={"date": day_str, "cycle_interval": [start_date, end_date]},
                            message=f"Planned date {day_str} falls outside cycle ownership [{start_date}, {end_date}]."
                        ))

        # -------------------------------------------------------------
        # DI-007: Cycle plannedDates derivation vs schedule
        # -------------------------------------------------------------
        rules_checked.append("DI-007")
        if cycle and isinstance(cycle, dict):
            stored_dates = set(cycle.get("plannedDates", []))
            actual_dates = set()
            for d_str, d_obj in state.get("days", {}).items():
                if isinstance(d_obj, dict) and (d_obj.get("exercises") or d_obj.get("plannedSession")):
                    actual_dates.add(d_str)
            start_date = cycle.get("startDate", "")
            end_date = cycle.get("endDate", "9999-99-99")
            cycle_actual = {d for d in actual_dates if start_date <= d <= end_date}
            if stored_dates != cycle_actual:
                iid = generate_issue_id("DI-007", user_id, "cycle", start_date, source_version)
                issues.append(Issue(
                    rule_id="DI-007", rule_version="1.0", issue_id=iid,
                    user_id=user_id, aggregate_type="cycle", aggregate_id=start_date,
                    source_version=source_version, detected_at=now_str,
                    severity="medium", repair_type="D", status="open",
                    evidence={"stored_dates": sorted(stored_dates), "actual_dates": sorted(cycle_actual)},
                    message="Cycle plannedDates array diverges from actual scheduled workouts."
                ))

        # -------------------------------------------------------------
        # DI-008: Same-day mutual exclusion: no union of conflicting plans
        # -------------------------------------------------------------
        rules_checked.append("DI-008")
        for day_str, day_data in state.get("days", {}).items():
            if not isinstance(day_data, dict):
                continue
            plan_variants = day_data.get("plan_variants", [])
            if len(plan_variants) > 1:
                iid = generate_issue_id("DI-008", user_id, "day", day_str, source_version)
                issues.append(Issue(
                    rule_id="DI-008", rule_version="1.0", issue_id=iid,
                    user_id=user_id, aggregate_type="day", aggregate_id=day_str,
                    source_version=source_version, detected_at=now_str,
                    severity="critical", repair_type="B", status="open",
                    evidence={"date": day_str, "variant_count": len(plan_variants)},
                    message=f"Mutually exclusive plans unioned on {day_str}; dual schedules detected."
                ))

        # -------------------------------------------------------------
        # DI-009: Acyclic version history
        # -------------------------------------------------------------
        rules_checked.append("DI-009")
        plan_versions = state.get("planVersions", [])
        graph = {}
        for pv in plan_versions:
            vid = str(pv.get("id"))
            pid = str(pv.get("parent_id") or "")
            graph[vid] = pid
        for node in graph:
            visited = set()
            curr = node
            while curr and curr in graph:
                if curr in visited:
                    iid = generate_issue_id("DI-009", user_id, "plan_version", node, source_version)
                    issues.append(Issue(
                        rule_id="DI-009", rule_version="1.0", issue_id=iid,
                        user_id=user_id, aggregate_type="plan_version", aggregate_id=node,
                        source_version=source_version, detected_at=now_str,
                        severity="high", repair_type="B", status="open",
                        evidence={"cycle_node": node},
                        message=f"Illegal cycle detected in planVersions tree at version {node}."
                    ))
                    break
                visited.add(curr)
                curr = graph.get(curr)

        # -------------------------------------------------------------
        # DI-010: Operation audit traceability
        # -------------------------------------------------------------
        rules_checked.append("DI-010")
        operations = state.get("data_operations", [])
        for op in operations:
            if not op.get("operation_id") or not op.get("actor") or "before_version" not in op:
                iid = generate_issue_id("DI-010", user_id, "operation", str(op.get("operation_id", "missing")), source_version)
                issues.append(Issue(
                    rule_id="DI-010", rule_version="1.0", issue_id=iid,
                    user_id=user_id, aggregate_type="operation", aggregate_id=str(op.get("operation_id", "missing")),
                    source_version=source_version, detected_at=now_str,
                    severity="medium", repair_type="B", status="open",
                    evidence={"operation": op},
                    message="Operation record missing required before/after version audit metadata."
                ))

        # -------------------------------------------------------------
        # DI-011: Transactional Outbox & Operation Atomicity
        # -------------------------------------------------------------
        rules_checked.append("DI-011")
        if "domain_outbox" in state:
            outbox_ops = {evt.get("operation_id") for evt in state.get("domain_outbox", []) if evt.get("operation_id")}
            for op in state.get("data_operations", []):
                if op.get("status") == "succeeded" and op.get("operation_id") not in outbox_ops:
                    iid = generate_issue_id("DI-011", user_id, "operation", str(op.get("operation_id")), source_version)
                    issues.append(Issue(
                        rule_id="DI-011", rule_version="1.0", issue_id=iid,
                        user_id=user_id, aggregate_type="operation", aggregate_id=str(op.get("operation_id")),
                        source_version=source_version, detected_at=now_str,
                        severity="high", repair_type="D", status="open",
                        evidence={"operation_id": op.get("operation_id"), "missing_outbox_event": True},
                        message=f"Succeeded operation {op.get('operation_id')} has no corresponding event in domain_outbox."
                    ))
        else:
            rules_deferred["DI-011"] = "Transactional Outbox table (domain_outbox) pending deployment in environment"

        # -------------------------------------------------------------
        # DI-012: Consumer Watermark & Event Idempotency
        # -------------------------------------------------------------
        rules_checked.append("DI-012")
        if "consumer_offsets" in state:
            auth_rev = int(state.get("revision") or 1)
            for consumer, offset in state.get("consumer_offsets", {}).items():
                if int(offset) > auth_rev:
                    iid = generate_issue_id("DI-012", user_id, "consumer", consumer, source_version)
                    issues.append(Issue(
                        rule_id="DI-012", rule_version="1.0", issue_id=iid,
                        user_id=user_id, aggregate_type="consumer", aggregate_id=consumer,
                        source_version=source_version, detected_at=now_str,
                        severity="high", repair_type="D", status="open",
                        evidence={"consumer": consumer, "offset": offset, "authoritative_revision": auth_rev},
                        message=f"Consumer offset {offset} exceeds authoritative revision {auth_rev}."
                    ))
        else:
            rules_deferred["DI-012"] = "Event consumer offset tracking pending deployment in environment"

        # -------------------------------------------------------------
        # DI-013: Background task lease & timeout protection
        # -------------------------------------------------------------
        rules_checked.append("DI-013")
        jobs = state.get("jobs", [])
        now_ts = state.get("current_timestamp", dt.datetime.now(dt.timezone.utc).timestamp())
        for j in jobs:
            if j.get("status") == "running":
                updated = j.get("updated", 0)
                if now_ts - updated > 300:  # 5 min lease timeout
                    iid = generate_issue_id("DI-013", user_id, "job", str(j.get("id")), source_version)
                    issues.append(Issue(
                        rule_id="DI-013", rule_version="1.0", issue_id=iid,
                        user_id=user_id, aggregate_type="job", aggregate_id=str(j.get("id")),
                        source_version=source_version, detected_at=now_str,
                        severity="medium", repair_type="D", status="open",
                        evidence={"job_id": j.get("id"), "elapsed_seconds": now_ts - updated},
                        message=f"Job {j.get('id')} lease expired ({now_ts - updated:.0f}s overdue); hanging worker."
                    ))

        # -------------------------------------------------------------
        # DI-014: Meal nutrition structural self-consistency
        # -------------------------------------------------------------
        rules_checked.append("DI-014")
        for day_str, day_data in state.get("days", {}).items():
            if not isinstance(day_data, dict):
                continue
            for meal in day_data.get("meals", []):
                meal_id = str(meal.get("id", ""))
                components = meal.get("components", [])
                totals = meal.get("nutrition", {})
                if components and totals:
                    c_cals = 0.0
                    has_unknown = False
                    for comp in components:
                        cal = comp.get("calories")
                        if cal is None:
                            has_unknown = True
                        else:
                            c_cals += float(cal)
                    tot_cal = totals.get("calories")
                    if not has_unknown and tot_cal is not None and abs(c_cals - float(tot_cal)) > 1.0:
                        iid = generate_issue_id("DI-014", user_id, "meal", meal_id, source_version)
                        issues.append(Issue(
                            rule_id="DI-014", rule_version="1.0", issue_id=iid,
                            user_id=user_id, aggregate_type="meal", aggregate_id=meal_id,
                            source_version=source_version, detected_at=now_str,
                            severity="medium", repair_type="D", status="open",
                            evidence={"meal_id": meal_id, "component_sum": c_cals, "recorded_total": tot_cal},
                            message=f"Meal {meal_id} component calories ({c_cals}) mismatch declared total ({tot_cal})."
                        ))

        # -------------------------------------------------------------
        # DI-015: AI Food recognition placement uniqueness
        # -------------------------------------------------------------
        rules_checked.append("DI-015")
        ai_sources: Dict[str, List[str]] = {}
        for day_str, day_data in state.get("days", {}).items():
            if not isinstance(day_data, dict):
                continue
            for meal in day_data.get("meals", []):
                src_id = meal.get("ai_source_id")
                if src_id:
                    ai_sources.setdefault(str(src_id), []).append(day_str)
        for s_id, d_list in ai_sources.items():
            if len(d_list) > 1:
                iid = generate_issue_id("DI-015", user_id, "ai_source", s_id, source_version)
                issues.append(Issue(
                    rule_id="DI-015", rule_version="1.0", issue_id=iid,
                    user_id=user_id, aggregate_type="ai_source", aggregate_id=s_id,
                    source_version=source_version, detected_at=now_str,
                    severity="medium", repair_type="C", status="open",
                    evidence={"ai_source_id": s_id, "placed_dates": d_list},
                    message=f"AI food source {s_id} placed across multiple dates: {d_list}."
                ))

        # -------------------------------------------------------------
        # DI-016: Media reference & tombstone integrity
        # -------------------------------------------------------------
        rules_checked.append("DI-016")
        tombstones = set(state.get("deleted_media_ids", []))
        for m_ref in state.get("active_media_refs", []):
            if m_ref in tombstones:
                iid = generate_issue_id("DI-016", user_id, "media", m_ref, source_version)
                issues.append(Issue(
                    rule_id="DI-016", rule_version="1.0", issue_id=iid,
                    user_id=user_id, aggregate_type="media", aggregate_id=m_ref,
                    source_version=source_version, detected_at=now_str,
                    severity="high", repair_type="D", status="open",
                    evidence={"resurrected_media": m_ref},
                    message=f"Deleted media tombstone {m_ref} resurrected in active references."
                ))

        # -------------------------------------------------------------
        # DI-017: Profile single authority vs projection
        # -------------------------------------------------------------
        rules_checked.append("DI-017")
        state_prof = state.get("profile", {})
        proj_prof = state.get("profiles_table_projection", {})
        if state_prof and proj_prof:
            for k in ("age", "gender", "height", "weight"):
                if k in state_prof and k in proj_prof and str(state_prof[k]) != str(proj_prof[k]):
                    iid = generate_issue_id("DI-017", user_id, "profile", k, source_version)
                    issues.append(Issue(
                        rule_id="DI-017", rule_version="1.0", issue_id=iid,
                        user_id=user_id, aggregate_type="profile", aggregate_id=k,
                        source_version=source_version, detected_at=now_str,
                        severity="high", repair_type="D", status="open",
                        evidence={"field": k, "authoritative": state_prof[k], "projection": proj_prof[k]},
                        message=f"Profile projection field '{k}' diverges from authoritative state profile."
                    ))

        # -------------------------------------------------------------
        # DI-018: Body measurements vs profile target separation
        # -------------------------------------------------------------
        rules_checked.append("DI-018")
        for day_str, day_data in state.get("days", {}).items():
            if not isinstance(day_data, dict):
                continue
            meas = day_data.get("body_measurement")
            if meas and isinstance(meas, dict):
                if meas.get("is_synthetic_from_profile"):
                    iid = generate_issue_id("DI-018", user_id, "measurement", day_str, source_version)
                    issues.append(Issue(
                        rule_id="DI-018", rule_version="1.0", issue_id=iid,
                        user_id=user_id, aggregate_type="measurement", aggregate_id=day_str,
                        source_version=source_version, detected_at=now_str,
                        severity="high", repair_type="B", status="open",
                        evidence={"date": day_str, "measurement": meas},
                        message=f"Historical date {day_str} has synthetic measurement backfilled from profile."
                    ))

        # -------------------------------------------------------------
        # DI-019: HealthKit export session deduplication
        # -------------------------------------------------------------
        rules_checked.append("DI-019")
        hk_exports = state.get("healthkit_exports", [])
        seen_sync_ids = set()
        for exp in hk_exports:
            sync_id = exp.get("sync_identifier")
            if sync_id:
                if sync_id in seen_sync_ids:
                    iid = generate_issue_id("DI-019", user_id, "healthkit", sync_id, source_version)
                    issues.append(Issue(
                        rule_id="DI-019", rule_version="1.0", issue_id=iid,
                        user_id=user_id, aggregate_type="healthkit", aggregate_id=sync_id,
                        source_version=source_version, detected_at=now_str,
                        severity="medium", repair_type="D", status="open",
                        evidence={"duplicate_sync_id": sync_id},
                        message=f"Duplicate HealthKit export receipt detected for sync ID {sync_id}."
                    ))
                else:
                    seen_sync_ids.add(sync_id)

        # -------------------------------------------------------------
        # DI-020: HealthKit Deletion & Anchor Pipeline
        # -------------------------------------------------------------
        rules_checked.append("DI-020")
        if "healthkit_anchors" in state:
            for anchor in state.get("healthkit_anchors", []):
                if anchor.get("status") == "corrupted" or not anchor.get("token"):
                    iid = generate_issue_id("DI-020", user_id, "healthkit_anchor", str(anchor.get("type")), source_version)
                    issues.append(Issue(
                        rule_id="DI-020", rule_version="1.0", issue_id=iid,
                        user_id=user_id, aggregate_type="healthkit_anchor", aggregate_id=str(anchor.get("type")),
                        source_version=source_version, detected_at=now_str,
                        severity="high", repair_type="D", status="open",
                        evidence={"anchor": anchor},
                        message=f"HealthKit anchor for {anchor.get('type')} is corrupted or missing token."
                    ))
        else:
            rules_deferred["DI-020"] = "HealthKit incremental anchor & deletion pipeline pending real hardware session"

        # -------------------------------------------------------------
        # DI-021: HealthKit write-out generation guard
        # -------------------------------------------------------------
        rules_checked.append("DI-021")
        for exp in hk_exports:
            if exp.get("generation_mismatch"):
                iid = generate_issue_id("DI-021", user_id, "healthkit_gen", str(exp.get("id")), source_version)
                issues.append(Issue(
                    rule_id="DI-021", rule_version="1.0", issue_id=iid,
                    user_id=user_id, aggregate_type="healthkit_gen", aggregate_id=str(exp.get("id")),
                    source_version=source_version, detected_at=now_str,
                    severity="high", repair_type="B", status="open",
                    evidence={"receipt": exp},
                    message="HealthKit write-out completed under mismatched account generation."
                ))

        # -------------------------------------------------------------
        # DI-022: AI context envelope & scope boundaries
        # -------------------------------------------------------------
        rules_checked.append("DI-022")
        ai_contexts = state.get("ai_contexts", [])
        for ctx in ai_contexts:
            if not ctx.get("owner_scope") or not ctx.get("source_version") or "business_time_zone" not in ctx:
                iid = generate_issue_id("DI-022", user_id, "ai_context", str(ctx.get("context_id", "anon")), source_version)
                issues.append(Issue(
                    rule_id="DI-022", rule_version="1.0", issue_id=iid,
                    user_id=user_id, aggregate_type="ai_context", aggregate_id=str(ctx.get("context_id", "anon")),
                    source_version=source_version, detected_at=now_str,
                    severity="high", repair_type="B", status="open",
                    evidence={"context": ctx},
                    message="AI context envelope missing required owner scope, source version, or timezone."
                ))

        # -------------------------------------------------------------
        # DI-023: AI execution intent hash binding
        # -------------------------------------------------------------
        rules_checked.append("DI-023")
        applied_jobs = state.get("applied_ai_jobs", [])
        for aj in applied_jobs:
            if not aj.get("intent_hash") or not aj.get("expected_version"):
                iid = generate_issue_id("DI-023", user_id, "ai_intent", str(aj.get("job_id")), source_version)
                issues.append(Issue(
                    rule_id="DI-023", rule_version="1.0", issue_id=iid,
                    user_id=user_id, aggregate_type="ai_intent", aggregate_id=str(aj.get("job_id")),
                    source_version=source_version, detected_at=now_str,
                    severity="critical", repair_type="B", status="open",
                    evidence={"applied_job": aj},
                    message=f"Applied AI job {aj.get('job_id')} lacks verified user intent hash binding."
                ))

        # -------------------------------------------------------------
        # DI-024: Report archive single current invariant (R03)
        # -------------------------------------------------------------
        rules_checked.append("DI-024")
        report_archive = state.get("report_archive", [])
        currents_by_scope: Dict[Tuple[str, str, str, str], List[Dict[str, Any]]] = {}
        for r in report_archive:
            if r.get("source_status") == "current":
                key = (str(r.get("owner")), str(r.get("kind")), str(r.get("date")), str(r.get("purpose", "")))
                currents_by_scope.setdefault(key, []).append(r)
        for scope_key, rows in currents_by_scope.items():
            if len(rows) > 1:
                iid = generate_issue_id("DI-024", user_id, "report_scope", f"{scope_key[1]}:{scope_key[2]}", source_version)
                issues.append(Issue(
                    rule_id="DI-024", rule_version="1.0", issue_id=iid,
                    user_id=user_id, aggregate_type="report_scope", aggregate_id=f"{scope_key[1]}:{scope_key[2]}",
                    source_version=source_version, detected_at=now_str,
                    severity="high", repair_type="D", status="open",
                    evidence={"scope": scope_key, "conflicting_job_ids": [r.get("job_id") for r in rows]},
                    message=f"Multiple current reports ({len(rows)}) found for scope {scope_key}."
                ))

        # -------------------------------------------------------------
        # DI-025: Confirmed training statistics methodology
        # -------------------------------------------------------------
        rules_checked.append("DI-025")
        cached_stats = state.get("training_statistics", {})
        if cached_stats:
            actual_confirmed = 0
            for day_str, day_data in state.get("days", {}).items():
                if isinstance(day_data, dict) and day_data.get("training_confirmed"):
                    actual_confirmed += 1
            recorded_confirmed = cached_stats.get("confirmed_sessions_count")
            if recorded_confirmed is not None and recorded_confirmed != actual_confirmed:
                iid = generate_issue_id("DI-025", user_id, "stats", "confirmed_sessions", source_version)
                issues.append(Issue(
                    rule_id="DI-025", rule_version="1.0", issue_id=iid,
                    user_id=user_id, aggregate_type="stats", aggregate_id="confirmed_sessions",
                    source_version=source_version, detected_at=now_str,
                    severity="medium", repair_type="D", status="open",
                    evidence={"recorded": recorded_confirmed, "actual_confirmed": actual_confirmed},
                    message=f"Statistics confirmed count ({recorded_confirmed}) diverges from actual ({actual_confirmed})."
                ))

        # -------------------------------------------------------------
        # DI-026: Push budget category DDL contract (R04)
        # -------------------------------------------------------------
        rules_checked.append("DI-026")
        push_budgets = state.get("club_push_budget", [])
        allowed_classes = {"proactive", "account", "report", "reminder"}
        for pb in push_budgets:
            b_class = pb.get("budget_class")
            if b_class not in allowed_classes:
                iid = generate_issue_id("DI-026", user_id, "push_budget", str(pb.get("semantic_key")), source_version)
                issues.append(Issue(
                    rule_id="DI-026", rule_version="1.0", issue_id=iid,
                    user_id=user_id, aggregate_type="push_budget", aggregate_id=str(pb.get("semantic_key")),
                    source_version=source_version, detected_at=now_str,
                    severity="high", repair_type="B", status="open",
                    evidence={"budget_class": b_class, "allowed": list(allowed_classes)},
                    message=f"Push budget record has illegal budget_class '{b_class}' not in allowed DDL enum."
                ))

        # -------------------------------------------------------------
        # DI-027: Business timezone validity & date boundary (R11)
        # -------------------------------------------------------------
        rules_checked.append("DI-027")
        tz_name = state.get("timeZone") or state.get("businessTimeZone")
        if tz_name:
            from zoneinfo import ZoneInfo
            try:
                ZoneInfo(str(tz_name))
            except Exception:
                iid = generate_issue_id("DI-027", user_id, "timezone", str(tz_name), source_version)
                issues.append(Issue(
                    rule_id="DI-027", rule_version="1.0", issue_id=iid,
                    user_id=user_id, aggregate_type="timezone", aggregate_id=str(tz_name),
                    source_version=source_version, detected_at=now_str,
                    severity="high", repair_type="B", status="open",
                    evidence={"invalid_timezone": tz_name},
                    message=f"Invalid IANA timezone identifier '{tz_name}'."
                ))

        # -------------------------------------------------------------
        # DI-028: Membership verified entitlement recomputation
        # -------------------------------------------------------------
        rules_checked.append("DI-028")
        membership = state.get("membership", {})
        receipts = state.get("verified_receipts", [])
        if membership and receipts is not None:
            now_epoch = dt.datetime.now(dt.timezone.utc).timestamp()
            has_active_receipt = any(r.get("expires_at", 0) > now_epoch for r in receipts)
            if membership.get("is_premium") and not has_active_receipt and not membership.get("manual_gift_until"):
                iid = generate_issue_id("DI-028", user_id, "membership", "entitlement", source_version)
                issues.append(Issue(
                    rule_id="DI-028", rule_version="1.0", issue_id=iid,
                    user_id=user_id, aggregate_type="membership", aggregate_id="entitlement",
                    source_version=source_version, detected_at=now_str,
                    severity="high", repair_type="D", status="open",
                    evidence={"is_premium": True, "active_receipts": 0},
                    message="Membership active entitlement not supported by any verified receipt or manual grant."
                ))

        # -------------------------------------------------------------
        # DI-029: Account deletion process traceability
        # -------------------------------------------------------------
        rules_checked.append("DI-029")
        deletions = state.get("account_deletions", [])
        for del_job in deletions:
            if del_job.get("status") == "completed" and del_job.get("user_data_retained"):
                iid = generate_issue_id("DI-029", user_id, "deletion", str(del_job.get("id")), source_version)
                issues.append(Issue(
                    rule_id="DI-029", rule_version="1.0", issue_id=iid,
                    user_id=user_id, aggregate_type="deletion", aggregate_id=str(del_job.get("id")),
                    source_version=source_version, detected_at=now_str,
                    severity="critical", repair_type="B", status="open",
                    evidence={"deletion_job": del_job},
                    message="Account deletion marked completed but user data is still retained in storage."
                ))

        # -------------------------------------------------------------
        # DI-030: Schema DDL & migration watermark match (R10)
        # -------------------------------------------------------------
        rules_checked.append("DI-030")
        schema_metadata = state.get("schema_metadata", {})
        if schema_metadata:
            missing_cols = schema_metadata.get("missing_columns", [])
            if missing_cols:
                iid = generate_issue_id("DI-030", "system", "schema", "columns", "migration")
                issues.append(Issue(
                    rule_id="DI-030", rule_version="1.0", issue_id=iid,
                    user_id="system", aggregate_type="schema", aggregate_id="columns",
                    source_version="ddl", detected_at=now_str,
                    severity="critical", repair_type="B", status="open",
                    evidence={"missing_columns": missing_cols},
                    message=f"Runtime database missing required schema columns: {missing_cols}."
                ))

        # -------------------------------------------------------------
        # DI-031: Cross-storage backup & watermark consistency
        # -------------------------------------------------------------
        rules_checked.append("DI-031")
        backups = state.get("backups", {})
        if backups:
            mysql_rev = backups.get("mysql_watermark_revision")
            sqlite_rev = backups.get("sqlite_watermark_revision")
            if mysql_rev is not None and sqlite_rev is not None and mysql_rev != sqlite_rev:
                iid = generate_issue_id("DI-031", "system", "backup", "watermark", "divergence")
                issues.append(Issue(
                    rule_id="DI-031", rule_version="1.0", issue_id=iid,
                    user_id="system", aggregate_type="backup", aggregate_id="watermark",
                    source_version="backup", detected_at=now_str,
                    severity="critical", repair_type="D", status="open",
                    evidence={"mysql_rev": mysql_rev, "sqlite_rev": sqlite_rev},
                    message="Backup snapshots have diverged recovery watermarks between MySQL and SQLite."
                ))

        finished_at = dt.datetime.now(dt.timezone.utc).isoformat()
        
        summary_by_rule = {}
        summary_by_severity = {}
        summary_by_repair_type = {}
        for iss in issues:
            summary_by_rule[iss.rule_id] = summary_by_rule.get(iss.rule_id, 0) + 1
            summary_by_severity[iss.severity] = summary_by_severity.get(iss.severity, 0) + 1
            summary_by_repair_type[iss.repair_type] = summary_by_repair_type.get(iss.repair_type, 0) + 1

        return ScanReport(
            scan_id=str(uuid.uuid4()),
            trigger_type=trigger_type,
            started_at=started_at,
            finished_at=finished_at,
            user_ids=[user_id],
            rules_checked=rules_checked,
            rules_deferred=rules_deferred,
            issues=issues,
            open_issues_count=len(issues),
            summary_by_rule=summary_by_rule,
            summary_by_severity=summary_by_severity,
            summary_by_repair_type=summary_by_repair_type
        )

    def repair(self, state: Dict[str, Any], issues: Optional[List[Issue]] = None, dry_run: bool = False) -> Tuple[Dict[str, Any], List[RepairLog]]:
        """Execute verified safe derived repairs (D type only) under strict source_version matching.
        Raw facts and user choices (B / C types) are NEVER modified.
        """
        if issues is None:
            report = self.scan(state)
            issues = report.issues

        target_state = copy.deepcopy(state)
        logs: List[RepairLog] = []
        current_source_version = str(state.get("revision") or state.get("version") or "v1")

        for issue in issues:
            rep_id = str(uuid.uuid4())
            now_str = dt.datetime.now(dt.timezone.utc).isoformat()

            # Safety Gate 1: Check repair type
            if issue.repair_type in ("B", "C"):
                logs.append(RepairLog(
                    repair_id=rep_id, issue_id=issue.issue_id, rule_id=issue.rule_id,
                    user_id=issue.user_id, aggregate_id=issue.aggregate_id,
                    source_version=issue.source_version, attempted_at=now_str,
                    success=False, action_taken="blocked",
                    details={"reason": f"Repair type {issue.repair_type} requires user/admin confirmation or is invariant guard"},
                    error=f"Cannot automatically repair type {issue.repair_type} issue"
                ))
                continue

            # Safety Gate 2: Source version pre-condition check
            if issue.source_version != current_source_version:
                logs.append(RepairLog(
                    repair_id=rep_id, issue_id=issue.issue_id, rule_id=issue.rule_id,
                    user_id=issue.user_id, aggregate_id=issue.aggregate_id,
                    source_version=issue.source_version, attempted_at=now_str,
                    success=False, action_taken="aborted_version_mismatch",
                    details={"expected_version": issue.source_version, "current_version": current_source_version},
                    error="State source_version changed concurrently; aborting repair"
                ))
                continue

            if dry_run:
                logs.append(RepairLog(
                    repair_id=rep_id, issue_id=issue.issue_id, rule_id=issue.rule_id,
                    user_id=issue.user_id, aggregate_id=issue.aggregate_id,
                    source_version=issue.source_version, attempted_at=now_str,
                    success=True, action_taken="dry_run_simulated",
                    details={"rule_id": issue.rule_id}
                ))
                continue

            # Specific D-repairs
            success = False
            action = "unknown"
            details = {}

            if issue.rule_id == "DI-002":
                day_str = issue.aggregate_id
                day_data = target_state.get("days", {}).get(day_str)
                if day_data:
                    active_id = day_data.get("activeWorkoutSessionID")
                    sessions = day_data.get("workoutSessions", [])
                    active_sess = next((s for s in sessions if str(s.get("id")) == str(active_id)), None)
                    if active_sess:
                        day_data["exercises"] = copy.deepcopy(active_sess.get("exercises", []))
                        success = True
                        action = "resynced_active_session_mirror"
                        details = {"day": day_str, "active_id": active_id}

            elif issue.rule_id == "DI-007":
                cycle = target_state.get("planCycle")
                if cycle:
                    start_date = cycle.get("startDate", "")
                    end_date = cycle.get("endDate", "9999-99-99")
                    actual_dates = []
                    for d_str, d_obj in target_state.get("days", {}).items():
                        if isinstance(d_obj, dict) and (d_obj.get("exercises") or d_obj.get("plannedSession")):
                            if start_date <= d_str <= end_date:
                                actual_dates.append(d_str)
                    cycle["plannedDates"] = sorted(actual_dates)
                    success = True
                    action = "rederived_cycle_planned_dates"
                    details = {"plannedDates": cycle["plannedDates"]}

            elif issue.rule_id == "DI-014":
                meal_id = issue.aggregate_id
                repaired = False
                for day_data in target_state.get("days", {}).values():
                    if isinstance(day_data, dict):
                        for meal in day_data.get("meals", []):
                            if str(meal.get("id")) == meal_id:
                                comps = meal.get("components", [])
                                cals = sum(float(c.get("calories", 0)) for c in comps)
                                protein = sum(float(c.get("protein", 0)) for c in comps)
                                carbs = sum(float(c.get("carbs", 0)) for c in comps)
                                fat = sum(float(c.get("fat", 0)) for c in comps)
                                meal["nutrition"] = {"calories": round(cals, 1), "protein": round(protein, 1), "carbs": round(carbs, 1), "fat": round(fat, 1)}
                                repaired = True
                                break
                if repaired:
                    success = True
                    action = "recalculated_meal_nutrition_totals"
                    details = {"meal_id": meal_id}

            elif issue.rule_id == "DI-017":
                state_prof = target_state.get("profile", {})
                if state_prof:
                    target_state["profiles_table_projection"] = copy.deepcopy(state_prof)
                    success = True
                    action = "reprojected_profiles_record"
                    details = {"updated_fields": list(state_prof.keys())}

            elif issue.rule_id == "DI-024":
                # Repair only the exact (owner, kind, date, purpose) scope the issue
                # was detected for; deduplicating across scopes would stale-mark the
                # single legitimate current report of unrelated scopes.
                reports = target_state.get("report_archive", [])
                scope = issue.evidence.get("scope") if isinstance(issue.evidence, dict) else None
                if isinstance(scope, (list, tuple)) and len(scope) == 4:
                    scope_owner, scope_kind, scope_date, scope_purpose = (str(value) for value in scope)
                    scope_reports = [r for r in reports if r.get("source_status") == "current"
                                     and str(r.get("owner")) == scope_owner
                                     and str(r.get("kind")) == scope_kind
                                     and str(r.get("date")) == scope_date
                                     and str(r.get("purpose", "")) == scope_purpose]
                else:
                    scope_reports = []
                    success = False
                    action = "blocked"
                    details = {"reason": "missing_scope_evidence"}
                if len(scope_reports) > 1:
                    scope_reports.sort(key=lambda x: x.get("created", 0), reverse=True)
                    newest = scope_reports[0]
                    for older in scope_reports[1:]:
                        older["source_status"] = "stale"
                        older["source_note"] = "已产生更新版本，本结果变更为历史版本（B05）。"
                    success = True
                    action = "invalidated_stale_current_reports"
                    details = {"retained_current": newest.get("job_id")}

            elif issue.rule_id == "DI-025":
                actual_confirmed = 0
                for day_str, day_data in target_state.get("days", {}).items():
                    if isinstance(day_data, dict) and day_data.get("training_confirmed"):
                        actual_confirmed += 1
                if "training_statistics" in target_state:
                    target_state["training_statistics"]["confirmed_sessions_count"] = actual_confirmed
                    success = True
                    action = "recalculated_confirmed_training_statistics"
                    details = {"new_confirmed_count": actual_confirmed}

            elif issue.rule_id == "DI-028":
                receipts = target_state.get("verified_receipts", [])
                now_epoch = dt.datetime.now(dt.timezone.utc).timestamp()
                has_active = any(r.get("expires_at", 0) > now_epoch for r in receipts)
                if "membership" in target_state:
                    target_state["membership"]["is_premium"] = has_active
                    success = True
                    action = "recomputed_membership_status"
                    details = {"is_premium": has_active}

            logs.append(RepairLog(
                repair_id=rep_id, issue_id=issue.issue_id, rule_id=issue.rule_id,
                user_id=issue.user_id, aggregate_id=issue.aggregate_id,
                source_version=issue.source_version, attempted_at=now_str,
                success=success, action_taken=action, details=details
            ))

        return target_state, logs
