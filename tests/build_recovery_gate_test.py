"""FIX-022 regression: background recovery notices de-duplicate per account."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
src = (root / 'BojiClub' / 'AIService.swift').read_text()
start = src.index('struct BackgroundRecoveryNoticeGate')
end = src.index('\n}\n', start) + 3
block = src[start:end]
code = 'import Foundation\n' + block + r'''
var gate = BackgroundRecoveryNoticeGate()
precondition(gate.shouldPresent(accountID: 1))
precondition(!gate.shouldPresent(accountID: 1))
precondition(gate.shouldPresent(accountID: 2))
gate.reset()
precondition(gate.shouldPresent(accountID: 1))
print("RECOVERY_GATE_OK")
'''
with tempfile.TemporaryDirectory() as d:
    path = Path(d) / 'probe.swift'; path.write_text(code)
    binary = Path(d) / 'probe'
    subprocess.run(['swiftc', '-o', str(binary), str(path)], check=True)
    subprocess.run([str(binary)], check=True)
