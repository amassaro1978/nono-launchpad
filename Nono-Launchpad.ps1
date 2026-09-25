#requires -Version 5.1
<#
Nono Launchpad.

Security model:
- The configured credential is encrypted with Windows DPAPI for the current user.
- The plaintext value is never written to disk, placed in a command line, or logged.
- Launch mode decrypts it only long enough to place it in the launcher's process
  environment. WSL imports it through WSLENV for the lifetime of that process tree.
- The WSL Bash login-shell process and every startup file it loads inherit the
  credential before nono starts. Those startup files are part of the trusted boundary.
- The configured credential variable is prohibited in {ENV:NAME} arguments so
  its value cannot be intentionally expanded into the spawned command's argv.

This utility is not a credential broker. Review the accompanying README.
#>

[CmdletBinding()]
param(
    [ValidateSet('Gui', 'Launch', 'Shell')]
    [string]$Mode = 'Gui',

    [string]$Agent,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
    [string]$Project
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# =========================== EDIT SETTINGS HERE ==============================
# CredentialVariable is the *actual* environment-variable name expected by the
# agents/proxy. PROXY_API_KEY is only a configurable default; replace it here.
#
# Add/remove agents only in Agents. Each entry supports:
#   Profile       nono profile name or file path
#   Command       executable passed after nono's -- separator
#   NonoArguments additional nono options before -- (safe string array)
#   AgentArguments arguments passed to the executable (safe string array)
#
# Neutral examples (comments only; no options are active by default):
#   NonoArguments  = @('--option-name', '{ENV:SERVICE_HOST}')
#   AgentArguments = @('--agent-option', 'example value')
# Use an exact {ENV:VARIABLE_NAME} item when an argument must come from the
# launch environment. Plain '$VARIABLE_NAME' is intentionally passed literally.
# Arguments are individually shell-quoted; do not combine multiple arguments
# into one string.
$Config = @{
    Distro            = 'Ubuntu-24.04'
    ProjectRoot       = 'projects' # relative to the WSL user's $HOME
    CredentialVariable = 'PROXY_API_KEY'
    CredentialFile    = Join-Path $env:LOCALAPPDATA 'NonoLaunchpad\credential.dpapi'
    # Configurable defaults for common signed registry profiles.
    # Validate every profile name or path in the target environment.
    Agents            = [ordered]@{
        'Claude Code' = @{
            Profile = 'nolabs-ai/claude'
            Command = 'claude'
            NonoArguments = @()
            AgentArguments = @()
        }
        'Codex' = @{
            Profile = 'nolabs-ai/codex'
            Command = 'codex'
            NonoArguments = @()
            AgentArguments = @()
        }
        'OpenCode' = @{
            Profile = 'nolabs-ai/opencode'
            Command = 'opencode'
            NonoArguments = @()
            AgentArguments = @()
        }
        # 'Future Agent' = @{
        #     Profile = '/home/account/profile.json'
        #     Command = 'future-agent'
        #     NonoArguments = @()
        #     AgentArguments = @()
        # }
    }
}
# ========================= END EDIT SETTINGS HERE ============================

function Assert-Configuration {
    if ($Config.Distro -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw 'Unsafe Distro setting.' }
    if ($Config.ProjectRoot -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw 'Unsafe ProjectRoot setting.' }
    if ($Config.CredentialVariable -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw 'CredentialVariable must be a valid environment-variable name.' }
    if ($Config.Agents.Count -lt 1) { throw 'Configure at least one agent.' }

    foreach ($entry in $Config.Agents.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.Key)) { throw 'Agent display names cannot be empty.' }
        foreach ($required in @('Profile','Command','NonoArguments','AgentArguments')) {
            if (-not $entry.Value.ContainsKey($required)) { throw "Agent '$($entry.Key)' is missing $required." }
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.Value.Profile)) { throw "Agent '$($entry.Key)' has an empty Profile." }
        if ([string]::IsNullOrWhiteSpace([string]$entry.Value.Command)) { throw "Agent '$($entry.Key)' has an empty Command." }
        foreach ($argument in @($entry.Value.NonoArguments) + @($entry.Value.AgentArguments)) {
            if ($null -eq $argument -or ([string]$argument).IndexOf([char]0) -ge 0) { throw "Agent '$($entry.Key)' contains an invalid argument." }
            $text = [string]$argument
            $placeholder = [regex]::Match($text, '^\{ENV:([A-Za-z_][A-Za-z0-9_]*)\}$')
            if ($text -match '^\{ENV:' -and -not $placeholder.Success) {
                throw "Agent '$($entry.Key)' contains an invalid environment placeholder: $text"
            }
            if ($placeholder.Success -and [StringComparer]::OrdinalIgnoreCase.Equals($placeholder.Groups[1].Value, [string]$Config.CredentialVariable)) {
                throw "Agent '$($entry.Key)' cannot expand the configured credential into a command argument."
            }
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
        $variableName = $placeholder.Groups[1].Value
        if ([StringComparer]::OrdinalIgnoreCase.Equals($variableName, [string]$Config.CredentialVariable)) {
            throw 'The configured credential cannot be expanded into a command argument.'
        }
        # Expand only a validated non-credential variable; quotes preserve one argument.
        return '"${' + $variableName + '}"'
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
    return (-not [string]::IsNullOrWhiteSpace($Name)) -and $Config.Agents.Contains($Name)
}

