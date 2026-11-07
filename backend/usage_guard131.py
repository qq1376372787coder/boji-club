"""Conservative per-attempt reservations: failed calls and fallbacks still consume budgets.
Only HMAC owner IDs, provider names, counters and timestamps are stored, never prompts.
These are resource ceilings, not invoices or measured token claims.
"""
import os
import re
import sqlite3
import time
import unicodedata


def cap(name, default):
    try:
        value = int(os.getenv(name, default))
        return max(1, value)
    except (TypeError, ValueError):
        return default


def reserve(db, job, owner, provider, messages, output_limit, casual=False, now=None):
    now = time.time() if now is None else now
    start = int((now + 28800) // 86400) * 86400 - 28800
    # UTF-8 bytes conservatively bound text tokens; images reserve a separate ceiling.
    text_bytes = 0
    images = 0
    for message in messages:
        content = message.get('content', '')
        if isinstance(content, str):
            text_bytes += len(content.encode('utf-8'))
        elif isinstance(content, list):
            for part in content:
                if part.get('type') == 'text':
                    text_bytes += len(part.get('text', '').encode('utf-8'))
                elif part.get('type') == 'image_url':
                    images += 1
    allowance = text_bytes + images * 16000 + output_limit
    if text_bytes > 360000 or images > 6:
        raise ValueError('input_ceiling')
    db.execute('CREATE TABLE IF NOT EXISTS model_reservations131(id INTEGER PRIMARY KEY,job TEXT,owner TEXT,provider TEXT,allowance INTEGER,casual INTEGER,created REAL)')
    db.execute('CREATE INDEX IF NOT EXISTS model_reservations131_owner_time ON model_reservations131(owner,created)')
    db.execute('DELETE FROM model_reservations131 WHERE created<?', (now - 31*86400,))
    count, tokens = db.execute('SELECT count(*),coalesce(sum(allowance),0) FROM model_reservations131 WHERE created>=?', (start,)).fetchone()
    if count >= cap('BOJI_MODEL_ATTEMPTS_GLOBAL_DAY', 6000) or tokens + allowance > cap('BOJI_MODEL_TOKEN_CEILING_GLOBAL_DAY', 50000000):
        raise ValueError('global_budget')
    if db.execute('SELECT count(*) FROM model_reservations131 WHERE job=?', (job,)).fetchone()[0] >= 6:
        raise ValueError('job_budget')
    if owner:
        count, tokens = db.execute('SELECT count(*),coalesce(sum(allowance),0) FROM model_reservations131 WHERE owner=? AND created>=?', (owner,start)).fetchone()
        if count >= cap('BOJI_MODEL_ATTEMPTS_ACCOUNT_DAY', 120) or tokens+allowance > cap('BOJI_MODEL_TOKEN_CEILING_ACCOUNT_DAY', 2400000):
            raise ValueError('account_budget')
        for seconds, ceiling in [(60,10),(600,60)]:
            if db.execute('SELECT count(*) FROM model_reservations131 WHERE owner=? AND created>=?', (owner,now-seconds)).fetchone()[0] >= ceiling:
                raise ValueError('account_rate')
        if casual:
            used = db.execute('SELECT count(DISTINCT job) FROM model_reservations131 WHERE owner=? AND casual=1 AND created>=? AND job<>?', (owner,start,job)).fetchone()[0]
            if used >= cap('BOJI_CASUAL_MESSAGES_ACCOUNT_DAY', 15):
                raise ValueError('casual_budget')
    db.execute('INSERT INTO model_reservations131(job,owner,provider,allowance,casual,created) VALUES(?,?,?,?,?,?)', (job,owner,provider,allowance,int(casual),now))


DOMAIN = re.compile(r'训练|健身|肌肉|饮食|吃|餐|食物|热量|蛋白|体重|身体|跑步|运动|计划|复盘|记录|健康|疼|痛|生病|睡眠|疲劳|累|营养|卡路里|身高|BMI|动作|教练|日历|俱乐部|登录|账号|反馈|同步|订阅|付费|休息|卧推|深蹲|硬拉|weight|workout|fitness|calori|meal|pain|sleep|protein|plan',re.I)

def casual(request):
    p = request.get('payload', {})
    return request.get('kind') == 'coach' and not (p.get('_references') or p.get('images') or p.get('source_session') or p.get('purpose') in ('workout','weekly_review')) and not DOMAIN.search(p.get('question',''))


def refusal(request):
    if request.get('kind') != 'coach':
        return None
    q = unicodedata.normalize('NFKC', request.get('payload',{}).get('question','')).lower()
    q = re.sub(r'[\s\u200b-\u200f]', '', q)
    # Match requests for actionable harm. Discussion of news, policy, symptoms and
    # safety is not banned by topic keywords. Model policy covers semantic variants.
    harmful = (re.search(r'(怎么|如何|教我|步骤|配方|制作|制造|组装).{0,18}(炸弹|炸药|爆炸物|毒药|毒气)',q) or
               re.search(r'(bomb|explosive|poison).{0,25}(recipe|instructions|manufactur)',q) or
               re.search(r'(make|build|manufacture).{0,20}(bomb|explosive)',q))
    if harmful:
        return '我不能提供制造爆炸物、毒物或伤害他人的操作方法。如果遇到可疑物品，请远离并联系当地应急部门。我们可以继续聊安全的训练、饮食或健康记录。'
    return None
