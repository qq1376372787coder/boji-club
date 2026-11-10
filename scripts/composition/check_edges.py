#!/usr/bin/env python3
"""Flag possible horizontal text clipping for human review; scroll chips may be intentional."""
import argparse
import json
import pathlib
import subprocess
import tempfile

p = argparse.ArgumentParser()
p.add_argument("screenshots", type=pathlib.Path)
p.add_argument("--output", required=True, type=pathlib.Path)
a = p.parse_args()
files = sorted(a.screenshots.rglob("*.png"))
if not files:
    p.error("No PNG screenshots found")
with tempfile.TemporaryDirectory(prefix="boji-edges-") as temporary:
    executable = pathlib.Path(temporary) / "visual-text"
    subprocess.run(["xcrun", "swiftc", str(pathlib.Path(__file__).with_name("VisualText.swift")), "-o", str(executable)], check=True)
    rows = json.loads(subprocess.check_output([str(executable), *map(str, files)], text=True))
result = []
for row in rows:
    flags = [o for o in row.get("observations", []) if .08 < o["y"] < .92 and len(o["text"]) > 1 and (o["x"] < .012 or o["x"] + o["width"] > .988)]
    result.append({"file": str(pathlib.Path(row["file"]).relative_to(a.screenshots)), "recognizedLines": len(row.get("texts", [])), "possibleHorizontalEdgeClipping": flags, "error": row.get("error"), "decision": "manual-review" if flags or row.get("error") else "no-edge-text-detected"})
a.output.parent.mkdir(parents=True, exist_ok=True)
a.output.write_text(json.dumps({"method": "Vision normalized text boxes within 1.2% of horizontal edge; excludes top/bottom chrome. Intentional horizontal scroll content requires review. This cannot prove absence of overflow.", "screenshots": result}, ensure_ascii=False, indent=2))
print(f"Checked {len(result)} screenshots; {sum(bool(x['possibleHorizontalEdgeClipping']) for x in result)} require edge review.")
