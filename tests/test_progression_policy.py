"""统一渐进策略 progression.policy.v1 的一致性回归（夜间实施令 4/9）。

锁三件事：
1. 上限函数本身的口径表与不变量（min(2.5,5%) + 10% 硬顶 + 0.5kg 粒度）；
2. **两个入口对同一重量结论一致**——5kg（都不加重）与 20kg（都只准 +1.0kg），
   这正是评估报告 P1-4 的原始冲突场景；
3. 周复盘 120% 容量护栏**未被本次改动波及**（16 组放行、18 组拦截，边界即 1.2）。
"""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'backend'))
sys.path.insert(0, str(ROOT / 'tests'))

import adaptive_core
import fitness_intelligence as fi
from test_backend_offline import weekly_request, weekly_result


def evidenced(before, library_id='lib-0001', per_session=3, target_reps=10):
    """构造 supported_increase 返回 True 所需的全部证据（2 个不同日期的确认场次）。

    只有证据齐备，才能把"拒绝"归因于加重上限而不是缺证据。
    """
    dates = ['2026-11-01', '2026-11-04']
    days = []
    for day in dates:
        session_id = 'session-' + day
        exercise_id = 'exercise-1'
        baseline = [{'id': f'{day}-{i}', 'unit': 'reps',
                     'targetWeight': before, 'targetReps': target_reps} for i in range(per_session)]
        actual = [{'id': f'{day}-{i}', 'completed': True, 'weight': before,
                   'reps': target_reps} for i in range(per_session)]
        days.append({'date': day, 'payload': {
            'workout_sessions': [{'id': session_id, 'confirmed': True,
                                  'executionBaseline': {'sets': [{**row, 'exerciseID': exercise_id}
                                                                 for row in baseline]}}],
            'exercises': [{'library_id': library_id, 'session_id': session_id,
                           'exercise_id': exercise_id, 'sets': actual}],
        }})
    movement = {'library_id': library_id,
                'sets': [{'weight': before, 'reps': target_reps}] * per_session}
    return {'days': days}, movement


def advisory_sets(weight, reps, sessions=2, per_session=3):
    """构造 progression_advisory 可比证据：两场同器械、同工作负重、每组超过目标次数。"""
    rows = []
    for index in range(sessions):
        for i in range(per_session):
            rows.append({'id': f's{index}-{i}', 'session_id': f'session-{index}',
                         'completed': True, 'weight': weight, 'reps': reps})
    return rows


def variant(recording_unit='reps'):
    return fi.ExerciseVariant(variant_id='lib-0001', canonical_id='canon:squat',
                              name_zh='深蹲', name_en='Squat', equipment_zh='杠铃',
                              weight_basis='barbell', recording_unit=recording_unit,
                              source_id='exercise-catalog:lib-0001')


class MaxLoadIncreaseTests(unittest.TestCase):
    """上限函数：口径表 + 不变量。"""

    def test_policy_version_is_declared(self):
        self.assertEqual(fi.PROGRESSION_POLICY_VERSION, 'progression.policy.v1')

    def test_expected_table(self):
        # (当前重量 kg, 期望上限 kg)。小重量被 0.5kg 粒度压到 0 是**有意行为**：
        # 两入口此时都必须回答"不加重"，改走次数进阶。
        table = [(3, 0.0), (5, 0.0), (8, 0.0), (9, 0.0),
                 (10, 0.5), (12, 0.5), (20, 1.0), (40, 2.0),
                 (50, 2.5), (100, 2.5), (200, 2.5)]
        for current, expected in table:
            with self.subTest(current=current):
                self.assertEqual(fi.max_load_increase(current), expected)

    def test_invariants_across_sweep(self):
        for step in range(1, 4001):
            current = step / 10.0  # 0.1kg .. 400kg
            delta = fi.max_load_increase(current)
            self.assertGreaterEqual(delta, 0.0, current)
            self.assertLessEqual(delta, 2.5 + 1e-9, current)          # 绝对封顶
            self.assertLessEqual(delta, current * 0.05 + 1e-9, current)  # 5% 取小
            self.assertLessEqual(delta, current * 0.10 + 1e-9, current)  # 10% 硬顶
            self.assertEqual(round(delta / 0.5, 6) % 1, 0.0, current)     # 0.5kg 粒度

    def test_non_positive_and_garbage_input(self):
        for bad in (0, -1, None, 'x', float('nan'), float('inf')):
            with self.subTest(bad=bad):
                self.assertEqual(fi.max_load_increase(bad), 0.0)

    def test_is_monotonic_never_decreases_with_weight(self):
        previous = -1.0
        for step in range(1, 2001):
            current = step / 2.0
            delta = fi.max_load_increase(current)
            self.assertGreaterEqual(delta, previous, current)
            previous = delta


