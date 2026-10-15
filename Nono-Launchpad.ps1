#requires -Version 5.1
<#
OpenCode-only Nono Launchpad for Windows PowerShell 5.1 and WSL.
Credentials remain DPAPI-encrypted and are imported into WSL only through the
current process environment and WSLENV. They are never placed in argv or files.
#>

[CmdletBinding()]
param(
    [ValidateSet('Gui', 'Launch', 'Shell')]
    [string]$Mode = 'Gui',
    [string]$Agent = 'OpenCode',
    [string]$ProjectPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Change this one value to rebrand every user-visible launchpad surface.
$DisplayName = 'Nono Launchpad'
$DisplayVersion = '1.0.0'
$ProjectHistoryLimit = 10

# =========================== EDIT SETTINGS HERE ==============================
$Config = @{
    Distro            = 'Nono-1-0-0'
    LinuxUser         = 'nono'
    DefaultAgent      = 'OpenCode'
    UseInteractiveAgentShell = $true
    CredentialVariable = 'PROXY_API_KEY'
    CredentialFile    = Join-Path $env:LOCALAPPDATA 'NonoLaunchpad\credential.dpapi'
    ProjectHistoryFile = Join-Path $env:LOCALAPPDATA 'NonoLaunchpad\projects.json'
    CurlConnectTimeoutSeconds = 10
    CurlMaxTimeSeconds = 60
    RemoteFiles       = [ordered]@{
        'OpenCode nono profile' = @{
            Url = ''
            Destination = '~/.config/nono/profiles/opencode.jsonc'
        }
        'OpenCode config' = @{
            Url = ''
            Destination = '~/.config/opencode/opencode.jsonc'
        }
    }
    Agents            = [ordered]@{
        'OpenCode' = @{
            Profile = 'opencode'
            Command = 'opencode'
            NonoArguments = @('--allow-cwd')
            AgentArguments = @()
        }
    }
}
# ========================= END EDIT SETTINGS HERE ============================

function Assert-Configuration {
    if ($Config.Distro -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw 'Unsafe Distro setting.' }
    if ($Config.LinuxUser -notmatch '^[a-z_][a-z0-9_-]{0,31}$') { throw 'Unsafe LinuxUser setting.' }
    if ($Config.UseInteractiveAgentShell -isnot [bool]) { throw 'UseInteractiveAgentShell must be true or false.' }
    if ($Config.CredentialVariable -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw 'CredentialVariable must be a valid environment-variable name.' }
    if ($Config.RemoteFiles.Count -ne 2) { throw 'RemoteFiles must contain exactly the OpenCode profile and config.' }
    if ($Config.Agents.Count -ne 1 -or -not $Config.Agents.Contains('OpenCode') -or $Config.DefaultAgent -ne 'OpenCode') {
        throw 'This release must contain only the OpenCode agent.'
    }
    foreach ($timeoutName in @('CurlConnectTimeoutSeconds','CurlMaxTimeSeconds')) {
        if ($Config[$timeoutName] -isnot [int] -or $Config[$timeoutName] -lt 1) { throw "$timeoutName must be a positive integer." }
    }
    if ($Config.CurlMaxTimeSeconds -lt $Config.CurlConnectTimeoutSeconds) { throw 'CurlMaxTimeSeconds cannot be shorter than CurlConnectTimeoutSeconds.' }
    $destinations = @{}
    foreach ($entry in $Config.RemoteFiles.GetEnumerator()) {
        foreach ($required in @('Url','Destination')) {
            if (-not $entry.Value.ContainsKey($required)) { throw "Remote file '$($entry.Key)' is missing $required." }
        }
        $url = [string]$entry.Value.Url
        if ($url -ne '' -and [string]::IsNullOrWhiteSpace($url)) { throw "Remote file '$($entry.Key)' has a whitespace-only Url." }
        if ($url -ne '') {
            $parsed = $null
            if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$parsed) -or $parsed.Scheme -ne 'https' -or $parsed.UserInfo) {
                throw "Remote file '$($entry.Key)' must use HTTPS without embedded credentials."
            }
        }
        $destination = [string]$entry.Value.Destination
        if ($destination -notmatch '^~/[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$' -or
            @($destination.Substring(2) -split '/' | Where-Object { $_ -in @('.','..') }).Count -gt 0) {
            throw "Remote file '$($entry.Key)' has an unsafe Destination."
        }
        if ($destinations.ContainsKey($destination)) { throw "Duplicate remote destination '$destination'." }
        $destinations[$destination] = $true
    }
    $agentConfig = $Config.Agents.OpenCode
    foreach ($required in @('Profile','Command','NonoArguments','AgentArguments')) {
        if (-not $agentConfig.ContainsKey($required)) { throw "OpenCode is missing $required." }
    }
    foreach ($argument in @($agentConfig.NonoArguments) + @($agentConfig.AgentArguments)) {
        if ($null -eq $argument -or ([string]$argument).IndexOf([char]0) -ge 0) { throw 'OpenCode contains an invalid argument.' }
        $text = [string]$argument
        $placeholder = [regex]::Match($text, '^\{ENV:([A-Za-z_][A-Za-z0-9_]*)\}$')
        if ($text -match '^\{ENV:' -and -not $placeholder.Success) { throw "Invalid environment placeholder: $text" }
        if ($placeholder.Success -and [StringComparer]::OrdinalIgnoreCase.Equals($placeholder.Groups[1].Value, [string]$Config.CredentialVariable)) {
            throw 'OpenCode cannot expand the configured credential into a command argument.'
        }
    }
}
Assert-Configuration

function ConvertTo-BashLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return "'" + $Value.Replace("'", "'`"'`"'") + "'"
}
function ConvertTo-BashArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $placeholder = [regex]::Match($Value, '^\{ENV:([A-Za-z_][A-Za-z0-9_]*)\}$')
    if ($placeholder.Success) {
        $name = $placeholder.Groups[1].Value
        if ([StringComparer]::OrdinalIgnoreCase.Equals($name, [string]$Config.CredentialVariable)) { throw 'The credential cannot be expanded into argv.' }
        return '"${' + $name + '}"'
    }
    if ($Value -match '^\{ENV:') { throw "Invalid environment placeholder: $Value" }
    return ConvertTo-BashLiteral $Value
}
function ConvertTo-PowerShellLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}
function Test-AgentConfigured {
    param([AllowNull()][string]$Name)
    return [StringComparer]::Ordinal.Equals($Name, 'OpenCode')
}