function Test-ProjectName {
    param([AllowNull()][string]$Name)
    return (-not [string]::IsNullOrWhiteSpace($Name)) -and
        ($Name -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
}

function Invoke-WslText {
    param([Parameter(Mandatory)][string]$LinuxScript)
    $output = & wsl.exe -d $Config.Distro -- bash -lc $LinuxScript 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (($output | Out-String).Trim())
    }
    return @(($output | ForEach-Object { ([string]$_).TrimEnd() }) | Where-Object { $_ -ne '' })
}

function Test-DistroRegistered {
    try {
        $names = @(& wsl.exe --list --quiet 2>$null) | ForEach-Object { ("$_" -replace "`0", '').Trim() }
        return $names -contains $Config.Distro
    }
    catch { return $false }
}

function Test-CredentialConfigured {
    return Test-Path -LiteralPath $Config.CredentialFile -PathType Leaf
}

function Save-Credential {
    param([Parameter(Mandatory)][Security.SecureString]$SecureValue)
    if ($SecureValue.Length -lt 1) { throw 'The credential cannot be empty.' }

    $directory = Split-Path -Parent $Config.CredentialFile
    [void](New-Item -ItemType Directory -Path $directory -Force)

    # On Windows PowerShell, no explicit key means DPAPI CurrentUser encryption.
    $encrypted = ConvertFrom-SecureString -SecureString $SecureValue
    Set-Content -LiteralPath $Config.CredentialFile -Value $encrypted -Encoding UTF8
}

function Get-StoredCredential {
    if (-not (Test-CredentialConfigured)) { throw "$($Config.CredentialVariable) has not been configured." }
    $encrypted = (Get-Content -LiteralPath $Config.CredentialFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($encrypted)) { throw 'The encrypted credential file is empty.' }
    return ConvertTo-SecureString -String $encrypted
}

function Invoke-WithCredentialEnvironment {
    param([Parameter(Mandatory)][scriptblock]$Action)

    $variableName = $Config.CredentialVariable
    $secure = Get-StoredCredential
    $bstr = [IntPtr]::Zero
    $plain = $null
    $previousValue = [Environment]::GetEnvironmentVariable($variableName, 'Process')
    $previousWslEnv = [Environment]::GetEnvironmentVariable('WSLENV', 'Process')

    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [Environment]::SetEnvironmentVariable($variableName, $plain, 'Process')

        $parts = @()
        $variablePattern = '^' + [regex]::Escape($variableName) + '(?:/.*)?$'
        if (-not [string]::IsNullOrWhiteSpace($previousWslEnv)) {
            $parts = @($previousWslEnv -split ':' | Where-Object { $_ -and $_ -notmatch $variablePattern })
        }
        $parts += "$variableName/u"
        [Environment]::SetEnvironmentVariable('WSLENV', ($parts -join ':'), 'Process')

        & $Action
    }
    finally {
        [Environment]::SetEnvironmentVariable($variableName, $previousValue, 'Process')
        [Environment]::SetEnvironmentVariable('WSLENV', $previousWslEnv, 'Process')
        $plain = $null
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        if ($null -ne $secure) { $secure.Dispose() }
    }
}

