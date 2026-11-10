"""Exercise the real AI request validator with synthetic, non-personal records."""
import copy
import sys
import tempfile
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from ai_core import AIError, analysis_facts, validate_request, messages_for
from server import JobStore, legacy_health_fingerprint


def sample():
    return {'kind': 'report', 'date': '2026-10-04', 'payload': {
        'exercises': [{'name': '卧推', 'sets': [{'weight': 30, 'reps': 8, 'completed': True}]}],
        'meals': [],
        'health': {'date': '2026-10-04', 'timeZone': 'Asia/Shanghai', 'updatedAt': 812000000,
                   'activeEnergy': {'value': 500, 'source': {'id': 'watch', 'name': 'Watch'}},
                   'workouts': [{'id': 'watch-session', 'name': '力量训练', 'start': 812000000,
                                 'end': 812003600, 'minutes': 60, 'calories': 200,
                                 'source': {'id': 'watch', 'name': 'Watch'},
                                 'activityKind': 'strength', 'averageHeartRate': 120}]},
        'workout_link': {'device_workout_id': 'watch-session', 'confirmed_by_user': True}}}


class PhaseOneAI(unittest.TestCase):
    def test_explicit_link_preserved_without_double_counting(self):
        value = validate_request(sample())['payload']
        self.assertEqual(value['totals']['completed_sets'], 1)
        self.assertEqual(value['totals']['volume_kg'], 240)
        self.assertEqual(value['health']['activeEnergy']['value'], 500)
        self.assertEqual(value['health']['workouts'][0]['calories'], 200)
        self.assertEqual(value['workout_link']['device_workout_id'], 'watch-session')

    def test_missing_heart_rate_is_unknown(self):
        request = sample()
        del request['payload']['health']['workouts'][0]['averageHeartRate']
        value = validate_request(request)['payload']['health']
        self.assertIsNone(value['workouts'][0]['average_heart_rate'])
        self.assertIsNone(value['heartRate'])

    def test_legacy_health_shape_stays_stable_for_existing_report_revisions(self):
        health = validate_request(sample())['payload']['health']
        self.assertEqual(set(health), {'date', 'time_zone', 'observed_at', 'steps',
                                     'activeEnergy', 'heartRate', 'restingHeartRate',
                                     'sleep', 'workouts'})

    def test_shared_body_measurements_reach_ai_with_units_and_sample_time(self):
        request = sample()
        health = request['payload']['health']
        health.update({
            'bodyMass': {'value': 55, 'source': {'id': 'scale', 'name': 'Scale'}, 'recordedAt': 812000000},
            'bodyFatPercentage': {'value': 22.5, 'source': {'id': 'scale', 'name': 'Scale'}, 'recordedAt': 812000000},
            'leanBodyMass': {'value': 42.9, 'source': {'id': 'scale', 'name': 'Scale'}, 'recordedAt': 812000000},
            'height': {'value': 165, 'source': {'id': 'profile', 'name': 'Health'}, 'recordedAt': 812000000},
            'bodyMassIndex': {'value': 20.2, 'source': {'id': 'scale', 'name': 'Scale'}, 'recordedAt': 812000000},
            'waistCircumference': {'value': 70, 'source': {'id': 'tape', 'name': 'Health'}, 'recordedAt': 812000000},
        })
        value = validate_request(request)['payload']['health']
        self.assertEqual(value['bodyMass']['value'], 55)
        self.assertEqual(value['bodyMass']['unit'], 'kg')
        self.assertEqual(value['bodyFatPercentage']['unit'], '%')
        self.assertEqual(value['height']['unit'], 'cm')
        self.assertEqual(value['bodyMassIndex']['unit'], 'kg/m²')
        self.assertTrue(value['waistCircumference']['recorded_at'].startswith('2026-'))

    def test_body_measurement_only_is_a_real_report_input(self):
        request = sample()
        request['payload']['exercises'] = []
        request['payload'].pop('workout_link', None)
        request['payload']['health'] = {
            'date': '2026-10-04', 'timeZone': 'Asia/Shanghai', 'updatedAt': 812000000,
            'bodyMass': {'value': 55, 'source': {'id': 'scale', 'name': 'Scale'}},
            'workouts': [],
        }
        validated = validate_request(request)
        clean = validated['payload']
        self.assertEqual(clean['health']['bodyMass']['value'], 55)
        self.assertEqual(analysis_facts(validated)['有已分享健康数据的日期'], ['2026-10-04'])

    def test_absent_consent_never_links_automatically(self):
        request = sample(); del request['payload']['workout_link']
        self.assertNotIn('workout_link', validate_request(request)['payload'])

    def test_link_requires_shared_health(self):
        request = sample(); request['payload']['health'] = None
        with self.assertRaises(AIError): validate_request(request)

    def test_link_requires_exact_existing_id(self):
        request = sample(); request['payload']['workout_link']['device_workout_id'] = 'missing'
        with self.assertRaises(AIError): validate_request(request)

    def test_link_requires_real_confirmation(self):
        for value in (False, 'true', 1, None):
            request = sample(); request['payload']['workout_link']['confirmed_by_user'] = value
            with self.subTest(value=value), self.assertRaises(AIError): validate_request(request)

    def test_link_requires_completed_app_training(self):
        request = sample(); request['payload']['exercises'][0]['sets'][0]['completed'] = False
        with self.assertRaises(AIError): validate_request(request)

    def test_duplicate_device_id_rejected(self):
        request = sample()
        request['payload']['health']['workouts'] *= 2
        with self.assertRaises(AIError): validate_request(request)

    def test_old_client_workout_without_new_fields_accepted(self):
        request = sample(); del request['payload']['workout_link']
        for key in ('id', 'activityKind', 'averageHeartRate'):
            del request['payload']['health']['workouts'][0][key]
        value = validate_request(request)['payload']['health']['workouts'][0]
        self.assertEqual(value['id'], '')
        self.assertIsNone(value['average_heart_rate'])

    def test_invalid_heart_rate_rejected(self):
        for number in (-1, 351, float('nan'), True):
            request = sample(); request['payload']['health']['workouts'][0]['averageHeartRate'] = number
            with self.subTest(number=number), self.assertRaises(AIError): validate_request(request)

    def test_historical_target_keeps_request_values(self):
        request = sample()
        target = dict(caloriesMin=1800, caloriesMax=2000, proteinMin=90, proteinMax=120,
                      fatMin=40, fatMax=60, meals=3)
        request['payload']['nutritionTarget'] = target
        self.assertEqual(validate_request(request)['payload']['nutritionTarget'], target)

    def test_prompt_explains_link_and_daily_heart_rate_boundary(self):
        messages = messages_for(validate_request(sample()))
        prompt = str(messages)
        self.assertIn('不得重复计算', prompt)
        self.assertIn('不得用全天heartRate替代', prompt)


