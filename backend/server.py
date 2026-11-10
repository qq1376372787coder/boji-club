"""Internal AI worker. Public clients must use the authenticated account proxy."""
from __future__ import annotations

import concurrent.futures
from contextlib import contextmanager
import hmac
import re
import json
import os
import signal
from pathlib import Path
import sqlite3
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from ai_core import AIError, PROVIDER_DEFAULTS, Router, canonical, fingerprint, load_env, providers_from_env, validate_request, validate_new_plan_start
import fitness_intelligence
import nutrition_engine
import personal_intelligence

BASE = Path(__file__).resolve().parent
PROVIDER_CONFIG_LOCK = threading.Lock()
MAX_WORKERS = 32
JOB_MEMORY_RESERVE = 24 * 1024 * 1024


def resource_snapshot():
    """Only numeric Linux resource counters; never processes, env or user data."""
    values = {'memory_current': None, 'memory_limit': None, 'host_available': None,
              'host_total': None, 'cpu_count': os.cpu_count(), 'php_max_children': None,
              'memory_guard_bytes': None, 'reclaimable_file_cache': None}
    try:
        for line in Path('/proc/meminfo').read_text().splitlines():
            if line.startswith('MemAvailable:'):
                values['host_available'] = int(line.split()[1]) * 1024
            if line.startswith('MemTotal:'):
                values['host_total'] = int(line.split()[1]) * 1024
        for line in Path('/proc/self/cgroup').read_text().splitlines():
            if line.startswith('0::'):
                directory = Path('/sys/fs/cgroup') / line.split('::', 1)[1].lstrip('/')
                values['memory_current'] = int((directory / 'memory.current').read_text())
                stat = dict(line.split() for line in (directory / 'memory.stat').read_text().splitlines())
                # Disk cache is included in memory.current. Clean unmapped files can
                # be reclaimed; do not freeze a queue solely because SQLite files
                # are cached. Dirty/writeback/shared/mapped pages stay in the guard.
                cache = max(0, int(stat.get('file', 0))-sum(int(stat.get(k, 0)) for k in ('shmem','file_dirty','file_writeback','file_mapped')))
                values['reclaimable_file_cache'] = min(cache, values['memory_current'])
                values['memory_guard_bytes'] = values['memory_current']-values['reclaimable_file_cache']
                maximum = (directory / 'memory.max').read_text().strip()
                if maximum != 'max': values['memory_limit'] = int(maximum)
                break
        if values['memory_current'] is None:
            for line in Path('/proc/self/status').read_text().splitlines():
                if line.startswith('VmRSS:'): values['memory_current'] = int(line.split()[1]) * 1024
    except (OSError, ValueError, IndexError):
        pass
    for config_path in ('/etc/php/8.2/fpm/pool.d/www.conf', '/etc/php-fpm.d/www.conf'):
        try:
            match = re.search(r'(?m)^pm\.max_children[ \t]*=[ \t]*(\d+)', Path(config_path).read_text())
            if match:
                values['php_max_children'] = int(match.group(1)); break
        except (OSError, ValueError):
            continue
    return values


def legacy_health_fingerprint(request):
    """Reproduce pre-v18 normalization, including for jobs whose payload was erased.

    Only the three additive workout fields are removed. Every original value and
    any newly confirmed association still participate in the fingerprint.
    """
    if request.get('kind') not in ('report', 'weekly_review'):
        return None
    legacy = json.loads(canonical(request))
    payload = legacy['payload']
    records = [payload] if legacy['kind'] == 'report' else payload.get('days', [])
    changed = False
    for record in records:
        health = record.get('health')
        if not isinstance(health, dict):
            continue
        for workout in health.get('workouts', []):
            for key in ('id', 'activity_kind', 'average_heart_rate'):
                if key in workout:
                    del workout[key]
                    changed = True
    return fingerprint(legacy) if changed else None


def request_audit_summary(request):
    """Short-lived operational evidence. It deliberately excludes copied text, photos and health values."""
    summary = _request_audit_summary(request)
    if request.get("source_revision"):
        # A hash of the source, used only to tell whether a report version is still current (C07).
        summary = {**summary, "source_revision": request["source_revision"]}
    return summary

def _request_audit_summary(request):
    payload = request["payload"]
    kind = request["kind"]
    if kind == "coach":
        summary={"context_days":len(payload['days']),"history_messages":len(payload['history']),"question_characters":len(payload['question'])}
        if payload.get('images'): summary['photos_submitted']=len(payload['images'])
        return summary
    if kind == "parse_plan" and payload.get("operation") == "notes_only":
        return {"reminder_count": len(payload["notes"]), "reminder_characters": sum(map(len, payload["notes"]))}
    if kind in ("generate_plan", "parse_plan"):
        profile = payload["profile"]
        summary = {"goal": profile["goal"], "experience": profile["experience"], "venue": profile["venue"],
                   "focus": profile["focus"], "days_per_week": profile["daysPerWeek"]}
        if kind == "parse_plan":
            summary["imported_text_characters"] = len(payload["text"])
        return summary
    if kind == "food":
        if payload.get('source') == 'text':
            return {'input_source': 'text', 'description_characters': len(payload['description']), 'photo_submitted': False, 'multiple_meals':payload.get('mode')=='multiple'}
        return {"photo_submitted": True, "photo_bytes": len(payload["image_base64"]) * 3 // 4,
                "has_user_note": bool(payload["context"].strip())}
    if kind == "weekly_review":
        return {"review_days": len(payload["days"]), "photos_submitted": len(payload["photos"]),
                "upcoming_days": len(payload["upcoming"])}
    return {"exercise_count": len(payload["exercises"]), "meal_count": len(payload["meals"]),
            "has_health_summary": payload["health"] is not None}


def protected_env_update(values):
    """Persist provider overrides in the service's writable data directory."""
    import tempfile
    allowed = {name.upper() + suffix for name in PROVIDER_DEFAULTS for suffix in ('_API_KEY', '_ENABLED', '_PRIORITY')}
    if any(key not in allowed or not isinstance(value, str) or '\n' in value or '\r' in value for key, value in values.items()):
        raise ValueError('invalid provider setting')
    path = BASE / '.data' / 'providers.json'
    with PROVIDER_CONFIG_LOCK:
        path.parent.mkdir(parents=True, exist_ok=True)
        current = json.loads(path.read_text(encoding='utf-8')) if path.exists() else {}
        current.update(values)
        fd, name = tempfile.mkstemp(prefix='.providers-', dir=path.parent)
        temporary = Path(name)
        try:
            os.chmod(temporary, 0o600)
            with os.fdopen(fd, 'w', encoding='utf-8') as stream:
                json.dump(current, stream)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
        os.environ.update(values)


def load_provider_overrides():
    path = BASE / '.data' / 'providers.json'
    if path.exists():
        values = json.loads(path.read_text(encoding='utf-8'))
        allowed = {name.upper() + suffix for name in PROVIDER_DEFAULTS for suffix in ('_API_KEY', '_ENABLED', '_PRIORITY')}
        if isinstance(values,dict): values={k:v for k,v in values.items() if not k.startswith(('MIMO_','LONGCAT_'))}
        if not isinstance(values, dict) or any(key not in allowed or not isinstance(value, str) for key, value in values.items()):
            raise ValueError('invalid provider configuration')
        os.environ.update(values)


def provider_status(providers):
    return [{"name": item.name, "model": item.model, "endpoint": item.endpoint, "configured": bool(item.key),
             "enabled": item.enabled, "priority": item.priority, "supports_images": item.supports_images,
             "key_suffix": "已配置" if item.key else ""} for item in providers]


