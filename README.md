# Nono Launchpad

`Nono-Launchpad.ps1` is a compact Windows PowerShell 5.1/WPF launchpad for WSL. It:

- stores the configured credential as a Windows DPAPI CurrentUser-encrypted blob;
- injects it only into the launched process tree through a configurable environment-variable name;
- creates and lists projects under `~/projects` in the WSL distro's native filesystem;
- opens a selected project's explicit `\\wsl.localhost\DISTRO\...` path in File Explorer, or opens a credentialed Linux shell;
- dynamically generates its agent list and readiness checks from one configuration mapping;
- optionally refreshes exactly six files from configured HTTPS raw-file URLs before agent launch or Open Shell;
- enables `--allow-cwd` for each included nono agent mapping and supports separately quoted custom arguments.

## Edit settings here

Near the top of `Nono-Launchpad.ps1`, find:

```text
EDIT SETTINGS HERE
```

All expected launchpad configuration is in that block.

The initial agent selection is controlled explicitly rather than by mapping order:

```powershell
DefaultAgent = 'OpenCode'
```

The value must exactly match one display name under `Config.Agents`.

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

Agent launch and **Open Shell** use the same Bash initialization mode:

```powershell
UseInteractiveAgentShell = $true
```

The default starts an interactive login shell, matching the environment that
works through **Open Shell**. This allows user startup files to supply the same
non-secret `PATH` customizations for shell and launch. Set it to `$false`
only when the managed environment intentionally requires a minimal,
noninteractive login shell.

The GUI readiness panel checks only prerequisites it can verify reliably:
distro registration and credential configuration. Executable and profile
validation happens in the real interactive Launch terminal, which remains open
on failure. The launchpad does not display or log `PATH` values or resolved
executable locations.

### Configurable agent defaults

The included mappings target the three local profiles refreshed before launch. Their names match the JSONC filenames under `~/.config/nono/profiles/` without the `.jsonc` extension.

```powershell
'Claude Code' = @{
    Profile = 'claude'
    Command = 'claude'
    NonoArguments = @('--allow-cwd')
    AgentArguments = @()
}
```

All included agents set `NonoArguments = @('--allow-cwd')` so the selected
`~/projects/...` working directory is available inside nono. Their
`AgentArguments` arrays remain empty. No domain, model, or other runtime option
is assumed.

Add or remove future agents only under `Config.Agents`. The GUI and readiness checks update automatically; no XAML or event-handler changes are required.

### Session-time remote files

`Config.RemoteFiles` contains exactly six entries: one nono profile and one
agent configuration for each of Claude, Codex, and OpenCode. Every URL and
destination is configured in the **EDIT SETTINGS HERE** block. URLs are empty
by default, so all six refreshes are disabled until deployment-specific raw
internal-Git HTTPS URLs are supplied.

```powershell
'Claude nono profile' = @{
    Url = ''
    Destination = '~/.config/nono/profiles/claude.jsonc'
}
```

The three Nono profile destinations are `claude.jsonc`, `codex.jsonc`, and
`opencode.jsonc`. OpenCode's application config is separately refreshed at
`~/.config/opencode/opencode.jsonc`; the Claude and Codex application configs
remain `~/.claude/settings.json` and `~/.codex/config.toml`.

Keep destinations below `~/`; the launchpad resolves that prefix against the
home directory of the explicitly configured `LinuxUser` (default: `nono`). Every
operational WSL call passes `-u LinuxUser` rather than trusting the distro's
default user. Do not embed usernames, tokens, or other credentials in a URL. If the internal Git service requires authentication,
configure an approved non-interactive `curl` authentication mechanism for the
Linux user separately. `CurlConnectTimeoutSeconds` and `CurlMaxTimeSeconds` in
the same settings block bound how long each attempted refresh may delay startup.

Immediately before `nono` starts or **Open Shell** hands control to the user's
shell, the selected WSL process handles each non-empty URL independently. It
downloads to a restrictive `mktemp` file in the destination directory and
moves that file over the configured destination only after a successful HTTPS
download. A failed download, directory preparation, or move prints a warning,
removes any temporary file, preserves the existing destination when possible,
and does not prevent the agent or shell from starting. Empty URLs are skipped
silently. Whitespace-only URLs are rejected during startup. Redirects are
restricted to HTTPS, and the exact destination must be a file, not a directory.