class LegacyJobCompatibility(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.store = JobStore(Path(self.directory.name) / 'jobs.sqlite3')
        raw = sample()
        del raw['payload']['workout_link']
        self.current = validate_request(raw)
        self.legacy = copy.deepcopy(self.current)
        for workout in self.legacy['payload']['health']['workouts']:
            for key in ('id', 'activity_kind', 'average_heart_rate'):
                del workout[key]

    def test_legacy_pending_job_retry_returns_existing_job(self):
        self.store.create('legacy-pending', self.legacy)
        self.assertEqual(self.store.create('legacy-pending', self.current)['status'], 'queued')

    def test_legacy_finished_job_remains_compatible_after_payload_erasure(self):
        self.store.create('legacy-done', self.legacy)
        self.store.complete('legacy-done', {'summary': 'already finished'}, 'test', 'test')
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT payload FROM jobs').fetchone()[0], '{}')
        self.assertEqual(self.store.create('legacy-done', self.current)['result'], {'summary': 'already finished'})

    def test_changed_original_record_still_conflicts(self):
        self.store.create('legacy-change', self.legacy)
        changed = copy.deepcopy(self.current)
        changed['payload']['health']['activeEnergy']['value'] += 1
        with self.assertRaises(AIError) as error:
            self.store.create('legacy-change', changed)
        self.assertEqual(error.exception.code, 'id_conflict')

    def test_new_confirmed_association_requires_new_job(self):
        self.store.create('legacy-link', self.legacy)
        with self.assertRaises(AIError) as error:
            self.store.create('legacy-link', validate_request(sample()))
        self.assertEqual(error.exception.code, 'id_conflict')

    def test_new_schema_jobs_do_not_ignore_changed_metadata(self):
        self.store.create('new-job', self.current)
        for field, value in [('id', 'other'), ('activity_kind', 'cycling'), ('average_heart_rate', 130)]:
            changed = copy.deepcopy(self.current)
            changed['payload']['health']['workouts'][0][field] = value
            with self.subTest(field=field), self.assertRaises(AIError):
                self.store.create('new-job', changed)

    def test_weekly_fingerprint_only_removes_additive_health_fields(self):
        current = {'kind': 'weekly_review', 'date': '2026-10-04',
                   'payload': {'days': [{'date': '2026-10-04', **self.current['payload']}], 'history': []}}
        old = copy.deepcopy(current)
        old['payload']['days'][0]['health'] = self.legacy['payload']['health']
        from ai_core import fingerprint
        self.assertEqual(legacy_health_fingerprint(current), fingerprint(old))
        current['payload']['days'][0]['meals'] = [{'name': 'changed'}]
        self.assertNotEqual(legacy_health_fingerprint(current), fingerprint(old))


if __name__ == '__main__': unittest.main()
