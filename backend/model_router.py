"""Task-aware, bounded two-provider routing. Stores metrics, never prompt text."""
import contextvars
import json
import os
import random
import sqlite3
import threading
import time
from pathlib import Path

POLICY = contextvars.ContextVar('boji_model_policy', default={})
VERSION = 'router.v3.20261026'
WEIGHTS = {'chat': .8, 'reference': .7, 'proposal': .7, 'complex': .5, 'vision': .5}

def task_policy(request):
    p = request.get('payload', {})
    vision = bool(p.get('images') or p.get('image_base64') or p.get('photos') or (request['kind']=='food' and p.get('source')!='text'))
    complex_task = request['kind'] in ('generate_plan','parse_plan','weekly_review') or p.get('deep_analysis') is True
    bucket = 'vision' if vision else 'complex' if complex_task else 'reference' if p.get('_references') or p.get('purpose')=='workout' else 'proposal' if p.get('_intent',{}).get('kind') in ('change_proposal','draft_create') else 'chat'
    return {'bucket':bucket, 'deep':p.get('deep_analysis') is True,
            'budget':90 if request['kind'] in ('generate_plan','parse_plan') else 60 if complex_task or vision or request['kind']=='report' else 45,
            'max_attempts':2, 'version':VERSION}

def request_body(provider, messages, limit, streaming):
    policy=POLICY.get(); deep=policy.get('deep',False)
    body={'model':provider.model,'messages':messages}
    if provider.name=='minimax':
        body.update(reasoning_effort='high' if deep else 'low', max_completion_tokens=max(limit,8192))
        # M3.1 Flash requires thinking. response_format is not portable.
    else:
        body.update(thinking={'type':'enabled' if deep else 'disabled'},max_tokens=limit)
        if deep: body['reasoning_effort']='high'
        if provider.name!='longcat': body['response_format']={'type':'json_object'}
        if provider.name=='mimo': body['max_completion_tokens']=body.pop('max_tokens')
    if streaming: body.update(stream=True,stream_options={'include_usage':True})
    return body

class RoutingMetrics:
    def __init__(self, path=None):
        self.path=Path(path or os.getenv('BOJI_ROUTER_METRICS',str(Path(__file__).parent/'.data/router-metrics.sqlite3')))
        self.lock=threading.Lock()
    def connect(self):
        self.path.parent.mkdir(parents=True,exist_ok=True)
        db=sqlite3.connect(self.path,timeout=3)
        db.execute('CREATE TABLE IF NOT EXISTS samples(bucket TEXT,provider TEXT,ok INTEGER,latency REAL,ttft REAL,tokens INTEGER,created REAL)')
        db.execute('CREATE TABLE IF NOT EXISTS controls(id INTEGER PRIMARY KEY CHECK(id=1),payload TEXT)')
        return db
    def controls(self):
        try:
            with self.connect() as db:
                row=db.execute('SELECT payload FROM controls WHERE id=1').fetchone()
                return json.loads(row[0]) if row else {}
        except (OSError,sqlite3.Error,ValueError): return {}
    def configure(self,body):
        if set(body)-{'weights','enabled'}: raise ValueError('router controls')
        weights=body.get('weights',{})
        if not isinstance(weights,dict) or set(weights)-set(WEIGHTS):raise ValueError('router weights')
        if any(type(v) not in (int,float) or not .1<=v<=.9 for v in weights.values()):raise ValueError('router weights')
        if type(body.get('enabled',True)) is not bool:raise ValueError('router enabled')
        with self.connect() as db: db.execute('INSERT OR REPLACE INTO controls VALUES(1,?)',(json.dumps(body),))
        return self.snapshot()
    def record(self,bucket,provider,ok,latency,usage):
        try:
            with self.lock,self.connect() as db:
                db.execute('INSERT INTO samples VALUES(?,?,?,?,?,?,?)',(bucket,provider,int(ok),latency,usage.get('first_text_ms'),usage.get('total_tokens',0),time.time()))
                db.execute('DELETE FROM samples WHERE rowid NOT IN (SELECT rowid FROM samples ORDER BY rowid DESC LIMIT 4000)')
        except (OSError,sqlite3.Error): pass
    def snapshot(self):
        stats={}
        try:
            with self.connect() as db:
                rows=db.execute('SELECT bucket,provider,ok,latency,ttft,tokens FROM samples WHERE created>? ORDER BY rowid DESC LIMIT 2000',(time.time()-86400,)).fetchall()
            for bucket,provider,ok,latency,ttft,tokens in rows:
                d=stats.setdefault(bucket+'/'+provider,{'n':0,'failures':0,'latency':[],'ttft':[],'tokens':0})
                d['n']+=1;d['failures']+=not ok;d['latency'].append(latency);d['tokens']+=tokens
                if ttft is not None:d['ttft'].append(ttft)
            for d in stats.values():
                for key in ('latency','ttft'):
                    values=sorted(d.pop(key));d[key+'_p95_ms']=values[min(len(values)-1,int(len(values)*.95))] if values else None
        except (OSError,sqlite3.Error):pass
        return {'version':VERSION,'controls':self.controls(),'default_weights_deepseek':WEIGHTS,'samples_24h':stats,'quality_gate':'schema_and_domain_validation','cost':'usage only; no fabricated price estimate'}
    def order(self,providers,request):
        candidates=list(providers)
        if not candidates or not {p.name for p in candidates}.issubset({'deepseek','minimax'}):return sorted(candidates,key=lambda p:p.priority)
        policy=task_policy(request);controls=self.controls()
        if controls.get('enabled') is False or request.get('payload',{}).get('_router_v3') is False:return sorted(candidates,key=lambda p:p.priority)
        weight=controls.get('weights',{}).get(policy['bucket'],WEIGHTS[policy['bucket']])
        stats=self.snapshot()['samples_24h']
        a=stats.get(policy['bucket']+'/deepseek',{});b=stats.get(policy['bucket']+'/minimax',{})
        # Require enough observations on both sides; adjust slowly, preserving exploration.
        if min(a.get('n',0),b.get('n',0))>=30:
            def score(d):return (d.get('ttft_p95_ms') or d['latency_p95_ms'])*.6+d['latency_p95_ms']*.4+20000*d['failures']/d['n']
            weight=max(.1,min(.9,weight+(.1 if score(a)<score(b) else -.1)))
        first='deepseek' if random.random()<weight else 'minimax'
        return sorted(candidates,key=lambda p:(p.name!=first,p.priority))
