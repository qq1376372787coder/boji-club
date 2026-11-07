"""Verify published admin flags are enforced by the real account API.

Excluded from the offline runner (`_http`). Local isolated run:
  BOJI_ADMIN_BASE=http://127.0.0.1:8090 BOJI_TEST_MYSQL=.../mysql python3 -m unittest tests.test_feature_gates_http -v
"""
import hashlib
import json
import os
import subprocess
import unittest
import urllib.error
import urllib.parse
import urllib.request
import uuid

BASE = os.environ.get('BOJI_ADMIN_BASE', 'http://127.0.0.1:8090').rstrip('/')
DB = os.environ.get('BOJI_TEST_DB', 'bojiclub_v2_it')
MYSQL = os.environ.get('BOJI_TEST_MYSQL', '/tmp/boji-tools/mysql-9.4.0-macos15-arm64/bin/mysql')
TOKEN = 'f' * 64


def sql(statement):
    command = [MYSQL, '--protocol=tcp', '-h127.0.0.1', '-P13306', '-uroot', DB, '-N', '-B', '-e', statement]
    result = subprocess.run(command, capture_output=True, text=True, timeout=15)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip()[:300])
    return result.stdout.strip()


def publish(config):
    payload = json.dumps(config, ensure_ascii=False)
    sql("INSERT INTO app_config(config_key,draft_json,published_json,draft_version,published_version,updated_at,published_at) "
        f"VALUES('app','{payload}','{payload}',100,100,UTC_TIMESTAMP(),UTC_TIMESTAMP()) "
        "ON DUPLICATE KEY UPDATE draft_json=VALUES(draft_json),published_json=VALUES(published_json),"
        "draft_version=VALUES(draft_version),published_version=VALUES(published_version),published_at=UTC_TIMESTAMP()")


def defaults(ai=True, club=True):
    return {'ai_enabled': ai, 'club_enabled': club, 'minimum_build': 0, 'latest_build': 0,
            'announcement': {'enabled': False, 'title': '', 'body': ''}}


class FeatureGates(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            urllib.request.urlopen(BASE + '/account/v1/config', timeout=5)
        except Exception as error:
            raise unittest.SkipTest(f'local API not available: {error}')
        token_hash = hashlib.sha256(TOKEN.encode()).hexdigest()
        sql("DELETE FROM sessions WHERE token_hash='" + token_hash + "'")
        sql("INSERT INTO users(phone,apple_subject,status,created_at,updated_at) VALUES('18800000999',NULL,'active',UTC_TIMESTAMP(),UTC_TIMESTAMP()) "
            "ON DUPLICATE KEY UPDATE status='active'")
        uid = sql("SELECT id FROM users WHERE phone='18800000999' LIMIT 1")
        cls.user_id = int(uid)
        sql("INSERT INTO sessions(user_id,token_hash,created_at,last_used_at,expires_at) VALUES("
            f"{cls.user_id},'{token_hash}',UTC_TIMESTAMP(),UTC_TIMESTAMP(),DATE_ADD(UTC_TIMESTAMP(),INTERVAL 1 DAY))")

    @classmethod
    def tearDownClass(cls):
        sql("DELETE FROM app_config")
        sql("DELETE FROM app_config_versions")
        sql("INSERT INTO app_config(config_key,draft_json,published_json,draft_version,published_version,updated_at,published_at) "
            f"VALUES('app','{json.dumps(defaults(), ensure_ascii=False)}','{json.dumps(defaults(), ensure_ascii=False)}',1,1,UTC_TIMESTAMP(),UTC_TIMESTAMP())")
        sql("INSERT INTO app_config_versions(config_key,version,value_json,action,note,created_at) "
            f"VALUES('app',1,'{json.dumps(defaults(), ensure_ascii=False)}','publish','test cleanup',UTC_TIMESTAMP())")
        sql("DELETE FROM sessions WHERE token_hash='" + hashlib.sha256(TOKEN.encode()).hexdigest() + "'")
        sql("DELETE FROM users WHERE phone='18800000999'")

    def request(self, method, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(BASE + '/account/v1' + path, data=data, method=method,
                                         headers={'Authorization': 'Bearer ' + TOKEN,
                                                  'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                value = json.loads(raw)
            except Exception:
                value = {'raw': raw.decode('utf-8', 'replace')}
            return error.code, value

    def test_admin_flags_block_server_routes(self):
        publish(defaults(ai=False, club=True))
        job = {'id': str(uuid.uuid4()), 'kind': 'food', 'date': '2026-10-20',
               'payload': {'source': 'text', 'description': '两个鸡蛋', 'meal_category': '早餐'}}
        status, value = self.request('POST', '/me/ai/jobs', job)
        self.assertEqual(status, 503)
        self.assertIn('暂未开放', value.get('error', ''))

        status, value = self.request('GET', '/club/current')
        self.assertEqual(status, 200)

        publish(defaults(ai=True, club=False))
        status, value = self.request('GET', '/club/current')
        self.assertEqual(status, 503)
        self.assertIn('暂未开放', value.get('error', ''))

        # With the AI flag on, the same request must reach the AI service check,
        # proving the gate is the flag and not a blanket rejection.
        publish(defaults(ai=True, club=True))
        status, value = self.request('POST', '/me/ai/jobs', job)
        self.assertEqual(status, 503)
        self.assertNotIn('暂未开放', value.get('error', ''))


if __name__ == '__main__':
    unittest.main(verbosity=2)
