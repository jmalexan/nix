import base64
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

spec = importlib.util.spec_from_file_location(
    "github_bot", Path(__file__).with_name("github-bot.py")
)
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)


class GitHubBotTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        cls.pem = cls.key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )

    def test_jwt_signature_and_bounded_lifetime(self):
        value = bot.jwt(1234, self.pem, now=1000)
        header, payload, signature = value.split(".")

        def decode(value):
            return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))

        self.assertEqual(json.loads(decode(header))["alg"], "RS256")
        self.assertEqual(
            json.loads(decode(payload)), {"iss": "1234", "iat": 940, "exp": 1540}
        )
        self.key.public_key().verify(
            decode(signature),
            f"{header}.{payload}".encode(),
            padding.PKCS1v15(),
            hashes.SHA256(),
        )

    def test_token_is_scoped_to_one_repository(self):
        calls = []

        def api(token, path, body=None):
            calls.append((path, body))
            if body is None:
                return {
                    "id": 42,
                    "account": {"login": "jmalexan"},
                    "repository_selection": "selected",
                    "permissions": bot.PERMISSIONS,
                }
            return {"token": "temporary-test-token"}

        token, _ = bot.installation_token(1234, self.pem, api)
        self.assertEqual(token, "temporary-test-token")
        self.assertEqual(
            calls[1],
            (
                "/app/installations/42/access_tokens",
                {"repositories": ["nix"], "permissions": bot.PERMISSIONS},
            ),
        )

    def test_rejects_excess_permissions_or_broad_installation(self):
        for permissions, selection in [
            (bot.PERMISSIONS | {"administration": "write"}, "selected"),
            (bot.PERMISSIONS, "all"),
        ]:
            with self.subTest(selection=selection, permissions=permissions):

                def api(token, path, body=None):
                    return {
                        "id": 42,
                        "account": {"login": "jmalexan"},
                        "repository_selection": selection,
                        "permissions": permissions,
                    }

                with self.assertRaises(ValueError):
                    bot.installation_token(1234, self.pem, api)

    def test_does_not_inherit_owner_tokens_or_debug_output(self):
        with patch.dict(
            os.environ,
            {
                "GH_TOKEN": "owner",
                "GITHUB_TOKEN": "owner",
                "GH_CONFIG_DIR": "/owner",
                "GH_DEBUG": "api",
                "GIT_TRACE_CURL": "1",
                "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "credential.helper",
                "GIT_CONFIG_VALUE_0": "owner-helper",
            },
        ):
            env = bot.clean_environment("bot-token", "/isolated")
        self.assertEqual(env["GH_TOKEN"], "bot-token")
        self.assertEqual(env["GH_CONFIG_DIR"], "/isolated")
        self.assertEqual(env["GIT_SSH_COMMAND"], "false")
        for key in (
            "GITHUB_TOKEN",
            "GH_DEBUG",
            "GIT_TRACE_CURL",
            "GIT_CONFIG_COUNT",
            "GIT_CONFIG_KEY_0",
            "GIT_CONFIG_VALUE_0",
        ):
            self.assertNotIn(key, env)

    def test_private_key_write_refuses_overwrite_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "key"
            bot.secure_write(path, b"test-key")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                bot.secure_write(path, b"replacement")
            link = Path(directory) / "link"
            link.symlink_to(path)
            with self.assertRaises(FileExistsError):
                bot.secure_write(link, b"replacement")
            self.assertEqual(path.read_bytes(), b"test-key")


if __name__ == "__main__":
    unittest.main()
