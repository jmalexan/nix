"""Import explicit distribution assets on an ephemeral macOS release runner."""

import base64
import hashlib
import json
import os
import plistlib
import re
import secrets
import shlex
import shutil
import ssl
import subprocess
import sys
from pathlib import Path


class SigningError(RuntimeError):
    pass


def security(stage, *arguments, binary=False, allow_codes=(0,)):
    """Report the failed stage without logging argv, passwords, or keychain dumps."""
    print("Signing: " + stage, flush=True)
    try:
        result = subprocess.run(
            ["security", *arguments], capture_output=True, timeout=30
        )
    except subprocess.TimeoutExpired:
        raise SigningError(
            stage + " timed out waiting for macOS keychain services."
        ) from None
    except OSError:
        raise SigningError(
            stage + " could not start macOS keychain services."
        ) from None
    if result.returncode not in allow_codes:
        reason = ""
        error = result.stderr.decode(errors="replace").lower()
        for marker, explanation in [
            ("mac verification failed", "The P12 password could not be verified."),
            ("unknown format", "The imported file format was not recognized."),
            ("already exists", "The keychain already contains this item."),
            (
                "user interaction is not allowed",
                "The keychain requires interactive authorization.",
            ),
            (
                "specified item could not be found",
                "The requested keychain item was not found.",
            ),
        ]:
            if marker in error:
                reason = " " + explanation
                break
        raise SigningError(f"{stage} failed (exit {result.returncode}).{reason}")
    return result.stdout if binary else result.stdout.decode(errors="replace")


def ensure_certificate(keychain, certificate, label):
    existing = security(
        "Inspect certificates for " + label,
        "find-certificate",
        "-a",
        "-p",
        str(keychain),
        allow_codes=(0, 44),
    )
    installed = [
        ssl.PEM_cert_to_DER_cert(pem)
        for pem in re.findall(
            r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
            existing,
            re.DOTALL,
        )
    ]
    if certificate.read_bytes() in installed:
        print("Signing: " + label + " is already installed", flush=True)
        return
    security("Import " + label, "import", str(certificate), "-k", str(keychain))


def ensure_intermediate(keychain):
    ensure_certificate(
        keychain,
        Path(__file__).parent / "certificates/AppleWWDRCAG3.cer",
        "Apple WWDR G3",
    )


def configure_keychain(
    keychain, certificate, p12_password, keychain_password, certificates=()
):
    existing = security("Read keychain search list", "list-keychains", "-d", "user")
    security(
        "Set keychain timeout", "set-keychain-settings", "-lut", "21600", str(keychain)
    )
    security(
        "Unlock signing keychain",
        "unlock-keychain",
        "-p",
        keychain_password,
        str(keychain),
    )
    security(
        "Import signing identity",
        "import",
        str(certificate),
        "-P",
        p12_password,
        "-f",
        "pkcs12",
        "-k",
        str(keychain),
        "-T",
        "/usr/bin/codesign",
    )
    security(
        "Authorize signing tools",
        "set-key-partition-list",
        "-S",
        "apple-tool:,apple:,codesign:",
        "-k",
        keychain_password,
        str(keychain),
    )
    ensure_intermediate(keychain)
    # A private-key-only export can be completed with the public certificate
    # authorized by both profiles. macOS must still find a matching private key.
    for der in certificates:
        leaf = Path(keychain).parent / (hashlib.sha256(der).hexdigest() + ".cer")
        leaf.write_bytes(der)
        ensure_certificate(keychain, leaf, "distribution certificate from profiles")
    security(
        "Extend keychain search list",
        "list-keychains",
        "-d",
        "user",
        "-s",
        *keychain_search_list(keychain, existing),
    )


def common_certificates(profiles):
    authorized = [set(profile["DeveloperCertificates"]) for profile in profiles]
    common = set.intersection(*authorized)
    if not common:
        raise ValueError(
            "The app and extension profiles authorize different distribution certificates"
        )
    return common


def signing_identity(profiles, identities, valid_identities):
    """Select a usable private-key identity authorized by every target profile."""
    common = {
        hashlib.sha1(certificate).hexdigest().upper()
        for certificate in common_certificates(profiles)
    }

    def fingerprints(output):
        return set(
            re.findall(r'^\s*\d+\)\s+([0-9A-F]{40})\s+"', output.upper(), re.MULTILINE)
        )

    matching = common & fingerprints(identities)
    if not matching:
        raise ValueError(
            "The P12 has no certificate/private-key pair matching both profiles. "
            "Export the Apple Distribution certificate together with its private key, "
            "and use that same certificate in both profiles."
        )
    valid = matching & fingerprints(valid_identities)
    if not valid:
        raise ValueError(
            "The matching signing identity is not trusted or has expired. "
            "Check the Apple WWDR certificate chain and distribution certificate validity."
        )
    if len(valid) != 1:
        raise ValueError(
            "More than one matching signing identity; export only the intended distribution identity"
        )
    return valid.pop()


