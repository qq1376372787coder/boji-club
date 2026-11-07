"""Intent Router 最小版（规则四分类）契约测试。

规则顺序承诺：change_proposal > draft_create > query > chat；异常输入一律 chat。
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
import intent_router


class IntentRouterTests(unittest.TestCase):
    def test_change_proposal_wins_over_other_keywords(self):
        # 「把今天的安排挪到明天」同时含"安排"与日期词，必须优先归类为提案意图。
        self.assertEqual(intent_router.classify({'question': '把今天的安排挪到明天可以吗'}),
                         'change_proposal')
        self.assertEqual(intent_router.classify({'question': '深蹲重量改成 60kg'}), 'change_proposal')
        self.assertEqual(intent_router.classify({'question': '帮我把周五的训练提前到周四'}),
                         'change_proposal')

    def test_draft_create_detected(self):
        self.assertEqual(intent_router.classify({'question': '记录体重 72.5'}), 'draft_create')
        self.assertEqual(intent_router.classify({'question': '中午吃了鸡胸肉和米饭'}), 'draft_create')
        self.assertEqual(intent_router.classify({'question': '记一下今天的训练打卡'}), 'draft_create')

    def test_query_detected(self):
        self.assertEqual(intent_router.classify({'question': '今天练什么'}), 'query')
        self.assertEqual(intent_router.classify({'question': '帮我看看近两周的体重趋势'}), 'query')
        self.assertEqual(intent_router.classify({'question': '我这周进度怎么样？'}), 'query')

    def test_chat_fallback(self):
        self.assertEqual(intent_router.classify({'question': '谢谢教练，感觉好多了'}), 'chat')
        self.assertEqual(intent_router.classify({'question': '你好'}), 'chat')
        self.assertEqual(intent_router.classify({'question': '给我讲个笑话'}), 'chat')

    def test_abnormal_input_is_chat(self):
        self.assertEqual(intent_router.classify(None), 'chat')
        self.assertEqual(intent_router.classify({}), 'chat')
        self.assertEqual(intent_router.classify({'question': 42}), 'chat')
        self.assertEqual(intent_router.classify({'question': '   '}), 'chat')
        # 超长输入（客户端上限 1200）不走分类，避免规则在超界文本上误判。
        self.assertEqual(intent_router.classify({'question': '练什么' * 500}), 'chat')

    def test_rules_version_constant(self):
        self.assertEqual(intent_router.RULES_VERSION, 3)

    def test_coach_result_carries_intent(self):
        # clean_result 端到端：intent 出现在结果顶层（向后兼容的新字段）。
        import datetime as dt
        import ai_core
        import coach_core
        today = dt.date.today()

        def day(date):
            # evidence() 需要的最小日载荷；全空 → 无 source，clean_result 允许空引用。
            return {'date': date, 'payload': {'exercises': [], 'meals': [],
                                              'totals': {'completed_sets': 0}}}

        def iso(d):
            return d if isinstance(d, dt.date) else dt.date.fromisoformat(d)

        request = {
            'id': 'test', 'kind': 'coach', 'date': today.isoformat(),
            'payload': {'conversation_id': 'conv', 'question': '今天练什么', 'history': [],
                        'days': [day(today)], 'timeZone': 'Asia/Shanghai'},
        }
        raw = {'kind': 'coach', 'coach': {'answer': '今天安排了推力日：平板杠铃卧推 3 组，每组 10 次。按当前计划完成即可，练后记得在训练页确认保存。',
                                          'source_ids': [], 'actions': []}}
        result = coach_core.clean_result(request, raw, (ai_core.text, ai_core.sequence, ai_core.iso_date))
        self.assertEqual(result['intent']['kind'], 'query')
        self.assertEqual(result['intent']['rules'], 3)
        # kind/coach 原有结构不变（向后兼容）。
        self.assertEqual(result['kind'], 'coach')
        self.assertIn('answer', result['coach'])


if __name__ == '__main__':
    unittest.main()