function Test-DistroRegistered {
    try {
        $names = @(& wsl.exe --list --quiet 2>$null) | ForEach-Object { ("$_" -replace "`0", '').Trim() }
        return $names -contains $Config.Distro
    }
    catch { return $false }
}
function Test-CredentialConfigured { return Test-Path -LiteralPath $Config.CredentialFile -PathType Leaf }
function Save-Credential {
    param([Parameter(Mandatory)][Security.SecureString]$SecureValue)
    if ($SecureValue.Length -lt 1) { throw 'The credential cannot be empty.' }
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $Config.CredentialFile) -Force)
    Set-Content -LiteralPath $Config.CredentialFile -Value (ConvertFrom-SecureString $SecureValue) -Encoding UTF8
}
function Get-StoredCredential {
    if (-not (Test-CredentialConfigured)) { throw "$($Config.CredentialVariable) has not been configured." }
    $encrypted = (Get-Content -LiteralPath $Config.CredentialFile -Raw).Trim()
    if (-not $encrypted) { throw 'The encrypted credential file is empty.' }
    return ConvertTo-SecureString -String $encrypted
}
function Invoke-WithCredentialEnvironment {
    param([Parameter(Mandatory)][scriptblock]$Action)
    $variableName = [string]$Config.CredentialVariable
    $secure = Get-StoredCredential
    $bstr = [IntPtr]::Zero; $plain = $null
    $previousValue = [Environment]::GetEnvironmentVariable($variableName, 'Process')
    $previousWslEnv = [Environment]::GetEnvironmentVariable('WSLENV', 'Process')
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [Environment]::SetEnvironmentVariable($variableName, $plain, 'Process')
        $parts = @()
        $pattern = '^' + [regex]::Escape($variableName) + '(?:/.*)?$'
        if ($previousWslEnv) { $parts = @($previousWslEnv -split ':' | Where-Object { $_ -and $_ -notmatch $pattern }) }
        $parts += "$variableName/u"
        [Environment]::SetEnvironmentVariable('WSLENV', ($parts -join ':'), 'Process')
        & $Action
    }
    finally {
        [Environment]::SetEnvironmentVariable($variableName, $previousValue, 'Process')
        [Environment]::SetEnvironmentVariable('WSLENV', $previousWslEnv, 'Process')
        $plain = $null
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if ($null -ne $secure) { $secure.Dispose() }
    }
}

