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
import subprocess
import sys
from pathlib import Path


def signing_identity(profiles, identities, valid_identities):
    """Select a usable private-key identity authorized by every target profile."""
    authorized = [
        {
            hashlib.sha1(certificate).hexdigest().upper()
            for certificate in profile["DeveloperCertificates"]
        }
        for profile in profiles
    ]
    common = set.intersection(*authorized)
    if not common:
        raise ValueError(
            "The app and extension profiles authorize different distribution certificates"
        )

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
            subprocess.check_output(["security", "cms", "-D", "-i", str(raw)])
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
    existing_keychains = subprocess.check_output(
        ["security", "list-keychains", "-d", "user"], text=True
    )
    password = secrets.token_urlsafe(32)
    subprocess.run(
        ["security", "create-keychain", "-p", password, str(keychain)], check=True
    )
    with open(os.environ["GITHUB_ENV"], "a") as output:
        output.write("BRIDGE_KEYCHAIN=" + str(keychain) + "\n")
        for name, value in names.items():
            output.write(name + "=" + value + "\n")
    for command in [
        ["security", "set-keychain-settings", "-lut", "21600", str(keychain)],
        ["security", "unlock-keychain", "-p", password, str(keychain)],
        [
            "security",
            "import",
            str(certificate),
            "-P",
            os.environ["DISTRIBUTION_P12_PASSWORD"],
            "-f",
            "pkcs12",
            "-k",
            str(keychain),
            "-T",
            "/usr/bin/codesign",
        ],
        [
            "security",
            "set-key-partition-list",
            "-S",
            "apple-tool:,apple:,codesign:",
            "-k",
            password,
            str(keychain),
        ],
        [
            "security",
            "import",
            str(Path(__file__).parent / "certificates/AppleWWDRCAG3.cer"),
            "-k",
            str(keychain),
        ],
        [
            "security",
            "list-keychains",
            "-d",
            "user",
            "-s",
            *keychain_search_list(keychain, existing_keychains),
        ],
    ]:
        subprocess.run(
            command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
    identity = signing_identity(
        profile_data,
        subprocess.check_output(
            ["security", "find-identity", "-p", "codesigning", str(keychain)], text=True
        ),
        subprocess.check_output(
            ["security", "find-identity", "-v", "-p", "codesigning", str(keychain)],
            text=True,
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
    except subprocess.CalledProcessError:
        # CalledProcessError includes argv, which can contain signing passwords.
        raise SystemExit(
            "Apple signing setup failed; check the configured signing assets."
        ) from None
