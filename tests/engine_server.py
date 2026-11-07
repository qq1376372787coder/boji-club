from pathlib import Path
import sys, os
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'backend'))
import server
store = server.JobStore(Path('/tmp/boji-fix-engine.sqlite3'))
http = server.make_server(store, None, 'independent-audit-loopback-only-token-1234', 18792)
http.serve_forever()
