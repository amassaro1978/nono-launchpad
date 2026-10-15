# Nono Launchpad

`Nono-Launchpad.ps1` is an **OpenCode-only** Windows PowerShell 5.1/WPF launcher for running OpenCode through Nono in WSL. It keeps the existing **Open Shell** utility and does not create or assume a `projects` directory in WSL.

## What it does

- launches only `OpenCode` with the local `opencode` Nono profile and `--allow-cwd`;
- uses the full Explorer-style picker, including its address bar and filename box, to browse to or paste an existing local-drive or UNC/network path;
- canonicalizes the directory, confirms that it exists, converts local paths with WSL `wslpath` (or resolves an existing WSL `drvfs` mount for UNC shares), verifies that WSL can access it, then launches from that directory;
- stores the 10 most recently used valid project folders, case-insensitively deduplicated, in `%LOCALAPPDATA%\NonoLaunchpad\projects.json`;
- preserves history across launches and prunes missing, inaccessible, or newly disallowed entries whenever history is loaded or refreshed;
- stores the configured credential with Windows DPAPI for the current user and imports it only into the launched process tree through `WSLENV`;
- safely synchronizes the OpenCode Nono profile and OpenCode configuration without unconditional overwrite;
- transfers generated Bash launch programs as UTF-8 base64 into cryptographically named mode-700 files, avoiding Windows PowerShell 5.1/`wsl.exe` multiline argument mangling.

## Branding

One clearly labeled variable near the top of the script controls the user-visible product name:

```powershell
$DisplayName = 'Nono Launchpad'
```

It is used for the window title and heading, dialog and error titles, About/version text, and helper-terminal title. Technical identifiers such as the `%LOCALAPPDATA%\NonoLaunchpad` storage directory and `NonoLaunchpad.NativePath` type remain stable.

## Configuration

Edit only the block marked `EDIT SETTINGS HERE`. `PROXY_API_KEY` is a placeholder **variable name**, not a secret value.

```powershell
CredentialVariable = 'PROXY_API_KEY'
```

`RemoteFiles` contains exactly two OpenCode files:

- `~/.config/nono/profiles/opencode.jsonc`
- `~/.config/opencode/opencode.jsonc`

Set each entry's `Url` to its approved raw repository HTTPS URL. Empty URLs disable synchronization. URLs must be HTTPS and may not contain embedded credentials. Authentication, if required, must use the WSL user's approved non-interactive curl configuration; the launchpad does not place credentials in URLs.

The sole agent mapping remains modular:

```powershell
'OpenCode' = @{
    Profile = 'opencode'
    Command = 'opencode'
    NonoArguments = @('--allow-cwd')
    AgentArguments = @()
}
```

Arguments are represented as separate array elements and shell-quoted individually. An exact `{ENV:NAME}` item expands a validated non-credential environment variable. The configured credential variable is explicitly prohibited from argv expansion.

## Project selection and path safety

Choose **Browse…** and select an existing Windows directory. The editable project dropdown also allows a previously used local or UNC path to be selected. A path is saved only after it passes Windows canonicalization and WSL accessibility checks.

The Browse button uses the standard Explorer-style file dialog rather than the legacy tree-only folder dialog. Navigate into the desired folder and choose **Open**, or paste a complete path such as `\\server\share\project` into the filename box. The temporary `Select this folder` filename is only a folder-selection marker and is never created.

Explorer sometimes returns that temporary marker with a filter suffix after navigating to a UNC share. The launchpad removes only that known marker before validation. Typing or leaving the project field no longer performs a network filesystem call; full existence and safety validation starts only after an explicit Browse, Launch, Open Folder, or Open Shell action, when progress is visible. Network path validation times out with a clear error instead of leaving the GUI waiting indefinitely.

Before save or launch, the script:

1. expands Windows environment variables;
2. requires an absolute drive or UNC path;
3. collapses dot segments with `Path.GetFullPath`;
4. requires an existing directory;
5. resolves the final filesystem path with `GetFinalPathNameByHandle`, covering symlink, junction, and reparse-point targets as far as Windows PowerShell 5.1 and the current account permit;
6. checks both the lexical and final path against the sensitive-path policy;
7. converts a drive-letter path with WSL `wslpath -a -u`, or locates a pre-existing `drvfs` mount for the UNC share, and verifies the resulting directory exists inside the configured distro.

The following are rejected with a clear safety message:

