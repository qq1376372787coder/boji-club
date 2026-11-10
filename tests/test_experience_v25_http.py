"""Real PHP HTTP state endpoint against a separately configured synthetic DB."""
import copy,unittest
import test_account_v2_http as fixture
class SessionHTTP(unittest.TestCase):
 @classmethod
 def setUpClass(cls): fixture.Acceptance.setUpClass()
 @classmethod
 def tearDownClass(cls): fixture.Acceptance.tearDownClass()
 def test_session_roundtrip_and_old_device_protection(self):
  a='00000000-0000-4000-8000-000000000001';b='00000000-0000-4000-8000-000000000002';day=fixture.TODAY
  state=copy.deepcopy(fixture.Acceptance.state)
  state['days'][day]={'exercises':[{'id':a,'name':'卧推','muscle':'胸','sets':[{'id':a,'weight':20,'reps':10,'completed':True}],'workoutSessionID':a}],'meals':[],'workoutSessions':[{'id':a,'startedAt':800000000,'endedAt':800003600,'savedAt':800003601},{'id':b}],'activeWorkoutSessionID':b}
  def put(value,revision=None):
   _,env=fixture.api('/me/state');return fixture.api('/me/state','PUT',{'base_revision':env['revision'] if revision is None else revision,'state':value})
  status,saved=put(state);self.assertEqual(status,200,saved);revision=saved['revision']
  _,read=fixture.api('/me/state');self.assertEqual(read['state']['days'][day]['workoutSessions'],state['days'][day]['workoutSessions'])
  old=copy.deepcopy(state);old['days'][day].pop('workoutSessions');old['days'][day].pop('activeWorkoutSessionID');old['days'][day]['exercises'][0].pop('workoutSessionID')
  self.assertEqual(put(old)[0],400)
  _,retained=fixture.api('/me/state');self.assertEqual(retained['revision'],revision);self.assertEqual(retained['state']['days'][day]['workoutSessions'],state['days'][day]['workoutSessions'])
  invalid=copy.deepcopy(state);invalid['days'][day]['exercises'][0]['workoutSessionID']='00000000-0000-4000-8000-000000000099'
  self.assertEqual(put(invalid)[0],400)
  changed=copy.deepcopy(state);changed['days'][day]['exercises'][0]['sets'][0]['weight']=25
  status,changedResult=put(changed);self.assertEqual(status,200,changedResult)
  self.assertEqual(put(state,revision=revision)[0],409)
  _,latest=fixture.api('/me/state');self.assertEqual(latest['state']['days'][day]['exercises'][0]['sets'][0]['weight'],25)
  # Concurrent devices can retain more sessions than the new-session UI limit.
  many=copy.deepcopy(changed)
  for number in range(3,10): many['days'][day]['workoutSessions'].append({'id':f'00000000-0000-4000-8000-{number:012d}'})
  status,result=put(many);self.assertEqual(status,200,result);self.assertEqual(len(result['state']['days'][day]['workoutSessions']),9)
  self.assertTrue(fixture.api('/me/state?known_revision='+str(result['revision']))[1]['unchanged'])
  print('PASS 12 v25 real HTTP state preservation assertions')
if __name__=='__main__':unittest.main()