def keychain_search_list(keychain, existing):
    """Retain runner keychains that may supply Apple's intermediate certificates."""
    return list(dict.fromkeys([str(keychain), *shlex.split(existing)]))


def main():
    root = Path(os.environ["RUNNER_TEMP"]) / "bridge-signing"
    manifest = root / "files.json"
    if sys.argv[1:] == ["--cleanup"]:
        if manifest.exists():
            for file in json.loads(manifest.read_text()):
                Path(file).unlink(missing_ok=True)
        shutil.rmtree(root, ignore_errors=True)
        return
    root.mkdir(mode=0o700)
    files = []

    def record(path, data):
        files.append(str(path))
        manifest.write_text(json.dumps(files))
        path.write_bytes(data)
        path.chmod(0o600)

    def decode(name):
        return base64.b64decode(os.environ[name], validate=True)

    profiles = {}
    profile_data = []
    names = {}
    team = os.environ["APPLE_TEAM_ID"]
    bundle = os.environ["BRIDGE_BUNDLE_ID"]
    for secret, variable, identifier in [
        ("APP_PROFILE_BASE64", "BRIDGE_PROFILE_NAME", bundle),
        (
            "EXTENSION_PROFILE_BASE64",
            "SERVICE_PROFILE_NAME",
            bundle + ".NotificationService",
        ),
    ]:
        raw = root / (variable + ".mobileprovision")
        record(raw, decode(secret))
        profile = plistlib.loads(
            security("Read " + variable, "cms", "-D", "-i", str(raw), binary=True)
        )
        if (
            profile["TeamIdentifier"] != [team]
            or profile["Entitlements"]["application-identifier"]
            != team + "." + identifier
        ):
            raise ValueError(
                "Provisioning profile does not match the configured app/team"
            )
        if "\n" in profile["Name"]:
            raise ValueError("Invalid profile name")
        for directory in [
            "Library/MobileDevice/Provisioning Profiles",
            "Library/Developer/Xcode/UserData/Provisioning Profiles",
        ]:
            destination = Path.home() / directory
            destination.mkdir(parents=True, exist_ok=True)
            record(
                destination / (profile["UUID"] + ".mobileprovision"), raw.read_bytes()
            )
        profiles[identifier] = profile["Name"]
        profile_data.append(profile)
        names[variable] = profile["Name"]
    certificate = root / "distribution.p12"
    record(certificate, decode("DISTRIBUTION_P12_BASE64"))
    keychain = root / "signing.keychain-db"
    password = secrets.token_urlsafe(32)
    security(
        "Create signing keychain", "create-keychain", "-p", password, str(keychain)
    )
    with open(os.environ["GITHUB_ENV"], "a") as output:
        output.write("BRIDGE_KEYCHAIN=" + str(keychain) + "\n")
        for name, value in names.items():
            output.write(name + "=" + value + "\n")
    configure_keychain(
        keychain,
        certificate,
        os.environ["DISTRIBUTION_P12_PASSWORD"],
        password,
        common_certificates(profile_data),
    )
    identity = signing_identity(
        profile_data,
        security(
            "Find imported private-key identities",
            "find-identity",
            "-p",
            "codesigning",
            str(keychain),
        ),
        security(
            "Validate signing trust",
            "find-identity",
            "-v",
            "-p",
            "codesigning",
            str(keychain),
        ),
    )
    with open(os.environ["GITHUB_ENV"], "a") as output:
        output.write("BRIDGE_SIGNING_IDENTITY=" + identity + "\n")
    print(
        "Validated a trusted signing identity with a private key matching both profiles."
    )
    key_id = os.environ["ASC_KEY_ID"]
    if not key_id.isalnum():
        raise ValueError("Invalid App Store Connect key ID")
    directory = Path.home() / ".appstoreconnect/private_keys"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    record(directory / ("AuthKey_" + key_id + ".p8"), decode("ASC_PRIVATE_KEY_BASE64"))
    record(
        Path(os.environ["RUNNER_TEMP"]) / "ExportOptions.plist",
        plistlib.dumps(
            {
                "method": "app-store-connect",
                "destination": "export",
                "teamID": team,
                "signingStyle": "manual",
                "signingCertificate": identity,
                "provisioningProfiles": profiles,
            }
        ),
    )


if __name__ == "__main__":
    try:
        main()
    except (SigningError, ValueError) as error:
        raise SystemExit(str(error)) from None
