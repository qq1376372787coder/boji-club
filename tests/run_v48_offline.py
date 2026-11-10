from pathlib import Path
import sys,unittest,json
folder=Path(__file__).resolve().parent
sys.path.insert(0,str(folder))
modules=sorted(p.stem for p in folder.glob('test_*.py') if '_http' not in p.stem and p.stem!='test_account_regression')
suite=unittest.defaultTestLoader.loadTestsFromNames(modules)
result=unittest.TextTestRunner(verbosity=1).run(suite)
print(json.dumps({'passed':result.wasSuccessful(),'tests':result.testsRun,'skipped':len(result.skipped),'failures':len(result.failures),'errors':len(result.errors)}))
sys.exit(not result.wasSuccessful())
