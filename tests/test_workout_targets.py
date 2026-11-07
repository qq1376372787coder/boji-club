import copy,sys,unittest,json
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from ai_core import validate_request,messages_for,AIError
from test_training_feedback_v63 import request,evaluate

class WorkoutTargets(unittest.TestCase):
    def modern(self):
        raw=request();base=raw['payload']['workout_sessions'][0]['executionBaseline'];base['restSeconds']=90
        for row in base['sets']:row.update(targetReps=12,targetWeight=22.5)
        return raw
    def baseline(self,raw):return validate_request(raw)['payload']['workout_sessions'][0]['executionBaseline']
    def test_load_and_rep_targets_survive_provider_request(self):
        raw=self.modern();clean=self.baseline(raw);self.assertEqual(clean['restSeconds'],90)
        self.assertEqual(clean['sets'][0]['targetWeight'],22.5);self.assertEqual(clean['sets'][0]['targetReps'],12)
        content=str(messages_for(validate_request(raw))[1]['content']);self.assertIn('targetWeight',content);self.assertIn('targetReps',content)
    def test_legacy_targets_remain_unknown(self):
        baseline=self.baseline(request());self.assertNotIn('restSeconds',baseline)
        self.assertNotIn('targetWeight',baseline['sets'][0]);self.assertNotIn('targetReps',baseline['sets'][0])
    def test_zero_weight_and_disabled_rest_preserved(self):
        raw=self.modern();base=raw['payload']['workout_sessions'][0]['executionBaseline'];base['restSeconds']=0;base['sets'][0]['targetWeight']=0
        clean=self.baseline(raw);self.assertEqual(clean['restSeconds'],0);self.assertEqual(clean['sets'][0]['targetWeight'],0)
    def test_timed_set_never_accepts_load_or_rep_targets(self):
        for key,value in [('targetWeight',20),('targetReps',10)]:
            raw=request(timed=60);raw['payload']['workout_sessions'][0]['executionBaseline']['sets'][0][key]=value
            with self.assertRaises(AIError):validate_request(raw)
    def test_invalid_numeric_targets_rejected(self):
        for key,value in [('targetWeight',-1),('targetWeight',2001),('targetWeight',True),('targetReps',0),('targetReps',1001),('targetReps',1.5),('targetReps',True)]:
            raw=self.modern();raw['payload']['workout_sessions'][0]['executionBaseline']['sets'][0][key]=value
            with self.assertRaises(AIError):validate_request(raw)
    def test_invalid_rest_rejected(self):
        for value in (-1,3601,False,1.5,'60'):
            raw=self.modern();raw['payload']['workout_sessions'][0]['executionBaseline']['restSeconds']=value
            with self.assertRaises(AIError):validate_request(raw)
    def test_original_targets_not_replaced_by_actual_values(self):
        raw=self.modern();raw['payload']['exercises'][0]['sets'][0].update(weight=15,reps=7)
        self.assertEqual(self.baseline(raw)['sets'][0]['targetWeight'],22.5);self.assertEqual(self.baseline(raw)['sets'][0]['targetReps'],12)
    def test_new_targets_do_not_silently_redefine_execution_color(self):
        self.assertEqual(evaluate(self.modern()),evaluate(request()))
    def test_private_unrecognized_fields_not_forwarded(self):
        raw=self.modern();raw['payload']['workout_sessions'][0]['executionBaseline']['secret']='never forward'
        self.assertNotIn('secret',self.baseline(raw))

if __name__=='__main__':unittest.main()