The included agent mappings intentionally use the local profile names `claude`,
`codex`, and `opencode`. These deployment profiles may extend the corresponding
signed `nolabs-ai/*` packs while adding organization-specific policy. The packs
must therefore be installed for `LinuxUser`, and refreshed local profiles remain
the profiles selected for launch.

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
banner states every current structural reason when launch is unavailable:
missing credential, distro, configured agent selection, or project selection.
The same reason is on the disabled button's tooltip. Agent or project selection changes refresh the
banner immediately.

The main content scrolls independently above the launch area. The initial,
minimum, and maximum window dimensions are bounded by the current Windows work
area in display-independent units, so display scaling or a small laptop screen
does not make the launch status and button unreachable. Agent launches prepend
`~/.local/bin` to the WSL `PATH`, matching common per-user installs.

**Open Folder** is intended to open Windows File Explorer directly at the
selected Linux-native project. It constructs the selected distro's WSL UNC
path explicitly; opening Explorer itself is expected, but landing at a generic
Explorer view is not.

The launch opens in Windows Terminal when `wt.exe` is available, otherwise in a separate Windows PowerShell console.

For both Launch and **Open Shell**, the helper transfers the generated
non-secret Bash program as UTF-8 base64 into a cryptographically named file
under WSL `/tmp`, sets mode `700`, and starts Bash with only login/interactive
flags and that file path.
The shell-safe base64 payload and random path are placed directly in the fixed
creation bootstrap because Windows PowerShell 5.1 native-argument serialization
and `wsl.exe` command-shell handling do not reliably preserve a multiline
program supplied after `bash -c`. The extra parsing pass can remove quoting and
expand variables intended for the inner Bash program. In Open Shell, that made
`$directory` empty before `refresh_file` ran, so each of the six configured
refreshes reached `mkdir -p --` without an operand. Transferring the program as
file content leaves only shell-safe bootstrap text and the script path on the
Windows-to-WSL command line.
Each generated file removes itself before its final `exec` (`nono` or Bash);
the Windows helper also attempts cleanup in a `finally` block. Creation must
succeed before the requested operation starts.
The six configured refresh operations run from this script as the configured
`LinuxUser` after entering the selected project and immediately before `nono`
or the Open Shell handoff. For Claude Code launches, the same pre-sandbox
script also creates `/tmp/claude-$(id -u)`, rejects a symlink or a directory not
owned by the configured user, applies mode `700`, and verifies read, write, and
search access. This must happen before `nono run`: after a reboot clears `/tmp`,
the Claude profile cannot grant access to a path that does not yet exist when
Nono builds its sandbox. A stale path with unsafe ownership fails visibly
instead of invoking `sudo`, changing ownership, or weakening its permissions.
Project listing/creation remains unaffected by this transport. Using a script
file for Open Shell prevents Windows PowerShell 5.1 and `wsl.exe` argument
processing from expanding or dropping Bash variables in the multiline refresh
program. Both entry points use the same DPAPI decryption
and process-scoped `WSLENV` injection wrapper, so the configured credential is
available to refresh commands, the shell, and its descendants without being
placed in the command line or written to disk.

## Static checks

From the repository root, run:

```text
python3 -m unittest -v tests/test_static.py tests/test_launch_transport.py
```

These checks parse the embedded XAML and guard the responsive layout, named
launch-status controls, structural readiness checks, folder
targeting, launch/Open Shell remote-file fallback and atomic replacement
structure, shared temporary-script transport, Open Shell credential wrapping,
unchanged project-management regions, and security-sensitive defaults. They do
not replace a Windows PowerShell 5.1/WPF/WSL runtime test.

## Credential behavior

The encrypted blob can only be decrypted through Windows DPAPI in the same account context. The helper decrypts it in memory, sets the configured process-scoped variable, and imports that variable into WSL through `WSLENV`.

The credential is inherited by the WSL Bash interactive login-shell startup
process **before nono launches or an Open Shell session starts**. Bash startup
files loaded in that path—such
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

`--allow-cwd` is active for all three included agents. Depending on the
selected profile, nono may prompt for project access or require additional
approved options.

A green readiness result confirms only that the distro, credential, selected
project, and configured agent selection are structurally ready. It does not
certify executable or profile availability, effective permissions, or runtime
behavior. Validate each profile strictly, review its effective filesystem and
network policy, and perform a real read/write launch test for every configured
agent before deployment.

The Launch button is enabled when the credential, distro, selected project,
and configured agent selection are valid. The launched terminal is the
authoritative runtime test and reports any genuine executable or profile error.

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
