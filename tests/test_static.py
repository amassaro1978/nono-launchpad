#!/usr/bin/env python3
"""Static regression tests for the self-contained PowerShell/WPF launchpad."""

from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "Nono-Launchpad.ps1").read_text(encoding="utf-8")
README = (ROOT / "README.md").read_text(encoding="utf-8")
XAML_MATCH = re.search(r"\[xml\]\$xaml = @'\n(.*?)\n'@", SCRIPT, re.S)


class LaunchpadStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if XAML_MATCH is None:
            raise AssertionError("embedded XAML here-string not found")
        cls.xaml_text = XAML_MATCH.group(1)
        cls.xaml = ET.fromstring(cls.xaml_text)
        cls.wpf = "{http://schemas.microsoft.com/winfx/2006/xaml/presentation}"
        cls.xname = "{http://schemas.microsoft.com/winfx/2006/xaml}Name"

    def test_xaml_has_scrollable_content_and_docked_launch_area(self):
        dock = self.xaml.find(f"{self.wpf}DockPanel")
        self.assertIsNotNone(dock)
        children = list(dock)
        self.assertEqual(children[0].tag, f"{self.wpf}Border")
        self.assertEqual(children[0].attrib[self.xname], "LaunchStatusArea")
        self.assertEqual(children[0].attrib["DockPanel.Dock"], "Bottom")
        self.assertEqual(children[1].tag, f"{self.wpf}ScrollViewer")
        self.assertEqual(children[1].attrib[self.xname], "MainScrollViewer")
        self.assertEqual(children[1].attrib["VerticalScrollBarVisibility"], "Auto")

    def test_launch_status_controls_are_named_and_footer_is_removed(self):
        names = {element.attrib.get(self.xname) for element in self.xaml.iter()}
        self.assertTrue(
            {"LaunchStatusArea", "LaunchStatusBanner", "LaunchStatusText", "LaunchButton"}
            <= names
        )
        self.assertNotIn("FooterText", names)
        self.assertIn("TextWrapping", next(
            element.attrib
            for element in self.xaml.iter()
            if element.attrib.get(self.xname) == "LaunchStatusText"
        ))

    def test_window_is_bounded_to_windows_work_area(self):
        self.assertNotIn("MinHeight", self.xaml.attrib)
        self.assertNotIn("MinWidth", self.xaml.attrib)
        for marker in (
            "$workArea = [System.Windows.SystemParameters]::WorkArea",
            "$window.MaxHeight = $workArea.Height",
            "$window.MaxWidth = $workArea.Width",
            "$window.MinHeight = [Math]::Min(420.0, $workArea.Height)",
            "$window.MinWidth = [Math]::Min(640.0, $workArea.Width)",
            "$window.Height = [Math]::Min(680.0, $workArea.Height)",
            "$window.Width = [Math]::Min(880.0, $workArea.Width)",
        ):
            self.assertIn(marker, SCRIPT)

    def test_pack_inventory_is_absent(self):
        combined = SCRIPT + "\n" + README
        for marker in (
            "nono list --installed",
            "Installed nono packs",
            "Pack inventory",
            "pack_output",
        ):
            self.assertNotIn(marker, combined)

    def test_launch_reasons_are_visible_nonblank_and_reactive(self):
        self.assertIn('$LaunchStatusText.Text = "Launch unavailable: $reasonText"', SCRIPT)
        self.assertIn("$LaunchButton.ToolTip = $reasonText", SCRIPT)
        self.assertIn("Where-Object { -not [string]::IsNullOrWhiteSpace", SCRIPT)
        self.assertIn("readiness checks have not completed", SCRIPT)
        self.assertIn("$ProjectCombo.Add_SelectionChanged({ Update-ControlState })", SCRIPT)
        self.assertIn("$AgentCombo.Add_SelectionChanged({ Update-ControlState })", SCRIPT)
        for reason in (
            "save $($Config.CredentialVariable)",
            "WSL distro '$($Config.Distro)' is unavailable",
            "select a configured agent",
            "select a project",
        ):
            self.assertIn(reason, SCRIPT)

    def test_agent_and_profile_validation_is_deferred_to_real_launch(self):
        self.assertIn('export PATH="$HOME/.local/bin:$PATH"', SCRIPT)
        self.assertNotIn("command -v $commandLiteral", SCRIPT)
        self.assertNotIn("nono profile show $profileLiteral --json", SCRIPT)
        self.assertIn("Agent executable and profile: validated by Launch", SCRIPT)
        self.assertIn("Launch errors remain visible in the agent terminal", SCRIPT)
        self.assertIn("$LaunchButton.IsEnabled = $blockers.Count -eq 0", SCRIPT)

    def test_opencode_is_the_explicit_default_agent(self):
        self.assertIn("DefaultAgent      = 'OpenCode'", SCRIPT)
        self.assertIn("DefaultAgent must match a configured agent display name", SCRIPT)
        self.assertIn("$AgentCombo.SelectedItem = [string]$Config.DefaultAgent", SCRIPT)
        self.assertNotIn("$AgentCombo.SelectedIndex = 0", SCRIPT)
        self.assertIn("DefaultAgent = 'OpenCode'", README)

    def test_false_command_and_profile_probe_warnings_are_removed(self):
        self.assertIn("$blockers = New-Object System.Collections.Generic.List[string]", SCRIPT)
        self.assertNotIn("$warnings = New-Object System.Collections.Generic.List[string]", SCRIPT)
        self.assertNotIn("nono executable was not verified", SCRIPT)
        self.assertNotIn("was not verified", SCRIPT)
        blocker_adds = "\n".join(
            line for line in SCRIPT.splitlines() if "$blockers.Add(" in line
        )
        self.assertNotIn("nono executable", blocker_adds)
        self.assertNotIn("agent executable", blocker_adds)
        self.assertNotIn("profile '", blocker_adds)
        self.assertIn("authoritative runtime test", README)

    def test_launch_and_open_shell_share_interactive_login_mode(self):
        self.assertIn("UseInteractiveAgentShell = $true", SCRIPT)
        self.assertIn("function Get-BashCommandArguments", SCRIPT)
        self.assertIn("if ($UseAgentShell -and $Config.UseInteractiveAgentShell)", SCRIPT)
        self.assertIn("$arguments += '-i'", SCRIPT)
        self.assertIn("if ($Config.UseInteractiveAgentShell) { $bashArguments += '-i' }", SCRIPT)
        self.assertIn("$bashArguments += $temporaryLinuxPath", SCRIPT)
        self.assertIn("Get-BashCommandArguments -LinuxScript $linux -UseAgentShell", SCRIPT)
        self.assertNotIn("-- bash -lc $linux", SCRIPT)

    def test_open_shell_uses_credential_environment_wrapper(self):
        open_shell = SCRIPT.split("function Open-ShellInCurrentConsole {", 1)[1].split(
            "if ($Mode -eq 'Launch') {", 1
        )[0]
        wrapper = open_shell.index("Invoke-WithCredentialEnvironment {")
        wsl = open_shell.index("& wsl.exe -d $Config.Distro -- bash @bashArguments")
        self.assertLess(wrapper, wsl)
        self.assertNotIn("CredentialVariable", open_shell)
        self.assertNotIn("Write-Host", open_shell)
        self.assertRegex(
            README,
            r"same DPAPI\s+decryption and process-scoped `WSLENV` injection wrapper",
        )

    def test_open_shell_runs_the_same_refresh_before_shell_handoff(self):
        open_shell = SCRIPT.split("function Open-ShellInCurrentConsole {", 1)[1].split(
            "if ($Mode -eq 'Launch') {", 1
        )[0]
        self.assertIn("@(Get-RemoteRefreshScriptLines)", open_shell)
        assembly = open_shell.index("@(Get-RemoteRefreshScriptLines)")
        handoff = open_shell.index("@('exec bash -l')")
        wrapper = open_shell.index("Invoke-WithCredentialEnvironment {")
        execution = open_shell.index("bash @bashArguments")
        self.assertLess(assembly, handoff)
        self.assertLess(wrapper, execution)

    def test_readiness_avoids_shell_probe_and_path_diagnostics(self):
        self.assertNotIn("__NONO_LAUNCHPAD_READINESS__", SCRIPT)
        self.assertNotIn("Only exact private markers are parsed", SCRIPT)
        self.assertNotIn("$lines.Add($line)", SCRIPT)
        combined = SCRIPT + "\n" + README
        for forbidden in ("type -a ", "command -V ", "which nono", 'Text = "PATH',
                          '$lines.Add("PATH', "Write-Host $env:PATH"):
            self.assertNotIn(forbidden, combined)
        self.assertRegex(README, r"does not\s+display or log `PATH`")

    def test_security_and_folder_invariants_remain(self):
        self.assertEqual(SCRIPT.count("NonoArguments = @('--allow-cwd')"), 3)
        self.assertGreaterEqual(SCRIPT.count("AgentArguments = @()"), 3)
        self.assertNotIn("-ExecutionPolicy Bypass", SCRIPT)
        self.assertIn("[Environment]::SetEnvironmentVariable($variableName, $plain, 'Process')", SCRIPT)
        self.assertIn("$parts += \"$variableName/u\"", SCRIPT)
        self.assertIn('$linuxPaths = @(Invoke-WslText', SCRIPT)
        self.assertIn('"\\\\wsl.localhost\\$($Config.Distro)"', SCRIPT)

    def test_exactly_six_remote_files_are_configured_with_safe_disabled_defaults(self):
        config_block = SCRIPT.split(
            "# =========================== EDIT SETTINGS HERE", 1
        )[1].split("# ========================= END EDIT SETTINGS HERE", 1)[0]
        remote_block = config_block.split("RemoteFiles       = [ordered]@{", 1)[1].split(
            "    Agents            = [ordered]@{", 1
        )[0]
        entries = re.findall(
            r"^        '([^']+)' = @\{\n"
            r"            Url = '([^']*)'\n"
            r"            Destination = '([^']+)'\n"
            r"        \}$",
            remote_block,
            re.M,
        )
        self.assertEqual(len(entries), 6)
        self.assertEqual(sum("nono profile" in name for name, _, _ in entries), 3)
        self.assertEqual(
            {name for name, _, _ in entries if name.endswith(" config")},
            {"Claude config", "Codex config", "OpenCode config"},
        )
        self.assertTrue(all(url == "" for _, url, _ in entries))
        destinations = [destination for _, _, destination in entries]
        self.assertTrue(all(destination.startswith("~/") for destination in destinations))
        self.assertEqual(len(set(destinations)), 6)
        self.assertIn("if ($Config.RemoteFiles.Count -ne 6)", SCRIPT)
        self.assertIn("must use an HTTPS URL without embedded credentials", SCRIPT)
        self.assertIn("has a whitespace-only Url", SCRIPT)
        self.assertIn("CurlConnectTimeoutSeconds = 10", SCRIPT)
        self.assertIn("CurlMaxTimeSeconds = 60", SCRIPT)

    def test_remote_refresh_preserves_existing_files_on_failure(self):
        refresh = SCRIPT.split("function Get-RemoteRefreshScriptLines {", 1)[1].split(
            "function Invoke-AgentInCurrentConsole {", 1
        )[0]
        for marker in (
            "curl --fail --silent --show-error --location --connect-timeout $connectTimeout --max-time $maxTime",
            "--proto '=https' --proto-redir '=https'",
            "mktemp --tmpdir=\"$directory\"",
            "mv -fT -- \"$temporary\" \"$destination\"",
            "rm -f -- \"$temporary\"",
            "keeping existing file if present",
            "$Config.RemoteFiles.GetEnumerator()",
        ):
            self.assertIn(marker, refresh)
        self.assertNotIn("sudo", refresh)
        self.assertIn("[ -n \"$url\" ] || return 0", refresh)
        launch = SCRIPT.split("function Invoke-AgentInCurrentConsole {", 1)[1].split(
            "function Open-ShellInCurrentConsole {", 1
        )[0]
        script_builder = launch.split("    $linuxScript = @(", 1)[1].split(
            "    $encodedScript = ", 1
        )[0]
        self.assertLess(script_builder.index("cd `\"`$HOME/$root/$ProjectName`\""),
                        script_builder.index("$remoteRefreshLines"))
        self.assertLess(script_builder.index("$remoteRefreshLines"),
                        script_builder.index('"exec $quotedLaunch"'))
        self.assertLess(launch.index("Invoke-WithCredentialEnvironment"),
                        launch.index("bash @bashArguments"))

    def test_failed_launch_stays_open_without_printing_credential(self):
        self.assertIn('Write-Host "Command structure: $quotedLaunch"', SCRIPT)
        self.assertIn('Write-Host "Launch failed: $($_.Exception.Message)"', SCRIPT)
        self.assertIn("[void](Read-Host)", SCRIPT)
        self.assertIn("The credential value was not printed", SCRIPT)
        self.assertNotIn('Write-Host $plain', SCRIPT)
        self.assertIn("terminal remains open", README)


if __name__ == "__main__":
    unittest.main(verbosity=2)
