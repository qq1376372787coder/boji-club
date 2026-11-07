#!/usr/bin/env python3
"""Read-only operational checks and durable, privacy-safe alert lifecycles.

Default: collect and show in admin only; never send externally. Configuration is
an optional root-owned 0600 JSON file at /etc/bojiclub/operations-alerts.json.
External delivery additionally requires --allow-notifications (operator opt-in).
Example config keys: failure_rate=0.2, minimum_samples=20, window_seconds=1800,
backup_max_age_seconds=93600, disk_min_free_bytes=2147483648,
notifications={enabled:false, webhook:{url:"https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=..."},
 smtp:{host:"smtp.example.com",port:465,username:"...",password:"...",sender:"...",recipients:["..."]}}.
Only fixed check metadata is published/sent, never SQL rows, paths, credentials,
HTTP bodies, exception text, prompts, user IDs, or health records.
"""
from __future__ import annotations
import argparse
import datetime as dt
from email.message import EmailMessage
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import smtplib
import sqlite3
import ssl
import stat
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request

DEFAULTS = {
    'failure_rate': .2, 'minimum_samples': 20, 'window_seconds': 1800,
    'backup_max_age_seconds': 26*3600, 'disk_min_free_bytes': 2*1024**3,
    'disk_min_free_percent': 10, 'cooldown_seconds': 6*3600, 'retry_seconds': 900,
    'ai_sqlite': '/opt/bojiclub-ai/.data/jobs.sqlite3', 'disk_path': '/opt',
    'backup_status': '/opt/bojiclub-account/runtime/backup-status.json',
    'mysql_database': 'bojiclub', 'ai_health_url': 'http://127.0.0.1:8787/health',
}
TIMERS = {
    'bojiclub-ai-runs': ('AI 对话处理', 180),
    'bojiclub-action-jobs': ('操作任务处理', 180),
    'bojiclub-domain-outbox': ('数据同步任务', 180),
    'bojiclub-domain-notifications': ('通知任务处理', 180),
    'bojiclub-account-deletions': ('注销清理任务', 180),
    'bojiclub-club-automation': ('活动自动处理', 1200),
    'bojiclub-club-push': ('分析完成提醒', 1200),
    'bojiclub-domain-reconcile': ('数据核对任务', 2700),
    'bojiclub-ai-run-prune': ('AI 历史清理', 7200),
    'bojiclub-backup': ('每日备份任务', 26*3600),
    'bojiclub-backup-monitor': ('备份状态更新', 1200),
    'bojiclub-scheduled-notifications': ('定时通知发送', 900),
    'operations-alerts': ('异常告警采集', 1200),
}


def timestamp(value=None):
    return dt.datetime.fromtimestamp(time.time() if value is None else value, dt.timezone.utc).isoformat()


def epoch(value):
    try:
        return dt.datetime.fromisoformat(str(value).replace('Z', '+00:00')).timestamp()
    except (ValueError, TypeError):
        try:
            return dt.datetime.strptime(str(value), '%a %Y-%m-%d %H:%M:%S %Z').replace(tzinfo=dt.timezone.utc).timestamp()
        except (ValueError, TypeError):
            return None


def read_json(path):
    try:
        with Path(path).open() as source:
            value = json.load(source)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def load_config(path):
    config = dict(DEFAULTS)
    if Path(path).exists() or Path(path).is_symlink():
        info = Path(path).lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
            raise ValueError('配置文件必须由 root 持有，权限为 0600 或 0400。')
        with Path(path).open() as source:
            custom = json.load(source)
        if not isinstance(custom, dict):
            raise ValueError('配置格式不正确。')
        config.update(custom)
    # Keep thresholds bounded so configuration mistakes cannot silently disable checks.
    for key, low, high in [('failure_rate', .01, 1), ('minimum_samples', 1, 100000),
                          ('window_seconds', 60, 86400), ('backup_max_age_seconds', 3600, 7*86400),
                          ('disk_min_free_bytes', 1, 1024**5), ('disk_min_free_percent', 1, 99),
                          ('cooldown_seconds', 300, 7*86400), ('retry_seconds', 60, 86400)]:
        value = config[key]
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not low <= value <= high:
            raise ValueError('告警阈值不正确。')
    if not re.fullmatch(r'[A-Za-z0-9_]+', str(config['mysql_database'])):
        raise ValueError('数据库名称不正确。')
    if not re.fullmatch(r'http://127\.0\.0\.1:[0-9]{2,5}/health', str(config['ai_health_url'])):
        raise ValueError('AI 健康检查只允许本机 /health。')
    notifications = config.get('notifications', {})
    if not isinstance(notifications, dict) or not isinstance(notifications.get('enabled', False), bool):
        raise ValueError('通知开关格式不正确。')
    if notifications.get('enabled') is True:
        channels = notification_channels(config, True)
        if not channels:
            raise ValueError('已开启外部通知，但尚未配置接收渠道。')
        for kind, channel in channels.items():
            (validate_webhook if kind == 'webhook' else validate_smtp)(channel)
    return config


