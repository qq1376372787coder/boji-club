"""动作风险标签判定（P0 动作禁忌拦截）。

数据源：同目录 ``exercise-risk-tags.json``（茵茵 33 项；顶层 ``version`` 递增即视为数据更新，
``regions`` 提供部位 → 中文名与匹配 pattern）。本模块只做确定性匹配，不猜测：

1. ``limited_regions(text)``：limitations 自由文本 → 部位集合；未匹配 → 空集合（不拦截）。
2. ``is_avoid(id, regions)``：只有 ``level='avoid'`` 且部位交集非空才为真；
   ``caution`` 永不拦截（只走既有提示链）。
3. ``excluded_for(text)``：prompt 层要剔除的 avoid 动作 ID 列表（空文本 → 空列表）。

已知取舍（茵茵报告 §五）：**否定词不处理**——「无腰伤」仍命中腰部，方向是过度拦截（fail-safe）。
急症词（胸痛、骨折等）仍由 ``fitness_intelligence.safety_triage`` 做整轮拦截，两层不重叠。
"""
from __future__ import annotations

import json
import re
from pathlib import Path

_DATA = json.loads(Path(__file__).with_name('exercise-risk-tags.json').read_text(encoding='utf-8'))

#: 数据版本：测试断言与回滚依据（回滚 = 版本回退或清空 tags）。
VERSION = _DATA.get('version')

_REGIONS = {
    key: re.compile(str(value.get('pattern', '')), re.I)
    for key, value in (_DATA.get('regions') or {}).items()
    if str(value.get('pattern', ''))
}
_TAGS = _DATA.get('tags', []) or []
_BY_ID = {str(tag.get('id')): tag for tag in _TAGS}


def limited_regions(limitations) -> set:
    """limitations 自由文本 → 命中的部位集合；无文本/无命中 → 空集合（不拦截）。"""
    text = str(limitations or '')
    if not text.strip():
        return set()
    return {key for key, pattern in _REGIONS.items() if pattern.search(text)}


def is_avoid(exercise_id, regions) -> bool:
    """仅 avoid 级且部位交集非空时拦截；caution 永不拦截，空部位不拦截。"""
    tag = _BY_ID.get(str(exercise_id or ''))
    if not tag or tag.get('level') != 'avoid':
        return False
    if not regions:
        return False
    return bool(set(tag.get('regions') or []) & set(regions))


def excluded_for(limitations) -> list:
    """prompt 层剔除清单：与 limitations 部位相交的 avoid 动作 ID。"""
    regions = limited_regions(limitations)
    if not regions:
        return []
    return [
        str(tag['id']) for tag in _TAGS
        if tag.get('level') == 'avoid' and set(tag.get('regions') or []) & regions
    ]


def tags() -> list:
    """只读快照，供测试/审计遍历；返回副本，调用方改动不影响模块状态。"""
    return [dict(tag) for tag in _TAGS]
