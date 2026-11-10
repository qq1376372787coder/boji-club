#!/usr/bin/env python3
"""校验协议种子文件完整性：语言覆盖、front matter、标题结构、占位符。"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
SEED = BASE / "seed"
LANGS = ["zh-CN", "zh-TW", "en", "ja", "ko", "th", "vi", "id", "ms"]
DOCS = ["terms", "privacy", "purchase", "deletion", "ai-notice", "health-disclaimer", "about", "faq", "changelog"]
SHORT_DOCS = ["about", "faq", "changelog"]
REQUIRED_META = ["title", "description", "version", "effective", "updated"]
PLACEHOLDERS = ["{{site_name}}", "{{operator_name}}", "{{contact_email}}"]
HOME_KEYS = ["hero_title", "hero_sub", "features", "shots", "cta_title"]
HOME_FEATURES = 6
HOME_SHOTS = 4


def parse_fm(text: str):
    meta = {}
    if text.startswith("---"):
        head = text.split("\n---", 2)[0][3:].strip()
        for line in head.splitlines():
            if ":" in line:
                k, _, v = line.partition(":")
                meta[k.strip()] = v.strip()
    return meta


def headings(text: str):
    return [re.sub(r"\s+", "", m.group(1)).lower() for m in re.finditer(r"^##\s+(.+)$", text, flags=re.M)]


def main() -> int:
    base = {}
    errors: list[str] = []
    warnings: list[str] = []

    for doc in DOCS:
        p = SEED / "zh-CN" / f"{doc}.md"
        if not p.exists():
            errors.append(f"缺少母本 zh-CN/{doc}.md")
            continue
        text = p.read_text(encoding="utf-8")
        base[doc] = {"headings": headings(text), "ph": {ph: text.count(ph) for ph in PLACEHOLDERS}}

    total_files = 0
    home_errors = 0
    for lang in LANGS:
        hp = SEED / lang / "home.json"
        if not hp.exists():
            errors.append(f"缺少文件 {lang}/home.json")
            home_errors += 1
        else:
            total_files += 1
            try:
                h = json.loads(hp.read_text(encoding="utf-8"))
                for k in HOME_KEYS:
                    if k not in h:
                        errors.append(f"{lang}/home.json 缺少键 {k}")
                if len(h.get("features", [])) != HOME_FEATURES:
                    errors.append(f"{lang}/home.json features 数量应为 {HOME_FEATURES}")
                if len(h.get("shots", [])) != HOME_SHOTS:
                    errors.append(f"{lang}/home.json shots 数量应为 {HOME_SHOTS}")
                for s in h.get("shots", []):
                    if not (BASE / "assets" / "screenshots" / s.get("file", "")).exists():
                        errors.append(f"{lang}/home.json 引用的截图 {s.get('file')} 不存在")
            except Exception as e:
                errors.append(f"{lang}/home.json 不是有效 JSON：{e}")
        for doc in DOCS:
            p = SEED / lang / f"{doc}.md"
            if not p.exists():
                errors.append(f"缺少文件 {lang}/{doc}.md")
                continue
            total_files += 1
            text = p.read_text(encoding="utf-8")
            meta = parse_fm(text)
            for k in REQUIRED_META:
                if not meta.get(k):
                    errors.append(f"{lang}/{doc}.md 缺少 front matter 字段 {k}")
            body = text.split("\n---", 2)[-1] if text.startswith("---") else text
            if len(body.strip()) < 800 and doc not in SHORT_DOCS:
                warnings.append(f"{lang}/{doc}.md 正文偏短（{len(body.strip())} 字符），可能未完整翻译")
            if lang != "zh-CN":
                want = base[doc]["headings"]
                got = headings(text)
                if len(got) != len(want):
                    errors.append(f"{lang}/{doc}.md ## 标题数不一致：应为 {len(want)}，实际 {len(got)}")
                # {{site_name}} 与 {{site_name_en}} 视为等价占位符（品牌名按语言渲染）
                want_n = base[doc]["ph"]["{{site_name}}"]
                got_n = text.count("{{site_name}}") + text.count("{{site_name_en}}")
                if got_n != want_n:
                    errors.append(f"{lang}/{doc}.md 品牌占位符数量不一致：应为 {want_n}，实际 {got_n}")
                for ph in ["{{operator_name}}", "{{contact_email}}"]:
                    if text.count(ph) != base[doc]["ph"][ph]:
                        errors.append(f"{lang}/{doc}.md 占位符 {ph} 数量不一致：应为 {base[doc]['ph'][ph]}，实际 {text.count(ph)}")
            if "{{contact_phone}}" in text:
                errors.append(f"{lang}/{doc}.md 含已废弃的 phone 占位符")
            for bad in ["TODO", "XXX", "lorem"]:
                if bad in text:
                    warnings.append(f"{lang}/{doc}.md 含可疑字符串 {bad}")

    print(f"文件总数：{total_files} / {len(LANGS) * (len(DOCS) + 1)}")
    for w in warnings:
        print(f"  [警告] {w}")
    for e in errors:
        print(f"  [错误] {e}")
    if errors:
        print("结果：未通过")
        return 1
    print("结果：全部通过 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
