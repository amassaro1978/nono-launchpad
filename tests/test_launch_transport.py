#!/usr/bin/env python3
"""Focused regression tests for the Launch-only WSL script transport."""

import base64
import hashlib
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT_BYTES = (ROOT / "Nono-Launchpad.ps1").read_bytes()
SCRIPT = SCRIPT_BYTES.decode("utf-8")


def byte_region(start: bytes, end: bytes) -> bytes:
    begin = SCRIPT_BYTES.index(start)
    finish = SCRIPT_BYTES.index(end, begin)
    return SCRIPT_BYTES[begin:finish]


def text_region(start: str, end: str) -> str:
    begin = SCRIPT.index(start)
    finish = SCRIPT.index(end, begin)
    return SCRIPT[begin:finish]


class ProtectedRegionTests(unittest.TestCase):
    """Hashes are SHA-256 snapshots from parent commit d318bf8."""

    EXPECTED = {
        "Invoke-WslText": (
            b"function Invoke-WslText {",
            b"function Test-DistroRegistered {",
            "5018a4cdb28508717df03de4b56403a1f8b0b36bf818af4f13b56e80c5638a36",
        ),
        "Open-ShellInCurrentConsole": (
            b"function Open-ShellInCurrentConsole {",
            b"if ($Mode -eq 'Launch') {",
            "5dd344e034175e4f9bc9e640d45647e4c684f4cc21dec0814bca8763b1a1f511",
        ),
        "Refresh-Projects": (
            b"function Refresh-Projects {",
            b"function Refresh-Readiness {",
            "370e68a5c66e92ec6223ace3dbbe931ab81693a645e7c31d566a3b2e3fa0d77f",
        ),
        "Start-HelperTerminal": (
            b"function Start-HelperTerminal {",
            b"$SetKeyButton.Add_Click({",
            "79d0f7e88bbbefa9d597bd37fc149d2ec14ffc1e44b45e05ce3ef309b6ceddc4",
        ),
        "CreateButton behavior": (
            b"$CreateButton.Add_Click({",
            b"$RefreshButton.Add_Click({",
            "84071a8a83fc0de0742de8d5d5c37828cd079ddfb20be8f1df83189b9fe036f8",
        ),
    }

    def test_non_launch_regions_match_parent_byte_for_byte(self):
        for name, (start, end, expected) in self.EXPECTED.items():
            with self.subTest(region=name):
                actual = hashlib.sha256(byte_region(start, end)).hexdigest()
                self.assertEqual(expected, actual)


class LaunchTransportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.launch = text_region(
            "function Invoke-AgentInCurrentConsole {",
            "function Open-ShellInCurrentConsole {",
        )
        cls.path_helper = text_region(
            "function New-CryptographicLaunchTempPath {",
            "function Invoke-AgentInCurrentConsole {",
        )
        cls.script_builder = text_region(
            "    $linuxScript = @(",
            "    $encodedScript = ",
        )

    def test_temp_path_is_cryptographically_random_and_shell_safe(self):
        self.assertIn("[Security.Cryptography.RandomNumberGenerator]::Create()", self.path_helper)
        self.assertIn("New-Object byte[] 24", self.path_helper)
        self.assertIn("$_.ToString('x2')", self.path_helper)
        self.assertIn('return "/tmp/nono-launch-$token.sh"', self.path_helper)
        self.assertRegex(self.path_helper, r"/tmp/nono-launch-\$token\.sh")
        self.assertNotIn("Get-Random", self.path_helper)

    def test_creation_uses_utf8_base64_noclobber_and_mode_700(self):
        self.assertIn("[Text.Encoding]::UTF8.GetBytes($linuxScript)", self.launch)
        self.assertIn("umask 077; set -C;", self.launch)
        self.assertIn("base64 -d", self.launch)
        self.assertIn("chmod 700 $temporaryLinuxPath", self.launch)
        bootstrap = re.search(r'\$createBootstrap = "([^"]+)"', self.launch).group(1)
        self.assertNotIn('"', bootstrap)
        self.assertIn(
            "bash -c $createBootstrap",
            self.launch,
        )
        self.assertNotIn("bash -c $createBootstrap bash $encodedScript $temporaryLinuxPath", self.launch)
        self.assertNotIn("printf %s $1", self.launch)
        self.assertNotIn("chmod 700 $2", self.launch)

    def test_creation_exit_is_checked_before_credentialed_launch(self):
        capture = self.launch.index("$creationExitCode = $LASTEXITCODE")
        check = self.launch.index("if ($creationExitCode -ne 0)")
        launch = self.launch.index("Invoke-WithCredentialEnvironment")
        self.assertLess(capture, check)
        self.assertLess(check, launch)

    def test_launch_bash_argv_is_simple_and_excludes_generated_command(self):
        argv = text_region(
            "        $bashArguments = @('-l')",
            "        Invoke-WithCredentialEnvironment",
        )
        self.assertIn("$bashArguments += '-i'", argv)
        self.assertIn("$bashArguments += $temporaryLinuxPath", argv)
        self.assertNotIn("$linuxScript", argv)
        self.assertNotIn("$quotedLaunch", argv)
        self.assertNotIn("'-c'", argv)
        self.assertIn("bash @bashArguments", self.launch)

    def test_script_self_deletes_before_exec_and_finally_cleans_up(self):
        self.assertLess(self.script_builder.index('rm -f -- \"$0\"'),
                        self.script_builder.index('"exec $quotedLaunch"'))
        self.assertIn("rm -f -- $temporaryLinuxPath", self.launch)
        self.assertRegex(
            self.launch,
            r"finally \{\n(?:.|\n)*?try \{ \$null = & wsl\.exe .*? rm -f -- \$temporaryLinuxPath",
        )

    def test_cleanup_covers_creation_and_launch_failures(self):
        outer_try = self.launch.index("    try {\n        # The bootstrap")
        creation = self.launch.index("bash -c $createBootstrap", outer_try)
        launch = self.launch.index("bash @bashArguments", creation)
        cleanup = self.launch.index("    finally {", launch)
        self.assertLess(outer_try, creation)
        self.assertLess(creation, launch)
        self.assertLess(launch, cleanup)
        self.assertIn("catch { }", self.launch[cleanup:])

    def test_credential_is_neither_embedded_nor_printed_by_transport(self):
        for forbidden in ("CredentialVariable", "$plain", "PROXY_API_KEY", "Write-Host $encodedScript"):
            self.assertNotIn(forbidden, self.script_builder)
        self.assertIn("Invoke-WithCredentialEnvironment", self.launch)
        self.assertNotIn("Write-Host $linuxScript", self.launch)
        self.assertNotIn("Write-Host $temporaryLinuxPath", self.launch)

    def test_ascii_quotes_and_semicolons_survive_base64_round_trip(self):
        sample = (
            "#!/usr/bin/env bash\n"
            "rm -f -- \"$0\" || { printf '%s\\n' 'cleanup failed'; exit 21; }\n"
            "exec 'nono' 'run' '--profile' 'vendor/profile' -- 'agent' "
            "'single'\"'\"'quote' 'semi;colon' 'spaces stay'\n"
        )
        encoded = base64.b64encode(sample.encode("utf-8")).decode("ascii")
        self.assertRegex(encoded, r"^[A-Za-z0-9+/]+={0,2}$")
        self.assertEqual(sample, base64.b64decode(encoded).decode("utf-8"))
        self.assertIn("[Convert]::ToBase64String", self.launch)


if __name__ == "__main__":
    unittest.main(verbosity=2)
