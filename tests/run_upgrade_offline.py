"""Backend behavior regressions for 0.14.0; legacy layout snapshots are historical."""
import sys,unittest,json
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
modules=['test_build106','test_adaptive_automation','test_coach','test_workout_targets','test_goal_context', 'test_backend_offline', 'test_backend_repairs', 'test_backend_v2', 'test_plan_explanation', 'test_plan_schedule', 'test_multiweek_v73', 'test_pretestflight_v74', 'test_repair_v75', 'test_repair_v77', 'test_training_feedback_v63', 'test_multi_meal', 'test_storage_timezone', 'test_experience_v33', 'test_experience_v36', 'test_experience_v37', 'test_experience_v42', 'test_experience_v43']
suite=unittest.defaultTestLoader.loadTestsFromNames(modules)
result=unittest.TextTestRunner(verbosity=1).run(suite)
print(json.dumps({'passed':result.wasSuccessful(),'tests':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'skipped':len(result.skipped)}))
sys.exit(not result.wasSuccessful())
