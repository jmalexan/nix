import base64
import hashlib
import importlib.util
import os
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

script = Path(__file__).resolve().parents[1] / "signing.py"
spec = importlib.util.spec_from_file_location("bridge_signing", script)
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.certificate = b"test distribution certificate"
        self.fingerprint = hashlib.sha1(self.certificate).hexdigest().upper()
        self.profiles = [{"DeveloperCertificates": [self.certificate]}] * 2
        self.identity = (
            f'  1) {self.fingerprint} "Apple Distribution: Test (TEAM123)"\n'
        )

    def test_existing_apple_keychains_are_preserved(self):
        existing = '    "/Users/runner/Library/Keychains/login.keychain-db"\n    "/Library/Keychains/System.keychain"\n'
        self.assertEqual(
            signing.keychain_search_list("/tmp/signing.keychain-db", existing),
            [
                "/tmp/signing.keychain-db",
                "/Users/runner/Library/Keychains/login.keychain-db",
                "/Library/Keychains/System.keychain",
            ],
        )
        self.assertEqual(
            signing.keychain_search_list("/tmp/with spaces", '"/tmp/with spaces"'),
            ["/tmp/with spaces"],
        )

    def test_valid_private_key_identity_is_selected(self):
        self.assertEqual(
            signing.signing_identity(self.profiles, self.identity, self.identity),
            self.fingerprint,
        )

    def test_certificate_without_private_key_fails_before_archive(self):
        with self.assertRaisesRegex(ValueError, "certificate/private-key pair"):
            signing.signing_identity(
                self.profiles, "0 identities found", "0 valid identities found"
            )

    def test_untrusted_identity_is_distinguished_from_missing_key(self):
        with self.assertRaisesRegex(ValueError, "not trusted or has expired"):
            signing.signing_identity(
                self.profiles,
                self.identity + "CSSMERR_TP_NOT_TRUSTED",
                "0 valid identities found",
            )

    def test_profiles_must_authorize_same_certificate(self):
        with self.assertRaisesRegex(ValueError, "different distribution certificates"):
            signing.signing_identity(
                [self.profiles[0], {"DeveloperCertificates": [b"different"]}],
                self.identity,
                self.identity,
            )

    def test_unrelated_valid_identity_is_not_selected(self):
        with self.assertRaisesRegex(ValueError, "not trusted or has expired"):
            signing.signing_identity(
                self.profiles, self.identity, "1) " + "A" * 40 + ' "Unrelated"'
            )

    def test_fingerprint_in_certificate_name_is_not_an_identity(self):
        unrelated = f'1) {"A" * 40} "Certificate named {self.fingerprint}"'
        with self.assertRaisesRegex(ValueError, "certificate/private-key pair"):
            signing.signing_identity(self.profiles, unrelated, unrelated)

    def test_public_apple_intermediate_is_pinned(self):
        certificate = script.parent / "certificates/AppleWWDRCAG3.cer"
        self.assertEqual(
            hashlib.sha256(certificate.read_bytes()).hexdigest(),
            "dcf21878c77f4198e4b4614f03d696d89c66c66008d4244e1b99161aac91601f",
        )

    def test_setup_preserves_keychains_and_exports_validated_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = {
                "HOME": directory,
                "RUNNER_TEMP": directory,
                "GITHUB_ENV": str(root / "env"),
                "APPLE_TEAM_ID": "TEAM123",
                "BRIDGE_BUNDLE_ID": "com.example.Bridge",
                "APP_PROFILE_BASE64": base64.b64encode(b"app-profile").decode(),
                "EXTENSION_PROFILE_BASE64": base64.b64encode(
                    b"extension-profile"
                ).decode(),
                "DISTRIBUTION_P12_BASE64": base64.b64encode(b"test-p12").decode(),
                "DISTRIBUTION_P12_PASSWORD": "test-secret-password",
                "ASC_KEY_ID": "KEY123",
                "ASC_PRIVATE_KEY_BASE64": base64.b64encode(
                    b"test-private-key"
                ).decode(),
            }

            def output(command, **kwargs):
                if command[1] == "cms":
                    app = "BRIDGE_PROFILE_NAME" in command[-1]
                    return plistlib.dumps(
                        {
                            "Name": "App" if app else "Extension",
                            "UUID": "app-uuid" if app else "extension-uuid",
                            "TeamIdentifier": ["TEAM123"],
                            "Entitlements": {
                                "application-identifier": "TEAM123.com.example.Bridge"
                                + ("" if app else ".NotificationService")
                            },
                            "DeveloperCertificates": [self.certificate],
                        }
                    )
                if command[1] == "list-keychains":
                    return '"/runner/login.keychain-db"\n"/Library/Keychains/System.keychain"'
                if command[1] == "find-identity":
                    return self.identity
                self.fail("Unexpected security command")

            with (
                patch.dict(os.environ, environment),
                patch("sys.argv", ["signing.py"]),
                patch.object(signing.subprocess, "check_output", side_effect=output),
                patch.object(signing.subprocess, "run") as run,
                patch("builtins.print") as printed,
            ):
                signing.main()
            commands = [call.args[0] for call in run.call_args_list]
            searches = [c for c in commands if c[1] == "list-keychains"]
            self.assertEqual(
                searches[0][-2:],
                ["/runner/login.keychain-db", "/Library/Keychains/System.keychain"],
            )
            self.assertTrue(
                any(
                    c[1] == "import" and c[2].endswith("AppleWWDRCAG3.cer")
                    for c in commands
                )
            )
            self.assertIn(
                "BRIDGE_SIGNING_IDENTITY=" + self.fingerprint,
                (root / "env").read_text(),
            )
            exported = plistlib.loads((root / "ExportOptions.plist").read_bytes())
            self.assertEqual(exported["signingCertificate"], self.fingerprint)
            self.assertNotIn("test-secret-password", str(printed.call_args_list))
            self.assertNotIn("test-private-key", str(printed.call_args_list))


if __name__ == "__main__":
    unittest.main()
