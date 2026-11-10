"""F06 manual body-measurement contract (body fat / waist, optional and sourced)."""
import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
import ai_core as core
import automation_core as auto


def report(**extra):
    payload = {'exercises': [], 'meals': []}
    payload.update(extra)
    return {'kind': 'report', 'date': '2026-10-18', 'payload': payload}


class BodyMeasurementContract(unittest.TestCase):
    def test_optional_manual_measurements_are_cleaned_with_source_and_time(self):
        clean = core.validate_request(report(body_fat_percentage=22.5, waist_circumference_cm=74.2,
                                             body_measurement_recorded_at=813999000,
                                             body_measurement_source='manual'))['payload']
        self.assertEqual(clean['body_fat_percentage'], 22.5)
        self.assertEqual(clean['waist_circumference_cm'], 74.2)
        self.assertEqual(clean['body_measurement_source'], 'manual')
        self.assertIn('2026-10-18T', clean['body_measurement_recorded_at'])

    def test_missing_measurements_stay_missing(self):
        clean = core.validate_request(report(), allow_empty_report=True)['payload']
        self.assertNotIn('body_fat_percentage', clean)
        self.assertNotIn('waist_circumference_cm', clean)
        self.assertNotIn('body_measurement_recorded_at', clean)

    def test_invalid_ranges_and_sources_are_rejected(self):
        for extra in ({'body_fat_percentage': 71}, {'body_fat_percentage': -1},
                      {'waist_circumference_cm': 29}, {'waist_circumference_cm': 301},
                      {'body_measurement_source': 'apple-health'},
                      {'body_measurement_recorded_at': 'yesterday'}):
            with self.subTest(extra=extra), self.assertRaises((ValueError, core.AIError)):
                core.validate_request(report(**extra))

    def test_measurement_only_day_is_meaningful_for_automation(self):
        day = {'exercises': [], 'meals': [], 'bodyWeight': {'bodyFatPercentage': 22.5,
               'waistCircumferenceCM': 74.2, 'updatedAt': 813999000, 'source': 'manual'}}
        state = {'days': {'2026-10-18': day}, 'aiJobs': []}
        body = {'owner': 13, 'settings': {'version': 1, 'enabled': True, 'daily': True, 'weekly': False,
                'workout': False, 'partial': True, 'hour': 0, 'zone': 'UTC', 'enabled_at': 1792321200},
                'state': state, 'coverage': {}, 'coverage_current': True, 'known_ids': []}
        jobs = auto.prepare(body, core.validate_request, 1792324800)
        self.assertEqual(len(jobs), 1)
        payload = jobs[0]['request']['payload']
        self.assertEqual(payload['body_fat_percentage'], 22.5)
        self.assertEqual(payload['waist_circumference_cm'], 74.2)
        self.assertEqual(payload['body_measurement_source'], 'manual')


if __name__ == '__main__':
    unittest.main()
