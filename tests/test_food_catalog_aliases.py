"""Alias-safety regression tests for the food catalogs (P0-1).

「土豆」在台湾用法里指花生，但在本 App 的简体中文语境里指马铃薯。它曾被挂到 13 条
花生条目上（含 油炸花生仁），导致用户搜「土豆」拿到高脂花生营养值。本文件锁定：

1. 任何目录里，「土豆」只能出现在马铃薯条目上；
2. 引擎目录（production + tfda130）里搜「土豆」必须命中马铃薯；
3. 花生条目仍可被「花生」正常检索（回归不许矫枉过正）。
"""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

import nutrition_engine  # noqa: E402

CATALOGS = (
    "backend/food-catalog.json",
    "backend/food-catalog-production.json",
    "backend/food-catalog-tfda130.json",
)
POTATO_NAME = "馬鈴薯|马铃薯|洋芋|potato"
PEANUT_NAME = "花生"


def entries(path: Path) -> list[dict]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    return raw.get("foods", []) if isinstance(raw, dict) else raw


class FoodCatalogAliasTests(unittest.TestCase):
    def test_potato_alias_only_on_potato_entries(self):
        for rel in CATALOGS:
            for entry in entries(ROOT / rel):
                if "土豆" not in (entry.get("aliases") or []):
                    continue
                with self.subTest(catalog=rel, food_id=entry.get("food_id")):
                    self.assertRegex(
                        str(entry.get("name", "")), POTATO_NAME,
                        msg=f"「土豆」挂在非马铃薯条目上：{entry.get('food_id')} {entry.get('name')}",
                    )
                    self.assertNotRegex(
                        str(entry.get("name", "")), PEANUT_NAME,
                        msg=f"「土豆」挂在花生条目上：{entry.get('food_id')} {entry.get('name')}",
                    )

    def test_alias_map_never_maps_potato_to_peanut(self):
        alias_file = ROOT / "backend" / "food-aliases-zh.json"
        if not alias_file.exists():
            self.skipTest("food-aliases-zh.json 不存在")
        by_id = {str(e["food_id"]): e for rel in CATALOGS for e in entries(ROOT / rel)}
        for food_id, aliases in json.loads(alias_file.read_text(encoding="utf-8")).items():
            if "土豆" not in (aliases or []):
                continue
            name = str(by_id.get(str(food_id), {}).get("name", ""))
            with self.subTest(food_id=food_id):
                self.assertRegex(name, POTATO_NAME)
                self.assertNotRegex(name, PEANUT_NAME)

    def test_search_potato_returns_potato_not_peanut(self):
        result = nutrition_engine.search_foods("土豆")
        candidates = result["candidates"]
        self.assertTrue(candidates, "搜「土豆」必须有结果（修复前为空或命中花生）")
        for candidate in candidates:
            self.assertRegex(str(candidate["name"]), POTATO_NAME)
            self.assertNotRegex(str(candidate["name"]), PEANUT_NAME)

    def test_match_food_potato_is_canonical_potato(self):
        entry = nutrition_engine.match_food("土豆")
        self.assertIsNotNone(entry)
        self.assertRegex(str(entry["name"]), POTATO_NAME)
        self.assertEqual(entry["food_id"], "tfda-B0700201")

    def test_peanut_search_still_works(self):
        # 修复只删错挂的别名，不得影响花生自身的检索。
        result = nutrition_engine.search_foods("花生")
        self.assertTrue(result["candidates"])
        self.assertTrue(
            any("花生" in str(c["name"]) for c in result["candidates"]),
            "「花生」检索必须仍命中花生条目",
        )
        self.assertTrue(
            any(str(c["food_id"]) == "tfda-R7101301" for c in result["candidates"]),
            "油炸花生仁必须仍可被「花生」检索到",
        )

    def test_regulated_peanut_alias_set_has_no_potato(self):
        # 13 条历史错挂条目逐个锁定，防止数据回灌。
        by_id = {
            str(e["food_id"]): e
            for e in entries(ROOT / "backend" / "food-catalog-tfda130.json")
        }
        expected = (
            "tfda-R7101301", "tfda-C1700201", "tfda-C1710101", "tfda-R7101201",
            "tfda-R7101101", "tfda-C1705101", "tfda-R7101401", "tfda-C1705201",
            "tfda-C1705301", "tfda-R7101001", "tfda-R7101501", "tfda-C1700101",
            "tfda-C1700301",
        )
        for food_id in expected:
            entry = by_id[food_id]
            with self.subTest(food_id=food_id, name=entry["name"]):
                self.assertIn("花生", entry["name"])
                self.assertNotIn("土豆", entry.get("aliases") or [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
