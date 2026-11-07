"""Loopback deterministic-engine fixture. No model workers or supplier calls."""
from pathlib import Path
import sys
import os
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
import server
import ai_core
with tempfile.TemporaryDirectory(prefix='boji-rules-fixture-') as folder:
    os.environ['BOJI_ROUTER_METRICS']=str(Path(folder)/'router-metrics.sqlite3')
    store=server.JobStore(Path(folder)/'jobs.sqlite3')
    service=server.make_server(store, ai_core.Router([]), 'independent-audit-loopback-only-token-1234',18792)
    print('RULES_FIXTURE_READY 127.0.0.1:18792',flush=True)
    try: service.serve_forever()
    finally: service.server_close()
