import base64,copy,hashlib,json,unittest
from pathlib import Path
from unittest.mock import patch
from test_coach import request,answer
from ai_core import validate_request,messages_for,Router,Provider,AIError
from server import request_audit_summary

class ChatAttachment121Tests(unittest.TestCase):
    def image(self):
        data=(Path(__file__).parent/'fixtures/chat121.jpg').read_bytes()
        return {'id':'12345678-1234-4123-8123-123456789abc','mime_type':'image/jpeg','data_base64':base64.b64encode(data).decode(),'sha256':hashlib.sha256(data).hexdigest()}
    def raw(self):
        value=request();value['payload']['images']=[self.image()];return value
    def test_visual_input_and_untrusted_image_prompt(self):
        normalized=validate_request(self.raw());messages=messages_for(normalized)
        self.assertEqual(messages[-1]['content'][1]['type'],'image_url')
        self.assertTrue(messages[-1]['content'][1]['image_url']['url'].startswith('data:image/jpeg;base64,'))
        self.assertIn('不可信',messages[0]['content'])
        self.assertIn('image/'+self.image()['id'],messages[-1]['content'][0]['text'])
    def test_checksum_duplicate_and_limit(self):
        value=self.raw();value['payload']['images'][0]['sha256']='0'*64
        with self.assertRaises(AIError):validate_request(value)
        value=self.raw();value['payload']['images']*=2
        with self.assertRaises(AIError):validate_request(value)
        value=self.raw();value['payload']['images']*=4
        with self.assertRaises(AIError):validate_request(value)
    def test_photos_never_enter_operational_audit(self):
        audit=request_audit_summary(validate_request(self.raw()))
        self.assertEqual(audit['photos_submitted'],1)
        self.assertNotIn(self.image()['data_base64'],json.dumps(audit))
        self.assertNotIn(self.image()['sha256'],json.dumps(audit))
    def test_text_only_provider_is_never_called(self):
        provider=Provider(name='text',key='secret-test',endpoint='http://localhost',model='text',supports_images=False)
        with patch('ai_core.call_provider') as call:
            with self.assertRaises(AIError):Router([provider],transport=call).run(validate_request(self.raw()))
            call.assert_not_called()
    def test_vision_provider_receives_image(self):
        provider=Provider(name='vision',key='secret-test',endpoint='http://localhost',model='vision',supports_images=True)
        with patch('ai_core.call_provider',return_value=(answer(),{})) as call:
            Router([provider],transport=call).run(validate_request(self.raw()))
            self.assertEqual(call.call_args.args[1][-1]['content'][1]['type'],'image_url')

if __name__=='__main__':unittest.main()