def atomic_json(path, value, mode):
    path = Path(path)
    new_parent = not path.parent.exists()
    directory_mode = 0o700 if mode == 0o600 else 0o755
    path.parent.mkdir(mode=directory_mode, parents=True, exist_ok=True)
    if new_parent:
        os.chmod(path.parent, directory_mode)  # Service umask must not hide the public runtime directory.
    fd, temp = tempfile.mkstemp(prefix='.alerts-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as target:
            os.fchmod(target.fileno(), mode)
            json.dump(value, target, ensure_ascii=False, allow_nan=False)
            target.flush()
            os.fsync(target.fileno())
        os.replace(temp, path)
    finally:
        Path(temp).unlink(missing_ok=True)


def check(key, title, fault, detail, severity='warning'):
    return {'key': key, 'title': title, 'fault': fault, 'detail': detail, 'severity': severity}


def rate_check(key, title, failed, total, config):
    rate = failed / total if total else 0
    enough = total >= config['minimum_samples']
    return check(key, title, enough and rate >= config['failure_rate'],
                 f"最近 {int(config['window_seconds'])//60} 分钟：{total} 次已结束任务中 {failed} 次失败，失败率 {rate:.1%}。" +
                 ('' if enough else '样本不足，继续观察。'))


def mysql_checks(config, now):
    cutoff = dt.datetime.fromtimestamp(now-config['window_seconds'], dt.timezone.utc).strftime('%Y-%m-%d %H:%M:%S')
    sql = "SELECT 1; SELECT COALESCE(SUM(status='failed'),0),COUNT(*) FROM ai_runs WHERE status IN ('completed','failed') AND updated_at >= '" + cutoff + "';"
    try:
        result = subprocess.run(['mysql', '--protocol=socket', '--connect-timeout=4', '--batch', '--skip-column-names',
                                 config['mysql_database'], '-e', sql], capture_output=True, text=True, timeout=8)
        lines = result.stdout.strip().splitlines()
        if result.returncode or len(lines) != 2 or lines[0] != '1':
            raise ValueError()
        failed, total = map(int, lines[1].split('\t'))
        if not 0 <= failed <= total:
            raise ValueError()
        return [check('account_database', '账号数据库连接异常', False, '账号数据库可读取。'),
                rate_check('account_failure_rate', 'AI 对话失败率偏高', failed, total, config)]
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return [check('account_database', '账号数据库检查失败', True, '无法完成数据库只读检查，请核对数据库和采集账号权限。', 'critical'),
                check('account_failure_rate', 'AI 对话失败率偏高', None, '暂时无法统计。')]


def ai_checks(config, now):
    checks = []
    try:
        # No proxy, no credentials, and a fixed local-only endpoint.
        with urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open(config['ai_health_url'], timeout=4) as response:
            payload = json.loads(response.read(65536))
            healthy = response.status == 200 and isinstance(payload, dict) and payload.get('status') == 'ok'
        checks.append(check('ai_service', 'AI 服务暂时不可用', not healthy, 'AI 服务健康检查' + ('正常。' if healthy else '未通过。'), 'critical'))
    except (OSError, ValueError, TypeError):
        checks.append(check('ai_service', 'AI 服务暂时不可用', True, '本机 AI 服务健康检查未通过。', 'critical'))
    try:
        path = Path(config['ai_sqlite']).resolve()
        with sqlite3.connect(path.as_uri()+'?mode=ro', uri=True, timeout=3) as db:
            failed, total = db.execute("SELECT COALESCE(SUM(status='failed'),0),COUNT(*) FROM jobs WHERE status IN ('succeeded','failed') AND updated>=?", (now-config['window_seconds'],)).fetchone()
        checks.extend([check('ai_database', 'AI 任务数据检查失败', False, 'AI 任务数据可读取。'),
                       rate_check('ai_failure_rate', 'AI 执行失败率偏高', failed, total, config)])
    except (OSError, sqlite3.Error, ValueError):
        checks.extend([check('ai_database', 'AI 任务数据检查失败', True, '无法读取 AI 任务统计，请检查数据库文件。', 'critical'),
                       check('ai_failure_rate', 'AI 执行失败率偏高', None, '暂时无法统计。')])
    return checks


def backup_checks(config, now):
    backup = read_json(config['backup_status'])
    checked = epoch(backup.get('checked_at'))
    last = epoch(backup.get('last_success'))
    fresh = checked is not None and -300 <= now-checked < 900
    return [check('backup_monitor', '备份状态长时间未更新', not fresh, '备份状态' + ('已更新。' if fresh else '超过 15 分钟未更新或尚无记录，请核对备份状态采集。')),
            check('backup_expired', '可用备份已过期或尚未确认', None if not fresh else
                  (last is None or now-last > config['backup_max_age_seconds'] or last > now+300 or not backup.get('local_archive_present')),
                  '需要最近 '+str(round(config['backup_max_age_seconds']/3600, 1))+' 小时内成功且仍存在的本机备份。', 'critical'),
            check('backup_failed', '最近一次备份失败', None if not fresh else backup.get('state') == 'failed',
                  '最近一次备份执行失败，请检查服务器备份日志。')]


def unit_properties(unit):
    try:
        result = subprocess.run(['systemctl', 'show', unit, '--no-pager', '--property=LoadState,ActiveState,UnitFileState,LastTriggerUSec,Result'],
                                capture_output=True, text=True, timeout=4, env={**os.environ, 'TZ': 'UTC'})
        if result.returncode:
            return {}
        return dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
    except (OSError, subprocess.TimeoutExpired):
        return {}


def scheduler_checks(now, uptime):
    checks = []
    for base, (title, max_age) in TIMERS.items():
        if base == 'bojiclub-ai-runs':
            workers = [unit_properties(f'{base}@{i}.service') for i in (1, 2)]
            if all(w.get('LoadState') == 'loaded' and w.get('ActiveState') == 'active' and
                   w.get('UnitFileState') in ('enabled', 'enabled-runtime') for w in workers):
                checks.append(check('schedule_'+base, title+'处理进程', False, '两个常驻处理进程运行正常。'))
                continue
        timer, service = unit_properties(base+'.timer'), unit_properties(base+'.service')
        if not timer:
            checks.append(check('schedule_'+base, title+'调度无法检查', True, '无法读取定时任务状态，请检查 systemd。'))
            continue
        last = epoch(timer.get('LastTriggerUSec'))
        fault = (timer.get('LoadState') != 'loaded' or timer.get('ActiveState') != 'active' or
                 timer.get('UnitFileState') not in ('enabled', 'enabled-runtime') or service.get('Result', 'success') not in ('', 'success', 'unknown') or
                 (last is not None and now-last > max_age and uptime > 600) or
                 (last is None and uptime > max(600, max_age)))
        checks.append(check('schedule_'+base, title+'未按时运行', fault,
                            '请检查定时任务是否启用、最近运行时间和执行结果。' if fault else '定时任务状态正常。'))
    return checks


def collect(config, now):
    checks = mysql_checks(config, now) + ai_checks(config, now) + backup_checks(config, now)
    try:
        usage = shutil.disk_usage(config['disk_path'])
        percent = usage.free / usage.total * 100
        checks.append(check('disk_space', '服务器磁盘空间不足', usage.free < config['disk_min_free_bytes'] or percent < config['disk_min_free_percent'],
                            f'剩余空间 {usage.free/1024**3:.1f} GB（{percent:.1f}%）。', 'critical'))
    except OSError:
        checks.append(check('disk_space', '服务器磁盘空间无法检查', True, '无法读取磁盘剩余空间。'))
    try:
        uptime = float(Path('/proc/uptime').read_text().split()[0])
    except (OSError, ValueError, IndexError):
        uptime = 86400*365
    return checks + scheduler_checks(now, uptime)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def notification_channels(config, allow):
    value = config.get('notifications', {})
    if not isinstance(value, dict) or value.get('enabled') is not True or not allow:
        return {}
    return {key: value[key] for key in ('webhook', 'smtp') if isinstance(value.get(key), dict) and value[key]}


def validate_webhook(channel):
    url = str(channel.get('url', ''))
    parsed = urllib.parse.urlsplit(url)
    allowed = {'qyapi.weixin.qq.com': '/cgi-bin/webhook/send',
               'open.feishu.cn': '/open-apis/bot/v2/hook/', 'oapi.dingtalk.com': '/robot/send'}
    prefix = allowed.get(parsed.hostname)
    if parsed.scheme != 'https' or parsed.port not in (None, 443) or parsed.username or parsed.password or parsed.fragment or not prefix:
        raise ValueError('通知地址不被允许。')
    if not (parsed.path.startswith(prefix) if prefix.endswith('/') else parsed.path == prefix):
        raise ValueError('通知路径不被允许。')
    return url, parsed


def send_webhook(channel, message):
    url, parsed = validate_webhook(channel)
    if parsed.hostname == 'open.feishu.cn':
        payload = {'msg_type': 'text', 'content': {'text': message}}
    else:
        payload = {'msgtype': 'text', 'text': {'content': message}}
    request = urllib.request.Request(url, data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json'}, method='POST')
    with urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open(request, timeout=8) as response:
        result = json.loads(response.read(65536))
        # HTTP 200 alone is not proof that the robot accepted the notification.
        if not isinstance(result, dict):
            raise ValueError('机器人返回格式异常。')
        code = result.get('code') if parsed.hostname == 'open.feishu.cn' else result.get('errcode')
        if not 200 <= response.status < 300 or type(code) is not int or code != 0:
            raise ValueError('机器人未接受通知。')


def validate_smtp(channel):
    host, port = str(channel.get('host', '')), int(channel.get('port', 465))
    sender, recipients = channel.get('sender'), channel.get('recipients')
    if not re.fullmatch(r'[A-Za-z0-9.-]+', host) or port not in (465, 587):
        raise ValueError('邮件服务器配置不正确。')
    if not isinstance(recipients, list) or not 1 <= len(recipients) <= 20:
        raise ValueError('邮件收件人不正确。')
    for address in [sender, *recipients]:
        if not isinstance(address, str) or not re.fullmatch(r'[^\s<>@]+@[^\s<>@]+', address):
            raise ValueError('邮件地址不正确。')
    if any(not isinstance(channel.get(key, ''), str) for key in ('username', 'password')):
        raise ValueError('邮件登录配置不正确。')
    return host, port, sender, recipients


def send_smtp(channel, message):
    host, port, sender, recipients = validate_smtp(channel)
    mail = EmailMessage()
    mail['Subject'], mail['From'], mail['To'] = '薄肌服务状态通知', sender, ', '.join(recipients)
    mail.set_content(message)
    context = ssl.create_default_context()
    connection = smtplib.SMTP_SSL(host, port, timeout=8, context=context) if port == 465 else smtplib.SMTP(host, port, timeout=8)
    with connection as smtp:
        if port == 587:
            smtp.ehlo(); smtp.starttls(context=context); smtp.ehlo()
        if channel.get('username'):
            smtp.login(channel['username'], channel.get('password', ''))
        if smtp.send_message(mail):
            raise ValueError('邮件服务器拒绝部分收件人。')


def deliver(event, config, allow, now):
    phase = event['status']
    channels = notification_channels(config, allow)
    deliveries = event.setdefault('notifications', {}).setdefault(phase, {})
    for name, channel in channels.items():
        if phase == 'recovered' and name not in event.get('notifications', {}).get('active', {}):
            continue  # Enabling a channel later must not replay old recovery history.
        previous = deliveries.get(name, {})
        # Retry failures, repeat unresolved alerts only after the longer cooldown.
        interval = config['cooldown_seconds'] if previous.get('state') == 'accepted' else config['retry_seconds']
        if previous and now-previous['attempted_at_epoch'] < interval:
            continue
        if phase == 'recovered' and previous.get('state') == 'accepted':
            continue
        if config.get('_remaining_deliveries', 8) <= 0:
            continue
        config['_remaining_deliveries'] = config.get('_remaining_deliveries', 8)-1
        message = '\n'.join(['薄肌服务'+('异常提醒' if phase == 'active' else '恢复通知'), event['title'],
                             event['detail'] if phase == 'active' else '本次检查已恢复正常。',
                             '发生时间：'+event['opened_at'], '检查时间：'+timestamp(now), '请登录管理后台查看。'])
        state = 'failed'
        try:
            (send_webhook if name == 'webhook' else send_smtp)(channel, message)
            state = 'accepted'
        except (OSError, ValueError, TypeError, AttributeError, smtplib.SMTPException):
            pass  # Never publish raw exception/response text: it can contain credentials.
        deliveries[name] = {'state': state, 'attempted_at': timestamp(now), 'attempted_at_epoch': now,
                            'attempts': previous.get('attempts', 0)+1}


def reconcile(state, checks, config, allow, now):
    config['_remaining_deliveries'] = 8
    events = state.setdefault('events', [])
    active = {e['key']: e for e in events if e['status'] == 'active'}
    observed = {c['key']: c for c in checks}
    for item in checks:
        event = active.get(item['key'])
        if item['fault'] is True:
            if event is None:
                event = {k: item[k] for k in ('key', 'title', 'detail', 'severity')}
                event.update(id=os.urandom(12).hex(), status='active', opened_at=timestamp(now), last_seen_at=timestamp(now))
                events.append(event)
            else:
                event.update(title=item['title'], detail=item['detail'], last_seen_at=timestamp(now))
        elif item['fault'] is False and event:
            event.update(status='recovered', recovered_at=timestamp(now), last_seen_at=timestamp(now))
        # An unavailable metric is unknown, never evidence of recovery.
    for event in events:
        item = observed.get(event['key'])
        if event['status'] == 'recovered' or (item and item['fault'] is True):
            deliver(event, config, allow, now)
    # Keep all active events and a bounded recent history; never drop an active fault.
    state['events'] = [e for e in events if e['status'] == 'active'] + [e for e in events if e['status'] == 'recovered'][-200:]
    state['schema_version'] = 1
    return state


def public_snapshot(state, checks, config, allow, now):
    channels = notification_channels(config, allow)
    events = []
    for event in state.get('events', []):
        safe = {key: event[key] for key in ('id', 'key', 'title', 'detail', 'severity', 'status', 'opened_at', 'last_seen_at', 'recovered_at') if key in event}
        states = event.get('notifications', {}).get(event['status'], {})
        safe['notifications'] = {name: {k: value[k] for k in ('state', 'attempted_at', 'attempts') if k in value} for name, value in states.items()}
        events.append(safe)
    return {'schema_version': 1, 'checked_at': timestamp(now), 'mode': 'external_enabled' if channels else 'dashboard_only',
            'channels': list(channels), 'active_count': sum(e['status'] == 'active' for e in events),
            'unknown_count': sum(c['fault'] is None for c in checks),
            'checks': checks, 'events': sorted(events, key=lambda e: e['opened_at'], reverse=True)}


def valid_state(value):
    events = value.get('events')
    if not isinstance(events, list):
        return False
    for event in events:
        if not isinstance(event, dict) or any(not isinstance(event.get(k), str) for k in
                ('id', 'key', 'status', 'title', 'detail', 'severity', 'opened_at', 'last_seen_at')):
            return False
        if event['status'] not in ('active', 'recovered') or not isinstance(event.get('notifications', {}), dict):
            return False
        for phase, channels in event.get('notifications', {}).items():
            if phase not in ('active', 'recovered') or not isinstance(channels, dict):
                return False
            for name, delivery in channels.items():
                if name not in ('webhook', 'smtp') or not isinstance(delivery, dict):
                    return False
                if delivery.get('state') not in ('accepted', 'failed') or not isinstance(delivery.get('attempted_at_epoch'), (int, float)) or not isinstance(delivery.get('attempts'), int):
                    return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', default='/etc/bojiclub/operations-alerts.json')
    parser.add_argument('--state-dir', default='/var/lib/bojiclub-operations-alerts')
    parser.add_argument('--output', default='/opt/bojiclub-account/runtime/operations-alerts.json')
    parser.add_argument('--allow-notifications', action='store_true')
    args = parser.parse_args()
    try:
        config_error = False
        try:
            config = load_config(args.config)
        except (OSError, ValueError, TypeError):
            config, config_error = dict(DEFAULTS), True
        folder = Path(args.state_dir)
        folder.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(folder, 0o700)
        with (folder/'collector.lock').open('a') as lock:
            os.chmod(folder/'collector.lock', 0o600)
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return 0
            now = time.time()
            checks = ([check('collector_config', '告警配置无法读取', True, '采集配置格式或权限有误，外部通知已停用；其他检查暂未刷新。', 'critical')]
                      if config_error else collect(config, now)+[check('collector_config', '告警配置无法读取', False, '采集配置可用。')])
            old_state = read_json(folder/'state.json')
            state_lost = (folder/'state.json').exists() and not valid_state(old_state)
            checks.append(check('collector_state', '告警历史状态需核对', state_lost, '历史状态损坏，已重新建立；请核对已有故障和通知记录。', 'critical'))
            if state_lost:
                old_state = {}
            state = reconcile(old_state, checks, config, args.allow_notifications, now)
            # Persist lifecycle before publication so a failed web write does not duplicate sends.
            atomic_json(folder/'state.json', state, 0o600)
            atomic_json(args.output, public_snapshot(state, checks, config, args.allow_notifications, now), 0o644)
        return 1 if config_error else 0
    except (OSError, ValueError, TypeError, KeyError):
        print('告警采集未完成，请检查 root 配置与文件权限。', file=__import__('sys').stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