class JobStore:
    RUN_LEASE_SECONDS = 120

    def __init__(self, path):
        self.path = str(path)
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("""CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, kind TEXT NOT NULL,
                payload TEXT NOT NULL, status TEXT NOT NULL, created REAL NOT NULL,
                updated REAL NOT NULL, next_run REAL NOT NULL, rounds INTEGER NOT NULL DEFAULT 0,
                result TEXT, provider TEXT, model TEXT, error_code TEXT, error_message TEXT)""")
            db.execute("""CREATE TABLE IF NOT EXISTS attempts (
                job_id TEXT, timestamp REAL, provider TEXT, model TEXT, outcome TEXT,
                duration_ms INTEGER, usage TEXT)""")
            db.execute("""CREATE TABLE IF NOT EXISTS controls (
                key TEXT PRIMARY KEY, value TEXT NOT NULL, updated REAL NOT NULL)""")
            db.execute("""CREATE TABLE IF NOT EXISTS task_audits (
                job_id TEXT PRIMARY KEY, created REAL NOT NULL, expires REAL NOT NULL, summary TEXT NOT NULL)""")
            db.execute("""CREATE TABLE IF NOT EXISTS job_stream_events (
                job_id TEXT NOT NULL, seq INTEGER NOT NULL, type TEXT NOT NULL,
                data TEXT NOT NULL, created REAL NOT NULL, PRIMARY KEY(job_id,seq))""")
            if 'run_token' not in {row['name'] for row in db.execute('PRAGMA table_info(jobs)')}:
                db.execute('ALTER TABLE jobs ADD COLUMN run_token TEXT')
            if 'quota_owner' not in {row['name'] for row in db.execute('PRAGMA table_info(jobs)')}:
                db.execute('ALTER TABLE jobs ADD COLUMN quota_owner TEXT')
            if 'validation_reason' not in {row['name'] for row in db.execute('PRAGMA table_info(attempts)')}:
                db.execute('ALTER TABLE attempts ADD COLUMN validation_reason TEXT')
            db.execute('CREATE INDEX IF NOT EXISTS jobs_queue_due ON jobs(status,next_run,created)')
            db.execute('CREATE INDEX IF NOT EXISTS jobs_created ON jobs(created)')
            db.execute('CREATE INDEX IF NOT EXISTS jobs_status_updated ON jobs(status,updated)')
            # Persistent runtime limits supersede the legacy environment limit.
            # Existing administrator choices survive restarts and upgrades.
            for key, value in [('daily_limit', 0), ('pending_limit', 800), ('worker_limit', 3), ('account_daily_limit', 0), ('account_pending_limit', 8)]:
                db.execute("INSERT OR IGNORE INTO controls(key,value,updated) VALUES(?,?,?)", (key, str(value), time.time()))
            db.execute('CREATE INDEX IF NOT EXISTS jobs_owner_status ON jobs(quota_owner,status)')
            db.execute('CREATE TABLE IF NOT EXISTS task_successes(job_id TEXT PRIMARY KEY, owner TEXT, completed REAL NOT NULL)')
            db.execute('CREATE INDEX IF NOT EXISTS successes_owner_day ON task_successes(owner,completed)')
            db.execute('CREATE INDEX IF NOT EXISTS successes_day ON task_successes(completed)')
            # Existing verified successes keep their original server completion time.
            db.execute("INSERT OR IGNORE INTO task_successes(job_id,owner,completed) SELECT id,quota_owner,updated FROM jobs WHERE status='succeeded' AND updated>=?",(time.time()-30*86400,))
            db.execute('CREATE TABLE IF NOT EXISTS task_failure_events(id INTEGER PRIMARY KEY AUTOINCREMENT,job_id TEXT NOT NULL,reason TEXT NOT NULL,occurred REAL NOT NULL)')
            db.execute('CREATE INDEX IF NOT EXISTS failures_day ON task_failure_events(occurred)')
            db.execute("""CREATE TABLE IF NOT EXISTS task_completions (
                day_start INTEGER NOT NULL, job_id TEXT NOT NULL, status TEXT NOT NULL,
                updated REAL NOT NULL, PRIMARY KEY(day_start,job_id))""")
            # Backfill retained terminal tasks once; future completion records survive retries.
            db.execute("""INSERT OR IGNORE INTO task_completions(day_start,job_id,status,updated)
                SELECT CAST((updated+28800)/86400 AS INTEGER)*86400-28800,id,status,updated
                FROM jobs WHERE status IN ('succeeded','failed') AND updated>=?""", (time.time()-30*86400,))
            db.execute('CREATE INDEX IF NOT EXISTS attempts_timestamp ON attempts(timestamp)')
            db.execute('CREATE INDEX IF NOT EXISTS attempts_job ON attempts(job_id)')
            db.execute('CREATE INDEX IF NOT EXISTS audits_expires ON task_audits(expires)')
            # Report storage is independent of temporary task/input retention.
            db.execute("""CREATE TABLE IF NOT EXISTS report_archive (
                job_id TEXT PRIMARY KEY, owner TEXT, kind TEXT NOT NULL,
                date TEXT NOT NULL, created REAL NOT NULL, result TEXT NOT NULL,
                provider TEXT, model TEXT, purpose TEXT)""")
            db.execute('CREATE INDEX IF NOT EXISTS reports_owner ON report_archive(owner)')
            # CA-08（B04）：报告版本链与源指纹。幂等加列，与 run_token/quota_owner 同机制；
            # 手工迁移与回退语句见 backend/report_versions_ca08.sql。
            # 列语义：parent_id=同范围前一版本 job_id；source_revision=提交时来源指纹；
            # source_status='current'|'stale'（旧数据 NULL 视为 current）；source_note=stale 说明。
            for column in ('parent_id', 'source_revision', 'source_status', 'source_note'):
                if column not in {row['name'] for row in db.execute('PRAGMA table_info(report_archive)')}:
                    db.execute(f'ALTER TABLE report_archive ADD COLUMN {column} TEXT')
            db.execute('CREATE INDEX IF NOT EXISTS reports_parent ON report_archive(parent_id)')
            db.execute('CREATE INDEX IF NOT EXISTS reports_source ON report_archive(owner,kind,date,source_status)')
            self.archive_reports(db)

            # Reclaim interrupted work on restart. Client application remains idempotent by job ID.
            interrupted = db.execute("SELECT id,rounds FROM jobs WHERE status='running'").fetchall()
            now = time.time()
            db.execute("UPDATE jobs SET status=CASE WHEN rounds<3 THEN 'retrying' ELSE 'failed' END,next_run=?,updated=?,run_token=NULL,error_code='worker_interrupted',error_message='处理已中断，请稍后重试。' WHERE status='running'", (now,now))
            db.execute("UPDATE jobs SET payload='{}' WHERE kind='weekly_review' AND status='failed' AND error_code='worker_interrupted'")
            for row in interrupted:
                self.record_failure_event(db,row['id'],'worker_interrupted',now)
                if row['rounds'] >= 3: self.record_completion(db,row['id'],'failed',now)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.execute('PRAGMA secure_delete=ON')
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def reserve_model_attempt131(self, job_id, provider, messages, output_limit, casual=False):
        import usage_guard131
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute("SELECT quota_owner,status FROM jobs WHERE id=?",(job_id,)).fetchone()
            if not row or row['status'] != 'running':
                raise AIError('stream_fenced','任务已停止。',False,False)
            try:
                usage_guard131.reserve(db,job_id,row['quota_owner'],provider,messages,output_limit,casual)
            except ValueError:
                raise AIError('resource_budget131','本次请求已达到用量保护限制，请稍后再试；训练和记录仍可照常使用。',False,False)

    def create(self, job_id, request, maximum_per_day=None, quota_owner=None, enforce_plan_date=False):
        self.validate_owner(quota_owner)
        digest = fingerprint(request)
        now = time.time()
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            previous = db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
            if previous:
                if previous["fingerprint"] != digest and previous["fingerprint"] != legacy_health_fingerprint(request):
                    raise AIError("id_conflict", "任务编号已对应另一份输入，请重新提交。")
                self.bind_owner(db,job_id,quota_owner)
                return self.public(previous)
            if enforce_plan_date:
                # Keep idempotent recovery working after midnight; reject only
                # a newly created expired plan, before reserving quota/capacity.
                validate_new_plan_start(request)
            if request["kind"] == "weekly_review":
                import weekly_core
                weekly_core.review_readiness(request["payload"], request["payload"], __import__("datetime").date.fromisoformat(request["date"]))
            control = db.execute("SELECT value FROM controls WHERE key='accepting'").fetchone()
            if control is not None and control["value"] != "1":
                raise AIError("maintenance", "AI 服务正在维护，请稍后再试。")
            active = db.execute("SELECT count(*) FROM jobs WHERE status IN ('queued','running','retrying')").fetchone()[0]
            limits = self.capacity_settings(db)
            daily_limit = limits['daily_limit'] if maximum_per_day is None else self.validate_limit(maximum_per_day)
            self.check_quota(db,quota_owner,daily_limit,limits['account_daily_limit'],now)
            if limits['pending_limit'] > 0 and active >= limits['pending_limit']:
                raise AIError("capacity", "当前分析任务较多，请稍后再试。")
            # One account must not occupy the whole global queue. Internal
            # (owner-less) jobs are only bound by the global limit.
            if limits['account_pending_limit'] > 0 and quota_owner is not None:
                owned = db.execute("SELECT count(*) FROM jobs WHERE quota_owner=? AND status IN ('queued','running','retrying')", (quota_owner,)).fetchone()[0]
                if owned >= limits['account_pending_limit']:
                    raise AIError("capacity", "你还有多个分析任务正在处理中，请等待完成后再试。")
            db.execute("INSERT INTO jobs(id,fingerprint,kind,payload,status,created,updated,next_run,quota_owner) VALUES(?,?,?,?,?,?,?,?,?)",
                       (job_id, digest, request["kind"], canonical(request), "queued", now, now, now,quota_owner))
            db.execute("DELETE FROM task_audits WHERE expires<?", (now,))
            db.execute("INSERT INTO task_audits(job_id,created,expires,summary) VALUES(?,?,?,?)",
                       (job_id, now, now + 30 * 86400, canonical({"date":request["date"],**request_audit_summary(request)})))
        return self.get(job_id)

    @staticmethod
    def archive_reports(db, job_id=None, stale=False, stale_note=None):
        # Called in the completion transaction and before cleanup/backfill.
        # Keep only a validated report result and routing metadata, never input
        # photos, conversation prompts, or full profile snapshots.
        # CA-08（B04）：归档写入 parent_id（同范围前一版本）与 source_revision（提交时来源指纹）。
        # stale=True（完成时来源指纹与提交时不一致）或同范围已有更新版本先归档时，
        # 本行标 source_status='stale' 并写 source_note，不发布为当前版本（B05）。
        where=" AND j.id=?" if job_id is not None else ""
        date_expr="COALESCE(json_extract(a.summary,'$.date'),json_extract(j.payload,'$.date'))"
        revision_expr="COALESCE(json_extract(a.summary,'$.source_revision'),CASE WHEN json_valid(j.payload) THEN json_extract(j.payload,'$.source_revision') END)"
        purpose_expr="COALESCE(json_extract(j.result,'$.coach.purpose'),'')"
        # 同范围 = (owner, kind, date[, purpose])。匿名任务（owner 空）不建链、不互判新旧。
        newer_exists=("EXISTS(SELECT 1 FROM report_archive r2 WHERE r2.owner IS NOT NULL AND r2.owner=j.quota_owner"
                      " AND r2.kind=j.kind AND r2.date="+date_expr+" AND COALESCE(r2.purpose,'')="+purpose_expr
                      +" AND r2.created>j.created AND COALESCE(r2.source_revision,'')!=''"
                      +" AND COALESCE(r2.source_revision,'')!=COALESCE("+revision_expr+",''))")
        stale_case="CASE WHEN ? OR "+newer_exists+" THEN 'stale' ELSE 'current' END"
        note_case="CASE WHEN ? OR "+newer_exists+" THEN ? ELSE NULL END"
        values=(1 if stale else 0, 1 if stale else 0,
                stale_note or "来源已产生更新版本，本结果未标记为当前版本（B05）。")
        if job_id is not None: values+=(job_id,)
        db.execute("""INSERT OR IGNORE INTO report_archive(job_id,owner,kind,date,created,result,provider,model,purpose,
            parent_id,source_revision,source_status,source_note)
            SELECT j.id,j.quota_owner,j.kind,"""+date_expr+""",j.created,j.result,j.provider,j.model,json_extract(j.result,'$.coach.purpose'),
                NULL,"""+revision_expr+","+stale_case+","+note_case+"""
            FROM jobs j LEFT JOIN task_audits a ON a.job_id=j.id
            WHERE j.status='succeeded' AND json_valid(j.result)
              AND ((j.kind='report' AND json_extract(j.result,'$.kind')='report') OR
                   (j.kind='coach' AND json_extract(j.result,'$.kind')='coach' AND json_extract(j.result,'$.coach.purpose') IN ('workout','weekly')))
              AND """+date_expr+""" IS NOT NULL
              AND NOT EXISTS(SELECT 1 FROM report_archive r WHERE r.job_id=j.id)"""+where, values)
        # 补链：与插入分离，避免同一 INSERT..SELECT 内先后插入的同范围行互相看不见。
        # 只填 NULL（幂等）；链上被删除的版本跳过，指向仍保留的最近前一版本。
        db.execute("""UPDATE report_archive SET parent_id=(
            SELECT r0.job_id FROM report_archive r0
            WHERE r0.owner IS NOT NULL AND r0.owner=report_archive.owner
              AND r0.kind=report_archive.kind AND r0.date=report_archive.date
              AND COALESCE(r0.purpose,'')=COALESCE(report_archive.purpose,'')
              AND r0.created<report_archive.created
            ORDER BY r0.created DESC, r0.job_id DESC LIMIT 1)
            WHERE parent_id IS NULL AND owner IS NOT NULL
              AND EXISTS(SELECT 1 FROM report_archive r1
                         WHERE r1.owner IS NOT NULL AND r1.owner=report_archive.owner
                           AND r1.kind=report_archive.kind AND r1.date=report_archive.date
                           AND COALESCE(r1.purpose,'')=COALESCE(report_archive.purpose,'')
                           AND r1.created<report_archive.created)""")
        # R03/DI-024: 确保同一 (owner, kind, date, purpose) 范围至多只有一份报告标为 current。
        # 当新报告标记为 current 时，同范围的历史报告自动变更为 stale 并记录说明。
        if job_id is not None:
            db.execute("""UPDATE report_archive
                SET source_status='stale',
                    source_note=COALESCE(source_note, '已产生更新版本，本结果变更为历史版本（B05）。')
                WHERE owner IS NOT NULL AND source_status='current'
                  AND job_id!=?
                  AND EXISTS(
                      SELECT 1 FROM report_archive r0
                      WHERE r0.job_id=? AND r0.source_status='current'
                        AND r0.owner=report_archive.owner
                        AND r0.kind=report_archive.kind
                        AND r0.date=report_archive.date
                        AND COALESCE(r0.purpose,'')=COALESCE(report_archive.purpose,'')
                  )""", (job_id, job_id))
        else:
            db.execute("""UPDATE report_archive
                SET source_status='stale',
                    source_note=COALESCE(source_note, '已产生更新版本，本结果变更为历史版本（B05）。')
                WHERE owner IS NOT NULL AND source_status='current'
                  AND EXISTS(
                      SELECT 1 FROM report_archive r2
                      WHERE r2.owner=report_archive.owner
                        AND r2.kind=report_archive.kind
                        AND r2.date=report_archive.date
                        AND COALESCE(r2.purpose,'')=COALESCE(report_archive.purpose,'')
                        AND r2.source_status='current'
                        AND (r2.created>report_archive.created OR (r2.created=report_archive.created AND r2.job_id>report_archive.job_id))
                  )""")

    def append_stream(self, job_id, run_token, kind, text):
        if kind not in ('delta', 'reset') or not isinstance(text, str) or len(text) > 5000:
            raise ValueError('invalid_stream_event')
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute("SELECT status,run_token FROM jobs WHERE id=?", (job_id,)).fetchone()
            if row is None or row['status'] != 'running' or row['run_token'] != run_token:
                return False
            seq = db.execute('SELECT COALESCE(MAX(seq),0)+1 FROM job_stream_events WHERE job_id=?', (job_id,)).fetchone()[0]
            if seq > 2000:
                raise ValueError('stream_event_limit')
            db.execute('INSERT INTO job_stream_events(job_id,seq,type,data,created) VALUES(?,?,?,?,?)',
                       (job_id, seq, kind, canonical({'text': text}), time.time()))
            return True

    def stream_events(self, job_id, after=0):
        with self.connect() as db:
            row = db.execute("SELECT status FROM jobs WHERE id=?", (job_id,)).fetchone()
            if row is None or row['status'] == 'deleted':
                return None
            rows = db.execute('SELECT seq,type,data FROM job_stream_events WHERE job_id=? AND seq>? ORDER BY seq LIMIT 100',
                              (job_id, max(0, int(after)))).fetchall()
            return {'events': [{'seq': r['seq'], 'type': r['type'], **json.loads(r['data'])} for r in rows]}

    def get(self, job_id):
        with self.connect() as db:
            row = db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
            archived = db.execute('SELECT * FROM report_archive WHERE job_id=?',(job_id,)).fetchone() if row is None or row['status']=='deleted' else None
            extra = db.execute('SELECT parent_id,source_revision,source_status,source_note FROM report_archive WHERE job_id=?', (job_id,)).fetchone() if row is not None and row['status']=='succeeded' else None
            attempts = db.execute('SELECT usage FROM attempts WHERE job_id=? ORDER BY timestamp,rowid', (job_id,)).fetchall()
        if archived:
            return {'id':archived['job_id'],'kind':archived['kind'],'status':'succeeded','result':json.loads(archived['result']),
                'provider':archived['provider'],'model':archived['model'],'error_code':None,'error_message':None,'retry_after':0,
                # CA-08：版本链与源复核字段（B04/B05）；旧归档行无值时字段为 None，键始终存在。
                'parent_id':archived['parent_id'],'source_revision':archived['source_revision'],
                'source_status':archived['source_status'],'source_note':archived['source_note']}
        value = self.public(row) if row else None
        if value is not None and value.get('status') == 'succeeded' and extra:
            # 成功任务同样带上来源复核字段：B05 要求客户端能把旧结果与当前版本区分开。
            value.update({'parent_id': extra['parent_id'], 'source_revision': extra['source_revision'],
                          'source_status': extra['source_status'], 'source_note': extra['source_note']})
        if value is not None:
            # Transport-owned telemetry, outside the model's result JSON. Include
            # paid failed/fallback attempts; absent provider usage stays unknown.
            usage = {'attempt_count': len(attempts), 'prompt_tokens': None, 'completion_tokens': None}
            if attempts:
                for target, alias in (('prompt_tokens', 'input_tokens'), ('completion_tokens', 'output_tokens')):
                    counts = []
                    for attempt in attempts:
                        try:
                            raw = json.loads(attempt['usage']) if attempt['usage'] else {}
                            n = raw.get(target, raw.get(alias)) if isinstance(raw, dict) else None
                            if type(n) is not int or n < 0: break
                            counts.append(n)
                        except (ValueError, TypeError): break
                    if len(counts) == len(attempts): usage[target] = sum(counts)
            elif value.get('provider') == 'deterministic':
                usage.update(prompt_tokens=0, completion_tokens=0)
            value['usage'] = usage
        return value

    @staticmethod
    def public(row):
        return {"id": row["id"], "status": row["status"], "kind": row["kind"],
                "result": json.loads(row["result"]) if row["result"] else None,
                "provider": row["provider"], "model": row["model"],
                "error_code": row["error_code"], "error_message": row["error_message"],
                "retry_after": max(0, round(row["next_run"] - time.time())) if row["status"] == "retrying" else 0}

    def cleanup(self):
        now = time.time()
        with self.connect() as db:
            self.archive_reports(db)
            db.execute("DELETE FROM task_audits WHERE expires<?", (now,))
            db.execute("DELETE FROM attempts WHERE timestamp<?", (now-90*86400,))
            db.execute("DELETE FROM task_completions WHERE day_start<?", (now-30*86400,))
            db.execute('DELETE FROM task_successes WHERE completed<?',(now-30*86400,))
            db.execute('DELETE FROM task_failure_events WHERE occurred<?',(now-30*86400,))
            db.execute("UPDATE jobs SET status='deleted',payload='{}',result=NULL,error_code=NULL,error_message=NULL,quota_owner=NULL,run_token=NULL,updated=? WHERE status!='deleted' AND created<?", (now, now-30*86400))
            db.execute("DELETE FROM job_stream_events WHERE job_id IN (SELECT id FROM jobs WHERE status='deleted') OR created<?", (now-30*86400,))
            # Failed requests may contain photos, health context and free text.
            # Keep them only one day for operational triage, then erase the payload.
            db.execute("UPDATE jobs SET payload='{}' WHERE status='failed' AND updated<?", (now-86400,))
            db.execute("DELETE FROM jobs WHERE status='deleted' AND updated<?", (now-90*86400,))

    def claim(self, interactive_only=False):
        with self.connect() as db:
            now = time.time()
            has_work = db.execute(
                "SELECT 1 FROM jobs WHERE "
                "(status='running' AND updated<?) OR "
                "(kind='weekly_review' AND status IN ('queued','retrying') AND created<?) OR "
                "(status IN ('queued','retrying') AND next_run<=?) LIMIT 1",
                (now - self.RUN_LEASE_SECONDS, now - 86400, now)
            ).fetchone()
            if not has_work:
                return None
            db.execute("BEGIN IMMEDIATE")
            now = time.time()
            interrupted = db.execute("SELECT id FROM jobs WHERE status='running' AND updated<?",(now-self.RUN_LEASE_SECONDS,)).fetchall()
            # Only a worker holding the current token can renew or finish this lease.
            terminal = [r['id'] for r in db.execute("SELECT id FROM jobs WHERE status='running' AND rounds>=3 AND updated<?", (now-self.RUN_LEASE_SECONDS,))]
            db.execute("UPDATE jobs SET status=CASE WHEN rounds<3 THEN 'retrying' ELSE 'failed' END,next_run=?,updated=?,run_token=NULL,error_code='worker_interrupted',error_message='处理已中断，正在重试；若仍未完成，可重新提交。' WHERE status='running' AND updated<?",
                       (now, now, now-self.RUN_LEASE_SECONDS))
            db.execute("UPDATE jobs SET payload='{}',error_message='复盘处理已中断，照片已清除，请重新提交。' WHERE kind='weekly_review' AND status='failed' AND error_code='worker_interrupted'")
            expired = [r['id'] for r in db.execute("SELECT id FROM jobs WHERE kind='weekly_review' AND status IN ('queued','retrying') AND created<?", (now-86400,))]
            terminal += expired
            db.execute("UPDATE jobs SET status='failed',payload='{}',updated=?,error_code='weekly_expired',error_message='复盘已过期，请重新提交。' WHERE kind='weekly_review' AND status IN ('queued','retrying') AND created<?", (now,now-86400))
            for row in interrupted: self.record_failure_event(db,row['id'],'worker_interrupted',now)
            for job_id in expired: self.record_failure_event(db,job_id,'weekly_expired',now)
            for job_id in terminal: self.record_completion(db, job_id, 'failed', now)
            row = db.execute("SELECT * FROM jobs WHERE status IN ('queued','retrying') AND next_run<=? " + ("AND kind='coach' " if interactive_only else "") + "ORDER BY CASE WHEN created<? THEN 0 WHEN kind='coach' THEN 1 ELSE 2 END,created LIMIT 1", (time.time(),time.time()-15)).fetchone()
            if not row:
                return None
            token = str(uuid.uuid4())
            db.execute("UPDATE jobs SET status='running', rounds=rounds+1, updated=?,run_token=? WHERE id=?", (now, token, row["id"]))
            return row["id"], json.loads(row["payload"]), row["rounds"] + 1, token

    def heartbeat(self, job_id, run_token):
        with self.connect() as db:
            return db.execute("UPDATE jobs SET updated=? WHERE id=? AND status='running' AND run_token=?",
                              (time.time(), job_id, run_token)).rowcount > 0

    def complete(self, job_id, result, provider, model, run_token=None, source_revision=None):
        """写结果前复核来源（CA-08/B05）：source_revision 是完成时来源的当前指纹（能提供方传入），
        与提交时记录（task_audits.summary）不一致 → 结果保留但不发布为当前版本：
        归档行标 source_status='stale' 并写 source_note 说明。未提供指纹时只做
        「同范围已有更新版本」判定（archive_reports 内），不在这里误判。"""
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            submitted = None
            audit = db.execute('SELECT summary FROM task_audits WHERE job_id=?', (job_id,)).fetchone()
            if audit:
                try:
                    value = json.loads(audit['summary']).get('source_revision')
                    if isinstance(value, str): submitted = value
                except (ValueError, TypeError, AttributeError):
                    submitted = None
            stale = submitted is not None and source_revision is not None and source_revision != submitted
            stale_note = "模型处理期间来源已变化，本结果保留但未标记为当前版本（B05）。" if stale else None
            # Retain only the fingerprint and result after success, not the uploaded meal photo.
            guard = " AND status='running' AND run_token=?" if run_token is not None else " AND status!='deleted'"
            values = (canonical(result), provider, model, time.time(), job_id)
            if run_token is not None: values += (run_token,)
            changed = db.execute("UPDATE jobs SET status='succeeded',result=?,provider=?,model=?,payload='{}',updated=?,run_token=NULL,error_code=NULL,error_message=NULL WHERE id=?" + guard, values).rowcount > 0
            if changed:
                self.archive_reports(db, job_id, stale=stale, stale_note=stale_note)
                self.record_completion(db, job_id, 'succeeded')
                owner=db.execute('SELECT quota_owner FROM jobs WHERE id=?',(job_id,)).fetchone()[0]
                db.execute('INSERT OR IGNORE INTO task_successes(job_id,owner,completed) VALUES(?,?,?)',(job_id,owner,time.time()))
            return changed

    def fail(self, job_id, error, rounds, run_token=None):
        # all_unavailable is retryable when the router observed a transient
        # upstream/circuit condition; invalid_output and task_timeout stay terminal.
        retry = error.retryable and rounds < 3 and error.code not in ("invalid_output", "task_timeout")
        delay = (30 if rounds == 1 else 90) if retry else 0
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            previous=db.execute('SELECT status FROM jobs WHERE id=?',(job_id,)).fetchone()
            guard = " AND status='running' AND run_token=?" if run_token is not None else " AND status!='deleted'"
            values = ("retrying" if retry else "failed", time.time() + delay, time.time(), error.code,
                      error.public_message if retry else "分析暂未完成，输入已保留。" + error.public_message, job_id)
            if run_token is not None: values += (run_token,)
            changed = db.execute("UPDATE jobs SET status=?, next_run=?, updated=?, error_code=?,error_message=?,run_token=NULL WHERE id=?" + guard, values).rowcount > 0
            if changed and previous and previous['status']!='failed': self.record_failure_event(db,job_id,error.code)
            if changed and not retry:
                self.record_completion(db, job_id, 'failed')
                db.execute("UPDATE jobs SET payload='{}',error_message='复盘未完成，照片已从任务中清除，请重新提交。' WHERE id=? AND kind='weekly_review'", (job_id,))
            return changed

    def delete_private(self, job_id):
        with self.connect() as db:
            db.execute('DELETE FROM report_archive WHERE job_id=?',(job_id,))
            now = time.time()
            db.execute("INSERT OR IGNORE INTO jobs(id,fingerprint,kind,payload,status,created,updated,next_run) VALUES(?, 'deleted','deleted','{}','deleted',?,?,?)", (job_id,now,now,now))
            # A tombstone clears every private task's payload and result, and prevents an old client retry from recreating it.
            db.execute("UPDATE jobs SET status='deleted',payload='{}',result=NULL,error_code=NULL,error_message=NULL,quota_owner=NULL,run_token=NULL,updated=?,next_run=? WHERE id=?", (now,now,job_id))
            db.execute('DELETE FROM job_stream_events WHERE job_id=?', (job_id,))
            db.execute('DELETE FROM attempts WHERE job_id=?', (job_id,))
            db.execute('DELETE FROM task_audits WHERE job_id=?', (job_id,))
            # Completed counters and quota facts are minimal retained records,
            # not a task's private payload. Deleting a task cannot refill quota.

    def retry(self, job_id, quota_owner=None, enforce_plan_date=False):
        self.validate_owner(quota_owner)
        retry_started = False
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT payload,status,quota_owner FROM jobs WHERE id=?", (job_id,)).fetchone()
            if row:self.bind_owner(db,job_id,quota_owner)
            if row and row['status'] == 'failed':
                if row['payload'] == '{}':
                    raise AIError('input_expired', '任务输入已清除，请重新生成。')
                if enforce_plan_date:
                    validate_new_plan_start(json.loads(row['payload']))
                control = db.execute("SELECT value FROM controls WHERE key='accepting'").fetchone()
                if control and control['value'] != '1':
                    raise AIError('maintenance', 'AI 服务正在维护，请稍后重试。')
                active = db.execute("SELECT count(*) FROM jobs WHERE status IN ('queued','running','retrying')").fetchone()[0]
                pending_limit = self.capacity_settings(db)['pending_limit']
                limits=self.capacity_settings(db)
                if not db.execute('SELECT 1 FROM task_successes WHERE job_id=?',(job_id,)).fetchone():
                    self.check_quota(db,quota_owner or row['quota_owner'],limits['daily_limit'],limits['account_daily_limit'],time.time())
                if pending_limit > 0 and active >= pending_limit:
                    raise AIError('capacity', '当前任务较多，请稍后重试。')
                owner = quota_owner or row['quota_owner']
                account_pending = limits['account_pending_limit']
                if account_pending > 0 and owner is not None:
                    owned = db.execute("SELECT count(*) FROM jobs WHERE quota_owner=? AND status IN ('queued','running','retrying')", (owner,)).fetchone()[0]
                    if owned >= account_pending:
                        raise AIError('capacity', '你的其他分析任务仍在处理中，请等待完成后再重试。')
                db.execute("UPDATE jobs SET status='queued',rounds=0,next_run=?,error_code=NULL,error_message=NULL WHERE id=? AND status='failed'", (time.time(), job_id))
                retry_started = True
        result = self.get(job_id)
        if result is not None:
            result['retry_started'] = retry_started
        return result

    @staticmethod
    def validate_owner(owner):
        if owner is not None and (not isinstance(owner,str) or not re.fullmatch(r'[a-f0-9]{64}',owner)):
            raise ValueError('invalid quota owner')

    @staticmethod
    def bind_owner(db,job_id,owner):
        if owner is None:return
        row=db.execute('SELECT quota_owner,status,updated FROM jobs WHERE id=?',(job_id,)).fetchone()
        if not row:return
        success=db.execute('SELECT owner FROM task_successes WHERE job_id=?',(job_id,)).fetchone()
        archived=db.execute('SELECT owner FROM report_archive WHERE job_id=?',(job_id,)).fetchone()
        if archived and archived['owner'] is not None and archived['owner']!=owner:
            raise AIError('id_conflict','任务归属不一致，请重新提交。')
        if (row['quota_owner'] is not None and row['quota_owner']!=owner) or (success and success['owner'] is not None and success['owner']!=owner):
            raise AIError('id_conflict','任务归属不一致，请重新提交。')
        if row['status']!='deleted': db.execute('UPDATE jobs SET quota_owner=? WHERE id=?',(owner,job_id))
        if archived and archived['owner'] is None:db.execute('UPDATE report_archive SET owner=? WHERE job_id=?',(owner,job_id))
        db.execute('UPDATE task_successes SET owner=? WHERE job_id=? AND owner IS NULL',(owner,job_id))

    @staticmethod
    def check_quota(db,owner,global_limit,account_limit,now):
        start=int((now+28800)//86400)*86400-28800
        for key,limit in [('global',global_limit),('account',account_limit)]:
            if limit==0:continue
            if key=='account' and owner is None:raise AIError('quota_owner_required','任务归属信息缺失，请重新提交。')
            predicate='' if key=='global' else ' AND owner=?'
            params=(start,start+86400) if key=='global' else (start,start+86400,owner)
            used=db.execute('SELECT count(*) FROM task_successes WHERE completed>=? AND completed<?'+predicate,params).fetchone()[0]
            active_where='' if key=='global' else ' AND j.quota_owner=?'
            active=db.execute("SELECT count(*) FROM jobs j LEFT JOIN task_successes s ON s.job_id=j.id WHERE j.status IN ('queued','running','retrying') AND s.job_id IS NULL"+active_where,() if key=='global' else (owner,)).fetchone()[0]
            if used>=limit:
                raise AIError('daily_capacity' if key=='global' else 'quota_exceeded','今日成功分析次数已达上限，北京时间零点恢复；失败和重试不重复计次。')
            if used+active>=limit:
                raise AIError('capacity' if key=='global' else 'quota_pending','剩余成功名额暂由处理中任务预留，失败会释放，请稍后再试。')

    def quota_usage(self,owner):
        self.validate_owner(owner)
        if owner is None:raise ValueError('owner required')
        now=time.time();start=int((now+28800)//86400)*86400-28800
        with self.connect() as db:
            db.execute('BEGIN')
            limit=self.capacity_settings(db)['account_daily_limit']
            used=db.execute('SELECT count(*) FROM task_successes WHERE owner=? AND completed>=? AND completed<?',(owner,start,start+86400)).fetchone()[0]
            reserved=db.execute("SELECT count(*) FROM jobs j LEFT JOIN task_successes s ON s.job_id=j.id WHERE j.quota_owner=? AND j.status IN ('queued','running','retrying') AND s.job_id IS NULL",(owner,)).fetchone()[0]
        return {'daily_limit':limit,'unlimited':limit==0,'successful_today':used,'processing_reserved':reserved,'remaining':None if limit==0 else max(0,limit-used-reserved),'resets_at':start+86400,'timezone':'Asia/Shanghai'}

    def bind_owners(self,pairs):
        if not isinstance(pairs,list) or len(pairs)>100:raise ValueError('invalid binding batch')
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            for pair in pairs:
                job_id=str(uuid.UUID(pair['id']));owner=pair['owner'];self.validate_owner(owner)
                if owner is None:raise ValueError('owner required')
                self.bind_owner(db,job_id,owner)
        return {'bound':len(pairs)}

    def erase_owner(self,owner):
        self.validate_owner(owner)
        if owner is None:raise ValueError('owner required')
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            if db.execute("SELECT 1 FROM sqlite_master WHERE name='model_reservations131'").fetchone():
                db.execute("UPDATE model_reservations131 SET owner=NULL,job='erased' WHERE owner=?",(owner,))
            ids=[r[0] for r in db.execute('SELECT id FROM jobs WHERE quota_owner=? UNION SELECT job_id FROM report_archive WHERE owner=?',(owner,owner))]
            db.execute('DELETE FROM report_archive WHERE owner=?',(owner,))
            for job_id in ids:
                db.execute("UPDATE jobs SET status='deleted',payload='{}',result=NULL,error_code=NULL,error_message=NULL,quota_owner=NULL,run_token=NULL WHERE id=?",(job_id,))
                db.execute('DELETE FROM job_stream_events WHERE job_id=?',(job_id,))
                db.execute('DELETE FROM attempts WHERE job_id=?',(job_id,));db.execute('DELETE FROM task_audits WHERE job_id=?',(job_id,))
            # Anonymous service totals remain; the account link is removed.
            db.execute('UPDATE task_successes SET owner=NULL WHERE owner=?',(owner,))
        return {'erased':True}

    @staticmethod
    def record_failure_event(db,job_id,reason,now=None):
        if not isinstance(reason,str) or not re.fullmatch(r'[a-z_0-9]{1,64}',reason):reason='task_failure'
        db.execute('INSERT INTO task_failure_events(job_id,reason,occurred) VALUES(?,?,?)',(job_id,reason,time.time() if now is None else now))

    def metadata(self, ids):
        if not isinstance(ids,list) or len(ids)>50 or any(not isinstance(value,str) or not re.fullmatch(r"[a-fA-F0-9-]{36}",value) for value in ids):
            raise AIError('invalid_request','任务编号格式不正确。')
        if not ids: return []
        marks=','.join('?' for _ in ids)
        with self.connect() as db:
            # CA-08：source_revision 优先取归档列（审计摘要 30 天后过期，归档永久保留）；
            # source_status 随行返回，供客户端把旧版本与当前版本区分开（B05）。
            rows=db.execute("SELECT j.id,j.kind,CASE WHEN j.status='deleted' AND r.job_id IS NOT NULL THEN 'succeeded' ELSE j.status END AS status,j.created,COALESCE(r.purpose,CASE WHEN j.kind='coach' AND json_valid(j.payload) THEN json_extract(j.payload,'$.payload.purpose') END) AS purpose,COALESCE(r.date,CASE WHEN json_valid(a.summary) THEN json_extract(a.summary,'$.date') END) AS date,COALESCE(r.source_revision,CASE WHEN json_valid(a.summary) THEN json_extract(a.summary,'$.source_revision') END) AS source_revision,r.source_status AS source_status FROM jobs j LEFT JOIN task_audits a ON a.job_id=j.id LEFT JOIN report_archive r ON r.job_id=j.id WHERE j.id IN ("+marks+")",ids).fetchall()
            items=[]
            for row in rows:
                date=row['date']
                if not date:
                    # Legacy-only fallback extracts one scalar inside SQLite; no photos enter Python.
                    old=db.execute("SELECT CASE WHEN json_valid(payload) THEN json_extract(payload,'$.date') END AS date FROM jobs WHERE id=?",(row['id'],)).fetchone()
                    date=old['date'] if old else None
                if isinstance(date,str):
                    items.append({'id':row['id'],'kind':row['kind'],'status':row['status'],'date':date,'created':row['created'],**({'purpose':row['purpose']} if row['purpose'] in ('workout','weekly') else {}),**({'source_revision':row['source_revision']} if isinstance(row['source_revision'],str) else {}),**({'source_status':row['source_status']} if isinstance(row['source_status'],str) else {})})
        return items

    @staticmethod
    def validate_limit(value):
        if type(value) is not int or not 0 <= value <= 2147483647:
            raise ValueError('capacity limit must be a nonnegative integer')
        return value

    def capacity_settings(self, db=None):
        if db is None:
            with self.connect() as connection:
                return self.capacity_settings(connection)
        values = {r['key']: r['value'] for r in db.execute("SELECT key,value FROM controls WHERE key IN ('daily_limit','pending_limit','worker_limit','account_daily_limit','account_pending_limit')")}
        result = {key: self.validate_limit(int(values.get(key, default))) for key, default in [('daily_limit', 0), ('pending_limit', 800), ('worker_limit', 3), ('account_daily_limit',0), ('account_pending_limit',8)]}
        if not 1 <= result['worker_limit'] <= MAX_WORKERS: raise ValueError('invalid worker limit')
        return result

    def settings(self):
        with self.connect() as db:
            value = self.capacity_settings(db)
            row = db.execute("SELECT value FROM controls WHERE key='accepting'").fetchone()
            value['accepting'] = row is None or row['value'] == '1'
        return value

    def update_settings(self, body):
        if not body or set(body) - {'accepting', 'daily_limit', 'pending_limit', 'worker_limit','account_daily_limit','account_pending_limit'}:
            raise ValueError('unknown setting')
        values = {}
        for key, value in body.items():
            if key == 'accepting':
                if type(value) is not bool: raise ValueError('accepting must be boolean')
                values[key] = '1' if value else '0'
            else:
                values[key] = str(self.validate_limit(value))
                if key == 'worker_limit' and not 1 <= value <= MAX_WORKERS:
                    raise ValueError('worker limit must be between 1 and 32')
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            for key, value in values.items():
                db.execute("INSERT INTO controls(key,value,updated) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated=excluded.updated", (key, value, time.time()))
        return self.settings()

    def live_stats(self, now=None):
        now = time.time() if now is None else now
        start = int((now + 8 * 3600) // 86400) * 86400 - 8 * 3600
        end = start + 86400
        with self.connect() as db:
            db.execute('BEGIN')
            active = {r['status']: r['total'] for r in db.execute("SELECT status,count(*) total FROM jobs WHERE status IN ('queued','running','retrying') GROUP BY status")}
            received = db.execute('SELECT count(*) FROM jobs WHERE created>=? AND created<?', (start, end)).fetchone()[0]
            # One task per Beijing day, even if it is retried; latest outcome wins.
            finished = {r['status']: r['total'] for r in db.execute("SELECT status,count(*) total FROM task_completions WHERE day_start=? GROUP BY status", (start,))}
            settings = self.capacity_settings(db)
            oldest = db.execute("SELECT MIN(created) FROM jobs WHERE status='queued'").fetchone()[0]
            failures = db.execute("SELECT count(*) FROM attempts WHERE timestamp>=? AND outcome!='success'", (now-900,)).fetchone()[0]
            attempts = db.execute("SELECT count(*) FROM attempts WHERE timestamp>=?", (now-900,)).fetchone()[0]
            failure_events=db.execute('SELECT count(*) FROM task_failure_events WHERE occurred>=? AND occurred<?',(start,end)).fetchone()[0]
            failed_attempts=db.execute("SELECT count(*) FROM attempts WHERE timestamp>=? AND timestamp<? AND outcome!='success'",(start,end)).fetchone()[0]
            success_used=db.execute('SELECT count(*) FROM task_successes WHERE completed>=? AND completed<?',(start,end)).fetchone()[0]
        value = {'sampled_at': now, 'day_start': start, 'timezone': 'Asia/Shanghai',
                'queued': active.get('queued', 0), 'running': active.get('running', 0), 'retrying': active.get('retrying', 0),
                'pending': sum(active.values()), 'today_received': received,
                'today_succeeded': finished.get('succeeded', 0), 'today_failed': finished.get('failed', 0),
                'today_processed': sum(finished.values()), 'capacity_settings': settings,
                'oldest_queue_seconds': max(0, round(now-oldest)) if oldest is not None else 0,
                'recent_attempts': attempts, 'recent_failed_attempts': failures,'today_failure_events':failure_events,'today_failed_attempts':failed_attempts,'today_quota_successes':success_used}
        runtime = getattr(self, 'runtime_snapshot', None)
        value['runtime'] = runtime() if runtime else {'configured_workers': settings['worker_limit'], 'effective_workers': None, 'active_workers': None, 'resources': resource_snapshot(), 'pause_reason': None}
        alerts=[]
        if value['oldest_queue_seconds'] >= 120: alerts.append('排队最久已超过2分钟，请关注等待时间。')
        if attempts >= 5 and failures/attempts >= 0.2: alerts.append('近15分钟接口失败尝试达到20%，请检查供应商状态。')
        if value['runtime']['pause_reason']: alerts.append('资源保护已暂缓取新任务；已有任务继续处理。')
        value['alerts'] = alerts
        return value

    @staticmethod
    def record_completion(db, job_id, status, now=None):
        now = time.time() if now is None else now
        start = int((now + 8 * 3600) // 86400) * 86400 - 8 * 3600
        db.execute("INSERT INTO task_completions(day_start,job_id,status,updated) VALUES(?,?,?,?) ON CONFLICT(day_start,job_id) DO UPDATE SET status=excluded.status,updated=excluded.updated", (start, job_id, status, now))

    def accepting(self):
        with self.connect() as db:
            row = db.execute("SELECT value FROM controls WHERE key='accepting'").fetchone()
        return row is None or row["value"] == "1"

    def set_accepting(self, accepting):
        with self.connect() as db:
            db.execute("INSERT INTO controls(key,value,updated) VALUES('accepting',?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated=excluded.updated", ("1" if accepting else "0", time.time()))
        return self.accepting()

    @staticmethod
    def _usage(value):
        """Normalise provider usage without retaining any prompt or response."""
        try:
            usage = json.loads(value) if isinstance(value, str) else (value or {})
            if not isinstance(usage, dict):
                return 0, 0, 0
            prompt = int(usage.get("prompt_tokens", usage.get("input_tokens", 0)) or 0)
            completion = int(usage.get("completion_tokens", usage.get("output_tokens", 0)) or 0)
            total = int(usage.get("total_tokens", prompt + completion) or 0)
            return max(0, prompt), max(0, completion), max(0, total)
        except (ValueError, TypeError, OverflowError):
            return 0, 0, 0

    def admin_overview(self, days=30):
        days = max(1, min(int(days), 90))
        since = time.time() - days * 86400
        with self.connect() as db:
            jobs = db.execute("SELECT kind,status,created,updated FROM jobs WHERE created>=?", (since,)).fetchall()
            attempts = db.execute("SELECT job_id,provider,model,outcome,duration_ms,usage,validation_reason FROM attempts WHERE timestamp>=? ORDER BY timestamp,rowid", (since,)).fetchall()
            waiting = db.execute("SELECT count(*) FROM jobs WHERE status IN ('queued','retrying')").fetchone()[0]
        by_kind, by_status, providers = {}, {}, {}
        for row in jobs:
            by_kind[row["kind"]] = by_kind.get(row["kind"], 0) + 1
            by_status[row["status"]] = by_status.get(row["status"], 0) + 1
        durations, input_tokens, output_tokens, total_tokens = [], 0, 0, 0
        failures_by_kind, failed_jobs, recovered_jobs, validation_reasons = {}, set(), set(), {}
        for row in attempts:
            if row['validation_reason']:
                validation_reasons[row['validation_reason']] = validation_reasons.get(row['validation_reason'], 0) + 1
            key = (row["provider"] or "unknown") + " / " + (row["model"] or "unknown")
            stat = providers.setdefault(key, {"provider": row["provider"] or "unknown", "model": row["model"] or "unknown", "calls": 0, "succeeded": 0, "failed": 0, "fallback_successes": 0, "input_tokens": 0, "output_tokens": 0, "total_tokens": 0})
            stat["calls"] += 1
            stat["succeeded" if row["outcome"] == "success" else "failed"] += 1
            if row["outcome"] == "success" and row["job_id"] in failed_jobs:
                stat["fallback_successes"] += 1
                recovered_jobs.add(row["job_id"])
            elif row["outcome"] != "success":
                failed_jobs.add(row["job_id"])
                failures_by_kind[row["outcome"]] = failures_by_kind.get(row["outcome"], 0) + 1
            prompt, completion, total = self._usage(row["usage"])
            stat["input_tokens"] += prompt; stat["output_tokens"] += completion; stat["total_tokens"] += total
            input_tokens += prompt; output_tokens += completion; total_tokens += total
            if isinstance(row["duration_ms"], int) and row["duration_ms"] >= 0:
                durations.append(row["duration_ms"])
        durations.sort()
        for stat in providers.values():
            stat["success_rate"] = round(stat["succeeded"] * 100 / stat["calls"], 1) if stat["calls"] else None
            stat["share_pct"] = round(stat["calls"] * 100 / len(attempts), 1) if attempts else 0
        return {"window_days": days, "jobs": len(jobs), "by_kind": by_kind, "by_status": by_status,
                "live": self.live_stats(), "capacity_settings": self.capacity_settings(),
                "validation_reasons": [{"code": key, "count": value} for key,value in sorted(validation_reasons.items())],
                "queue_waiting": waiting, "accepting": self.accepting(), "attempts": len(attempts),
                "recovered_jobs": len(recovered_jobs), "failure_reasons": sorted(
                    [{"code": code, "count": count} for code, count in failures_by_kind.items()], key=lambda item: -item["count"]),
                "success_rate": round(100 * sum(1 for a in attempts if a["outcome"] == "success") / len(attempts), 1) if attempts else None,
                "avg_duration_ms": round(sum(durations) / len(durations)) if durations else None,
                "p95_duration_ms": durations[min(len(durations)-1, int(len(durations)*.95))] if durations else None,
                "usage": {"input_tokens": input_tokens, "output_tokens": output_tokens, "total_tokens": total_tokens},
                "providers": sorted(providers.values(), key=lambda item: (-item["calls"], item["provider"]))}

    def admin_tasks(self, days=30, status="", kind="", page=1):
        days = max(1, min(int(days), 90)); page = max(1, min(int(page), 10000)); limit = 50
        clauses, values = ["created>=?"], [time.time() - days * 86400]
        if status in {"queued", "running", "retrying", "succeeded", "failed", "deleted"}:
            clauses.append("status=?"); values.append(status)
        if kind in {"generate_plan", "parse_plan", "food", "report", "weekly_review", "coach"}:
            clauses.append("kind=?"); values.append(kind)
        with self.connect() as db:
            rows = db.execute("SELECT id,kind,status,created,updated,rounds,provider,model,error_code,error_message FROM jobs WHERE " + " AND ".join(clauses) + " ORDER BY created DESC LIMIT ? OFFSET ?", tuple(values + [limit + 1, (page-1)*limit])).fetchall()
        items = []
        for row in rows[:limit]:
            # No payload, result, image, device ID, or user linkage is ever exposed here.
            items.append({key: row[key] for key in ("id", "kind", "status", "created", "updated", "rounds", "provider", "model", "error_code", "error_message")})
        return {"items": items, "page": page, "has_more": len(rows) > limit}

    def admin_task_audit(self, job_id):
        with self.connect() as db:
            row = db.execute("SELECT j.id,j.kind,j.status,j.created,j.provider,j.model,a.expires,a.summary FROM jobs j LEFT JOIN task_audits a ON a.job_id=j.id WHERE j.id=?", (job_id,)).fetchone()
        if not row:
            return None
        summary = None if not row["summary"] or row["expires"] < time.time() else json.loads(row["summary"])
        return {"id": row["id"], "kind": row["kind"], "status": row["status"], "created": row["created"],
                "provider": row["provider"], "model": row["model"], "summary": summary,
                "expires_at": row["expires"] if row["expires"] else None}

    def attempt(self, job_id, event):
        with self.connect() as db:
            row = db.execute('SELECT status FROM jobs WHERE id=?', (job_id,)).fetchone()
            if row and row['status']=='deleted': return
            reason = event.get('reason')
            # The worker only persists fixed operational codes, never arbitrary exception text.
            if not isinstance(reason, str) or not re.fullmatch(r'[a-z_]{1,64}', reason): reason = None
            db.execute("INSERT INTO attempts(job_id,timestamp,provider,model,outcome,duration_ms,usage,validation_reason) VALUES(?,?,?,?,?,?,?,?)", (job_id, time.time(), event["provider"], event["model"],
                       event["outcome"], event["duration_ms"], canonical(event["usage"]), reason))


class Workers:
    def __init__(self, store, router, resource_reader=resource_snapshot, source_checker=None):
        self.store = store
        self.router = router
        self.stop = threading.Event()
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS)
        self.condition = threading.Condition()
        self.active = 0
        self.resource_reader = resource_reader
        self.source_checker = source_checker
        initial = resource_reader()
        self.baseline_memory = initial.get('memory_guard_bytes') if initial.get('memory_guard_bytes') is not None else initial.get('memory_current') or 0
        self.setting_time = 0
        self.configured_limit = store.capacity_settings()['worker_limit']
        self.store.runtime_snapshot = self.snapshot
        self.thread = threading.Thread(target=self.dispatch, daemon=True)

    def snapshot(self):
        resources = self.resource_reader()
        with self.condition: active = self.active
        maximum = resources.get('memory_limit')
        effective = self.configured_limit
        reason = None
        if maximum:
            effective = min(effective, max(0, int((maximum*.85-self.baseline_memory)//JOB_MEMORY_RESERVE)))
            guard_bytes = resources.get('memory_guard_bytes') if resources.get('memory_guard_bytes') is not None else resources.get('memory_current') or 0
            if guard_bytes+JOB_MEMORY_RESERVE > maximum*.85:
                reason = 'ai_memory'
        if resources.get('host_available') is not None and resources['host_available'] < 128*1024*1024:
            reason = 'host_memory'
        if effective == 0: reason = reason or 'ai_memory'
        return {'configured_workers': self.configured_limit, 'effective_workers': effective,
                'active_workers': active, 'maximum_workers': MAX_WORKERS,
                'job_memory_reserve': JOB_MEMORY_RESERVE, 'resources': resources, 'pause_reason': reason}

    def release_slot(self):
        with self.condition:
            self.active -= 1
            self.condition.notify_all()

    def dispatch(self):
        last_cleanup = 0
        while not self.stop.is_set():
            if time.monotonic() - last_cleanup >= 60:
                try:
                    self.store.cleanup()
                except Exception as error:
                    print("AI cleanup error:", type(error).__name__, flush=True)
                last_cleanup = time.monotonic()
            try:
                if time.monotonic()-self.setting_time >= 1:
                    self.configured_limit = self.store.capacity_settings()['worker_limit']
                    self.setting_time = time.monotonic()
                state = self.snapshot()
                with self.condition:
                    if not state['pause_reason'] and self.active < state['effective_workers']:
                        self.active += 1
                        reserved = True
                    else: reserved = False
                if reserved:
                    try:
                        # JobStore.claim already orders coach jobs ahead of
                        # background work. Filtering to coach-only at the
                        # concurrency ceiling can leave slots permanently
                        # reserved when the queue contains only background
                        # jobs, so always let the store select the next job.
                        item = self.store.claim(interactive_only=False)
                        if item:
                            self.pool.submit(self.run, item)
                            continue  # Fill available slots without the old 0.5s delay per job.
                        self.release_slot()
                    except Exception:
                        self.release_slot()
                        raise
            except Exception as error:
                print("AI dispatcher error:", type(error).__name__, flush=True)
            self.stop.wait(0.1)

    def run(self, item):
        job_id, request, rounds, token = item
        heartbeat_stop = threading.Event()
        def renew():
            while not heartbeat_stop.wait(15):
                try:
                    if not self.store.heartbeat(job_id, token): return
                except Exception as error:
                    print('AI heartbeat error:', type(error).__name__, flush=True)
        heartbeat = threading.Thread(target=renew, daemon=True)
        heartbeat.start()
        try:
            def publish(kind, text):
                if not self.store.append_stream(job_id, token, kind, text):
                    raise AIError('stream_fenced', '任务已停止。', False, False)
            if isinstance(self.router, Router):
                result, provider, model = self.router.run(request, lambda event: self.store.attempt(job_id, event), on_text=publish, reserve_attempt=lambda provider,messages,limit,casual: self.store.reserve_model_attempt131(job_id,provider,messages,limit,casual))
            else:
                result, provider, model = self.router.run(request, lambda event: self.store.attempt(job_id, event))
            current_rev = None
            if hasattr(self, 'source_checker') and callable(self.source_checker):
                try:
                    current_rev = self.source_checker(job_id, request)
                except Exception:
                    current_rev = None
            if current_rev is None:
                current_rev = request.get('source_revision')
            for attempt in range(3):
                try:
                    # CA-08/B05：完成写入时带上来源指纹复核；不一致的结果不标成当前版本。
                    self.store.complete(job_id, result, provider, model, token,
                                        source_revision=current_rev)
                    break
                except (sqlite3.Error, OSError):
                    if attempt == 2: raise
                    self.stop.wait(attempt + 1)
        except AIError as error:
            self.record_failure(job_id, error, rounds, token)
        except Exception as error:
            # No exception text/traceback: third-party errors may contain request data.
            print("AI worker error:", type(error).__name__, flush=True)
            self.record_failure(job_id, AIError("internal_error", "这次分析未能完成，请稍后重新生成。", True), rounds, token)
        finally:
            heartbeat_stop.set()
            heartbeat.join(timeout=0.1)
            self.release_slot()

    def record_failure(self, job_id, error, rounds, token):
        try:
            self.store.fail(job_id, error, rounds, token)
        except Exception as storage_error:
            # Claim will reclaim the expired lease when storage recovers.
            print('AI failure persistence error:', type(storage_error).__name__, flush=True)


class Handler(BaseHTTPRequestHandler):
    def internal_owner(self):
        return hmac.compare_digest(self.headers.get('Authorization','').encode(), ('Bearer '+self.server.app_token).encode())

    def do_DELETE(self):
        if not self.internal_owner():
            self.reply(404, {'error':'接口不存在。'}); return
        if self.path.startswith('/v1/jobs/'):
            try:
                job_id=str(uuid.UUID(self.path.rsplit('/',1)[-1]))
                self.server.store.delete_private(job_id)
                self.reply(200, {'deleted':True})
            except ValueError:
                self.reply(400, {'error':'任务编号无效。'})
        else: self.reply(404, {'error':'接口不存在。'})
    server_version = "BojiClubAI/0.3"

    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def log_message(self, *_):
        pass

    def reply(self, code, body):
        payload = canonical(body).encode()
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        try:
            self.handle_get()
        except (ValueError, TypeError, KeyError, UnicodeError):
            self.reply(400, {"error": "请求参数格式不正确。"})
        except (OSError, sqlite3.Error):
            self.reply(503, {"error": "后端存储暂不可用，请稍后重试。"})

    def handle_get(self):
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self.reply(200, {"status": "ok", "version": "0.4"})
            return
        if not self.internal_owner():
            self.reply(404, {"error": "接口不存在。"})
            return
        if parsed.path == "/v1/admin/ai/overview":
            days = parse_qs(parsed.query).get("days", [30])[0]
            self.reply(200, self.server.store.admin_overview(days))
        elif parsed.path == "/v1/admin/ai/router":
            self.reply(200, self.server.router.routing_metrics.snapshot())
        elif parsed.path == "/v1/admin/ai/providers":
            self.reply(200, {"providers": provider_status(self.server.router.providers)})
        elif parsed.path == "/v1/admin/ai/live":
            self.reply(200, self.server.store.live_stats())
        elif parsed.path == "/v1/admin/ai/settings":
            self.reply(200, self.server.store.settings())
        elif parsed.path == "/v1/admin/ai/tasks":
            query = parse_qs(parsed.query)
            self.reply(200, self.server.store.admin_tasks(query.get("days", [30])[0], query.get("status", [""])[0], query.get("kind", [""])[0], query.get("page", [1])[0]))
        elif parsed.path.startswith("/v1/admin/ai/tasks/") and parsed.path.endswith("/audit"):
            job_id = parsed.path.split("/")[-2]
            try:
                job_id = str(uuid.UUID(job_id))
            except ValueError:
                self.reply(400, {"error": "任务编号无效。"}); return
            audit = self.server.store.admin_task_audit(job_id)
            self.reply(200 if audit else 404, audit or {"error": "任务不存在。"})
        elif parsed.path == "/v1/admin/ai/health":
            self.reply(200, {"status": "ok", "version": self.server_version.split("/")[-1], "database_bytes": os.path.getsize(self.server.store.path),
                              "providers": provider_status(self.server.router.providers)})
        elif parsed.path.startswith("/v1/jobs/") and parsed.path.endswith('/events'):
            try:
                job_id = str(uuid.UUID(parsed.path.split('/')[-2]))
                after = int(parse_qs(parsed.query).get('after_seq', ['0'])[0])
                if not 0 <= after <= 100000: raise ValueError()
            except (ValueError, IndexError):
                self.reply(400, {'error': '事件游标不正确。'}); return
            wait_ms = max(0,min(800,int(parse_qs(parsed.query).get('wait_ms',['0'])[0])))
            until = time.monotonic()+wait_ms/1000
            events = self.server.store.stream_events(job_id, after)
            while events is not None and not events.get('events') and time.monotonic()<until:
                time.sleep(.04)
                events = self.server.store.stream_events(job_id, after)
            self.reply(200 if events is not None else 404, events or {'error': '任务不存在。'})
        elif self.path.startswith("/v1/jobs/"):
            job = self.server.store.get(self.path.rsplit("/", 1)[-1])
            self.reply(200 if job else 404, job or {"error": "任务不存在，可使用本机保留的输入重新提交。"})
        else:
            self.reply(404, {"error": "接口不存在。"})

    def do_POST(self):
        try:
            if not self.internal_owner():
                self.reply(404, {"error": "接口不存在。"})
                return
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 <= length <= 6_000_000 or self.headers.get("Transfer-Encoding"):
                self.reply(413, {"error": "输入过大，请缩小照片后重试。"})
                return
            data = self.rfile.read(length)
            if len(data) != length:
                raise ValueError("incomplete body")
            body = json.loads(data)
            if not isinstance(body, dict):
                raise ValueError("body must be an object")
            if self.path == "/v1/automation/prepare":
                import automation_core
                deferred=[]
                self.reply(200, {"items": automation_core.prepare(body, validate_request,on_skip=deferred.append),"deferred":deferred})
            elif self.path == "/v1/jobs/metadata":
                self.reply(200, {"items": self.server.store.metadata(body.get("ids"))})
            elif self.path == "/v1/jobs":
                job_id = str(uuid.UUID(body["id"]))
                request = validate_request(body)
                if request["kind"] == "report" and body.get("source_revision") is not None:
                    import automation_core
                    # Recomputed from the validated payload: the client value is advisory only.
                    request["source_revision"] = automation_core.source_revision(request["payload"])
                result = self.server.store.create(job_id, request,quota_owner=body.get('_quota_owner'),enforce_plan_date=True)
                self.reply(202, result)
            elif self.path == '/v1/account-quota/usage':
                self.reply(200,self.server.store.quota_usage(body.get('owner')))
            elif self.path == '/v1/account-quota/bind':
                self.reply(200,self.server.store.bind_owners(body.get('pairs')))
            elif self.path == '/v1/account-quota/erase':
                self.reply(200,self.server.store.erase_owner(body.get('owner')))
            elif self.path == "/v1/fitness/features":
                records = body.get("records") or []
                if not isinstance(records, list) or len(records) > 2000:
                    raise ValueError("records")
                variants = fitness_intelligence.load_variants()
                result = fitness_intelligence.training_features(
                    records, variants,
                    as_of=fitness_intelligence._parse_date(body.get("as_of")),
                    window_days=int(body.get("window_days") or 28))
                self.reply(200, {"status": "ok", "result": result, "rule_version": fitness_intelligence.FEATURE_VERSION})
            elif self.path == "/v1/fitness/assess":
                question = body.get("question") if isinstance(body.get("question"), str) else ""
                facts = body.get("facts")
                if not isinstance(facts, dict):
                    records = body.get("records") or []
                    if not isinstance(records, list) or len(records) > 2000:
                        raise ValueError("records")
                    variants = fitness_intelligence.load_variants()
                    features = fitness_intelligence.training_features(records, variants, window_days=7)
                    facts = {
                        "coverage_score": features["coverage_score"],
                        "training_days": features["training_days"],
                        "completed_sets": sum(v["completed_sets"] for v in features["variants"]),
                        "source_record_ids": features["source_record_ids"],
                        "data_freshness_days": features["data_freshness_days"],
                    }
                self.reply(200, {"status": "ok", "result": fitness_intelligence.assess_readiness(facts, question)})
            elif self.path == "/v1/fitness/progression":
                variant = fitness_intelligence.load_variants().get(str(body.get("library_id") or ""))
                sets = body.get("sets") or []
                if not isinstance(sets, list) or len(sets) > 100:
                    raise ValueError("sets")
                self.reply(200, {"status": "ok", "result": fitness_intelligence.progression_advisory(
                    variant, sets, target_reps=int(body.get("target_reps") or 8),
                    effort_acceptable=body.get("effort_acceptable"),
                    pain_reported=body.get("pain_reported") is True)})
            elif self.path == "/v1/nutrition/search":
                self.reply(200, {'result': nutrition_engine.search_foods(body.get('query'), body.get('limit', 8))})
            elif self.path == "/v1/nutrition/compute":
                items = body.get("items") or []
                if not isinstance(items, list) or not 1 <= len(items) <= 50:
                    raise ValueError("items")
                self.reply(200, {"status": "ok", "result": nutrition_engine.compute_meal(
                    items, category=str(body.get("category") or ""),
                    on_date=body.get("date") if isinstance(body.get("date"), str) else None,
                    photo_hash=body.get("photo_hash") if isinstance(body.get("photo_hash"), str) else None)})
            elif self.path == "/v1/nutrition/amend":
                original = body.get("original")
                corrections = body.get("corrections")
                if not isinstance(original, dict) or not isinstance(corrections, dict):
                    raise ValueError("amendment")
                self.reply(200, {"status": "ok", "result": nutrition_engine.amendment_of(original, corrections)})
            elif self.path == "/v1/personal/memories/resolve":
                incoming_raw = body.get("incoming")
                if not isinstance(incoming_raw, dict):
                    raise ValueError("incoming")
                incoming = personal_intelligence.MemoryItem(
                    key=str(incoming_raw.get("key") or ""),
                    kind=str(incoming_raw.get("kind") or "ai_hypothesis"),
                    value=str(incoming_raw.get("value") or ""),
                    status=str(incoming_raw.get("status") or "tentative"),
                    confidence=float(incoming_raw.get("confidence") or 0),
                    evidence_refs=incoming_raw.get("evidence_refs") if isinstance(incoming_raw.get("evidence_refs"), list) else [],
                    source=str(incoming_raw.get("source") or "ai"),
                )
                existing_raw = body.get("existing")
                existing = None
                if isinstance(existing_raw, dict):
                    existing = personal_intelligence.MemoryItem(
                        key=str(existing_raw.get("key") or ""),
                        kind=str(existing_raw.get("kind") or "ai_hypothesis"),
                        value=str(existing_raw.get("value") or ""),
                        status=str(existing_raw.get("status") or "tentative"),
                        confidence=float(existing_raw.get("confidence") or 0),
                        evidence_refs=existing_raw.get("evidence_refs") if isinstance(existing_raw.get("evidence_refs"), list) else [],
                        source=str(existing_raw.get("source") or "ai"),
                    )
                decision = personal_intelligence.resolve_memory(existing, incoming)
                self.reply(200, {"status": "ok", "result": {
                    "action": decision["action"], "reason": decision.get("reason"),
                    "item": decision.get("item").__dict__ if decision.get("item") else None}})
            elif self.path == "/v1/personal/insights/rank":
                candidates = body.get("candidates") or []
                if not isinstance(candidates, list) or len(candidates) > 200:
                    raise ValueError("candidates")
                history = body.get("history") if isinstance(body.get("history"), dict) else {}
                preferences = body.get("preferences") if isinstance(body.get("preferences"), dict) else {}
                self.reply(200, {"status": "ok", "result": personal_intelligence.rank_insights(
                    candidates, history=history, preferences=preferences)})
            elif self.path == "/v1/admin/ai/settings":
                self.reply(200, self.server.store.update_settings(body))
            elif self.path == "/v1/admin/ai/router":
                self.reply(200, self.server.router.routing_metrics.configure(body))
            elif self.path == "/v1/admin/ai/providers":
                name = body.get("name")
                if name not in PROVIDER_DEFAULTS or type(body.get("enabled")) is not bool:
                    raise ValueError("provider configuration")
                priority = body.get("priority")
                if isinstance(priority, bool) or not isinstance(priority, int) or not 1 <= priority <= 99:
                    raise ValueError("provider priority")
                key = body.get("key", "")
                if not isinstance(key, str) or len(key) > 500 or "\n" in key or "\r" in key:
                    raise ValueError("provider key")
                clear_key = body.get("clear_key", False)
                if type(clear_key) is not bool or (clear_key and key.strip()):
                    raise ValueError("provider key clear")
                prefix = name.upper()
                values = {prefix + "_ENABLED": "1" if body["enabled"] else "0", prefix + "_PRIORITY": str(priority)}
                if clear_key:
                    # Explicitly remove a leaked/retired credential; an empty
                    # key input still means "keep the stored key".
                    values[prefix + "_API_KEY"] = ""
                elif key.strip():
                    values[prefix + "_API_KEY"] = key.strip()
                protected_env_update(values)
                self.server.router.replace_providers(providers_from_env())
                self.reply(200, {"providers": provider_status(self.server.router.providers)})
            elif self.path.startswith("/v1/jobs/") and self.path.endswith("/retry"):
                job_id = str(uuid.UUID(self.path.split("/")[-2]))
                existing = self.server.store.get(job_id)
                if existing and existing['kind']=='weekly_review':
                    self.reply(404, {'error':'请重新创建复盘。'}); return
                job = self.server.store.retry(job_id,quota_owner=body.get('_quota_owner'),enforce_plan_date=True)
                self.reply(202 if job else 404, job or {"error": "任务不存在。"})
            else:
                self.reply(404, {"error": "接口不存在。"})
        except AIError as error:
            status = 409 if error.code == "id_conflict" else 429 if error.code in ("capacity","daily_capacity","quota_exceeded","quota_pending") else 503 if error.code == "maintenance" else 400
            delay = 86400-int((time.time()+8*3600)%86400) if error.code in ('daily_capacity','quota_exceeded') else 30 if error.code=='quota_pending' else 60
            self.reply(status, {"error": error.public_message, "code": error.code, **({'retry_after': delay} if error.code in ('capacity','maintenance','daily_capacity','quota_exceeded','quota_pending') else {})})
        except (ValueError, TypeError, KeyError, UnicodeError):
            self.reply(400, {"error": "请求数据格式不正确。"})
        except (OSError, sqlite3.Error):
            self.reply(503, {"error": "后端存储暂不可用，输入仍保留在 App 内。"})


def make_server(store, router, token, port=8787, maximum_per_day=None):
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    server.store = store
    server.router = router
    server.app_token = token
    # Compatibility for callers explicitly passing a limit; main() uses stored settings.
    if maximum_per_day is not None:
        store.update_settings({'daily_limit': maximum_per_day})
    return server


def main():
    os.umask(0o077)
    load_env(BASE / ".env")
    load_provider_overrides()
    token = os.getenv("APP_TOKEN", "")
    if len(token) < 24:
        raise SystemExit("请先运行 python3 setup.py，生成安全的后端连接码。")
    router = Router()
    if not any(p.key for p in router.providers):
        raise SystemExit("请先配置至少一个模型 API Key。")
    store = JobStore(BASE / ".data" / "jobs.sqlite3")
    workers = Workers(store, router)
    server = make_server(store, router, token, int(os.getenv("PORT", "8787")))
    workers.thread.start()
    # systemd stops accepting HTTP, then lets bounded in-flight requests finish.
    # shutdown() cannot run on the serve_forever thread itself.
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown, daemon=True).start())
    print("薄肌 AI 后端已启动：监听 127.0.0.1:%s（请通过 HTTPS 反向代理对外提供服务）" % server.server_port, flush=True)
    print("AI 并发由后台配置；按内存保护调度。旧授权请求保留原接收方范围。按 Ctrl+C 停止。", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        workers.stop.set()
        workers.thread.join(2)
        server.server_close()
        workers.pool.shutdown(wait=True)


if __name__ == "__main__":
    main()
