#!/usr/bin/env python3
"""Static PHP syntax check using tree-sitter (no PHP runtime required).

This verifies that each file parses without ERROR/MISSING nodes. It does NOT
execute PHP and is not a substitute for integration tests. Exit code 0 means
syntax-only pass.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

try:
    import tree_sitter
    import tree_sitter_php
except ImportError:
    print("tree-sitter-php is required: pip3 install --user tree_sitter tree_sitter_php", file=sys.stderr)
    raise SystemExit(2)


def make_parser():
    language = tree_sitter.Language(tree_sitter_php.language_php())
    parser = tree_sitter.Parser()
    if hasattr(parser, "set_language"):
        parser.set_language(language)
    else:  # tree-sitter >= 0.22
        parser = tree_sitter.Parser(language)
    return parser


def walk_errors(node, errors, source):
    if node.type in ("ERROR", "MISSING"):
        row, col = node.start_point
        line = source.splitlines()[row][:160] if source.splitlines() else ""
        errors.append({"type": node.type, "line": row + 1, "column": col + 1, "text": line})
    for child in node.children:
        walk_errors(child, errors, source)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--json", dest="json_path")
    args = ap.parse_args()
    parser = make_parser()
    files = []
    for path in args.paths:
        if os.path.isdir(path):
            for root, _, names in os.walk(path):
                files.extend(os.path.join(root, n) for n in names if n.endswith(".php"))
        elif path.endswith(".php"):
            files.append(path)
    results = []
    failed = 0
    for path in sorted(set(files)):
        raw = open(path, "rb").read()
        source = raw.decode("utf-8", "replace")
        tree = parser.parse(raw)
        errors = []
        walk_errors(tree.root_node, errors, source)
        if errors:
            failed += 1
        results.append({"file": path, "ok": not errors, "errors": errors[:8]})
    report = {"checked": len(results), "failed": failed, "files": results}
    print(json.dumps({"checked": len(results), "failed": failed}, ensure_ascii=False))
    for item in results:
        if item["ok"]:
            continue
        print(f"FAIL {item['file']}")
        for error in item["errors"]:
            print(f"  line {error['line']}:{error['column']} {error['type']} | {error['text']}")
    if args.json_path:
        with open(args.json_path, "w", encoding="utf-8") as handle:
            json.dump(report, handle, ensure_ascii=False, indent=2)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
