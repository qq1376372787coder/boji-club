"""FIX-014 regression: a failed template save must stop loading the new draft."""
from pathlib import Path
import subprocess, sys, tempfile
root = Path(__file__).resolve().parents[1]
src = (root / 'BojiClub' / 'ManualPlanView.swift').read_text()
start = src.index('enum ManualPlanImportRules')
end = src.index('\n}\n', start) + 3
block = src[start:end]
code = 'import Foundation\n' + block + r'''
precondition(ManualPlanImportRules.mayLoad(keepPrevious: true, templateSaved: true))
precondition(!ManualPlanImportRules.mayLoad(keepPrevious: true, templateSaved: false))
precondition(ManualPlanImportRules.mayLoad(keepPrevious: false, templateSaved: false))
precondition(ManualPlanImportRules.templateFailure.contains("停止载入"))
print("MANUAL_PLAN_IMPORT_RULES_OK")
'''
with tempfile.TemporaryDirectory() as d:
    path = Path(d) / 'probe.swift'; path.write_text(code)
    binary = Path(d) / 'probe'
    subprocess.run(['swiftc', '-o', str(binary), str(path)], check=True)
    subprocess.run([str(binary)], check=True)
