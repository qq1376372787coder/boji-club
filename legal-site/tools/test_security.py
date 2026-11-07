import importlib.util
import io
import os
import tempfile
import unittest
from email.message import Message
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


SERVER_PATH = Path(__file__).resolve().parents[1] / "server.py"
SPEC = importlib.util.spec_from_file_location("boji_legal_server", SERVER_PATH)
server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server)


class LegalSiteSecurityTests(unittest.TestCase):
    def test_unsafe_markdown_schemes_are_not_rendered_as_links(self):
        rendered = server._inline("[click](javascript:alert(1))")
        self.assertNotIn("<a ", rendered)
        self.assertNotIn("javascript:", rendered)
        self.assertIn('href="https://example.com"', server._inline("[safe](https://example.com)"))

    def test_sensitive_atomic_files_are_private(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sessions.json"
            server._atomic_write(path, "{}")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_forwarding_headers_are_ignored_for_direct_clients(self):
        handler = object.__new__(server.Handler)
        handler.client_address = ("203.0.113.8", 1234)
        handler.headers = Message()
        handler.headers["X-Real-IP"] = "127.0.0.1"
        handler.headers["X-Forwarded-Proto"] = "https"
        self.assertEqual(handler.client_ip(), "203.0.113.8")
        self.assertFalse(handler.is_https())

    def test_forwarding_headers_are_accepted_from_loopback_proxy(self):
        handler = object.__new__(server.Handler)
        handler.client_address = ("127.0.0.1", 1234)
        handler.headers = Message()
        handler.headers["X-Real-IP"] = "203.0.113.9"
        handler.headers["X-Forwarded-Proto"] = "https"
        self.assertEqual(handler.client_ip(), "203.0.113.9")
        self.assertTrue(handler.is_https())

    def test_public_site_requires_confirmed_identity_contact_and_icp(self):
        with tempfile.TemporaryDirectory() as directory:
            old_config_file = server.CONFIG_FILE
            try:
                server.CONFIG_FILE = Path(directory) / "config.json"
                cfg = dict(server.DEFAULT_CONFIG)
                server._save_json(server.CONFIG_FILE, cfg)
                self.assertFalse(server.Handler.public_site_ready(SimpleNamespace()))
                cfg["icp_number"] = "ICP fixture"
                server._save_json(server.CONFIG_FILE, cfg)
                with patch.dict(os.environ, {"BOJI_LEGAL_PUBLISH": "0"}):
                    self.assertFalse(server.Handler.public_site_ready(SimpleNamespace()))
                with patch.dict(os.environ, {"BOJI_LEGAL_PUBLISH": "1"}):
                    self.assertTrue(server.Handler.public_site_ready(SimpleNamespace()))
            finally:
                server.CONFIG_FILE = old_config_file

    def test_json_reader_rejects_negative_and_oversized_lengths(self):
        for length in ("-1", "5000001"):
            handler = object.__new__(server.Handler)
            handler.headers = Message()
            handler.headers["Content-Length"] = length
            handler.rfile = io.BytesIO(b'{"admin":true}')
            self.assertEqual(handler.read_json(), {})


if __name__ == "__main__":
    unittest.main()
