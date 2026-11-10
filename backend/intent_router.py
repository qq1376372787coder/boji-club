"""Phase 2 §2.3 最小意图路由：规则四分类（先规则后模型）。

分类只作为 job 结果上的新增只读字段（intent），供后续批次做上下文按意图拉取与
Phase 3 提案路由；不改变现有链路行为。规则刻意保守：意图词重叠时取承诺更强的
分类（change_proposal > question-query > draft_create > query > chat），拿不准一律 chat——
错误地降级为 chat 只是少优化，错误地升级会误触发写入/提案语义。

Golden evals found three real ambiguities, fixed here:
- “昨天吃了多少热量” is a query, not a new record.
- “我什么时候可以加重量” is advice, not a plan change.
- “今天有点累 / 今天心情不好” is chat, not today's-plan query.
"""

import re

_CHANGE = re.compile(
    r'(改成|改为|换成|换到|挪到|挪一下|移动到|移到|搬到|搬至|推迟|提前|推后|延后|减轻|'
    r'改到|排到|安排到|换个时间|调整.{0,6}(?:安排|计划|日程)|'
    r'(?:重量|负荷).{0,6}(?:加到|调到|降到|减到|增加到|减少到|调整到|调高|调低)|'
    r'(?:加|减)重量.{0,6}(?:\d|kg|公斤)|'
    r'reschedule|move )')
# Imperative record commands only. A noun such as “身体记录” is not one.
_RECORD_COMMAND = re.compile(
    r'(记录一下|记录一笔|记录(?:早餐|午餐|晚餐|加餐|饮食|体重|今天)|记一下|记一笔|打卡|称了|称重|'
    r'帮我记|接着记|加上今天|日志里加|log |add )')
_RECORD_FACT = re.compile(r'(吃了|喝了|点了|加了|用了|刚称|体重.{0,3}\d)')
_MEAL_FACT = re.compile(r'(早餐|午餐|晚餐|加餐).{0,10}(吃|两|三|一|半|个|碗|杯|份|根|片)')
_CASUAL = re.compile(
    r'(你觉得|适合我|适合健身|陪我|聊会|聊会儿|重要吗|压力|心情|焦虑|放弃|鼓励|晚安|谢谢|你好|笑话)')
_STRONG = re.compile(r'(练什么|训练|计划|体重|饮食|热量|几组|多少|进度|安排|恢复|身体|记录)')
_QUESTION = re.compile(r'(多少|几组|几次|怎么样|如何|为什么|什么时候|何时|吗[？?]?|？|\?)')
_LOOK = re.compile(r'(看看|看一下|查一下|回顾|复盘|总结|进度|趋势)')
_QUERY = re.compile(
    r'(练什么|练哪些|怎么练|进度|几组|多少|怎么样|趋势|总结|复盘|看看|查一下|回顾|什么时候|'
    r'还差|为什么|\?|？|(?:今天|明天|昨天|本周|这周|上周).{0,8}(?:练|安排|计划|进度|吃|训练|复盘|怎么样))')

RULES_VERSION = 3


def classify(payload: object) -> str:
    """返回 chat | query | draft_create | change_proposal。任何异常输入返回 chat。"""
    if not isinstance(payload, dict):
        return 'chat'
    question = payload.get('question')
    text = question.strip() if isinstance(question, str) else ''
    if not text or len(text) > 1200:
        return 'chat'
    if _CHANGE.search(text):
        return 'change_proposal'
    if _RECORD_COMMAND.search(text):
        return 'draft_create'
    # Casual questions (“你觉得我适合健身吗”) are conversation, not data
    # queries. A concrete data term still wins (“你觉得我该练什么”).
    if _CASUAL.search(text) and not _LOOK.search(text) and not _STRONG.search(text):
        return 'chat'
    # A real question about past facts wins over a report-style verb.
    if _QUESTION.search(text) or _LOOK.search(text):
        return 'query'
    if _RECORD_FACT.search(text) or _MEAL_FACT.search(text):
        return 'draft_create'
    if _QUERY.search(text):
        return 'query'
    return 'chat'