class TwoEntriesAgreeTests(unittest.TestCase):
    """评估报告 P1-4 的原始冲突场景：两个入口必须给同一结论。"""

    def test_small_weight_5kg_both_say_no(self):
        payload, movement = evidenced(5.0)
        # 证据齐备时"不加重"本身是允许的 → 证明下面的拒绝来自上限而非缺证据
        self.assertTrue(adaptive_core.supported_increase(payload, movement, 5.0, 5.0))
        # 统一前 adaptive 允许 5→7.5（+50%），现在必须拒绝
        self.assertFalse(adaptive_core.supported_increase(payload, movement, 7.5, 5.0))
        self.assertFalse(adaptive_core.supported_increase(payload, movement, 5.5, 5.0))
        # 另一入口同样回答"不加重"
        advice = fi.progression_advisory(variant(), advisory_sets(5.0, 9),
                                         target_reps=8, effort_acceptable=True)
        self.assertEqual(advice['decision'], 'HOLD_CURRENT_LOAD')
        self.assertFalse(advice['auto_apply'])

    def test_mid_weight_20kg_both_say_plus_one_kilo(self):
        payload, movement = evidenced(20.0)
        # 上限 = min(2.5, 5%) = 1.0kg → 21.0 放行、21.5 拒绝
        self.assertTrue(adaptive_core.supported_increase(payload, movement, 21.0, 20.0))
        self.assertFalse(adaptive_core.supported_increase(payload, movement, 21.5, 20.0))
        self.assertFalse(adaptive_core.supported_increase(payload, movement, 22.5, 20.0))
        advice = fi.progression_advisory(variant(), advisory_sets(20.0, 9),
                                         target_reps=8, effort_acceptable=True)
        self.assertEqual(advice['decision'], 'MAY_SUGGEST_SMALL_PROGRESSION')
        self.assertEqual(advice['suggested_increment_kg'], 1.0)
        # 两入口给出的可执行重量一致
        self.assertEqual(20.0 + advice['suggested_increment_kg'], 21.0)

    def test_heavy_weight_100kg_absolute_cap_wins(self):
        payload, movement = evidenced(100.0)
        # 统一前 adaptive 允许到 105（5%），现被 2.5kg 绝对封顶压回 102.5
        self.assertTrue(adaptive_core.supported_increase(payload, movement, 102.5, 100.0))
        self.assertFalse(adaptive_core.supported_increase(payload, movement, 105.0, 100.0))
        advice = fi.progression_advisory(variant(), advisory_sets(100.0, 9),
                                         target_reps=8, effort_acceptable=True)
        self.assertEqual(advice['decision'], 'MAY_SUGGEST_SMALL_PROGRESSION')
        self.assertEqual(advice['suggested_increment_kg'], 2.5)

    def test_never_exceeds_ten_percent_on_any_weight(self):
        """扫一遍：任何重量下两个入口都不允许超过 10%（原 adaptive 在 5kg 处是 50%）。"""
        for step in range(2, 4002):
            current = step / 2.0
            payload, movement = evidenced(current)
            cap = fi.max_load_increase(current)
            if cap <= 0:
                continue
            self.assertFalse(
                adaptive_core.supported_increase(payload, movement,
                                                 current + current * 0.10 + 0.5, current),
                f'{current}kg 允许了超过 10% 的增量')
            self.assertLessEqual((current + cap) / current - 1.0, 0.10 + 1e-9)


class WeeklyCapUnchangedTests(unittest.TestCase):
    """周复盘 120% 容量护栏不属于本次改动，必须保持原边界。"""

    def _run(self, exercises_per_session, sets_per_session):
        result = weekly_result()
        sessions = []
        for date in ('2026-09-28', '2026-09-30'):
            sessions.append({'date': date, 'label': '适当安排',
                             'exercises': [{'library_query': 'barbell squat', 'name': '深蹲',
                                            'muscle': '腿部',
                                            'sets': [{'weight': None, 'reps': 10}] * sets_per_session}
                                           for _ in range(exercises_per_session)]})
        result['decision'] = 'adjust'
        result['sessions'] = sessions
        import ai_core
        clean = ai_core.validate_request(weekly_request())
        return ai_core.validate_result(clean, result)

    def test_under_threshold_still_allows_adjust(self):
        # 2 场 × 4 动作 × 2 组 = 16 组；历史 14 组 × 1.2 = 16.8 → 未超，保持 adjust
        output = self._run(exercises_per_session=4, sets_per_session=2)
        self.assertEqual(output['decision'], 'adjust')
        self.assertEqual(len(output['sessions']), 2)

    def test_over_threshold_blocks_adjust(self):
        # 2 场 × 3 动作 × 3 组 = 18 组 > 16.8 → 必须回落 insufficient 且清空 sessions
        output = self._run(exercises_per_session=3, sets_per_session=3)
        self.assertEqual(output['decision'], 'insufficient')
        self.assertEqual(output['sessions'], [])
        self.assertIn('小幅调整范围', output['reason'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
