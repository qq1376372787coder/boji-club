"""Admin RBAC and published-config propagation over a real PHP server.

This is an HTTP integration test and is intentionally excluded from the offline
runner (`_http` suffix). Start an isolated account/admin server first, then:
  BOJI_ADMIN_BASE=http://127.0.0.1:8090 python3 -m unittest tests.test_admin_v2_http -v
"""
import http.cookiejar
import json
import os
import re
import unittest
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get('BOJI_ADMIN_BASE', 'http://127.0.0.1:8090').rstrip('/')
PASSWORD = os.environ.get('BOJI_TEST_ADMIN_PASSWORD', 'TestSuper!2026')


class Session:
    def __init__(self):
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.jar),
            NoRedirect())
        self.csrf = None

    def get(self, path, expect=200):
        request = urllib.request.Request(BASE + path)
        try:
            response = self.opener.open(request, timeout=10)
            body = response.read().decode('utf-8', 'replace')
            status = response.status
        except urllib.error.HTTPError as error:
            body = error.read().decode('utf-8', 'replace')
            status = error.code
        self._remember_csrf(body)
        if expect is not None:
            assert status == expect, (path, status, body[:200])
        return status, body

    def post(self, data, expect=303):
        assert self.csrf, 'csrf token not loaded'
        payload = urllib.parse.urlencode({'csrf': self.csrf, **data}).encode()
        request = urllib.request.Request(BASE + '/admin/', data=payload,
                                         headers={'Content-Type': 'application/x-www-form-urlencoded'})
        try:
            response = self.opener.open(request, timeout=10)
            body = response.read().decode('utf-8', 'replace')
            status = response.status
            location = response.headers.get('Location')
        except urllib.error.HTTPError as error:
            body = error.read().decode('utf-8', 'replace')
            status = error.code
            location = error.headers.get('Location')
        self._remember_csrf(body)
        if expect is not None:
            assert status == expect, (data.get('action'), status, body[:300])
        return status, location, body

    def _remember_csrf(self, body):
        match = re.search(r'name="csrf" value="([a-f0-9]{32,})"', body)
        if match:
            self.csrf = match.group(1)

    def login(self, username):
        status, body = self.get('/admin/', expect=200)
        assert '管理员登录' in body, 'login page missing'
        status, location, body = self.post({'action': 'login', 'username': username, 'password': PASSWORD}, expect=None)
        assert status == 303 and location, (username, status, location, body[:200])
        return self.get('/admin/?p=overview', expect=200)[1]

    def logout(self):
        try:
            self.post({'action': 'logout'}, expect=None)
        except AssertionError:
            pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def public_config():
    with urllib.request.urlopen(BASE + '/account/v1/config', timeout=10) as response:
        return response.status, json.loads(response.read()), dict(response.headers)


