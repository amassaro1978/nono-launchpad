#!/usr/bin/env python3
"""Static release checks for the OpenCode-only PowerShell/WPF launchpad."""

from pathlib import Path
import ntpath
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "Nono-Launchpad.ps1").read_text(encoding="utf-8")
README = (ROOT / "README.md").read_text(encoding="utf-8")
XAML_MATCH = re.search(r"\[xml\]\$xaml = @'\n(.*?)\n'@", SCRIPT, re.S)


def region(start: str, end: str) -> str:
    begin = SCRIPT.index(start)
    return SCRIPT[begin : SCRIPT.index(end, begin)]


class LaunchpadStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if XAML_MATCH is None:
            raise AssertionError("embedded XAML here-string not found")
        cls.xaml_text = XAML_MATCH.group(1)
        cls.xaml = ET.fromstring(cls.xaml_text)
        cls.wpf = "{http://schemas.microsoft.com/winfx/2006/xaml/presentation}"
        cls.xname = "{http://schemas.microsoft.com/winfx/2006/xaml}Name"
        cls.names = {item.attrib.get(cls.xname) for item in cls.xaml.iter()}

    def test_opencode_is_the_only_agent_and_artifact(self):
        config = region("# =========================== EDIT SETTINGS HERE", "# ========================= END EDIT SETTINGS HERE")
        agents = config.split("Agents            = [ordered]@{", 1)[1]
        self.assertEqual(re.findall(r"^        '([^']+)' = @\{$", agents, re.M), ["OpenCode"])
        self.assertIn("DefaultAgent      = 'OpenCode'", config)
        self.assertEqual(config.count("NonoArguments = @('--allow-cwd')"), 1)
        combined = (SCRIPT + "\n" + README).lower()
        self.assertNotIn("clau" + "de", combined)
        self.assertNotIn("co" + "dex", combined)
        self.assertNotIn("agentcombo", combined)
        self.assertNotIn("projectroot", combined)
        self.assertNotIn("create a project", combined)

    def test_only_two_jsonc_remote_files_exist(self):
        config = region("RemoteFiles       = [ordered]@{", "    Agents            = [ordered]@{")
        entries = re.findall(
            r"^        '([^']+)' = @\{\n            Url = '([^']*)'\n            Destination = '([^']+)'\n        \}$",
            config,
            re.M,
        )
        self.assertEqual(
            entries,
            [
                ("OpenCode nono profile", "", "~/.config/nono/profiles/opencode.jsonc"),
                ("OpenCode config", "", "~/.config/opencode/opencode.jsonc"),
            ],
        )
        self.assertIn("$Config.RemoteFiles.Count -ne 2", SCRIPT)
        self.assertIn("must use HTTPS without embedded credentials", SCRIPT)

    def test_one_display_name_variable_drives_visible_branding(self):
        self.assertEqual(SCRIPT.count("$DisplayName = 'Nono Launchpad'"), 1)
        self.assertNotIn('Title="Nono Launchpad"', self.xaml_text)
        self.assertNotIn('Text="Nono Launchpad"', self.xaml_text)
        for marker in (
            "$window.Title = $DisplayName",
            "$BrandHeading.Text = $DisplayName",
            "$DisplayName launch failed",
            "$DisplayName shell failed",
            '"About $DisplayName"',
            '"$DisplayName - $HelperMode"',
            "$dialog.Title = \"$DisplayName",
        ):
            self.assertIn(marker, SCRIPT)
        self.assertIn("Version $DisplayVersion", SCRIPT)
        self.assertIn("technical identifiers", README.lower())

    def test_browse_and_persistent_ten_entry_history(self):
        self.assertTrue({"ProjectCombo", "ProjectValidationText", "BrowseButton", "RefreshButton"} <= self.names)
        combo = next(x for x in self.xaml.iter() if x.attrib.get(self.xname) == "ProjectCombo")
        self.assertEqual(combo.attrib.get("IsEditable"), "True")
        self.assertIn("System.Windows.Forms.OpenFileDialog", SCRIPT)
        self.assertIn("$dialog.ValidateNames = $false", SCRIPT)
        self.assertIn("$dialog.CheckFileExists = $false", SCRIPT)
        self.assertNotIn("System.Windows.Forms.FolderBrowserDialog", SCRIPT)
        self.assertIn("ProjectHistoryFile = Join-Path $env:LOCALAPPDATA 'NonoLaunchpad\\projects.json'", SCRIPT)
        self.assertEqual(SCRIPT.count("$ProjectHistoryLimit = 10"), 1)
        self.assertIn("System.Collections.Generic.HashSet[string]", SCRIPT)
        self.assertIn("[StringComparer]::OrdinalIgnoreCase", SCRIPT)
        self.assertIn("Save-ProjectHistory -Paths $valid.ToArray()", SCRIPT)
        history = region("function Save-ProjectHistory {", "function Invoke-WslScriptText {")
        self.assertIn("Select-Object -First $ProjectHistoryLimit", history)
        self.assertIn("if ($valid.Count -eq $ProjectHistoryLimit) { break }", history)
        self.assertIn("$needsRewrite = $true", history)
        self.assertIn("Move-Item -LiteralPath $temporary -Destination $Config.ProjectHistoryFile -Force", history)
        self.assertIn("uniquely named sibling temporary file", README)
        self.assertIn("at most 10 valid entries", README)
        self.assertIn("Test-Path -LiteralPath $lexical -PathType Container", SCRIPT)
        self.assertIn("$ProjectValidationText.Text = $projectMessage", SCRIPT)

    def test_windows_and_unc_paths_are_canonicalized_then_proved_in_wsl(self):
        resolver = region("function Resolve-WindowsProjectPath {", "function ConvertTo-WslProjectPath {")
        self.assertIn("[Environment]::ExpandEnvironmentVariables", resolver)
        self.assertIn("[IO.Path]::GetFullPath", resolver)
        self.assertIn("GetFinalDirectoryPath", resolver)
        self.assertRegex(resolver, r"A-Za-z\]:\[\\\\/\].*\\\\\\\\")
        converter = region("function ConvertTo-WslProjectPath {", "function Save-ProjectHistory {")
        self.assertIn("wslpath -a -u --", converter)
        self.assertIn("findmnt -rn -S", converter)
        self.assertIn("escaped_unc=", converter)
        self.assertIn("shopt -s nocasematch", converter)
        self.assertIn("not mounted in WSL", converter)
        self.assertIn('[ -d "`$linux_path" ]', converter)
        self.assertIn("[Convert]::ToBase64String", converter)
        launch = region("function Invoke-AgentInCurrentConsole {", "function Open-ShellInCurrentConsole {")
        self.assertLess(launch.index("Resolve-WindowsProjectPath"), launch.index("ConvertTo-WslProjectPath"))
        self.assertIn("cd -- ' + (ConvertTo-BashLiteral $wslPath)", launch)

    def test_sensitive_path_policy_and_bypass_defenses(self):
        roots = region("function Get-SensitiveWindowsRoots {", "function Resolve-WindowsProjectPath {")
        for value in (
            "'C:\\'",
            "'C:\\Windows'",
            "'C:\\Program Files'",
            "'C:\\Program Files (x86)'",
            "'C:\\ProgramData'",
            "'SystemRoot'",
            "'windir'",
            "'ProgramFiles'",
            "'ProgramFiles(x86)'",
            "'ProgramW6432'",
            "'ProgramData'",
        ):
            self.assertIn(value, roots)
        resolver = region("function Resolve-WindowsProjectPath {", "function ConvertTo-WslProjectPath {")
        self.assertIn("$lexical", resolver)
        self.assertIn("$final", resolver)
        self.assertIn("foreach ($candidate in @($lexical, $final))", resolver)
        self.assertIn("OrdinalIgnoreCase", resolver)
        self.assertIn("TrimEnd('\\')", resolver)
        self.assertIn("GetFinalPathNameByHandle", SCRIPT)
        self.assertIn("Extended-device and device namespace paths are not accepted", resolver)
        self.assertIn("junction", README.lower())
        self.assertIn("reparse", README.lower())
        self.assertIn("cannot be used as projects", SCRIPT)

    def test_sync_has_install_compare_notice_decline_update_and_offline_paths(self):
        sync = region("function Invoke-OpenCodeFileOperation {", "function Invoke-OpenCodeSyncProbe {")
        for marker in (
            "if [ ! -e \"`$destination\" ]",
            "cmp -s --",
            "sha256sum --",
            "declined_file",
            "INSTALLED",
            "SAME",
            "CHANGED",
            "DECLINED",
            "OFFLINE",
            "UPDATED",
            "mktemp --tmpdir",
            "download validation failed",
            "cp -a --",
            'backup="`$destination.backup.`$stamp"',
            "mv -fT --",
            "atomic install failed",
            "atomic replace failed",
            "upstream changed during update",
        ):
            self.assertIn(marker, sync)
        self.assertTrue({"SyncNotice", "SyncNoticeText", "UpdateFilesButton", "KeepFilesButton"} <= self.names)
        self.assertIn("Repository versions changed for:", SCRIPT)
        self.assertIn("timestamped backup", SCRIPT)
        self.assertIn("same repository version does not prompt again", README)
        self.assertIn("Repository unavailable; existing local files are preserved. Launching offline.", SCRIPT)
        self.assertRegex(sync, re.compile(r'if ! mv -fT -- .*?atomic install failed', re.S))
        self.assertRegex(sync, re.compile(r'if ! mv -fT -- .*?atomic replace failed', re.S))
        self.assertIn("existing local files were preserved. Launching anyway", SCRIPT)

    def test_first_run_install_precedes_launch_and_direct_mode_preserves_changes(self):
        launch = region("function Invoke-AgentInCurrentConsole {", "function Open-ShellInCurrentConsole {")
        self.assertLess(launch.index("Invoke-OpenCodeSyncProbe"), launch.index("Invoke-GeneratedLinuxScript"))
        self.assertIn("keeping the existing local file", launch)
        probe = region("function Invoke-OpenCodeFileOperation {", "function Invoke-OpenCodeSyncProbe {")
        self.assertLess(probe.index('if [ ! -e "`$destination" ]'), probe.index("cmp -s --"))

    def test_layout_and_about_controls_exist(self):
        dock = self.xaml.find(f"{self.wpf}DockPanel")
        self.assertIsNotNone(dock)
        self.assertEqual(list(dock)[0].attrib[self.xname], "LaunchStatusArea")
        self.assertEqual(list(dock)[0].attrib["DockPanel.Dock"], "Bottom")
        self.assertEqual(list(dock)[1].tag, f"{self.wpf}ScrollViewer")
        self.assertTrue({"LaunchButton", "LaunchStatusText", "AboutButton", "OpenShellButton"} <= self.names)
        self.assertEqual(next(x for x in self.xaml.iter() if x.attrib.get(self.xname) == "LaunchButton").attrib["Content"], "Launch OpenCode")

    def test_slow_first_use_operations_render_a_busy_state(self):
        busy = region("function Set-UiBusy {", "function Select-ProjectDirectory {")
        self.assertIn("Dispatcher.Invoke", busy)
        self.assertIn("DispatcherPriority]::Render", busy)
        self.assertIn("[Windows.Input.Cursors]::Wait", busy)
        for message in (
            "Checking the selected folder and WSL access...",
            "Saving $($Config.CredentialVariable) securely...",
            "Credential saved. Refreshing readiness...",
            "Checking the project and repository before launch...",
        ):
            self.assertIn(message, SCRIPT)
        self.assertIn("$script:UiBusy", SCRIPT)
        self.assertIn("function Clear-ProjectResolutionCache", SCRIPT)
        for action in ("$RefreshButton.Add_Click", "$CheckButton.Add_Click", "$OpenFolderButton.Add_Click", "$OpenShellButton.Add_Click"):
            handler = SCRIPT[SCRIPT.index(action) : SCRIPT.index("})", SCRIPT.index(action)) + 2]
            self.assertIn("Clear-ProjectResolutionCache", handler)
        pending = region("function Complete-PendingLaunch", "$AboutButton.Add_Click")
        self.assertIn("Set-UiBusy $true", pending)
        self.assertIn("Set-UiBusy $false", pending)
        rendered = SCRIPT[SCRIPT.index("$window.Add_ContentRendered") :]
        self.assertIn("Set-UiBusy $true", rendered)
        self.assertIn("finally { Set-UiBusy $false }", rendered)
        self.assertIn("if ($null -ne $copy) { $copy.Dispose() }", SCRIPT)

    def test_powershell_source_is_ascii_for_windows_powershell_51(self):
        self.assertTrue(
            SCRIPT.isascii(),
            "Windows PowerShell 5.1 misparses UTF-8-without-BOM punctuation",
        )

    def test_public_source_has_no_obvious_secret_or_private_path(self):
        combined = SCRIPT + "\n" + README
        patterns = (
            r"(?i)(?:api[_-]?key|token|password)\s*[:=]\s*['\"][A-Za-z0-9_\-/+=]{20,}",
            "/" + "Users" + r"/[^/\s]+",
            "C:\\\\" + "Users" + r"\\[^\\\s]+",
            r"ghp_[A-Za-z0-9]{20,}",
        )
        for pattern in patterns:
            self.assertIsNone(re.search(pattern, combined), pattern)


