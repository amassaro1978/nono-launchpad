# Nono Launchpad

`Nono-Launchpad.ps1` is a compact Windows PowerShell 5.1/WPF launchpad for WSL. It:

- stores the configured credential as a Windows DPAPI CurrentUser-encrypted blob;
- injects it only into the launched process tree through a configurable environment-variable name;
- creates and lists projects under `~/projects` in the WSL distro's native filesystem;
- opens a selected project's explicit `\\wsl.localhost\DISTRO\...` path in File Explorer, or opens a Linux shell;
- dynamically generates its agent list and readiness checks from one configuration mapping;
- supports separately quoted custom nono options and agent arguments without enabling any by default.

## Edit settings here

Near the top of `Nono-Launchpad.ps1`, find:

```text
EDIT SETTINGS HERE
```

All expected launchpad configuration is in that block.

### Credential variable

`PROXY_API_KEY` is only a placeholder default. Replace it with the actual environment-variable **name** when confirmed. Never place a credential value in the script.

```powershell
CredentialVariable = 'PROXY_API_KEY'
```

The GUI, status text, process environment, and `WSLENV` injection all derive from this setting.

The encrypted value is stored at:

```text
%LOCALAPPDATA%\NonoLaunchpad\credential.dpapi
```

### Agent shell initialization

Readiness and actual agent launch use the same Bash initialization mode:

```powershell
UseInteractiveAgentShell = $true
```

The default starts an interactive login shell, matching the environment that
works through **Open Shell**. This allows user startup files to supply the same
non-secret `PATH` customizations for readiness and launch. Set it to `$false`
only when the managed environment intentionally requires a minimal,
noninteractive login shell.

Interactive startup files may print banners or job-control warnings when a GUI
readiness check has no terminal. Readiness parses only private status markers
and ignores all unrelated startup output. A failed agent-environment check
reports only its exit code, not raw startup output. The launchpad does not
display or log `PATH` values or resolved executable locations.

### Configurable agent defaults

The included mappings are configurable defaults for common signed registry profiles. Validate every profile name or path in the target environment before use.

```powershell
'Claude Code' = @{
    Profile = 'nolabs-ai/claude'
    Command = 'claude'
    NonoArguments = @()
    AgentArguments = @()
}
```

All included agents intentionally begin with empty `NonoArguments` and `AgentArguments`. No project-access, domain, model, or other runtime option is assumed.

Add or remove future agents only under `Config.Agents`. The GUI and readiness checks update automatically; no XAML or event-handler changes are required.

### Optional arguments

Each array element represents one argument. Keep separate arguments as separate array items.

Neutral example only:

```powershell
NonoArguments = @('--option-name', '{ENV:SERVICE_HOST}')
AgentArguments = @('--agent-option', 'example value')
```

Ordinary items are POSIX single-quoted. To intentionally expand an environment-backed argument, use the exact placeholder form:

```text
{ENV:VARIABLE_NAME}
```

The variable name is validated and rendered as one double-quoted Bash expansion:

```text
{ENV:SERVICE_HOST}  ->  "${SERVICE_HOST}"
```

A plain `$SERVICE_HOST` item remains literal text and does not expand. The named variable must already exist in the WSL launch environment; the placeholder does not store or create its value.

The placeholder name must not equal `CredentialVariable`, case-insensitively. The launchpad rejects that configuration during startup and checks again during argument conversion. This prevents the stored credential from being expanded into command-line arguments where process inspection could expose it.

## Start the launchpad

Inspect the script before running it. If Windows marked a trusted downloaded copy as blocked, remove that mark only after inspection:

```powershell
Get-Content .\Nono-Launchpad.ps1
Unblock-File -LiteralPath .\Nono-Launchpad.ps1
```

Then run it under Windows PowerShell 5.1 without changing execution policy:

```powershell
powershell.exe -NoProfile -STA -File .\Nono-Launchpad.ps1
```

If organizational policy still prevents execution, use the approved signing or policy process.

Then:

1. Select **Set / Replace _configured-variable-name_** and enter the credential.
2. Create a project or select an existing folder under `~/projects`.
3. Select a configured agent.
4. Review **Readiness** and choose **Launch Selected Agent**.

The launch area remains docked at the bottom of the window. Its named status
banner states every current reason when launch is unavailable: missing
credential, distro, `nono`, selected agent executable, project selection, or a
profile that was checked and could not be resolved. The same reason is on the
disabled button's tooltip. Agent or project selection changes refresh the
banner immediately.