function Initialize-FinalPathApi {
    if ('NonoLaunchpad.NativePath' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace NonoLaunchpad {
  public static class NativePath {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern uint GetFinalPathNameByHandle(SafeFileHandle file, StringBuilder path, uint length, uint flags);
    public static string GetFinalDirectoryPath(string path) {
      using (SafeFileHandle handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
        if (handle.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        StringBuilder buffer = new StringBuilder(32768);
        uint result = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
        if (result == 0 || result >= buffer.Capacity) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        string value = buffer.ToString();
        if (value.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) return @"\\" + value.Substring(8);
        if (value.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) return value.Substring(4);
        return value;
      }
    }
  }
}
'@
}
function Test-PathAtOrBelow {
    param([Parameter(Mandatory)][string]$Candidate, [Parameter(Mandatory)][string]$Root)
    $candidateValue = $Candidate.TrimEnd('\')
    $rootValue = $Root.TrimEnd('\')
    return [StringComparer]::OrdinalIgnoreCase.Equals($candidateValue, $rootValue) -or
        $candidateValue.StartsWith($rootValue + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Get-SensitiveWindowsRoots {
    $values = @('C:\', 'C:\Windows', 'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData')
    foreach ($name in @('SystemRoot','windir','ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { $values += $value }
    }
    return @($values | ForEach-Object {
        try { [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$_)).TrimEnd('\') }
        catch { $null }
    } | Where-Object { $_ } | Select-Object -Unique)
}
function Resolve-WindowsProjectPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOf([char]0) -ge 0 -or $Path -match '[\x00-\x1F]') {
        throw 'Select a valid Windows project directory.'
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if ($expanded.StartsWith('\\?\') -or $expanded.StartsWith('\\.\')) {
        throw 'Extended-device and device namespace paths are not accepted as project paths.'
    }
    if ($expanded -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)') {
        throw 'Project path must be an absolute local-drive or UNC/network path.'
    }
    try { $lexical = [IO.Path]::GetFullPath($expanded.Replace('/', '\')) }
    catch { throw 'The project path is not a valid Windows path.' }
    if (-not (Test-Path -LiteralPath $lexical -PathType Container)) { throw 'The selected project directory does not exist or is not accessible.' }
    Initialize-FinalPathApi
    try { $final = [NonoLaunchpad.NativePath]::GetFinalDirectoryPath($lexical).TrimEnd('\') }
    catch { throw "The selected project directory could not be canonicalized: $($_.Exception.Message)" }
    if ($final -match '^[A-Za-z]:$') { $final += '\' }
    foreach ($candidate in @($lexical, $final)) {
        foreach ($root in Get-SensitiveWindowsRoots) {
            $isDriveRoot = $root -match '^[A-Za-z]:$'
            $blocked = if ($isDriveRoot) {
                [StringComparer]::OrdinalIgnoreCase.Equals($candidate.TrimEnd('\'), $root)
            } else {
                Test-PathAtOrBelow -Candidate $candidate -Root $root
            }
            if ($blocked) {
                throw 'For safety, the C:\ root, Windows, Program Files, Program Files (x86), and ProgramData trees cannot be used as projects.'
            }
        }
    }
    return $final
}
function ConvertTo-WslProjectPath {
    param([Parameter(Mandatory)][string]$WindowsPath)
    if ($WindowsPath -match '^\\\\([^\\]+)\\([^\\]+)(?:\\(.*))?$') {
        # wslpath does not translate SMB UNC paths. Reuse a share that an
        # administrator has already exposed to this distro with drvfs rather
        # than trying to elevate or silently creating a persistent mount.
        $uncRoot = '\\' + $Matches[1] + '\' + $Matches[2]
        $relative = [string]$Matches[3]
        $encodedRoot = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($uncRoot))
        $encodedRelative = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($relative))
        $scriptText = @"
set -e
unc_root=`$(printf %s $encodedRoot | base64 -d)
relative=`$(printf %s $encodedRelative | base64 -d)
mount_target=`$(findmnt -rn -S "`$unc_root" -o TARGET 2>/dev/null | head -n 1)
if [ -z "`$mount_target" ]; then
  escaped_unc=`$(printf '%s' "`$unc_root" | sed 's/\\/\\\\/g')
  mount_target=`$(findmnt -rn -S "`$escaped_unc" -o TARGET 2>/dev/null | head -n 1)
fi
if [ -z "`$mount_target" ]; then
  shopt -s nocasematch
  while IFS=' ' read -r candidate_source candidate_target; do
    if [[ "`$candidate_source" == "`$unc_root" || "`$candidate_source" == "`$escaped_unc" ]]; then
      mount_target=`$(printf '%b' "`$candidate_target")
      break
    fi
  done < <(findmnt -rn -o SOURCE,TARGET 2>/dev/null)
fi
[ -n "`$mount_target" ] || { printf '%s\n' 'This network share is available in Windows but is not mounted in WSL. Mount the UNC share with drvfs (or select a drive-letter path that WSL can access), then try again.' >&2; exit 25; }
[ "`$(printf '%s' "`$mount_target" | cut -c 1)" = / ] || { printf '%s\n' 'WSL returned an invalid network-share mount target.' >&2; exit 25; }
relative=`$(printf '%s' "`$relative" | tr '\\' '/')
linux_path="`$mount_target"
[ -z "`$relative" ] || linux_path="`$mount_target/`$relative"
[ -d "`$linux_path" ] || { printf '%s\n' 'The project path is not accessible inside the existing WSL network-share mount.' >&2; exit 24; }
printf '%s\n' "`$linux_path"
"@
    }
    else {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($WindowsPath))
        $scriptText = @"
set -e
windows_path=`$(printf %s $encoded | base64 -d)
linux_path=`$(wslpath -a -u -- "`$windows_path")
[ -d "`$linux_path" ] || { printf '%s\n' 'The project path is not accessible inside WSL.' >&2; exit 24; }
printf '%s\n' "`$linux_path"
"@
    }
    $lines = @(Invoke-WslScriptText -LinuxScript $scriptText -UseCredential:$false)
    if ($lines.Count -ne 1 -or -not ([string]$lines[0]).StartsWith('/')) { throw 'WSL could not convert the project directory to one accessible Linux path.' }
    return [string]$lines[0]
}

function Save-ProjectHistory {
    param([string[]]$Paths)
    $directory = Split-Path -Parent $Config.ProjectHistoryFile
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $temporary = Join-Path $directory ('.projects.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $limitedPaths = @($Paths | Select-Object -First $ProjectHistoryLimit)
        ConvertTo-Json -InputObject $limitedPaths -Compress | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $Config.ProjectHistoryFile -Force
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } }
}
function Get-ProjectHistory {
    $inputPaths = @()
    $needsRewrite = $false
    if (Test-Path -LiteralPath $Config.ProjectHistoryFile -PathType Leaf) {
        try { $inputPaths = @((Get-Content -LiteralPath $Config.ProjectHistoryFile -Raw | ConvertFrom-Json)) }
        catch { $inputPaths = @(); $needsRewrite = $true }
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $valid = New-Object System.Collections.Generic.List[string]
    foreach ($path in $inputPaths) {
        try {
            $canonical = Resolve-WindowsProjectPath ([string]$path)
            if ($seen.Add($canonical)) { $valid.Add($canonical) }
            if ($valid.Count -eq $ProjectHistoryLimit) { break }
        }
        catch { }
    }
    if ($needsRewrite -or @($inputPaths).Count -ne $valid.Count -or ((@($inputPaths) -join "`n") -cne (($valid.ToArray()) -join "`n"))) { Save-ProjectHistory -Paths $valid.ToArray() }
    return $valid.ToArray()
}
function Add-ProjectHistory {
    param([Parameter(Mandatory)][string]$Path)
    $canonical = Resolve-WindowsProjectPath $Path
    $all = New-Object System.Collections.Generic.List[string]
    $all.Add($canonical)
    foreach ($existing in @(Get-ProjectHistory)) {
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals($canonical, $existing)) { $all.Add($existing) }
    }
    Save-ProjectHistory -Paths $all.ToArray()
    return $canonical
}

function Invoke-WslScriptText {
    param([Parameter(Mandatory)][string]$LinuxScript, [bool]$UseCredential = $true)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($LinuxScript))
    $bootstrap = "printf %s $encoded | base64 -d | bash"
    $runner = {
        $output = @(& wsl.exe -d $Config.Distro -u $Config.LinuxUser -- bash -c $bootstrap 2>&1)
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { throw (($output | Out-String).Trim()) }
        return @(($output | ForEach-Object { ([string]$_).TrimEnd() }) | Where-Object { $_ -ne '' })
    }
    if ($UseCredential) { return @(Invoke-WithCredentialEnvironment $runner) }
    return @(& $runner)
}
function New-CryptographicLaunchTempPath {
    $bytes = New-Object byte[] 24
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return '/tmp/nono-launch-' + (-join @($bytes | ForEach-Object { $_.ToString('x2') })) + '.sh'
}
function Invoke-GeneratedLinuxScript {
    param([Parameter(Mandatory)][string]$LinuxScript, [Parameter(Mandatory)][string]$OperationName, [switch]$UseAgentShell, [switch]$CheckExecutionExitCode)
    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($LinuxScript))
    $temporaryLinuxPath = New-CryptographicLaunchTempPath
    $createBootstrap = "umask 077; set -C; printf %s $encodedScript | base64 -d > $temporaryLinuxPath && chmod 700 $temporaryLinuxPath"
    try {
        & wsl.exe -d $Config.Distro -u $Config.LinuxUser -- bash -c $createBootstrap
        if ($LASTEXITCODE -ne 0) { throw "Could not create the temporary WSL script for $OperationName (exit code $LASTEXITCODE)." }
        $bashArguments = @('-l')
        if ($UseAgentShell -and $Config.UseInteractiveAgentShell) { $bashArguments += '-i' }
        $bashArguments += $temporaryLinuxPath
        Invoke-WithCredentialEnvironment {
            & wsl.exe -d $Config.Distro -u $Config.LinuxUser -- bash @bashArguments
            $exitCode = $LASTEXITCODE
            if ($CheckExecutionExitCode -and $exitCode -ne 0) { throw "$OperationName exited with code $exitCode." }
        }
    }
    finally {
        try { $null = & wsl.exe -d $Config.Distro -u $Config.LinuxUser -- rm -f -- $temporaryLinuxPath 2>$null } catch { }
    }
}

function Invoke-OpenCodeFileOperation {
    param([Parameter(Mandatory)]$Entry, [ValidateSet('Probe','Update','Decline')][string]$Action, [string]$ExpectedHash)
    $label = [string]$Entry.Key; $url = [string]$Entry.Value.Url
    if (-not $url) { return [pscustomobject]@{ Status='Disabled'; Label=$label; Hash=''; Detail='' } }
    $relative = ([string]$Entry.Value.Destination).Substring(2)
    $stateKeyBytes = [Text.Encoding]::UTF8.GetBytes($relative)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $stateKey = -join @($sha.ComputeHash($stateKeyBytes) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
    $qLabel = ConvertTo-BashLiteral $label; $qUrl = ConvertTo-BashLiteral $url; $qRelative = ConvertTo-BashLiteral $relative
    $connect = [int]$Config.CurlConnectTimeoutSeconds; $maximum = [int]$Config.CurlMaxTimeSeconds
    if ($Action -eq 'Decline') {
        if ($ExpectedHash -notmatch '^[a-f0-9]{64}$') { throw 'Invalid upstream hash for Keep Existing.' }
        $scriptText = @"
set -e
state_dir="`$HOME/.local/state/nono-launchpad/declined"
mkdir -p -- "`$state_dir"
temporary=`$(mktemp --tmpdir="`$state_dir" '.declined.XXXXXXXXXX')
printf '%s\n' '$ExpectedHash' > "`$temporary"
mv -fT -- "`$temporary" "`$state_dir/$stateKey.sha256"
printf '%s\t%s\t%s\n' DECLINED $qLabel '$ExpectedHash'
"@
    }
    else {
        $expectedCheck = ':'
        if ($Action -eq 'Update') {
            $expectedCheck = '[ "$upstream_hash" = ' + (ConvertTo-BashLiteral $ExpectedHash) + " ] || { printf '%s\\t%s\\t%s\\n' OFFLINE $qLabel 'upstream changed during update'; exit 0; }"
            $applyBlock = @"
if [ -e "`$destination" ]; then
  stamp=`$(date -u +%Y%m%dT%H%M%SZ); backup="`$destination.backup.`$stamp"; suffix=0
  while [ -e "`$backup" ]; do suffix=`$((suffix+1)); backup="`$destination.backup.`$stamp.`$suffix"; done
  cp -a -- "`$destination" "`$backup" || { printf '%s\t%s\t%s\n' OFFLINE $qLabel 'backup failed'; exit 0; }
fi
if ! mv -fT -- "`$temporary" "`$destination"; then
  printf '%s\t%s\t%s\n' OFFLINE $qLabel 'atomic replace failed'; exit 0
fi
rm -f -- "`$declined_file"
printf '%s\t%s\t%s\n' UPDATED $qLabel "`$upstream_hash"
exit 0
"@
        }
        else {
            $applyBlock = @"
if [ ! -e "`$destination" ]; then
  if ! mv -fT -- "`$temporary" "`$destination"; then
    printf '%s\t%s\t%s\n' OFFLINE $qLabel 'atomic install failed'; exit 0
  fi
  printf '%s\t%s\t%s\n' INSTALLED $qLabel "`$upstream_hash"
  exit 0
fi
if cmp -s -- "`$temporary" "`$destination"; then printf '%s\t%s\t%s\n' SAME $qLabel "`$upstream_hash"; exit 0; fi
if [ -f "`$declined_file" ] && [ "`$(cat -- "`$declined_file")" = "`$upstream_hash" ]; then
  printf '%s\t%s\t%s\n' DECLINED $qLabel "`$upstream_hash"; exit 0
fi
printf '%s\t%s\t%s\n' CHANGED $qLabel "`$upstream_hash"
exit 0
"@
        }
        $scriptText = @"
set -u
destination="`$HOME/$relative"; directory=`${destination%/*}
state_dir="`$HOME/.local/state/nono-launchpad/declined"; declined_file="`$state_dir/$stateKey.sha256"
mkdir -p -- "`$directory" "`$state_dir" || { printf '%s\t%s\t%s\n' OFFLINE $qLabel 'cannot prepare destination'; exit 0; }
temporary=`$(mktemp --tmpdir="`$directory" '.nono-launchpad-download.XXXXXXXXXX') || { printf '%s\t%s\t%s\n' OFFLINE $qLabel 'cannot create temporary file'; exit 0; }
trap 'rm -f -- "`$temporary"' EXIT
if ! curl --fail --silent --show-error --location --connect-timeout $connect --max-time $maximum --proto '=https' --proto-redir '=https' --output "`$temporary" -- $qUrl; then
  printf '%s\t%s\t%s\n' OFFLINE $qLabel 'repository unavailable'; exit 0
fi
if [ ! -s "`$temporary" ] || [ ! -f "`$temporary" ] || [ -L "`$temporary" ] || ! grep -q '[{}]' "`$temporary"; then
  printf '%s\t%s\t%s\n' OFFLINE $qLabel 'download validation failed'; exit 0
fi
upstream_hash=`$(sha256sum -- "`$temporary" | awk '{print `$1}')
$expectedCheck
$applyBlock
"@
    }
    try {
        $line = [string](@(Invoke-WslScriptText -LinuxScript $scriptText -UseCredential:$true) | Select-Object -Last 1)
        $parts = $line -split "`t", 3
        if ($parts.Count -lt 2) { throw 'Unexpected synchronization response.' }
        return [pscustomobject]@{ Status=$parts[0]; Label=$parts[1]; Hash=$(if ($parts.Count -gt 2 -and $parts[2] -match '^[a-f0-9]{64}$') { $parts[2] } else { '' }); Detail=$(if ($parts.Count -gt 2) { $parts[2] } else { '' }) }
    }
    catch { return [pscustomobject]@{ Status='Offline'; Label=$label; Hash=''; Detail=$_.Exception.Message } }
}
function Invoke-OpenCodeSyncProbe {
    $results = @()
    foreach ($entry in $Config.RemoteFiles.GetEnumerator()) { $results += Invoke-OpenCodeFileOperation -Entry $entry -Action Probe }
    return $results
}
function Set-OpenCodeSyncDecision {
    param([Parameter(Mandatory)][object[]]$Changes, [ValidateSet('Update','Decline')][string]$Action)
    $results = @()
    foreach ($change in $Changes) {
        $entry = $Config.RemoteFiles.GetEnumerator() | Where-Object { [string]$_.Key -eq [string]$change.Label } | Select-Object -First 1
        if ($null -eq $entry) { throw "Unknown synchronized file '$($change.Label)'." }
        $results += Invoke-OpenCodeFileOperation -Entry $entry -Action $Action -ExpectedHash ([string]$change.Hash)
    }
    return $results
}

function Get-OpenCodeCommand {
    $agentConfig = $Config.Agents.OpenCode
    $parts = @((ConvertTo-BashLiteral 'nono'),(ConvertTo-BashLiteral 'run'),(ConvertTo-BashLiteral '--profile'),(ConvertTo-BashLiteral ([string]$agentConfig.Profile)))
    $parts += @($agentConfig.NonoArguments | ForEach-Object { ConvertTo-BashArgument ([string]$_) })
    $parts += @((ConvertTo-BashLiteral '--'),(ConvertTo-BashLiteral ([string]$agentConfig.Command)))
    $parts += @($agentConfig.AgentArguments | ForEach-Object { ConvertTo-BashArgument ([string]$_) })
    return $parts -join ' '
}
function Invoke-AgentInCurrentConsole {
    param([Parameter(Mandatory)][string]$AgentName, [Parameter(Mandatory)][string]$WindowsProjectPath)
    if (-not (Test-AgentConfigured $AgentName)) { throw 'This release supports OpenCode only.' }
    if (-not (Test-DistroRegistered)) { throw "WSL distribution '$($Config.Distro)' is not registered." }
    $canonical = Resolve-WindowsProjectPath $WindowsProjectPath
    $wslPath = ConvertTo-WslProjectPath $canonical
    [void](Add-ProjectHistory $canonical)
    $sync = @(Invoke-OpenCodeSyncProbe)
    foreach ($item in $sync | Where-Object { $_.Status -in @('Changed','Offline') }) { Write-Warning "$($item.Label): $($item.Status); keeping the existing local file." }
    $quotedLaunch = Get-OpenCodeCommand
    $linuxScript = @(
        '#!/usr/bin/env bash'
        'rm -f -- "$0" || { printf ''%s\n'' ''Unable to remove temporary launch script.'' >&2; exit 21; }'
        'export PATH="$HOME/.local/bin:$PATH"'
        'cd -- ' + (ConvertTo-BashLiteral $wslPath) + ' || exit 20'
        "exec $quotedLaunch"
    ) -join "`n"
    $linuxScript += "`n"
    Write-Host "Launching OpenCode in $canonical ..." -ForegroundColor Cyan
    Write-Host "Command structure: $quotedLaunch" -ForegroundColor DarkGray
    Invoke-GeneratedLinuxScript -LinuxScript $linuxScript -OperationName 'OpenCode' -UseAgentShell -CheckExecutionExitCode
}
function Open-ShellInCurrentConsole {
    param([string]$WindowsProjectPath)
    if (-not (Test-DistroRegistered)) { throw "WSL distribution '$($Config.Distro)' is not registered." }
    $changeDirectory = 'cd "$HOME" || exit 20'
    if ($WindowsProjectPath) {
        $canonical = Resolve-WindowsProjectPath $WindowsProjectPath
        $wslPath = ConvertTo-WslProjectPath $canonical
        [void](Add-ProjectHistory $canonical)
        $changeDirectory = 'cd -- ' + (ConvertTo-BashLiteral $wslPath) + ' || exit 20'
    }
    $sync = @(Invoke-OpenCodeSyncProbe)
    foreach ($item in $sync | Where-Object { $_.Status -in @('Changed','Offline') }) { Write-Warning "$($item.Label): $($item.Status); keeping the existing local file." }
    $linux = @('#!/usr/bin/env bash','rm -f -- "$0" || { printf ''%s\n'' ''Unable to remove temporary shell script.'' >&2; exit 21; }',$changeDirectory,'exec bash -l') -join "`n"
    Invoke-GeneratedLinuxScript -LinuxScript ($linux + "`n") -OperationName 'the WSL shell' -UseAgentShell
}

if ($Mode -eq 'Launch') {
    try { Invoke-AgentInCurrentConsole -AgentName $Agent -WindowsProjectPath $ProjectPath; exit 0 }
    catch {
        Write-Host ''; Write-Host "$DisplayName launch failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'The credential value was not printed. Press Enter to close this window.' -ForegroundColor Yellow
        [void](Read-Host); exit 1
    }
}
if ($Mode -eq 'Shell') {
    try { Open-ShellInCurrentConsole -WindowsProjectPath $ProjectPath; exit 0 }
    catch { Write-Error "$DisplayName shell failed: $($_.Exception.Message)"; exit 1 }
}

if ($env:OS -ne 'Windows_NT') { throw "$DisplayName must run on Windows." }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw "$DisplayName requires Windows PowerShell STA mode." }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
Initialize-FinalPathApi

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Height="650" Width="860" WindowStartupLocation="CenterScreen" Background="#F3F6FA" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <SolidColorBrush x:Key="Ink" Color="#172033"/><SolidColorBrush x:Key="Muted" Color="#5F6B7A"/><SolidColorBrush x:Key="Line" Color="#D9E1EA"/>
    <Style TargetType="Button"><Setter Property="MinHeight" Value="34"/><Setter Property="Padding" Value="14,4"/><Setter Property="Margin" Value="4"/></Style>
    <Style TargetType="ComboBox"><Setter Property="MinHeight" Value="34"/><Setter Property="Padding" Value="7,4"/></Style>
    <Style x:Key="Card" TargetType="Border"><Setter Property="Background" Value="White"/><Setter Property="BorderBrush" Value="{StaticResource Line}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="8"/><Setter Property="Padding" Value="18"/></Style>
  </Window.Resources>
  <DockPanel>
    <Border x:Name="LaunchStatusArea" DockPanel.Dock="Bottom" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="20,12">
      <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock x:Name="LaunchStatusText" TextWrapping="Wrap" VerticalAlignment="Center" Foreground="#35516E"/>
        <Button x:Name="LaunchButton" Grid.Column="1" Content="Launch OpenCode" MinWidth="170" Background="#2563A6" Foreground="White" FontWeight="SemiBold"/>
      </Grid>
    </Border>
    <ScrollViewer x:Name="MainScrollViewer" VerticalScrollBarVisibility="Auto">
      <StackPanel Margin="24,20">
        <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <StackPanel><TextBlock x:Name="BrandHeading" FontSize="25" FontWeight="SemiBold" Foreground="{StaticResource Ink}"/><TextBlock Text="Open OpenCode safely in an existing Windows project through Nono and WSL." Foreground="{StaticResource Muted}" Margin="0,4,0,0"/></StackPanel>
          <Button x:Name="AboutButton" Grid.Column="1" Content="About"/>
        </Grid>
        <Border Style="{StaticResource Card}" Margin="0,16,0,0"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <StackPanel><TextBlock x:Name="CredentialHeading" FontWeight="SemiBold" FontSize="15"/><TextBlock x:Name="CredentialStatus" Margin="0,7,0,0"/><TextBlock Text="Encrypted for this Windows account with DPAPI; never displayed." Foreground="{StaticResource Muted}" Margin="0,4,0,0"/></StackPanel>
          <Button x:Name="SetKeyButton" Grid.Column="1" VerticalAlignment="Center"/>
        </Grid></Border>
        <Border Style="{StaticResource Card}" Margin="0,14,0,0"><StackPanel>
          <TextBlock Text="Project" FontWeight="SemiBold" FontSize="15"/><TextBlock Text="Choose an existing local-drive or UNC/network directory." Foreground="{StaticResource Muted}" Margin="0,4,0,10"/>
          <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <ComboBox x:Name="ProjectCombo" IsEditable="True" IsTextSearchEnabled="False"/>
            <Button x:Name="BrowseButton" Grid.Column="1" Content="Browse..."/>
            <Button x:Name="RefreshButton" Grid.Column="2" Content="Prune / Refresh"/>
          </Grid>
          <TextBlock x:Name="ProjectValidationText" Foreground="#B03A2E" TextWrapping="Wrap" Margin="0,6,0,0"/>
          <TextBlock Text="Agent" FontWeight="SemiBold" Margin="0,14,0,4"/><TextBlock Text="OpenCode"/>
          <StackPanel Orientation="Horizontal" Margin="0,12,0,0"><Button x:Name="OpenFolderButton" Content="Open Folder"/><Button x:Name="OpenShellButton" Content="Open Shell"/></StackPanel>
        </StackPanel></Border>
        <Border x:Name="SyncNotice" Style="{StaticResource Card}" Margin="0,14,0,0" Background="#FFF4E5" Visibility="Collapsed"><StackPanel>
          <TextBlock Text="OpenCode configuration update available" FontWeight="SemiBold"/><TextBlock x:Name="SyncNoticeText" TextWrapping="Wrap" Margin="0,5,0,8"/>
          <StackPanel Orientation="Horizontal"><Button x:Name="UpdateFilesButton" Content="Update"/><Button x:Name="KeepFilesButton" Content="Keep Existing"/></StackPanel>
        </StackPanel></Border>
        <Border Style="{StaticResource Card}" Margin="0,14,0,0"><StackPanel><TextBlock Text="Readiness" FontWeight="SemiBold" FontSize="15"/><TextBox x:Name="StatusText" IsReadOnly="True" Height="100" Margin="0,8,0,0" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas"/><Button x:Name="CheckButton" Content="Check Again" HorizontalAlignment="Right"/></StackPanel></Border>
      </StackPanel>
    </ScrollViewer>
  </DockPanel>
</Window>
'@
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$window.Title = $DisplayName
$window.MaxHeight = [System.Windows.SystemParameters]::WorkArea.Height
$window.MaxWidth = [System.Windows.SystemParameters]::WorkArea.Width
$BrandHeading = $window.FindName('BrandHeading'); $BrandHeading.Text = $DisplayName
$names = @('CredentialHeading','CredentialStatus','SetKeyButton','ProjectCombo','ProjectValidationText','BrowseButton','RefreshButton','OpenFolderButton','OpenShellButton','SyncNotice','SyncNoticeText','UpdateFilesButton','KeepFilesButton','StatusText','CheckButton','LaunchStatusArea','LaunchStatusText','LaunchButton','AboutButton')
foreach ($name in $names) { Set-Variable -Name $name -Value $window.FindName($name) -Scope Script }
$CredentialHeading.Text = "Credential: $($Config.CredentialVariable)"
$SetKeyButton.Content = "Set / Replace $($Config.CredentialVariable)"
$script:Readiness = @{ Distro=$false }; $script:PendingChanges=@(); $script:PendingLaunchPath=$null
$script:UiBusy=$false; $script:LastProjectInput=$null; $script:LastProjectCanonical=$null; $script:LastProjectError=$null

function Show-LaunchpadError { param([string]$Message) [void][Windows.MessageBox]::Show($window, $Message, $DisplayName, 'OK', 'Error') }
function Get-SelectedProjectPath { return [string]$ProjectCombo.Text }
function Resolve-SelectedProjectCached {
    $inputPath = Get-SelectedProjectPath
    if ([string]::IsNullOrWhiteSpace($inputPath)) { throw 'Select an existing project directory.' }
    if ([StringComparer]::Ordinal.Equals($inputPath, [string]$script:LastProjectInput)) {
        if ($script:LastProjectError) { throw $script:LastProjectError }
        return [string]$script:LastProjectCanonical
    }
    $script:LastProjectInput = $inputPath; $script:LastProjectCanonical = $null; $script:LastProjectError = $null
    try { $script:LastProjectCanonical = Resolve-WindowsProjectPath $inputPath; return [string]$script:LastProjectCanonical }
    catch { $script:LastProjectError = $_.Exception.Message; throw }
}
function Clear-ProjectResolutionCache {
    $script:LastProjectInput=$null; $script:LastProjectCanonical=$null; $script:LastProjectError=$null
}
function Set-UiBusy {
    param([bool]$Busy, [string]$Message)
    $script:UiBusy = $Busy
    $window.Cursor = if ($Busy) { [Windows.Input.Cursors]::Wait } else { $null }
    foreach ($control in @($SetKeyButton,$BrowseButton,$RefreshButton,$CheckButton,$OpenFolderButton,$OpenShellButton,$LaunchButton,$UpdateFilesButton,$KeepFilesButton,$ProjectCombo)) {
        if ($null -ne $control) { $control.IsEnabled = -not $Busy }
    }
    if ($Busy -and $Message) { $LaunchStatusText.Text = $Message }
    # Synchronous filesystem, DPAPI, and WSL calls can take a few seconds on
    # first use. Paint the busy state before entering them so the UI never
    # appears to ignore the click.
    [void]$window.Dispatcher.Invoke([Action]{ $null = $window.Title }, [Windows.Threading.DispatcherPriority]::Render)
    if (-not $Busy) { Update-ControlState }
}
function Select-ProjectDirectory {
    # FolderBrowserDialog is a tree-only picker and has no usable address box.
    # OpenFileDialog provides the full Explorer surface (address bar, Network,
    # and a filename box where a UNC path can be pasted). The sentinel turns it
    # into a folder picker while retaining Windows PowerShell 5.1 compatibility.
    $sentinel = 'Select this folder'
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "$DisplayName - Select an existing project directory"
    $dialog.Filter = 'Folders|*.folder'
    $dialog.FileName = $sentinel
    $dialog.CheckFileExists = $false; $dialog.CheckPathExists = $true
    $dialog.ValidateNames = $false; $dialog.AddExtension = $false
    $dialog.DereferenceLinks = $true; $dialog.RestoreDirectory = $true; $dialog.AutoUpgradeEnabled = $true
    $current = Get-SelectedProjectPath
    if ($current -and (Test-Path -LiteralPath $current -PathType Container)) { $dialog.InitialDirectory = $current }
    try {
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        $chosen = [string]$dialog.FileName
        if ([IO.Path]::GetFileName($chosen) -eq $sentinel) { $chosen = [IO.Path]::GetDirectoryName($chosen) }
        return $chosen
    }
    finally { $dialog.Dispose() }
}
function Refresh-Projects {
    $selected = Get-SelectedProjectPath
    $ProjectCombo.Items.Clear()
    foreach ($path in @(Get-ProjectHistory)) { [void]$ProjectCombo.Items.Add($path) }
    if ($selected) { $ProjectCombo.Text = $selected } elseif ($ProjectCombo.Items.Count -gt 0) { $ProjectCombo.SelectedIndex = 0 }
    Update-ControlState
}
function Test-SelectedProject {
    try { if (-not (Get-SelectedProjectPath)) { return $false }; [void](Resolve-WindowsProjectPath (Get-SelectedProjectPath)); return $true } catch { return $false }
}
function Update-ControlState {
    $projectOk = $false; $projectMessage = ''
    try {
        if (Get-SelectedProjectPath) { [void](Resolve-SelectedProjectCached); $projectOk = $true }
    }
    catch { $projectMessage = $_.Exception.Message }
    $ProjectValidationText.Text = $projectMessage
    $keyOk = Test-CredentialConfigured
    $blockers = New-Object System.Collections.Generic.List[string]
    if (-not $keyOk) { $blockers.Add("save $($Config.CredentialVariable)") }
    if (-not $script:Readiness.Distro) { $blockers.Add("WSL distro '$($Config.Distro)' is unavailable") }
    if (-not $projectOk) { $blockers.Add('select an existing, permitted project directory') }
    $LaunchButton.IsEnabled = (-not $script:UiBusy) -and $blockers.Count -eq 0
    $OpenFolderButton.IsEnabled = (-not $script:UiBusy) -and $projectOk
    $OpenShellButton.IsEnabled = -not $script:UiBusy
    $CredentialStatus.Text = if ($keyOk) { 'Configured' } else { 'Not configured' }
    $LaunchStatusText.Text = if ($LaunchButton.IsEnabled) { 'Ready to launch OpenCode.' } else { 'Launch unavailable: ' + ($blockers -join '; ') }
}
function Refresh-Readiness {
    $script:Readiness.Distro = Test-DistroRegistered
    $StatusText.Text = @("Distro $($Config.Distro): " + $(if ($script:Readiness.Distro) {'OK'} else {'MISSING'}), "Credential $($Config.CredentialVariable): " + $(if (Test-CredentialConfigured) {'CONFIGURED'} else {'NOT CONFIGURED'}), 'Agent: OpenCode only', 'Project: existing Windows local or UNC folder') -join [Environment]::NewLine
    Update-ControlState
}
function Start-HelperTerminal {
    param([ValidateSet('Launch','Shell')][string]$HelperMode, [string]$Path)
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $command = '$Host.UI.RawUI.WindowTitle = ' + (ConvertTo-PowerShellLiteral "$DisplayName - $HelperMode") + '; & ' + (ConvertTo-PowerShellLiteral $PSCommandPath) + ' -Mode ' + (ConvertTo-PowerShellLiteral $HelperMode)
    if ($HelperMode -eq 'Launch') { $command += " -Agent 'OpenCode'" }
    if ($Path) { $command += ' -ProjectPath ' + (ConvertTo-PowerShellLiteral $Path) }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    # PowerShell 5.1 Start-Process flattens ArgumentList before CreateProcess. These
    # fixed tokens and base64 payload contain no spaces or shell metacharacters.
    Start-Process -FilePath $powershell -ArgumentList @('-NoLogo','-NoProfile','-EncodedCommand',$encoded)
}
function Complete-PendingLaunch { param([ValidateSet('Update','Decline')][string]$Decision)
    $path = $script:PendingLaunchPath
    try {
        $busyMessage = if ($Decision -eq 'Update') { 'Updating OpenCode files...' } else { 'Keeping existing OpenCode files...' }
        Set-UiBusy $true $busyMessage
        $results = @(Set-OpenCodeSyncDecision -Changes $script:PendingChanges -Action $Decision)
        $expectedStatus = if ($Decision -eq 'Update') { 'Updated' } else { 'Declined' }
        if (@($results | Where-Object { $_.Status -ne $expectedStatus }).Count -gt 0) {
            $LaunchStatusText.Text = 'The repository action could not be completed for every file; existing local files were preserved. Launching anyway.'
        }
    }
    catch {
        $LaunchStatusText.Text = 'The repository is unavailable; existing local files were preserved. Launching anyway.'
    }
    finally {
        $script:PendingChanges=@(); $script:PendingLaunchPath=$null; $SyncNotice.Visibility='Collapsed'
        Set-UiBusy $false
    }
    if ($path) { Start-HelperTerminal -HelperMode Launch -Path $path }
}

$AboutButton.Add_Click({ [void][Windows.MessageBox]::Show($window, "$DisplayName`nVersion $DisplayVersion`nOpenCode-only WSL launcher", "About $DisplayName", 'OK', 'Information') })
$SetKeyButton.Add_Click({
    try {
        $dialog = New-Object Windows.Window; $dialog.Title = "$DisplayName - Set $($Config.CredentialVariable)"; $dialog.Width=480; $dialog.Height=210; $dialog.Owner=$window; $dialog.WindowStartupLocation='CenterOwner'; $dialog.ResizeMode='NoResize'
        $panel=New-Object Windows.Controls.StackPanel; $panel.Margin=20
        $label=New-Object Windows.Controls.TextBlock; $label.Text="Enter $($Config.CredentialVariable). It will be DPAPI-encrypted and never displayed."; $label.TextWrapping='Wrap'
        $box=New-Object Windows.Controls.PasswordBox; $box.Margin='0,12,0,12'; $box.MinHeight=30
        $save=New-Object Windows.Controls.Button; $save.Content='Save'; $save.HorizontalAlignment='Right'; $save.IsDefault=$true
        [void]$panel.Children.Add($label); [void]$panel.Children.Add($box); [void]$panel.Children.Add($save); $dialog.Content=$panel
        $save.Add_Click({
            if ($box.SecurePassword.Length -lt 1) { return }
            $save.IsEnabled=$false; $label.Text="Saving $($Config.CredentialVariable) securely..."; $dialog.Cursor=[Windows.Input.Cursors]::Wait
            [void]$dialog.Dispatcher.Invoke([Action]{ $null=$dialog.Title }, [Windows.Threading.DispatcherPriority]::Render)
            $copy=$null
            $copy=$box.SecurePassword.Copy()
            try { Save-Credential $copy; $dialog.DialogResult=$true }
            catch { $save.IsEnabled=$true; $dialog.Cursor=$null; $label.Text=$_.Exception.Message }
            finally { if ($null -ne $copy) { $copy.Dispose() } }
        })
        $saved = $dialog.ShowDialog()
        if ($saved) { Set-UiBusy $true 'Credential saved. Refreshing readiness...'; Refresh-Readiness }
    } catch { Show-LaunchpadError $_.Exception.Message }
    finally { Set-UiBusy $false }
})
$BrowseButton.Add_Click({
    try {
        $selected = Select-ProjectDirectory
        if ($selected) {
            Set-UiBusy $true 'Checking the selected folder and WSL access...'
            $canonical = Resolve-WindowsProjectPath $selected
            $ProjectCombo.Text=$canonical; $script:LastProjectInput=$canonical; $script:LastProjectCanonical=$canonical; $script:LastProjectError=$null
            [void](ConvertTo-WslProjectPath $canonical); [void](Add-ProjectHistory $canonical); Refresh-Projects
        }
    } catch { Show-LaunchpadError $_.Exception.Message }
    finally { Set-UiBusy $false }
})
$RefreshButton.Add_Click({ try { Set-UiBusy $true 'Pruning and refreshing saved projects...'; Clear-ProjectResolutionCache; Refresh-Projects } catch { Show-LaunchpadError $_.Exception.Message } finally { Set-UiBusy $false } })
$CheckButton.Add_Click({ try { Set-UiBusy $true 'Checking WSL and saved settings...'; Clear-ProjectResolutionCache; Refresh-Readiness; Refresh-Projects } catch { Show-LaunchpadError $_.Exception.Message } finally { Set-UiBusy $false } })
$ProjectCombo.Add_SelectionChanged({ Update-ControlState }); $ProjectCombo.Add_LostFocus({ Update-ControlState })
$OpenFolderButton.Add_Click({ try { Clear-ProjectResolutionCache; $path=Resolve-SelectedProjectCached; Start-Process -FilePath explorer.exe -ArgumentList ('/e,"{0}"' -f $path) } catch { Show-LaunchpadError $_.Exception.Message } })
$OpenShellButton.Add_Click({ try { Set-UiBusy $true 'Checking the project and opening WSL...'; Clear-ProjectResolutionCache; $path=$null; if (Get-SelectedProjectPath) { $path=Resolve-SelectedProjectCached; [void](ConvertTo-WslProjectPath $path); [void](Add-ProjectHistory $path) }; Start-HelperTerminal -HelperMode Shell -Path $path } catch { Show-LaunchpadError $_.Exception.Message } finally { Set-UiBusy $false } })
$LaunchButton.Add_Click({
    try {
        Set-UiBusy $true 'Checking the project and repository before launch...'
        Clear-ProjectResolutionCache; $path=Resolve-SelectedProjectCached; [void](ConvertTo-WslProjectPath $path); [void](Add-ProjectHistory $path)
        $probe=@(Invoke-OpenCodeSyncProbe); $changes=@($probe | Where-Object { $_.Status -eq 'Changed' })
        if ($changes.Count -gt 0) {
            $script:PendingChanges=$changes; $script:PendingLaunchPath=$path
            $SyncNoticeText.Text = "Repository versions changed for: " + (($changes | ForEach-Object {$_.Label}) -join ', ') + ". Update replaces local customizations after making a timestamped backup. Keep Existing preserves local files and suppresses this version's prompt."
            $SyncNotice.Visibility='Visible'; return
        }
        $offline=@($probe | Where-Object { $_.Status -eq 'Offline' })
        if ($offline.Count -gt 0) { $LaunchStatusText.Text='Repository unavailable; existing local files are preserved. Launching offline.' }
        Start-HelperTerminal -HelperMode Launch -Path $path
    } catch { Show-LaunchpadError $_.Exception.Message }
    finally { Set-UiBusy $false }
})
$UpdateFilesButton.Add_Click({ Complete-PendingLaunch -Decision Update })
$KeepFilesButton.Add_Click({ Complete-PendingLaunch -Decision Decline })
$window.Add_ContentRendered({
    try { Set-UiBusy $true 'Checking WSL and loading saved projects...'; Clear-ProjectResolutionCache; Refresh-Readiness; Refresh-Projects }
    catch { Show-LaunchpadError $_.Exception.Message }
    finally { Set-UiBusy $false }
})
[void]$window.ShowDialog()