function Invoke-AgentInCurrentConsole {
    param(
        [Parameter(Mandatory)][string]$AgentName,
        [Parameter(Mandatory)][string]$ProjectName
    )
    if (-not (Test-ProjectName $ProjectName)) { throw 'Invalid project name.' }
    if (-not (Test-AgentConfigured $AgentName)) { throw 'Unknown agent.' }
    if (-not (Test-DistroRegistered)) { throw "WSL distribution '$($Config.Distro)' is not registered." }

    $agentConfig = $Config.Agents[$AgentName]
    $root = $Config.ProjectRoot
    $quotedParts = @(
        (ConvertTo-BashLiteral 'nono'),
        (ConvertTo-BashLiteral 'run'),
        (ConvertTo-BashLiteral '--profile'),
        (ConvertTo-BashLiteral ([string]$agentConfig.Profile))
    )
    $quotedParts += @($agentConfig.NonoArguments | ForEach-Object { ConvertTo-BashArgument ([string]$_) })
    $quotedParts += @((ConvertTo-BashLiteral '--'), (ConvertTo-BashLiteral ([string]$agentConfig.Command)))
    $quotedParts += @($agentConfig.AgentArguments | ForEach-Object { ConvertTo-BashArgument ([string]$_) })
    $quotedLaunch = $quotedParts -join ' '

    # Project names/root are constrained above. Ordinary configurable arguments
    # are single-quoted. Exact {ENV:NAME} items become validated, double-quoted
    # runtime expansions. The credential arrives only through the environment.
    $linux = "export PATH=`"`$HOME/.local/bin:`$PATH`"; cd `"`$HOME/$root/$ProjectName`" || exit 20; exec $quotedLaunch"

    Invoke-WithCredentialEnvironment {
        & wsl.exe -d $Config.Distro -- bash -lc $linux
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { throw "The sandboxed agent exited with code $exitCode." }
    }
}

function Open-ShellInCurrentConsole {
    param([string]$ProjectName)
    if (-not (Test-DistroRegistered)) { throw "WSL distribution '$($Config.Distro)' is not registered." }
    $root = $Config.ProjectRoot
    if ([string]::IsNullOrWhiteSpace($ProjectName)) {
        $linux = 'cd "$HOME" || exit 20; exec bash -l'
    }
    else {
        if (-not (Test-ProjectName $ProjectName)) { throw 'Invalid project name.' }
        $linux = "cd `"`$HOME/$root/$ProjectName`" || exit 20; exec bash -l"
    }
    & wsl.exe -d $Config.Distro -- bash -lc $linux
}

if ($Mode -eq 'Launch') {
    try { Invoke-AgentInCurrentConsole -AgentName $Agent -ProjectName $Project; exit 0 }
    catch { Write-Error $_.Exception.Message; exit 1 }
}
if ($Mode -eq 'Shell') {
    try { Open-ShellInCurrentConsole -ProjectName $Project; exit 0 }
    catch { Write-Error $_.Exception.Message; exit 1 }
}

