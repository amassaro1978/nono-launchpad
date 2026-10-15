#!/usr/bin/env python3
"""Focused security and transport checks."""

import base64
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "Nono-Launchpad.ps1").read_text(encoding="utf-8")
README = (ROOT / "README.md").read_text(encoding="utf-8")


def region(start: str, end: str) -> str:
    begin = SCRIPT.index(start)
    return SCRIPT[begin : SCRIPT.index(end, begin)]


class LaunchTransportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.credential = region("function Invoke-WithCredentialEnvironment {", "function Initialize-FinalPathApi {")
        cls.path_conversion = region("function ConvertTo-WslProjectPath {", "function Save-ProjectHistory {")
        cls.transport = region("function Invoke-GeneratedLinuxScript {", "function Invoke-OpenCodeFileOperation {")
        cls.launch = region("function Invoke-AgentInCurrentConsole {", "function Open-ShellInCurrentConsole {")
        cls.shell = region("function Open-ShellInCurrentConsole {", "if ($Mode -eq 'Launch') {")

    def test_dpapi_and_wslenv_lifecycle_remain_intact(self):
        self.assertIn("ConvertFrom-SecureString $SecureValue", SCRIPT)
        self.assertIn("ConvertTo-SecureString -String $encrypted", SCRIPT)
        for marker in (
            "SecureStringToBSTR",
            "PtrToStringBSTR",
            "SetEnvironmentVariable($variableName, $plain, 'Process')",
            '$parts += "$variableName/u"',
            "SetEnvironmentVariable($variableName, $previousValue, 'Process')",
            "SetEnvironmentVariable('WSLENV', $previousWslEnv, 'Process')",
            "ZeroFreeBSTR",
            "$secure.Dispose()",
        ):
            self.assertIn(marker, self.credential)
        self.assertNotIn("Write-Host $plain", SCRIPT)

    def test_credential_cannot_be_expanded_into_argv(self):
        conversion = region("function ConvertTo-BashArgument {", "function ConvertTo-PowerShellLiteral {")
        self.assertIn("OrdinalIgnoreCase", conversion)
        self.assertIn("$Config.CredentialVariable", conversion)
        self.assertIn("cannot be expanded into argv", conversion)
        self.assertIn("cannot expand the configured credential", SCRIPT)

    def test_temp_path_is_random_and_shell_safe(self):
        helper = region("function New-CryptographicLaunchTempPath {", "function Invoke-GeneratedLinuxScript {")
        self.assertIn("RandomNumberGenerator", helper)
        self.assertIn("New-Object byte[] 24", helper)
        self.assertIn("ToString('x2')", helper)
        self.assertIn("/tmp/nono-launch-", helper)
        self.assertNotIn("Get-Random", helper)

    def test_creation_uses_base64_noclobber_mode_700_and_checks_exit(self):
        for marker in (
            "[Text.Encoding]::UTF8.GetBytes($LinuxScript)",
            "umask 077; set -C;",
            "base64 -d",
            "chmod 700 $temporaryLinuxPath",
            "if ($LASTEXITCODE -ne 0)",
        ):
            self.assertIn(marker, self.transport)
        bootstrap = re.search(r'\$createBootstrap = "([^"]+)"', self.transport).group(1)
        self.assertNotIn('"', bootstrap)
        self.assertNotIn("$LinuxScript", bootstrap)

    def test_generated_script_is_not_passed_through_bash_c(self):
        argv = self.transport[self.transport.index("$bashArguments = @('-l')") : self.transport.index("Invoke-WithCredentialEnvironment")]
        self.assertIn("$bashArguments += $temporaryLinuxPath", argv)
        self.assertNotIn("$LinuxScript", argv)
        self.assertNotIn("'-c'", argv)
        self.assertIn("bash @bashArguments", self.transport)

    def test_launch_and_shell_use_explicit_linux_user_and_shared_transport(self):
        self.assertGreaterEqual(SCRIPT.count("wsl.exe -d $Config.Distro -u $Config.LinuxUser --"), 3)
        self.assertIn("wsl.exe -d $Config.Distro -u $LinuxUser --", SCRIPT)
        self.assertIn("Invoke-GeneratedLinuxScript", self.launch)
        self.assertIn("Invoke-GeneratedLinuxScript", self.shell)
        self.assertIn("-UseAgentShell -CheckExecutionExitCode", self.launch)
        self.assertIn("-UseAgentShell", self.shell)
        self.assertIn("Invoke-OpenCodeSyncProbe", self.launch)
        self.assertIn("Invoke-OpenCodeSyncProbe", self.shell)

    def test_script_self_deletes_and_finally_cleans_up(self):
        self.assertIn('rm -f -- "$0"', self.launch)
        self.assertIn('rm -f -- "$0"', self.shell)
        self.assertIn("finally {", self.transport)
        self.assertIn("rm -f -- $temporaryLinuxPath", self.transport)
        self.assertIn("catch { }", self.transport)

    def test_command_shape_and_working_directory_access(self):
        command = region("function Get-OpenCodeCommand {", "function Invoke-AgentInCurrentConsole {")
        for value in ("'nono'", "'run'", "'--profile'", "'--'"):
            self.assertIn(value, command)
        self.assertIn("Profile = 'opencode'", SCRIPT)
        self.assertIn("Command = 'opencode'", SCRIPT)
        self.assertEqual(SCRIPT.count("NonoArguments = @('--allow-cwd')"), 1)
        self.assertIn("cd -- ' + (ConvertTo-BashLiteral $wslPath)", self.launch)
        self.assertNotIn("~/projects", SCRIPT)
        self.assertNotIn("mkdir -p -- `\"`$HOME", SCRIPT)

    def test_sync_urls_and_generated_scripts_never_embed_credentials(self):
        sync = region("function Invoke-OpenCodeFileOperation {", "function Invoke-OpenCodeSyncProbe {")
        self.assertIn("--proto '=https' --proto-redir '=https'", sync)
        self.assertIn("Invoke-WslScriptText", sync)
        self.assertNotIn("$plain", sync)
        self.assertNotIn("PROXY_API_KEY", sync)
        self.assertNotIn("CredentialVariable", self.launch)
        self.assertNotIn("CredentialVariable", self.shell)

    def test_base64_round_trip_preserves_special_characters(self):
        sample = "#!/usr/bin/env bash\ncd -- '/mnt/c/a b'\nexec 'nono' 'run' '--profile' 'opencode' '--allow-cwd' '--' 'opencode'\n"
        encoded = base64.b64encode(sample.encode()).decode()
        self.assertRegex(encoded, r"^[A-Za-z0-9+/]+={0,2}$")
        self.assertEqual(base64.b64decode(encoded).decode(), sample)

    def test_unc_mount_transport_preserves_spaces_and_backslashes(self):
        unc = r"\\server\Team Share"
        mount_path = "/mnt/nono-launchpad/a path with spaces"
        self.assertEqual(base64.b64decode(base64.b64encode(unc.encode())).decode(), unc)
        marker = "NONO_MOUNT:" + base64.b64encode(mount_path.encode()).decode()
        self.assertEqual(base64.b64decode(marker.removeprefix("NONO_MOUNT:")).decode(), mount_path)
        self.assertIn("mounted_source=`$(printf '%b'", self.path_conversion)
        self.assertIn("findmnt -rn -M", self.path_conversion)
        self.assertIn("-o FSTYPE", self.path_conversion)
        self.assertIn("NONO_MOUNT:%s", self.path_conversion)
        self.assertIn("FromBase64String", self.path_conversion)

    def test_helper_terminal_avoids_start_process_argument_flattening_bugs(self):
        helper = region("function Start-HelperTerminal {", "function Complete-PendingLaunch {")
        self.assertIn("$Host.UI.RawUI.WindowTitle", helper)
        self.assertIn("[Text.Encoding]::Unicode.GetBytes($command)", helper)
        self.assertIn("'-EncodedCommand'", helper)
        self.assertNotIn("wt.exe", helper)
        self.assertNotIn("'--title'", helper)

    def test_no_execution_policy_bypass_or_credential_logging(self):
        self.assertNotIn("-ExecutionPolicy Bypass", SCRIPT)
        self.assertNotIn("Write-Host $linuxScript", SCRIPT)
        self.assertNotIn("Write-Host $encodedScript", SCRIPT)
        self.assertIn("credential value was not printed", SCRIPT)
        self.assertIn("process environment", README)


if __name__ == "__main__":
    unittest.main(verbosity=2)