- the `C:\` root itself;
- `C:\Windows` and descendants;
- `C:\Program Files` and descendants;
- `C:\Program Files (x86)` and descendants;
- `C:\ProgramData` and descendants.

Relevant environment aliases such as `%SystemRoot%`, `%windir%`, `%ProgramFiles%`, `%ProgramW6432%`, `%ProgramFiles(x86)%`, and `%ProgramData%` are included. Comparisons are case-insensitive, tolerate trailing separators, and are repeated after final-path resolution to resist dot-segment and reparse-point bypasses. UNC paths remain supported but must exist in Windows and their share must already be mounted in WSL with `drvfs`. The launchpad deliberately does not elevate or create a persistent network mount. If no matching mount exists, it explains that requirement instead of passing the raw UNC path to `wslpath` and displaying its cryptic error.

Project history is a compact JSON array of canonical Windows path strings in newest-first order at `%LOCALAPPDATA%\NonoLaunchpad\projects.json`. It retains at most 10 valid entries. Canonically equivalent paths are deduplicated case-insensitively; selecting an existing entry moves it to the front; and stale, inaccessible, malformed, or newly disallowed entries are removed during load/refresh while older valid entries fill the available slots. Local-drive and UNC paths use the same rules.

History is persisted after a project passes Windows canonicalization and WSL accessibility checks when it is chosen through **Browse**, **Launch OpenCode**, or **Open Shell**. **Open Folder** only opens the already validated Windows path and does not start WSL. Loading or refreshing also persists any pruning or cap migration. Writes serialize the complete array to a uniquely named sibling temporary file and then replace `projects.json`, so an interrupted serialization cannot leave a partially written history file. Invalid JSON is treated as an empty history and repaired through the same replacement path.

## Safe OpenCode file synchronization

Synchronization is conservative and happens at launch (and as a non-destructive probe before Open Shell):

- **Missing local file:** download the repository copy to a restrictive temporary file in the destination directory, validate it as a non-empty JSONC-like regular file, then atomically install it with `mv -fT`.
- **Identical local and repository files:** continue silently.
- **Changed repository file:** show an in-launcher notice naming the changed files. Nothing is overwritten until the user chooses an action.
- **Update:** download again, validate the temporary file, confirm its SHA-256 still matches the prompted version, create a timestamped backup beside the local file, and atomically replace the destination.
- **Keep Existing:** preserve the local file and record the declined upstream SHA-256 under `~/.local/state/nono-launchpad/declined/`. The same repository version does not prompt again; a later upstream hash does.
- **Offline/repository/validation failure:** preserve every local file and continue launching. The GUI indicates offline fallback when detected.

A direct `-Mode Launch` or **Open Shell** invocation never overwrites customized files without a prior GUI Update decision. It installs a missing file, accepts an identical file, honors a declined hash, and otherwise warns while preserving the existing file.

## Credential and transport behavior

The credential is encrypted using DPAPI CurrentUser at:

```text
%LOCALAPPDATA%\NonoLaunchpad\credential.dpapi
```

At launch, the script decrypts it in memory, sets only the current process environment, adds the variable to `WSLENV` with `/u`, invokes WSL, restores the prior environment, and zeroes the unmanaged plaintext buffer. It is never written to a generated script, command line, GUI field, status output, or log.

Launch and **Open Shell** share the same safe transport. The generated non-secret Bash program is UTF-8 base64 encoded, written to a random `/tmp/nono-launch-….sh` path with mode `700`, self-deletes before final `exec`, and is also cleaned in a PowerShell `finally` block. This preserves the existing fix for PowerShell/WSL expansion of inner Bash variables and keeps Open Shell credential behavior aligned with OpenCode launch.

## Run

Inspect the script, then use Windows PowerShell 5.1 in STA mode:

```powershell
powershell.exe -NoProfile -STA -File .\Nono-Launchpad.ps1
```

1. Set the configured credential.
2. Browse to an existing Windows project folder.
3. Review readiness.
4. Choose **Launch OpenCode**.
5. If repository files changed, choose **Update** or **Keep Existing** in the launcher.

**Open Folder** opens the selected Windows directory. **Open Shell** opens a credentialed WSL login shell in the selected project (or the WSL home directory when no project is selected).

Folder validation, first WSL startup, DPAPI storage, and repository checks can take several seconds on first use. During those synchronous checks the launchpad immediately displays the current operation, switches to a wait cursor, disables duplicate actions, and forces the busy state to render before work begins. Repeated project-state refreshes reuse the last validation result while the selected text is unchanged.

## Verification

From the repository root:

```text
python3 -m unittest discover -s tests -v
python3 -m py_compile tests/test_static.py tests/test_launch_transport.py
```

The tests parse the embedded XAML and statically cover OpenCode-only configuration, branding, Browse/history behavior, Windows/UNC conversion, sensitive-path defenses, safe synchronization choices, offline fallback, DPAPI/WSLENV handling, Open Shell, and temporary-script transport. They do not replace a Windows PowerShell 5.1/WPF/WSL runtime test.