class PolicyContractExamples(unittest.TestCase):
    """Executable examples for the case-insensitive separator-boundary policy."""

    @staticmethod
    def blocked(path: str) -> bool:
        value = ntpath.normpath(path).rstrip("\\").casefold()
        if value == "c:":
            return True
        roots = [r"c:\windows", r"c:\program files", r"c:\program files (x86)", r"c:\programdata"]
        return any(value == root or value.startswith(root + "\\") for root in roots)

    def test_denylist_case_dot_segment_trailing_separator_and_boundaries(self):
        denied = [
            "C:\\",
            r"c:\WINDOWS\\",
            r"C:\temp\..\Windows\System32",
            r"C:\PROGRAM FILES\Vendor",
            r"C:\Program Files (x86)\Tool",
            r"C:\ProgramData\.\Vendor",
        ]
        allowed = [r"C:\Projects\App", r"C:\WindowsOld\App", r"D:\Windows\App"]
        self.assertTrue(all(self.blocked(path) for path in denied))
        self.assertTrue(all(not self.blocked(path) for path in allowed))

    def test_ten_entry_recency_dedup_pruning_and_unc_history_contract(self):
        values = [
            r"C:\Projects\Newest",
            r"c:\projects\newest",
            r"C:\Projects\Missing",
            r"\\server\share\Repo",
        ] + [rf"D:\Projects\P{i}" for i in range(20)]
        seen, result = set(), []
        for value in values:
            canonical = ntpath.normpath(value)
            if canonical.casefold() == ntpath.normpath(r"C:\Projects\Missing").casefold():
                continue
            key = canonical.casefold()
            if key not in seen:
                seen.add(key)
                result.append(canonical)
            if len(result) == 10:
                break
        self.assertEqual(len(result), 10)
        self.assertEqual(result[0], r"C:\Projects\Newest")
        self.assertIn(r"\\server\share\Repo", result)
        self.assertNotIn(r"C:\Projects\Missing", result)
        self.assertNotIn(r"D:\Projects\P19", result)


if __name__ == "__main__":
    unittest.main(verbosity=2)
