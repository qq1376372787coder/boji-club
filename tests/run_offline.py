from pathlib import Path
import unittest,sys
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tests'))
suite=unittest.TestSuite()
modules=[]
for path in sorted((root/'tests').glob('test_*.py')):
 # HTTP and real-DB concurrency suites run in their dedicated CI jobs, which
 # provision their disposable services. Keep every suite in CI; do not load
 # integration-only modules into the no-service offline lane.
 if '_http' in path.stem or path.stem.endswith('_runtime'): continue
 modules.append(path.stem);suite.addTests(unittest.defaultTestLoader.loadTestsFromName(path.stem))
print('OFFLINE_MODULES',','.join(modules),flush=True)
result=unittest.TextTestRunner(verbosity=1).run(suite)
raise SystemExit(not result.wasSuccessful())
