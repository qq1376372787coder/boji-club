#!/usr/bin/env python3
"""Compare same-device screenshot baselines. No automatic aesthetic verdict."""
import argparse
import hashlib
import json
import pathlib
import subprocess
import tempfile

p = argparse.ArgumentParser()
p.add_argument("before", type=pathlib.Path)
p.add_argument("after", type=pathlib.Path)
p.add_argument("--output", required=True, type=pathlib.Path)
a = p.parse_args()
a.output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="boji-pixels-") as temporary:
    executable = pathlib.Path(temporary) / "compare"
    subprocess.run(["xcrun", "swiftc", "-O", str(pathlib.Path(__file__).with_name("ComparePixels.swift")), "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(a.before), str(a.after), str(a.output)], check=True)
rows = json.loads(a.output.read_text())
for row in rows:
    for phase, folder in (("before", a.before), ("after", a.after)):
        row[phase + "SHA256"] = hashlib.sha256((folder / row["file"]).read_bytes()).hexdigest()
a.output.write_text(json.dumps({"purpose": "change detection; composition requires human review", "pairs": rows}, indent=2, ensure_ascii=False))