The main content scrolls independently above the launch area. The initial,
minimum, and maximum window dimensions are bounded by the current Windows work
area in display-independent units, so display scaling or a small laptop screen
does not make the launch status and button unreachable. Executable checks and
launches prepend `~/.local/bin` to the WSL `PATH`, matching common per-user
installs.

**Open Folder** is intended to open Windows File Explorer directly at the
selected Linux-native project. It constructs the selected distro's WSL UNC
path explicitly; opening Explorer itself is expected, but landing at a generic
Explorer view is not.

The launch opens in Windows Terminal when `wt.exe` is available, otherwise in a separate Windows PowerShell console.

For Launch only, the helper transfers the generated non-secret Bash program as
UTF-8 base64 into a cryptographically named file under WSL `/tmp`, sets mode
`700`, and starts Bash with only login/interactive flags and that file path.
The shell-safe base64 payload and random path are placed directly in the fixed
creation bootstrap because `wsl.exe` does not reliably preserve extra
positional arguments supplied after `bash -c` by Windows PowerShell 5.1.
The file removes itself before `exec nono`; the Windows helper also attempts
cleanup in a `finally` block. Creation must succeed before the agent starts.
Project listing/creation and **Open Shell** continue to use their existing
command transport and are not affected by this Launch-only path.

## Static checks

From the repository root, run:

```text
python3 -m unittest -v tests/test_static.py tests/test_launch_transport.py
```

These checks parse the embedded XAML and guard the responsive layout, named
launch-status controls, direct agent/profile readiness checks, folder
targeting, Launch-only script transport, unchanged project/Open Shell regions,
and security-sensitive defaults. They do not replace a Windows PowerShell
5.1/WPF/WSL runtime test.

## Credential behavior

The encrypted blob can only be decrypted through Windows DPAPI in the same account context. The helper decrypts it in memory, sets the configured process-scoped variable, and imports that variable into WSL through `WSLENV`.

The credential is inherited by the WSL Bash interactive login-shell startup
process **before nono launches**. Bash startup files loaded in that path—such
as system profiles, the account's selected login profile, interactive startup
files sourced by that profile, and scripts those files source—can read the
inherited environment. Those startup files are part of the trusted boundary
and must be protected from untrusted modification.

The value remains process-environment-only: it is not written into the WSL
command line, temporary Bash script, startup files, GUI, readiness output, or
shell-mode configuration. It is nevertheless present in the
environment of Bash, its startup processing, nono, the launched tool, and
descendant processes.

For deployment, security must decide whether DPAPI-file storage is acceptable or whether Windows Credential Manager or an enterprise secret broker is required.

To remove the stored credential, close all launchpad and agent windows and delete the DPAPI file. The launchpad intentionally has no reset or delete button.

## Profile validation and runtime compatibility

No launch options are active by default. Depending on the selected profile, nono may prompt for project access or require additional approved options.

A green readiness result confirms only that the distro, configured executable,
and resolvable profile are present. It does not certify the profile's effective
permissions or runtime behavior. Validate each profile strictly, review its
effective filesystem and network policy, and perform a real read/write launch
test for every configured agent before deployment.

Readiness checks each configured profile directly with `nono profile show`.

Executable and profile probes are advisory rather than hard launch gates.
Shell startup behavior can make command discovery report a false negative even
when a tool is available in the real launch environment. The Launch button is
enabled when the credential, distro, selected project, and configured agent
selection are valid. The launched terminal is the authoritative runtime test
and reports any genuine command or profile error.

If a launch fails, its terminal remains open and displays the generated command
structure plus the WSL/nono error before waiting for Enter. The command
structure contains profile, executable, and configured argument syntax but does
not contain the stored credential value, which remains environment-only.

## Safety choices

- Project names are limited to 1–64 characters: letters, numbers, `.`, `_`, and `-`; the first character must be alphanumeric.
- Projects remain in WSL ext4 under `~/projects`, not `/mnt/c`.
- No install, update, repair, overwrite-profile, delete-project, or reset-distro operation is included.
- No credential value is displayed or intentionally logged.
- The generated launch structure is:

  ```bash
  nono run --profile PROFILE NONO_ARGUMENTS -- COMMAND AGENT_ARGUMENTS
  ```
