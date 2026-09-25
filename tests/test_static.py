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

    def test_agent_and_profile_readiness_remain_direct(self):
        self.assertIn('export PATH="$HOME/.local/bin:$PATH"', SCRIPT)
        self.assertIn("command -v $commandLiteral", SCRIPT)
        self.assertIn("nono profile show $profileLiteral --json", SCRIPT)
        self.assertIn("$LaunchButton.IsEnabled = $blockers.Count -eq 0", SCRIPT)

    def test_command_and_profile_probes_are_advisory_not_hard_gates(self):
        self.assertIn("$blockers = New-Object System.Collections.Generic.List[string]", SCRIPT)
        self.assertIn("$warnings = New-Object System.Collections.Generic.List[string]", SCRIPT)
        self.assertIn("nono executable was not verified", SCRIPT)
        self.assertIn("agent executable", SCRIPT)
        self.assertIn("profile '", SCRIPT)
        blocker_adds = "\n".join(
            line for line in SCRIPT.splitlines() if "$blockers.Add(" in line
        )
        self.assertNotIn("nono executable", blocker_adds)
        self.assertNotIn("agent executable", blocker_adds)
        self.assertNotIn("profile '", blocker_adds)
        self.assertIn("Executable and profile probes are advisory", README)

    def test_readiness_launch_and_open_shell_share_interactive_login_mode(self):
        self.assertIn("UseInteractiveAgentShell = $true", SCRIPT)
        self.assertIn("function Get-BashCommandArguments", SCRIPT)
        self.assertIn("if ($UseAgentShell -and $Config.UseInteractiveAgentShell)", SCRIPT)
        self.assertIn("$arguments += '-i'", SCRIPT)
        self.assertGreaterEqual(SCRIPT.count("-UseAgentShell)"), 1)
        self.assertIn("-UseAgentShell\n            foreach ($line in $result)", SCRIPT)
        self.assertIn("if ($Config.UseInteractiveAgentShell) { $bashArguments += '-i' }", SCRIPT)
        self.assertIn("$bashArguments += $temporaryLinuxPath", SCRIPT)
        self.assertNotIn("-- bash -lc $linux", SCRIPT)

    def test_startup_chatter_is_ignored_without_path_diagnostics(self):
        marker = "__NONO_LAUNCHPAD_READINESS__"
        self.assertGreaterEqual(SCRIPT.count(marker), 6)
        self.assertIn("Only exact private markers are parsed", SCRIPT)
        self.assertNotIn("$lines.Add($line)", SCRIPT)
        self.assertIn('throw "WSL agent-environment check failed with exit code $LASTEXITCODE."', SCRIPT)
        combined = SCRIPT + "\n" + README
        for forbidden in ("type -a ", "command -V ", "which nono", 'Text = "PATH',
                          '$lines.Add("PATH', "Write-Host $env:PATH"):
            self.assertNotIn(forbidden, combined)
        self.assertRegex(README, r"does not\s+display or log `PATH`")

    def test_security_and_folder_invariants_remain(self):
        self.assertGreaterEqual(SCRIPT.count("NonoArguments = @()"), 3)
        self.assertGreaterEqual(SCRIPT.count("AgentArguments = @()"), 3)
        self.assertNotIn("-ExecutionPolicy Bypass", SCRIPT)
        self.assertIn("[Environment]::SetEnvironmentVariable($variableName, $plain, 'Process')", SCRIPT)
        self.assertIn("$parts += \"$variableName/u\"", SCRIPT)
        self.assertIn('$linuxPaths = @(Invoke-WslText', SCRIPT)
        self.assertIn('"\\\\wsl.localhost\\$($Config.Distro)"', SCRIPT)

    def test_failed_launch_stays_open_without_printing_credential(self):
        self.assertIn('Write-Host "Command structure: $quotedLaunch"', SCRIPT)
        self.assertIn('Write-Host "Launch failed: $($_.Exception.Message)"', SCRIPT)
        self.assertIn("[void](Read-Host)", SCRIPT)
        self.assertIn("The credential value was not printed", SCRIPT)
        self.assertNotIn('Write-Host $plain', SCRIPT)
        self.assertIn("terminal remains open", README)


if __name__ == "__main__":
    unittest.main(verbosity=2)