if ($env:OS -ne 'Windows_NT') { throw 'Nono Launchpad must run on Windows.' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'WPF requires STA mode. Start with: powershell.exe -STA -File .\Nono-Launchpad.ps1'
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Nono Launchpad" Height="680" Width="880"
        WindowStartupLocation="CenterScreen"
        Background="#F3F6FA" FontFamily="Segoe UI" FontSize="13"
        SnapsToDevicePixels="True" UseLayoutRounding="True">
  <Window.Resources>
    <SolidColorBrush x:Key="InkBrush" Color="#172033"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#5F6B7A"/>
    <SolidColorBrush x:Key="BlueBrush" Color="#2563A6"/>
    <SolidColorBrush x:Key="BlueDarkBrush" Color="#1D4F86"/>
    <SolidColorBrush x:Key="LineBrush" Color="#D9E1EA"/>
    <SolidColorBrush x:Key="FieldBrush" Color="#F8FAFC"/>

    <Style x:Key="CardStyle" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="{StaticResource LineBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="18"/>
    </Style>

    <Style x:Key="SectionTitleStyle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource InkBrush}"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <Style x:Key="FieldLabelStyle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource MutedBrush}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="0,0,0,5"/>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="MinHeight" Value="32"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Background" Value="{StaticResource FieldBrush}"/>
      <Setter Property="BorderBrush" Value="#C9D3DF"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>

    <Style TargetType="ComboBox">
      <Setter Property="MinHeight" Value="32"/>
      <Setter Property="Padding" Value="6,3"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Background" Value="{StaticResource FieldBrush}"/>
      <Setter Property="BorderBrush" Value="#C9D3DF"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>

    <Style x:Key="SecondaryButtonStyle" TargetType="Button">
      <Setter Property="Height" Value="34"/>
      <Setter Property="MinWidth" Value="88"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="{StaticResource InkBrush}"/>
      <Setter Property="BorderBrush" Value="#B9C6D4"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="ButtonBorder" CornerRadius="5"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.88"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.74"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.48"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="Button" BasedOn="{StaticResource SecondaryButtonStyle}"/>

    <Style x:Key="PrimaryButtonStyle" TargetType="Button" BasedOn="{StaticResource SecondaryButtonStyle}">
      <Setter Property="Height" Value="40"/>
      <Setter Property="MinWidth" Value="190"/>
      <Setter Property="Padding" Value="22,0"/>
      <Setter Property="Background" Value="{StaticResource BlueBrush}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="{StaticResource BlueDarkBrush}"/>
      <Setter Property="FontSize" Value="14"/>
    </Style>
  </Window.Resources>

  <DockPanel LastChildFill="True">
    <Border x:Name="LaunchStatusArea" DockPanel.Dock="Bottom"
            Background="#F3F6FA" BorderBrush="{StaticResource LineBrush}"
            BorderThickness="0,1,0,0" Padding="24,14">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="18"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border x:Name="LaunchStatusBanner" Grid.Column="0" Background="#FFF4E5"
                BorderBrush="#E5C07B" BorderThickness="1" CornerRadius="6"
                Padding="11,8" VerticalAlignment="Center">
          <StackPanel>
            <TextBlock Text="Launch status" FontWeight="SemiBold"
                       Foreground="{StaticResource InkBrush}" FontSize="12"/>
            <TextBlock x:Name="LaunchStatusText" TextWrapping="Wrap"
                       Margin="0,2,0,0" Foreground="#7A4B00" FontSize="12"/>
          </StackPanel>
        </Border>
        <Button x:Name="LaunchButton" Grid.Column="2" Content="Launch Selected Agent"
                Style="{StaticResource PrimaryButtonStyle}" VerticalAlignment="Center"/>
      </Grid>
    </Border>

    <ScrollViewer x:Name="MainScrollViewer" VerticalScrollBarVisibility="Auto"
                  HorizontalScrollBarVisibility="Disabled" CanContentScroll="True">
      <Grid Margin="24,20,24,22">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="14"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="14"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="14"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Grid Grid.Row="0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <StackPanel>
        <TextBlock Text="Nono Launchpad" FontSize="25" FontWeight="SemiBold"
                   Foreground="{StaticResource InkBrush}"/>
        <TextBlock Text="Securely open an AI coding agent in a WSL project."
                   Margin="0,4,0,0" Foreground="{StaticResource MutedBrush}"/>
      </StackPanel>
      <Border Grid.Column="1" Background="#E7F0FA" BorderBrush="#C5D9EF"
              BorderThickness="1" CornerRadius="12" Padding="12,5"
              VerticalAlignment="Center">
        <TextBlock Text="WSL" Foreground="{StaticResource BlueDarkBrush}"
                   FontSize="11" FontWeight="SemiBold"/>
      </Border>
    </Grid>

    <Border Grid.Row="2" Style="{StaticResource CardStyle}">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel VerticalAlignment="Center">
          <TextBlock x:Name="CredentialHeading" Text="Credential"
                     Style="{StaticResource SectionTitleStyle}"/>
          <StackPanel Orientation="Horizontal" Margin="0,7,0,0">
            <TextBlock Text="Status:" Foreground="{StaticResource MutedBrush}" Margin="0,0,6,0"/>
            <TextBlock x:Name="CredentialStatus" FontWeight="SemiBold"/>
          </StackPanel>
          <TextBlock Text="Encrypted for this Windows account with DPAPI. The value is never displayed."
                     Foreground="{StaticResource MutedBrush}" FontSize="12" Margin="0,4,0,0"/>
        </StackPanel>
        <Button x:Name="SetKeyButton" Grid.Column="1" Content="Set / Replace Credential"
                VerticalAlignment="Center" Margin="20,0,0,0" MinWidth="180"/>
      </Grid>
    </Border>

    <Border Grid.Row="4" Style="{StaticResource CardStyle}">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="1.12*"/>
          <ColumnDefinition Width="1"/>
          <ColumnDefinition Width="26"/>
          <ColumnDefinition Width="0.88*"/>
        </Grid.ColumnDefinitions>

        <StackPanel Grid.Column="0">
          <TextBlock Text="Project" Style="{StaticResource SectionTitleStyle}"/>
          <TextBlock Text="Existing project" Style="{StaticResource FieldLabelStyle}" Margin="0,11,0,5"/>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <ComboBox x:Name="ProjectCombo" Grid.Column="0"/>
            <Button x:Name="RefreshButton" Grid.Column="2" Content="Refresh" MinWidth="82"/>
          </Grid>
          <TextBlock Text="Create a project" Style="{StaticResource FieldLabelStyle}" Margin="0,12,0,5"/>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBox x:Name="NewProjectText" Grid.Column="0"
                     ToolTip="Letters, numbers, dots, underscores and hyphens; must start with a letter or number."/>
            <Button x:Name="CreateButton" Grid.Column="2" Content="Create" MinWidth="82"/>
          </Grid>
        </StackPanel>

        <Border Grid.Column="1" Width="1" Background="{StaticResource LineBrush}" Margin="0,2"/>

        <StackPanel Grid.Column="3">
          <TextBlock Text="Agent" Style="{StaticResource SectionTitleStyle}"/>
          <TextBlock Text="Configured agent" Style="{StaticResource FieldLabelStyle}" Margin="0,11,0,5"/>
          <ComboBox x:Name="AgentCombo"/>
          <TextBlock Text="Utilities" Style="{StaticResource FieldLabelStyle}" Margin="0,16,0,7"/>
          <StackPanel Orientation="Horizontal">
            <Button x:Name="OpenFolderButton" Content="Open Folder" Margin="0,0,8,0"/>
            <Button x:Name="OpenShellButton" Content="Open Shell"/>
          </StackPanel>
        </StackPanel>
      </Grid>
    </Border>

    <Border Grid.Row="6" Style="{StaticResource CardStyle}">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="10"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="10"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid Grid.Row="0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <StackPanel>
            <TextBlock Text="Readiness" Style="{StaticResource SectionTitleStyle}"/>
            <TextBlock Text="Local checks for the selected WSL environment."
                       Foreground="{StaticResource MutedBrush}" FontSize="12" Margin="0,3,0,0"/>
          </StackPanel>
          <Button x:Name="CheckButton" Grid.Column="1" Content="Check Again"
                  Width="104" HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>
        <TextBox x:Name="StatusText" Grid.Row="2" IsReadOnly="True"
                 Height="145"
                 TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                 HorizontalScrollBarVisibility="Disabled" VerticalContentAlignment="Top"
                 Background="{StaticResource FieldBrush}" BorderBrush="#D5DEE8"
                 Padding="10" FontFamily="Consolas" FontSize="12"/>
        <Border Grid.Row="4" Background="#EEF4FA" BorderBrush="#D4E2F0"
                BorderThickness="1" CornerRadius="5" Padding="10,7">
          <TextBlock Text="Readiness confirms local components only. Profile compatibility still requires strict validation and a real launch test."
                     Foreground="#3E5872" FontSize="12" TextWrapping="Wrap"/>
        </Border>
      </Grid>
    </Border>

      </Grid>
    </ScrollViewer>
  </DockPanel>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$workArea = [System.Windows.SystemParameters]::WorkArea
$window.MaxHeight = $workArea.Height
$window.MaxWidth = $workArea.Width
$window.MinHeight = [Math]::Min(420.0, $workArea.Height)
$window.MinWidth = [Math]::Min(640.0, $workArea.Width)
$window.Height = [Math]::Min(680.0, $workArea.Height)
$window.Width = [Math]::Min(880.0, $workArea.Width)

$names = @('CredentialHeading','CredentialStatus','SetKeyButton','RefreshButton','ProjectCombo','CreateButton','NewProjectText','AgentCombo','OpenFolderButton','OpenShellButton','CheckButton','StatusText','LaunchStatusArea','LaunchStatusBanner','LaunchStatusText','LaunchButton','MainScrollViewer')
foreach ($name in $names) { Set-Variable -Name $name -Value $window.FindName($name) -Scope Script }

$script:Readiness = @{ Distro = $false; Nono = $false; Agents = @{}; Profiles = @{} }
foreach ($agentName in $Config.Agents.Keys) {
    [void]$AgentCombo.Items.Add([string]$agentName)
    $script:Readiness.Agents[[string]$agentName] = $false
    $script:Readiness.Profiles[[string]$agentName] = $null
}
if ($AgentCombo.Items.Count -gt 0) { $AgentCombo.SelectedIndex = 0 }
$CredentialHeading.Text = "Credential: $($Config.CredentialVariable)"
$SetKeyButton.Content = "Set / Replace $($Config.CredentialVariable)"

function Show-LaunchpadError {
    param([string]$Message)
    [void][Windows.MessageBox]::Show($window, $Message, 'Nono Launchpad', 'OK', 'Error')
}

function Get-SelectedProject { return [string]$ProjectCombo.SelectedItem }
function Get-SelectedAgent {
    if ($null -eq $AgentCombo.SelectedItem) { return $null }
    return [string]$AgentCombo.SelectedItem
}

function Update-ControlState {
    $projectOk = Test-ProjectName (Get-SelectedProject)
    $keyOk = Test-CredentialConfigured
    $agentName = Get-SelectedAgent
    $agentConfigured = Test-AgentConfigured $agentName
    $agentOk = $agentConfigured -and ($script:Readiness.Agents.ContainsKey($agentName)) -and $script:Readiness.Agents[$agentName]
    $profileOk = $true
    if ($agentConfigured -and $script:Readiness.Profiles.ContainsKey($agentName) -and $null -ne $script:Readiness.Profiles[$agentName]) {
        $profileOk = [bool]$script:Readiness.Profiles[$agentName]
    }

    $reasons = New-Object System.Collections.Generic.List[string]
    if (-not $keyOk) { $reasons.Add("save $($Config.CredentialVariable)") }
    if (-not $script:Readiness.Distro) { $reasons.Add("WSL distro '$($Config.Distro)' is unavailable") }
    if (-not $script:Readiness.Nono) { $reasons.Add('nono executable is unavailable') }
    if (-not $agentConfigured) { $reasons.Add('select a configured agent') }
    elseif (-not $agentOk) { $reasons.Add("agent executable '$([string]$Config.Agents[$agentName].Command)' is unavailable") }
    if (-not $projectOk) { $reasons.Add('select a project') }
    if (-not $profileOk) { $reasons.Add("profile '$([string]$Config.Agents[$agentName].Profile)' is unavailable") }

    $LaunchButton.IsEnabled = $reasons.Count -eq 0
    $OpenFolderButton.IsEnabled = $projectOk -and $script:Readiness.Distro
    $CredentialStatus.Text = if ($keyOk) { 'Configured' } else { 'Not configured' }
    $CredentialStatus.Foreground = if ($keyOk) { '#1E8449' } else { '#B03A2E' }
    if ($LaunchButton.IsEnabled) {
        $LaunchStatusText.Text = "Ready to launch in $($Config.Distro) under ~/$($Config.ProjectRoot)."
        $LaunchStatusBanner.Background = '#EAF7EF'
        $LaunchStatusBanner.BorderBrush = '#9AC9AA'
        $LaunchStatusText.Foreground = '#176B3A'
        $LaunchButton.ToolTip = 'Ready to launch the selected agent.'
    }
    else {
        $reasonText = @($reasons | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join '; '
        if ([string]::IsNullOrWhiteSpace($reasonText)) { $reasonText = 'readiness checks have not completed' }
        $LaunchStatusText.Text = "Launch unavailable: $reasonText"
        $LaunchStatusBanner.Background = '#FFF4E5'
        $LaunchStatusBanner.BorderBrush = '#E5C07B'
        $LaunchStatusText.Foreground = '#7A4B00'
        $LaunchButton.ToolTip = $reasonText
    }
}

function Refresh-Projects {
    $selected = Get-SelectedProject
    $ProjectCombo.Items.Clear()
    if (-not (Test-DistroRegistered)) { Update-ControlState; return }
    try {
        $root = $Config.ProjectRoot
        $lines = Invoke-WslText -LinuxScript "mkdir -p -- `"`$HOME/$root`"; find `"`$HOME/$root`" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort"
        foreach ($line in $lines) {
            if (Test-ProjectName $line) { [void]$ProjectCombo.Items.Add($line) }
        }
        if ($selected -and $ProjectCombo.Items.Contains($selected)) { $ProjectCombo.SelectedItem = $selected }
        elseif ($ProjectCombo.Items.Count -gt 0) { $ProjectCombo.SelectedIndex = 0 }
    }
    catch { Show-LaunchpadError $_.Exception.Message }
    Update-ControlState
}

function Refresh-Readiness {
    $agentReadiness = @{}
    $profileReadiness = @{}
    foreach ($agentName in $Config.Agents.Keys) {
        $agentReadiness[[string]$agentName] = $false
        $profileReadiness[[string]$agentName] = $null
    }
    $script:Readiness = @{ Distro = (Test-DistroRegistered); Nono = $false; Agents = $agentReadiness; Profiles = $profileReadiness }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Distro $($Config.Distro): " + $(if ($script:Readiness.Distro) { 'OK' } else { 'MISSING' }))
    $lines.Add("Credential $($Config.CredentialVariable): " + $(if (Test-CredentialConfigured) { 'CONFIGURED' } else { 'NOT CONFIGURED' }))

    if ($script:Readiness.Distro) {
        try {
            $agentNames = @($Config.Agents.Keys | ForEach-Object { [string]$_ })
            $checks = New-Object System.Collections.Generic.List[string]
            $checks.Add('export PATH="$HOME/.local/bin:$PATH"')
            $checks.Add("if command -v 'nono' >/dev/null 2>&1; then printf 'nono=OK\n'; else printf 'nono=MISSING\n'; fi")
            for ($i = 0; $i -lt $agentNames.Count; $i++) {
                $commandLiteral = ConvertTo-BashLiteral ([string]$Config.Agents[$agentNames[$i]].Command)
                $checks.Add("if command -v $commandLiteral >/dev/null 2>&1; then printf 'agent$i=OK\n'; else printf 'agent$i=MISSING\n'; fi")
                $profileLiteral = ConvertTo-BashLiteral ([string]$Config.Agents[$agentNames[$i]].Profile)
                $checks.Add("if command -v 'nono' >/dev/null 2>&1; then if nono profile show $profileLiteral --json >/dev/null 2>&1; then printf 'profile$i=OK\n'; else printf 'profile$i=MISSING\n'; fi; fi")
            }

            $result = Invoke-WslText -LinuxScript ($checks -join '; ')
            foreach ($line in $result) {
                if ($line -match '^nono=(OK|MISSING)$') {
                    $script:Readiness.Nono = $Matches[1] -eq 'OK'
                    $lines.Add("nono: $($Matches[1])")
                }
                elseif ($line -match '^agent([0-9]+)=(OK|MISSING)$') {
                    $index = [int]$Matches[1]
                    if ($index -lt $agentNames.Count) {
                        $agentName = $agentNames[$index]
                        $script:Readiness.Agents[$agentName] = $Matches[2] -eq 'OK'
                        $command = [string]$Config.Agents[$agentName].Command
                        $lines.Add("$agentName command ($command): $($Matches[2])")
                    }
                }
                elseif ($line -match '^profile([0-9]+)=(OK|MISSING)$') {
                    $index = [int]$Matches[1]
                    if ($index -lt $agentNames.Count) {
                        $agentName = $agentNames[$index]
                        $script:Readiness.Profiles[$agentName] = $Matches[2] -eq 'OK'
                        $profile = [string]$Config.Agents[$agentName].Profile
                        $lines.Add("$agentName profile ($profile): $($Matches[2])")
                    }
                }
            }

        }
        catch { $lines.Add("Readiness check failed: $($_.Exception.Message)") }
    }
    $StatusText.Text = $lines -join [Environment]::NewLine
    Update-ControlState
}

function Start-HelperTerminal {
    param(
        [Parameter(Mandatory)][ValidateSet('Launch','Shell')][string]$HelperMode,
        [string]$AgentName,
        [string]$ProjectName
    )
    $powerShell = (Get-Command powershell.exe -ErrorAction Stop).Source

    # Use EncodedCommand so arbitrary configured display names and script paths
    # survive PowerShell 5.1 argument joining. No secret is encoded.
    $helperCommand = '& ' + (ConvertTo-PowerShellLiteral $PSCommandPath) + ' -Mode ' + (ConvertTo-PowerShellLiteral $HelperMode)
    if ($AgentName) { $helperCommand += ' -Agent ' + (ConvertTo-PowerShellLiteral $AgentName) }
    if ($ProjectName) { $helperCommand += ' -Project ' + (ConvertTo-PowerShellLiteral $ProjectName) }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($helperCommand))
    $helperArgs = @('-NoLogo','-NoProfile','-EncodedCommand', $encoded)

    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($wt) {
        $safeTitle = if ($HelperMode -eq 'Launch') { "Nono-Agent-$ProjectName" } else { "Nono-Shell-$ProjectName" }
        $arguments = @('new-tab','--title', $safeTitle,'--', $powerShell) + $helperArgs
        Start-Process -FilePath $wt.Source -ArgumentList $arguments
    }
    else {
        Start-Process -FilePath $powerShell -ArgumentList $helperArgs
    }
}

$SetKeyButton.Add_Click({
    try {
        $dialog = New-Object Windows.Window
        $dialog.Title = "Set $($Config.CredentialVariable)"
        $dialog.Width = 480; $dialog.Height = 210
        $dialog.WindowStartupLocation = 'CenterOwner'; $dialog.Owner = $window
        $dialog.ResizeMode = 'NoResize'
        $panel = New-Object Windows.Controls.StackPanel
        $panel.Margin = 20
        $label = New-Object Windows.Controls.TextBlock
        $label.Text = "Enter the value for $($Config.CredentialVariable). It will be encrypted for your Windows account and will not be displayed again."
        $label.TextWrapping = 'Wrap'; $label.Margin = '0,0,0,12'
        $box = New-Object Windows.Controls.PasswordBox
        $box.MinHeight = 30; $box.Padding = 5
        $buttons = New-Object Windows.Controls.StackPanel
        $buttons.Orientation = 'Horizontal'; $buttons.HorizontalAlignment = 'Right'; $buttons.Margin = '0,16,0,0'
        $cancel = New-Object Windows.Controls.Button
        $cancel.Content = 'Cancel'; $cancel.Padding = '14,6'; $cancel.Margin = '0,0,8,0'
        $save = New-Object Windows.Controls.Button
        $save.Content = 'Save'; $save.Padding = '14,6'; $save.IsDefault = $true
        [void]$buttons.Children.Add($cancel); [void]$buttons.Children.Add($save)
        [void]$panel.Children.Add($label); [void]$panel.Children.Add($box); [void]$panel.Children.Add($buttons)
        $dialog.Content = $panel
        $cancel.Add_Click({ $dialog.DialogResult = $false })
        $save.Add_Click({
            if ($box.SecurePassword.Length -lt 1) {
                [void][Windows.MessageBox]::Show($dialog, 'Enter a non-empty key.', 'Nono Launchpad', 'OK', 'Warning')
                return
            }
            $secureCopy = $box.SecurePassword.Copy()
            try { Save-Credential -SecureValue $secureCopy }
            finally { $secureCopy.Dispose() }
            $dialog.DialogResult = $true
        })
        [void]$dialog.ShowDialog()
        Refresh-Readiness
    }
    catch { Show-LaunchpadError $_.Exception.Message }
})

$CreateButton.Add_Click({
    try {
        $name = $NewProjectText.Text.Trim()
        if (-not (Test-ProjectName $name)) { throw 'Use 1-64 characters: letters, numbers, dots, underscores or hyphens. Start with a letter or number.' }
        if (-not (Test-DistroRegistered)) { throw "WSL distribution '$($Config.Distro)' is not registered." }
        $root = $Config.ProjectRoot
        [void](Invoke-WslText -LinuxScript "mkdir -p -- `"`$HOME/$root/$name`"")
        $NewProjectText.Clear()
        Refresh-Projects
        $ProjectCombo.SelectedItem = $name
    }
    catch { Show-LaunchpadError $_.Exception.Message }
})

$RefreshButton.Add_Click({ Refresh-Projects })
$CheckButton.Add_Click({ Refresh-Readiness; Refresh-Projects })
$ProjectCombo.Add_SelectionChanged({ Update-ControlState })
$AgentCombo.Add_SelectionChanged({ Update-ControlState })

$OpenFolderButton.Add_Click({
    try {
        $projectName = Get-SelectedProject
        if (-not (Test-ProjectName $projectName)) { throw 'Select a project first.' }
        $root = $Config.ProjectRoot
        $linuxPaths = @(Invoke-WslText -LinuxScript "printf '%s\n' `"`$HOME/$root/$projectName`"")
        if ($linuxPaths.Count -ne 1) { throw 'WSL did not return one project path.' }
        $linuxPath = [string]$linuxPaths[0]
        if (-not $linuxPath.StartsWith('/') -or $linuxPath.IndexOf([char]0) -ge 0 -or $linuxPath.Contains('"')) {
            throw 'WSL returned an invalid project path.'
        }
        # Target the selected distro and Linux-native project explicitly. This
        # avoids a malformed wslpath argument opening only a generic Explorer window.
        $uncPath = "\\wsl.localhost\$($Config.Distro)" + $linuxPath.Replace('/', '\')
        Start-Process -FilePath explorer.exe -ArgumentList ('/e,"{0}"' -f $uncPath)
    }
    catch { Show-LaunchpadError $_.Exception.Message }
})

$OpenShellButton.Add_Click({
    try { Start-HelperTerminal -HelperMode Shell -ProjectName (Get-SelectedProject) }
    catch { Show-LaunchpadError $_.Exception.Message }
})

$LaunchButton.Add_Click({
    try {
        $agentName = Get-SelectedAgent
        $projectName = Get-SelectedProject
        if (-not $agentName -or -not (Test-ProjectName $projectName)) { throw 'Select an agent and project.' }
        Start-HelperTerminal -HelperMode Launch -AgentName $agentName -ProjectName $projectName
    }
    catch { Show-LaunchpadError $_.Exception.Message }
})

$window.Add_ContentRendered({ Refresh-Readiness; Refresh-Projects })
[void]$window.ShowDialog()
