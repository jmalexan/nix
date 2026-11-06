import importlib.util
import json
import os
import shlex
import socket
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "nasa_access", Path(__file__).with_name("nasa-access.py")
)
access = importlib.util.module_from_spec(spec)
spec.loader.exec_module(access)


class AccessTests(unittest.TestCase):
    def test_approved_mode_never_falls_back_to_forwarded_agent(self):
        with (
            patch.object(
                access.sys,
                "argv",
                [
                    "nasa-access.py",
                    "--approved",
                    "--reason",
                    "Inspect host",
                    "--",
                    "stat",
                    "/Data/smb",
                ],
            ),
            patch.object(access, "choose_agent") as agent,
            patch.object(access, "audit") as audit,
            patch.object(
                access.subprocess,
                "run",
                return_value=subprocess.CompletedProcess([], 37),
            ) as run,
        ):
            self.assertEqual(access.main(), 37)
            agent.assert_not_called()
            run.assert_called_once()
            self.assertEqual(run.call_args.args[0][1:3], ["-m", "microapps.access"])
            self.assertEqual(
                audit.call_args.kwargs["target"], "nasa-automation@10.0.1.10:2222"
            )

    def test_ssh_requires_verified_host_and_never_forwards_agent_onward(self):
        command = access.ssh_command(["stat", "/path with spaces"], "/tmp/agent")
        for option in (
            "StrictHostKeyChecking=yes",
            "ForwardAgent=no",
            "ClearAllForwardings=yes",
            "IdentityFile=none",
            "BatchMode=yes",
            "IdentityAgent=/tmp/agent",
        ):
            self.assertIn(option, command)
        self.assertEqual(command[-2], "jmalexan@10.0.1.10")

    def test_remote_arguments_are_quoted_without_shell_interpolation(self):
        arguments = ["stat", "a b", "$(touch /tmp/no)", "quote'and\"quote"]
        self.assertEqual(
            shlex.split(access.ssh_command(arguments, "/tmp/agent")[-1]), arguments
        )

    def test_audit_is_private_and_omits_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "private/events.jsonl"
            with patch.object(access, "AUDIT", log):
                access.audit(
                    "Check operation", ["example", "secret-value"], "end", exitCode=0
                )
            self.assertEqual(stat.S_IMODE(log.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(log.parent.stat().st_mode), 0o700)
            self.assertNotIn("secret-value", log.read_text())
            self.assertEqual(json.loads(log.read_text())["exitCode"], 0)

    def test_socket_discovery_excludes_regular_files_and_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            agent_path = str(Path(directory) / "agent")
            ordinary_path = str(Path(directory) / "ordinary")
            Path(ordinary_path).touch()
            with socket.socket(socket.AF_UNIX) as agent:
                agent.bind(agent_path)
                with (
                    patch.dict(os.environ, {"SSH_AUTH_SOCK": agent_path}),
                    patch.object(
                        access.glob, "glob", return_value=[agent_path, ordinary_path]
                    ),
                ):
                    self.assertEqual(access.agent_candidates(), [agent_path])

    def test_missing_agent_fails_without_connecting(self):
        with (
            patch.object(access, "agent_candidates", return_value=[]),
            patch.object(access.subprocess, "run") as run,
        ):
            with self.assertRaisesRegex(ValueError, "No usable SSH agent"):
                access.choose_agent()
            run.assert_not_called()

    def test_discovers_agent_in_user_ssh_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            agent_directory = Path(directory) / ".ssh/agent"
            agent_directory.mkdir(parents=True)
            agent_path = str(agent_directory / "s.forwarded")
            with socket.socket(socket.AF_UNIX) as agent:
                agent.bind(agent_path)
                with (
                    patch.dict(os.environ, {"SSH_AUTH_SOCK": ""}),
                    patch.object(access.Path, "home", return_value=Path(directory)),
                    patch.object(
                        access.glob,
                        "glob",
                        side_effect=lambda pattern: (
                            [agent_path]
                            if pattern == str(agent_directory / "*")
                            else []
                        ),
                    ),
                ):
                    self.assertEqual(access.agent_candidates(), [agent_path])


if __name__ == "__main__":
    unittest.main()