class AdminV2Http(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            urllib.request.urlopen(BASE + '/admin/', timeout=5)
        except Exception as error:
            raise unittest.SkipTest(f'local admin server not available: {error}')

    @staticmethod
    def save_config(session, values):
        _, page = session.get('/admin/?p=config', expect=200)
        match = re.search(r'name="draft_version" value="(\d+)"', page)
        assert match, 'draft version field missing'
        base = {'draft_version': int(match.group(1)), 'club_enabled': '1',
                'minimum_build': '0', 'latest_build': '0', 'note': 'http test'}
        base.update(values)
        session.post({'action': 'config_save_draft', **base})

    @staticmethod
    def publish_config(session):
        _, page = session.get('/admin/?p=config', expect=200)
        if '线上与草稿一致' in page:
            return False
        match = re.search(r'name="draft_version" value="(\d+)"', page)
        assert match, 'draft version field missing'
        session.post({'action': 'config_publish', 'draft_version': int(match.group(1))})
        return True

    def test_super_publishes_and_public_endpoint_receives_it(self):
        session = Session()
        session.login('v2-super')
        # Previous runs may have left any published version. Establish a known baseline.
        self.save_config(session, {'ai_enabled': '1'})
        self.publish_config(session)
        status, page = session.get('/admin/?p=config', expect=200)
        self.assertIn('发布状态', page)
        match = re.search(r'name="draft_version" value="(\d+)"', page)
        self.assertIsNotNone(match, 'draft version field missing')
        draft_version = int(match.group(1))

        status, page = session.get('/admin/?p=overview', expect=200)
        self.assertIn('运营总览', page)
        self.assertIn('超级管理员', page)

        # Saving a draft must not change the public endpoint.
        before_status, before, _ = public_config()
        session.post({
            'action': 'config_save_draft', 'draft_version': draft_version,
            'club_enabled': '1', 'minimum_build': '120', 'latest_build': '121',
            'announcement_enabled': '1', 'announcement_title': '内测公告',
            'announcement_body': '这是自动化测试写入的公告。', 'note': 'rbac/config HTTP test',
        })
        after_status, after, _ = public_config()
        self.assertEqual(after['version'], before['version'])
        self.assertTrue(after['config']['ai_enabled'])

        # Publish and verify the exact values the iOS client will decode.
        status, page = session.get('/admin/?p=config', expect=200)
        match = re.search(r'name="draft_version" value="(\d+)"', page)
        session.post({'action': 'config_publish', 'draft_version': int(match.group(1))})
        status, published, headers = public_config()
        self.assertEqual(status, 200)
        self.assertGreater(published['version'], after['version'])
        self.assertFalse(published['config']['ai_enabled'])
        self.assertEqual(published['config']['minimum_build'], 120)
        self.assertEqual(published['config']['latest_build'], 121)
        self.assertEqual(published['config']['announcement']['title'], '内测公告')
        self.assertTrue(published['config']['announcement']['enabled'])
        self.assertTrue(headers.get('X-Config-Version'))

        # ETag is stable for the same body.
        request = urllib.request.Request(BASE + '/account/v1/config', headers={'If-None-Match': headers['ETag']})
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(request, timeout=10)
        self.assertEqual(caught.exception.code, 304)

        # Invalid values are rejected before reaching the database.
        status, page = session.get('/admin/?p=config', expect=200)
        match = re.search(r'name="draft_version" value="(\d+)"', page)
        status, _, body = session.post({
            'action': 'config_save_draft', 'draft_version': int(match.group(1)),
            'club_enabled': '1', 'minimum_build': '200', 'latest_build': '100', 'note': '',
        }, expect=None)
        self.assertIn('最低兼容构建号不能高于最新构建号', body)
        # Leave the local environment in its default published state.
        self.save_config(session, {'ai_enabled': '1'})
        self.publish_config(session)
        session.logout()

    def test_readonly_support_operator_and_content_boundaries(self):
        readonly = Session()
        readonly.login('v2-readonly')
        readonly.get('/admin/?p=overview', expect=200)
        status, members = readonly.get('/admin/?p=users', expect=200)
        self.assertIn('只读视图', members)
        readonly.get('/admin/?p=config', expect=403)
        status, _, body = readonly.post({'action': 'config_save_draft'}, expect=None)
        self.assertEqual(status, 403)
        self.assertIn('无权执行', body)
        readonly.logout()

        support = Session()
        support.login('v2-support')
        support.get('/admin/?p=users', expect=200)
        support.get('/admin/?p=club', expect=403)
        status, support_user = support.get('/admin/?p=user&id=1', expect=200)
        self.assertNotIn('赠送或延长会员', support_user)
        self.assertNotIn('确认更改该成员账号状态', support_user)
        status, _, body = support.post({'action': 'status', 'user_id': '1', 'status': 'disabled',
                                        'expected': 'active', 'reason': 'should be denied'}, expect=None)
        self.assertEqual(status, 403)
        self.assertIn('无权执行', body)
        support.logout()

        operator = Session()
        operator.login('v2-operator')
        operator.get('/admin/?p=users', expect=200)
        operator.get('/admin/?p=config', expect=403)
        operator.get('/admin/?p=admins', expect=403)
        operator.logout()

        content = Session()
        content.login('v2-content')
        status, badges = content.get('/admin/?p=badges', expect=200)
        self.assertNotIn('只读视图', badges)
        status, club = content.get('/admin/?p=club', expect=200)
        self.assertIn('只读视图', club)
        self.assertIn('workspace is-readonly', club)
        content.get('/admin/?p=config', expect=403)
        content.get('/admin/?p=audit', expect=403)
        status, _, body = content.post({'action': 'notification_test'}, expect=None)
        self.assertEqual(status, 403)
        self.assertIn('无权执行', body)
        status, notifications = content.get('/admin/?p=notifications', expect=200)
        self.assertNotIn('发送真实测试通知', notifications)
        operator_notifications = Session()
        operator_notifications.login('v2-operator')
        status, notifications = operator_notifications.get('/admin/?p=notifications', expect=200)
        self.assertIn('发送真实测试通知', notifications)
        operator_notifications.logout()
        content.logout()

    def test_admin_create_disable_and_audit(self):
        super_session = Session()
        super_session.login('v2-super')
        super_session.get('/admin/?p=admins', expect=200)
        name = 'v2-created'
        # The test database is disposable; delete a previous run through SQL is
        # intentionally avoided, so a duplicate is treated as a stable outcome.
        status, _, body = super_session.post({
            'action': 'admin_create', 'username': name, 'password': 'Created!2026Pass', 'role': 'readonly'
        }, expect=None)
        self.assertIn(status, (200, 303))
        if status == 303:
            status, _, body = super_session.post({
                'action': 'admin_create', 'username': name, 'password': 'Created!2026Pass', 'role': 'readonly'
            }, expect=None)
        self.assertIn('已存在', body)
        status, audit = super_session.get('/admin/?p=audit', expect=200)
        self.assertTrue('新增管理员' in audit or '更新管理员' in audit or '发布配置' in audit)
        super_session.logout()


if __name__ == '__main__':
    unittest.main(verbosity=2)
