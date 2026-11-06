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
            for bundle_layout in ("leaf", "leaf-and-intermediate", "private-key-only"):
                with self.subTest(bundle_layout=bundle_layout):
                    keychain = root / (uuid.uuid4().hex + ".keychain-db")
                    p12 = root / "fixture.p12"
                    # Public CI fixture passwords protect only generated, disposable test keys.
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
                            if bundle_layout == "leaf-and-intermediate"
                            else []
                        ),
                        *(["-nocerts"] if bundle_layout == "private-key-only" else []),
                    )
                    signing.security(
                        "Create CI keychain",
                        "create-keychain",
                        "-p",
                        "ci-keychain",
                        str(keychain),
                    )
                    trusted = False
                    try:
                        signing.configure_keychain(
                            keychain, p12, "ci-fixture", "ci-keychain", [der]
                        )
                        # Trust only this generated certificate for code signing on the
                        # disposable runner, never in the production signing path.
                        self.run_tool(
                            "/usr/bin/sudo",
                            "-n",
                            "/usr/bin/security",
                            "add-trusted-cert",
                            "-d",
                            "-r",
                            "trustRoot",
                            "-p",
                            "codeSign",
                            "-k",
                            "/Library/Keychains/System.keychain",
                            str(certificate),
                        )
                        trusted = True
                        signing.ensure_intermediate(keychain)
                        identity = signing.signing_identity(
                            [{"DeveloperCertificates": [der]}] * 2,
                            signing.security(
                                "Find CI identity",
                                "find-identity",
                                "-p",
                                "codesigning",
                                str(keychain),
                            ),
                            signing.security(
                                "Validate CI identity",
                                "find-identity",
                                "-v",
                                "-p",
                                "codesigning",
                                str(keychain),
                            ),
                        )
                        self.run_tool(
                            "/usr/bin/codesign",
                            "--force",
                            "--sign",
                            identity,
                            "--keychain",
                            str(keychain),
                            "--timestamp=none",
                            str(binary),
                        )
                        self.run_tool(
                            "/usr/bin/codesign", "--verify", "--strict", str(binary)
                        )
                    finally:
                        if trusted:
                            self.run_tool(
                                "/usr/bin/sudo",
                                "-n",
                                "/usr/bin/security",
                                "remove-trusted-cert",
                                "-d",
                                str(certificate),
                            )
                            self.run_tool(
                                "/usr/bin/sudo",
                                "-n",
                                "/usr/bin/security",
                                "delete-certificate",
                                "-Z",
                                hashlib.sha1(der).hexdigest().upper(),
                                "/Library/Keychains/System.keychain",
                            )
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
