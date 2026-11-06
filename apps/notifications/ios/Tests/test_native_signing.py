"""Exercise real macOS keychains and codesign using generated CI-only keys."""

import hashlib
import os
import shlex
import ssl
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

from test_signing import signing


@unittest.skipUnless(
    sys.platform == "darwin" and os.environ.get("GITHUB_ACTIONS") == "true",
    "Requires an ephemeral GitHub macOS runner",
)
class NativeSigningTests(unittest.TestCase):
    def run_tool(self, *command):
        result = subprocess.run(command, capture_output=True, timeout=30)
        self.assertEqual(
            result.returncode,
            0,
            f"CI signing fixture tool {command[0]} {command[1]} failed: {result.stderr.decode(errors='replace')}",
        )
        return result.stdout

    def test_real_import_identity_selection_and_codesign(self):
        with tempfile.TemporaryDirectory(prefix="bridge-signing-ci-") as directory:
            root = Path(directory)
            key, certificate = root / "test.key", root / "test.pem"
            config = root / "test.cnf"
            config.write_text("""[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=Notification Bridge CI Test
[extensions]
basicConstraints=critical,CA:true
keyUsage=critical,digitalSignature,keyCertSign
extendedKeyUsage=codeSigning
""")
            self.run_tool(
                "/usr/bin/openssl",
                "req",
                "-new",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-days",
                "1",
                "-config",
                str(config),
                "-keyout",
                str(key),
                "-out",
                str(certificate),
            )
            der = ssl.PEM_cert_to_DER_cert(certificate.read_text())
            fingerprint = hashlib.sha1(der).hexdigest().upper()
            intermediate = root / "wwdr.pem"
            intermediate.write_text(
                ssl.DER_cert_to_PEM_cert(
                    (
                        Path(signing.__file__).parent / "certificates/AppleWWDRCAG3.cer"
                    ).read_bytes()
                )
            )
            original = shlex.split(
                signing.security("Save CI search list", "list-keychains", "-d", "user")
            )
            source = root / "test.c"
            source.write_text("int main(void) { return 0; }\n")
            binary = root / "test-binary"
            self.run_tool("/usr/bin/clang", str(source), "-o", str(binary))
            for layout in ("leaf", "leaf-and-intermediate", "private-key-only"):
                with self.subTest(layout=layout):
                    keychain = root / (uuid.uuid4().hex + ".keychain-db")
                    p12 = root / "fixture.p12"
                    # These public fixture passwords protect only generated test keys.
                    self.run_tool(
                        "/usr/bin/openssl",
                        "pkcs12",
                        "-export",
                        "-inkey",
                        str(key),
                        "-in",
                        str(certificate),
                        "-out",
                        str(p12),
                        "-passout",
                        "pass:ci-fixture",
                        "-keypbe",
                        "PBE-SHA1-3DES",
                        "-certpbe",
                        "PBE-SHA1-3DES",
                        *(
                            ["-certfile", str(intermediate)]
                            if layout == "leaf-and-intermediate"
                            else []
                        ),
                        *(["-nocerts"] if layout == "private-key-only" else []),
                    )
                    signing.security(
                        "Create CI keychain",
                        "create-keychain",
                        "-p",
                        "ci-keychain",
                        str(keychain),
                    )
                    try:
                        if layout == "private-key-only":
                            with self.assertRaisesRegex(
                                signing.SigningError,
                                "No usable signing key was imported",
                            ):
                                signing.configure_keychain(
                                    keychain, p12, "ci-fixture", "ci-keychain"
                                )
                            continue
                        signing.configure_keychain(
                            keychain, p12, "ci-fixture", "ci-keychain"
                        )
                        signing.ensure_intermediate(keychain)
                        identities = signing.security(
                            "Find CI identity",
                            "find-identity",
                            "-p",
                            "codesigning",
                            str(keychain),
                        )
                        self.assertIn(fingerprint, identities.upper())
                        # A self-signed fixture must fail production trust validation.
                        valid = signing.security(
                            "Validate CI trust",
                            "find-identity",
                            "-v",
                            "-p",
                            "codesigning",
                            str(keychain),
                        )
                        with self.assertRaisesRegex(
                            ValueError, "not trusted or has expired"
                        ):
                            signing.signing_identity(
                                [{"DeveloperCertificates": [der]}] * 2,
                                identities,
                                valid,
                            )
                        # Explicit signing proves key access and cryptographic validity;
                        # it does not claim this fixture is trusted by Apple or iOS.
                        self.run_tool(
                            "/usr/bin/codesign",
                            "--force",
                            "--sign",
                            fingerprint,
                            "--keychain",
                            str(keychain),
                            "--timestamp=none",
                            str(binary),
                        )
                        self.run_tool(
                            "/usr/bin/codesign", "--verify", "--strict", str(binary)
                        )
                    finally:
                        signing.security(
                            "Restore CI search list",
                            "list-keychains",
                            "-d",
                            "user",
                            "-s",
                            *original,
                        )
                        signing.security(
                            "Delete CI keychain", "delete-keychain", str(keychain)
                        )


if __name__ == "__main__":
    unittest.main()
