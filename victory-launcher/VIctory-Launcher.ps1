# VIctory Launcher - a front end for victory.exe (https://github.com/marvisak/VIctory).
# Modelled on the XCL Launcher: checks what VIctory needs (Git, Rust, C++ build tools, AVX2,
# a D3D12 GPU, memory), installs / builds what is missing, keeps the game path in victory.toml
# and starts the title with `victory run <exe> --execute`.
# Runs on Windows PowerShell 5.1 (STA) with WPF; no build step, so it works before Rust exists.
#
# Layout (everything under one folder):
#   <root>\VIctory Launcher.cmd     double-click to start
#   <root>\launcher\                this script
#   <root>\source\                  git clone of VIctory
#   <root>\victory.toml             config (kept OUTSIDE the source tree, as VIctory requires)
#   <root>\launcher.json            launcher state (game exe, options)

$ErrorActionPreference = 'Stop'

# Started as another account (Start-Process -Credential, as the restricted starter does), the
# process keeps the caller's environment: TEMP, LOCALAPPDATA... point into a profile this account
# cannot open. Use this account's own profile, for us and everything we start (VIctory too).
$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$profileDir = (Get-CimInstance Win32_UserProfile -Filter "SID='$($me.User.Value)'" -ErrorAction SilentlyContinue).LocalPath
if ($profileDir -and $env:USERPROFILE -ne $profileDir) {
    $previous = $env:USERPROFILE
    # Drop what points into the other profile (XCL_DXC_DIR, PATH entries such as its .cargo\bin...).
    foreach ($v in @(Get-ChildItem Env: | Where-Object { $_.Name -ne 'Path' -and $_.Value -like "$previous\*" })) {
        Remove-Item "Env:$($v.Name)" -ErrorAction SilentlyContinue
    }
    $env:Path = (($env:Path -split ';') | Where-Object { $_ -and $_ -notlike "$previous\*" }) -join ';'
    $env:USERPROFILE = $profileDir
    $env:HOMEPATH = $profileDir.Substring(2)
    $env:APPDATA = Join-Path $profileDir 'AppData\Roaming'
    $env:LOCALAPPDATA = Join-Path $profileDir 'AppData\Local'
    $env:TEMP = Join-Path $env:LOCALAPPDATA 'Temp'
    $env:TMP = $env:TEMP
    $env:USERNAME = $me.Name.Split('\')[-1]
    New-Item -ItemType Directory -Force $env:TEMP | Out-Null
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$script:Root = Split-Path -Parent $PSScriptRoot
# The launcher either sits beside a `source` clone (<root>\launcher, <root>\source) or inside
# the clone itself (<repo>\victory-launcher); VIctory's tree is marked by `.victory-root`.
$script:InRepo = Test-Path (Join-Path $script:Root '.victory-root')
$script:Repo = if ($script:InRepo) { $script:Root } else { Join-Path $script:Root 'source' }
$script:RepoUrl = 'https://github.com/marvisak/VIctory.git'
# Inside the clone: the git-ignored victory.toml at its root.
$script:Config = Join-Path $script:Root 'victory.toml'
# Launcher state and run logs live beside VIctory's data folder when victory.toml names one
# (the restricted account may write only there), else beside the launcher.
$script:StateFile = Join-Path $script:Root 'launcher.json'
# Versions the launcher runs: our clone, and the ztrx fork cloned beside it (each with its own
# victory.toml, so its own shader cache, saves and logs).
$script:Versions = [ordered]@{
    victory = @{ Name = 'VIctory (our build)'; Repo = $script:Repo; Config = $script:Config; Url = $script:RepoUrl }
    ztrx    = @{ Name = 'ztrx'; Repo = (Join-Path (Split-Path $script:Repo) 'ztrx'); Config = (Join-Path (Join-Path (Split-Path $script:Repo) 'ztrx') 'victory.toml'); Url = 'https://github.com/Hynicon/ztrx.git' }
}
$script:Tasks = @{}      # key -> process of a running install / build / game
$script:State = [pscustomobject]@{ exe = $null; console = 'series-x'; warp = $false; skipIntro = $false; windowSize = '1920x1080'; stableMode = $true; version = 'victory'; fast = $false }

# Stable mode: what keeps the world from hanging or crawling on an NVIDIA RTX 2060 today
# (2026-11-24 runs): ray tracing off, and these passes skipped -
#   f607780aa8e502d0, 5f13c9550dc4ab39  indirect_light_probes:CS_IrradianceCache_ShadowTrace(_WithFar)
#                                       (hang the GPU while the irradiance cache's wave64 passes are refused)
#   00167d58cc5a78d7                    WindNew:CS_CopyLatestWindFieldForRenderingWithSmooth (~18 s per frame)
$script:StableSkips = 'f607780aa8e502d0,5f13c9550dc4ab39,00167d58cc5a78d7'

# ---------------------------------------------------------------- the window ----

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="VIctory Launcher" Width="1080" Height="800" MinWidth="940" MinHeight="740"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="CanResizeWithGrip" WindowStartupLocation="CenterScreen"
        FontFamily="Bahnschrift, Segoe UI" Foreground="#F2FBFF">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#36E2C8"/>
    <SolidColorBrush x:Key="Gold" Color="#FFC857"/>
    <SolidColorBrush x:Key="Muted" Color="#A9C4D6"/>
    <SolidColorBrush x:Key="Panel" Color="#B3061A2B"/>
    <LinearGradientBrush x:Key="Hot" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#36E2C8" Offset="0"/>
      <GradientStop Color="#2C8BFF" Offset="1"/>
    </LinearGradientBrush>

    <Style x:Key="NeonButton" TargetType="Button">
      <Setter Property="Foreground" Value="#F2FBFF"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="6" Background="#40000000" BorderBrush="#36E2C8" BorderThickness="1.5" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#5536E2C8"/>
                <Setter TargetName="B" Property="Effect">
                  <Setter.Value><DropShadowEffect Color="#36E2C8" BlurRadius="18" ShadowDepth="0" Opacity="0.9"/></Setter.Value>
                </Setter>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="B" Property="Background" Value="#8836E2C8"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="B" Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PlayButton" TargetType="Button" BasedOn="{StaticResource NeonButton}">
      <Setter Property="FontSize" Value="24"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="#04121F"/>
      <Setter Property="Padding" Value="44,10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="8" Background="{StaticResource Hot}" Padding="{TemplateBinding Padding}">
              <Border.Effect><DropShadowEffect Color="#36E2C8" BlurRadius="22" ShadowDepth="0" Opacity="0.7"/></Border.Effect>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Effect">
                  <Setter.Value><DropShadowEffect Color="#2C8BFF" BlurRadius="36" ShadowDepth="0" Opacity="1"/></Setter.Value>
                </Setter>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="B" Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ChromeButton" TargetType="Button">
      <Setter Property="Foreground" Value="#F2FBFF"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="Width" Value="40"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="4" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#5536E2C8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PanelBorder" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Panel}"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="BorderBrush" Value="#5536E2C8"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="18"/>
    </Style>

    <Style x:Key="Heading" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="{StaticResource Gold}"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>

    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="#F2FBFF"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Margin" Value="0,0,16,6"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="6"/>
      <Setter Property="MinWidth" Value="6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border CornerRadius="3" Background="#AA36E2C8"/>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border CornerRadius="14" ClipToBounds="True" BorderBrush="#8836E2C8" BorderThickness="1">
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
        <GradientStop Color="#030B16" Offset="0"/>
        <GradientStop Color="#06203A" Offset="0.45"/>
        <GradientStop Color="#0B4A63" Offset="0.78"/>
        <GradientStop Color="#127A7A" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
    <Grid>
      <!-- waves along the bottom -->
      <Path VerticalAlignment="Bottom" Height="90" Stretch="Fill" Opacity="0.35" Fill="#36E2C8"
            Data="M0,40 C120,10 240,70 360,40 C480,10 600,70 720,40 C840,10 960,70 1080,40 L1080,90 L0,90 Z"/>
      <Path VerticalAlignment="Bottom" Height="60" Stretch="Fill" Opacity="0.5" Fill="#06203A"
            Data="M0,30 C150,0 300,60 450,30 C600,0 750,60 900,30 C960,18 1020,20 1080,30 L1080,60 L0,60 Z"/>
      <Rectangle Height="30" VerticalAlignment="Bottom" Fill="#CC020810"/>

      <Grid Margin="26,14,26,40">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <!-- header / drag area -->
        <Grid x:Name="Header" Background="Transparent" Margin="0,0,0,14">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="VIctory" FontSize="54" FontWeight="Bold" Foreground="{StaticResource Hot}">
              <TextBlock.Effect><DropShadowEffect Color="#36E2C8" BlurRadius="24" ShadowDepth="0" Opacity="0.9"/></TextBlock.Effect>
            </TextBlock>
            <StackPanel VerticalAlignment="Center" Margin="18,6,0,0">
              <TextBlock Text="L A U N C H E R" FontSize="20" FontWeight="Bold" Foreground="{StaticResource Gold}"/>
              <TextBlock Text="Front end for the VIctory compatibility project" FontSize="13" Foreground="{StaticResource Muted}"/>
            </StackPanel>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
            <Button x:Name="MinBtn" Style="{StaticResource ChromeButton}" Content="&#x2013;"/>
            <Button x:Name="CloseBtn" Style="{StaticResource ChromeButton}" Content="&#x2715;"/>
          </StackPanel>
        </Grid>

        <Grid Grid.Row="1">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="5*"/>
            <ColumnDefinition Width="20"/>
            <ColumnDefinition Width="4*"/>
          </Grid.ColumnDefinitions>

          <!-- game + options -->
          <Border Style="{StaticResource PanelBorder}">
            <DockPanel>
              <TextBlock DockPanel.Dock="Top" Style="{StaticResource Heading}" Text="GAME"/>
              <StackPanel DockPanel.Dock="Top">
                <TextBlock x:Name="GameName" Text="No game selected" FontSize="30" FontWeight="Bold" TextTrimming="CharacterEllipsis"/>
                <TextBlock x:Name="GameDetail" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,4,0,12"/>
                <WrapPanel Margin="0,0,0,16">
                  <Button x:Name="PickBtn" Style="{StaticResource NeonButton}" Content="CHOOSE GAME..."/>
                  <Button x:Name="ConfigBtn" Style="{StaticResource NeonButton}" Content="EDIT CONFIG"/>
                  <Button x:Name="CheckCfgBtn" Style="{StaticResource NeonButton}" Content="CHECK PATHS"/>
                </WrapPanel>

                <TextBlock Style="{StaticResource Heading}" Text="VERSION"/>
                <WrapPanel Margin="0,0,0,4">
                  <RadioButton x:Name="VerVictory" GroupName="Version" Content="VIctory (our build)"/>
                  <RadioButton x:Name="VerZtrx" GroupName="Version" Content="ztrx"/>
                </WrapPanel>
                <TextBlock x:Name="VersionHint" FontSize="11" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,0,0,10"/>
                <TextBlock Style="{StaticResource Heading}" Text="CONSOLE MODE"/>
                <WrapPanel Margin="0,0,0,10">
                  <RadioButton x:Name="SeriesX" GroupName="Console" Content="Series X"/>
                  <RadioButton x:Name="SeriesS" GroupName="Console" Content="Series S (lighter)"/>
                </WrapPanel>
                <TextBlock Style="{StaticResource Heading}" Text="RENDERER"/>
                <WrapPanel Margin="0,0,0,4">
                  <RadioButton x:Name="RenderGpu" GroupName="Render" Content="GPU (release build)"/>
                  <RadioButton x:Name="RenderWarp" GroupName="Render" Content="Software / WARP (diagnostics build)"/>
                </WrapPanel>
                <TextBlock x:Name="RenderHint" FontSize="11" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,0,0,10"/>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                  <TextBlock Text="Window size" FontSize="13" VerticalAlignment="Center" Margin="0,0,10,0"/>
                  <ComboBox x:Name="WindowSize" Width="170" FontSize="13">
                    <ComboBoxItem Content="1280x720"/>
                    <ComboBoxItem Content="1600x900"/>
                    <ComboBoxItem Content="1920x1080"/>
                    <ComboBoxItem Content="2560x1440"/>
                    <ComboBoxItem Content="Game's own size"/>
                  </ComboBox>
                </StackPanel>
                <CheckBox x:Name="StableMode" Foreground="#F2FBFF" FontSize="13" Margin="0,0,0,4" Cursor="Hand"
                          Content="Stable mode - ray tracing off, known problem passes skipped (diagnostics build)"/>
                <CheckBox x:Name="ZtrxFast" Foreground="#F2FBFF" FontSize="13" Margin="0,0,0,4" Cursor="Hand"
                          Content="Faster - ztrx's optional speed setting (VICTORY__RELAY=2)"/>
                <CheckBox x:Name="SkipIntro" Foreground="#F2FBFF" FontSize="13" Margin="0,0,0,4" Cursor="Hand"
                          Content="Skip intro - press A automatically for the first 45 s (diagnostics build)"/>
                <TextBlock FontSize="11" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,0,0,16"
                           Text="Every run is logged; LOG opens the newest log. The diagnostics build also records GPU crash details (DRED)."/>

                <WrapPanel>
                  <Button x:Name="PlayBtn" Style="{StaticResource PlayButton}" Content="PLAY" Margin="0,0,14,0"/>
                  <Button x:Name="LogBtn" Style="{StaticResource NeonButton}" Content="LOG" VerticalAlignment="Center"/>
                  <Button x:Name="CrashBtn" Style="{StaticResource NeonButton}" Content="CRASH LOG" VerticalAlignment="Center"/>
                  <Button x:Name="DataBtn" Style="{StaticResource NeonButton}" Content="DATA" VerticalAlignment="Center"/>
                  <Button x:Name="CacheBtn" Style="{StaticResource NeonButton}" Content="CACHE" VerticalAlignment="Center"/>
                  <Button x:Name="PrebuildBtn" Style="{StaticResource NeonButton}" Content="PRE-BUILD SHADERS" VerticalAlignment="Center"
                          ToolTip="Translate every shader into the cache now, so the game does not wait for them (same build PLAY uses)."/>
                </WrapPanel>
              </StackPanel>
              <TextBlock VerticalAlignment="Bottom" FontSize="11" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                         Text="VIctory is early work: per its README the title reaches the world but does not render it yet. On a real GPU, entering the world can hang the driver; the WARP renderer avoids that but is very slow."/>
            </DockPanel>
          </Border>

          <!-- system check -->
          <Border Grid.Column="2" Style="{StaticResource PanelBorder}">
            <DockPanel>
              <Grid DockPanel.Dock="Top">
                <TextBlock Style="{StaticResource Heading}" Text="SYSTEM CHECK"/>
                <Button x:Name="RefreshBtn" Style="{StaticResource NeonButton}" Content="REFRESH" Padding="10,3" FontSize="11"
                        HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0"/>
              </Grid>
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel x:Name="CheckRows"/>
              </ScrollViewer>
            </DockPanel>
          </Border>
        </Grid>
      </Grid>

      <TextBlock x:Name="Status" VerticalAlignment="Bottom" Margin="28,0,40,7" FontSize="12" Foreground="#F2FBFF" TextTrimming="CharacterEllipsis"/>
    </Grid>
  </Border>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'Header','MinBtn','CloseBtn','GameName','GameDetail','PickBtn','ConfigBtn','CheckCfgBtn',
               'SeriesX','SeriesS','RenderGpu','RenderWarp','RenderHint','SkipIntro','StableMode','WindowSize','VerVictory','VerZtrx','VersionHint','ZtrxFast','PlayBtn','LogBtn','CrashBtn','DataBtn','CacheBtn','PrebuildBtn',
               'RefreshBtn','CheckRows','Status') {
    $ui[$n] = $win.FindName($n)
}

function Set-Status([string]$text) { $ui.Status.Text = $text }

# ---------------------------------------------------------------- state / config ----

function Save-State {
    ConvertTo-Json -InputObject $script:State | Set-Content -Path $script:StateFile -Encoding UTF8
}

function Load-State {
    if (Test-Path $script:StateFile) {
        try {
            $o = Get-Content $script:StateFile -Raw | ConvertFrom-Json
            foreach ($k in 'exe', 'console', 'warp', 'skipIntro', 'windowSize', 'stableMode', 'version', 'fast') { if ($null -ne $o.$k) { $script:State.$k = $o.$k } }
        } catch { Set-Status "Could not read $($script:StateFile): $_" }
    }
}

# Reads one `key = '...'` / `key = "..."` value from victory.toml (enough for the paths section).
function Get-ConfigValue([string]$key) {
    if (-not (Test-Path $script:Config)) { return $null }
    foreach ($line in Get-Content $script:Config) {
        if ($line -match "^\s*$key\s*=\s*['""](.*)['""]\s*$") { return $Matches[1] }
    }
    return $null
}

# Writes game_dir into victory.toml, creating it from the repo's example if needed.
function Set-GameDir([string]$dir) {
    if ($dir.Contains("'")) { throw "The game path contains a ' character, which victory.toml cannot hold in a literal string." }
    $line = "game_dir = '$dir'"
    if (Test-Path $script:Config) {
        $text = Get-Content $script:Config -Raw
        if ($text -match '(?m)^\s*game_dir\s*=') { $text = [regex]::Replace($text, '(?m)^\s*game_dir\s*=.*$', $line) }
        elseif ($text -match '(?m)^\[paths\]\s*$') { $text = [regex]::Replace($text, '(?m)^\[paths\]\s*$', "[paths]`r`n$line") }
        else { $text = "[paths]`r`n$line`r`n`r`n" + $text }
    } else {
        $example = Join-Path $script:Repo 'victory.example.toml'
        if (Test-Path $example) {
            $text = [regex]::Replace((Get-Content $example -Raw), '(?m)^\s*game_dir\s*=.*$', $line)
        } else {
            $text = "[paths]`r`n$line`r`ntest_titles = []`r`n"
        }
    }
    [IO.File]::WriteAllText($script:Config, $text, (New-Object Text.UTF8Encoding $false))
}

function Get-DataDir {
    if ($env:VICTORY_DATA_DIR) { return $env:VICTORY_DATA_DIR }
    $v = Get-ConfigValue 'data_dir'; if ($v) { return $v }
    Join-Path $env:LOCALAPPDATA 'victory\data'
}

function Get-CacheDir {
    if ($env:VICTORY_CACHE_DIR) { return $env:VICTORY_CACHE_DIR }
    $v = Get-ConfigValue 'cache_dir'; if ($v) { return $v }
    Join-Path $env:LOCALAPPDATA 'victory\cache'
}

# ---------------------------------------------------------------- detection ----

function Get-CargoPath {
    $c = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
    if (Test-Path $c) { return $c }
    $cmd = Get-Command cargo.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-MsvcPath {
    $vw = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vw)) { return $null }
    $p = & $vw -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -latest -property installationPath 2>$null
    if ($p) { return @($p)[0] }
    return $null
}

function Get-GitPath {
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in "$env:ProgramFiles\Git\cmd\git.exe", "${env:ProgramFiles(x86)}\Git\cmd\git.exe") { if (Test-Path $p) { return $p } }
    return $null
}

# Switches the repo, config and source URL to a version (`$script:Versions` key).
function Set-Version([string]$key) {
    if (-not $script:Versions.Contains($key)) { $key = 'victory' }
    $v = $script:Versions[$key]
    $script:State.version = $key
    $script:Repo = $v.Repo
    $script:Config = $v.Config
    $script:RepoUrl = $v.Url
}

function Test-Ztrx { $script:State.version -eq 'ztrx' }

function Find-Victory([string]$profile) {
    $p = Join-Path $script:Repo "target\$profile\victory.exe"
    if (Test-Path $p) { return $p }
    return $null
}

# dxil.dll (DXIL validator) - optional; VIctory uses it only to check translated shaders.
function Get-DxilPath {
    $cands = @()
    foreach ($v in @($env:VICTORY_DXIL, [Environment]::GetEnvironmentVariable('VICTORY_DXIL', 'User'))) { if ($v) { $cands += $v } }
    foreach ($v in @($env:XCL_DXC_DIR, [Environment]::GetEnvironmentVariable('XCL_DXC_DIR', 'User'))) { if ($v) { $cands += (Join-Path $v 'dxil.dll') } }
    $cands += (Join-Path $env:LOCALAPPDATA 'XCL\dxc\bin\x64\dxil.dll')
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (Test-Path $kits) {
        $cands += Get-ChildItem $kits -Directory | Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'x64\dxil.dll' }
    }
    foreach ($p in $cands) { if ($p -and (Test-Path $p)) { return $p } }
    return $null
}

if (-not ('VictoryLauncher.Native' -as [type])) {
    Add-Type -Namespace VictoryLauncher -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint feature);
'@
}
function Test-Avx2 { [VictoryLauncher.Native]::IsProcessorFeaturePresent(40) }   # PF_AVX2_INSTRUCTIONS_AVAILABLE

# The title's exe from MicrosoftGame.config, starting at a picked file or folder.
function Resolve-GameExe([string]$path) {
    $dir = if (Test-Path $path -PathType Container) { $path } else { Split-Path $path }
    if ((Test-Path $path -PathType Leaf) -and $path -match '\.exe$') { return $path }
    for ($i = 0; $i -lt 5 -and $dir; $i++) {
        $cfg = Join-Path $dir 'MicrosoftGame.config'
        if (Test-Path $cfg) {
            $xml = New-Object System.Xml.XmlDocument
            $xml.Load($cfg)
            $ex = $xml.SelectSingleNode("//*[local-name()='Executable']/@Name")
            if ($ex) { return (Join-Path $dir $ex.Value) }
        }
        $dir = Split-Path $dir
    }
    return $null
}

# ---------------------------------------------------------------- install / build tasks ----

# Runs $body in its own PowerShell window (so the user sees progress); the launcher watches it.
function Start-LauncherTask([string]$key, [string]$title, [string]$body) {
    if ($script:Tasks.ContainsKey($key)) { return }
    $full = @"
`$Host.UI.RawUI.WindowTitle = 'VIctory Launcher - $title'
`$ProgressPreference = 'SilentlyContinue'
`$env:Path = "`$env:USERPROFILE\.cargo\bin;`$env:ProgramFiles\Git\cmd;" + `$env:Path
`$env:VICTORY_CONFIG = '$($script:Config)'
`$global:LASTEXITCODE = 0
Write-Host '== $title ==' -ForegroundColor Cyan
try {
$body
} catch { Write-Host `$_ -ForegroundColor Red; `$global:LASTEXITCODE = 1 }
`$code = `$LASTEXITCODE
Write-Host ''
if (`$code -eq 0) { Write-Host 'Done.' -ForegroundColor Green } else { Write-Host "Failed (exit code `$code)." -ForegroundColor Red }
Write-Host 'Press Enter to close this window.'
[void](Read-Host)
exit `$code
"@
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($full))
    $p = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64" -PassThru
    [void]$p.Handle   # keep the handle so ExitCode is readable later
    $script:Tasks[$key] = $p
    Set-Status "$title started in its own window..."
    Update-Checks
}

$InstallGit = @'
winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements
'@

# rust-toolchain.toml in the repo pins the version; rustup fetches it on the first cargo call.
$InstallRust = @'
winget install --id Rustlang.Rustup -e --accept-source-agreements --accept-package-agreements
& "$env:USERPROFILE\.cargo\bin\rustup.exe" default stable-x86_64-pc-windows-msvc
'@

$InstallMsvc = @'
winget install --id Microsoft.VisualStudio.2022.BuildTools -e --accept-source-agreements --accept-package-agreements --override "--passive --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
'@

function Get-CloneScript {
    "git clone '$($script:RepoUrl)' '$($script:Repo)'"
}

function Get-BuildScript([string]$kind) {
    $cmd = if ($kind -eq 'diag') { 'cargo build --profile diag -p victory --features diagnostics' } else { 'cargo build --release -p victory' }
    "Set-Location '$($script:Repo)'`nrustup show active-toolchain`n$cmd"
}

# Pull the latest VIctory (never over uncommitted edits), replaying local commits - such as the
# sandbox's NVIDIA / plane-compositor fixes - on top with a rebase, then rebuild what was built.
function Get-SyncScript {
    "Set-Location '$($script:Repo)'`n" + @'
git fetch origin
if ($LASTEXITCODE -eq 0) {
    $dirty = git status --porcelain --untracked-files=no
    if ($dirty) {
        Write-Host 'You have changed files that git tracks - not updating, so nothing of yours is lost:' -ForegroundColor Yellow
        git status --short --untracked-files=no
        $global:LASTEXITCODE = 1
    } else {
        $before = git rev-parse HEAD
        git pull --rebase
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'The update conflicts with the local fixes - undoing, nothing changed.' -ForegroundColor Yellow
            git rebase --abort 2>$null
            $global:LASTEXITCODE = 1
        } else {
            $after = git rev-parse HEAD
            if ($before -eq $after) {
                Write-Host 'Already up to date.' -ForegroundColor Green
            } else {
                Write-Host ''
                Write-Host 'New changes:' -ForegroundColor Cyan
                git log --oneline "$before..$after"
                if (Get-Command cargo -ErrorAction SilentlyContinue) {
                    if (Test-Path 'target\release\victory.exe') { Write-Host "`nRebuilding (release)..." -ForegroundColor Cyan; cargo build --release -p victory }
                    if (Test-Path 'target\diag\victory.exe') { Write-Host "`nRebuilding (diagnostics)..." -ForegroundColor Cyan; cargo build --profile diag -p victory --features diagnostics }
                } else {
                    Write-Host 'Rust is not installed - press BUILD in the launcher once it is.' -ForegroundColor Yellow
                }
            }
        }
    }
}
'@
}

function Get-RepoState {
    $ErrorActionPreference = 'Continue'
    $git = Get-GitPath
    if (-not $git) { return @{ Git = $false } }
    if (-not (Test-Path (Join-Path $script:Repo '.git'))) { return @{ Git = $true; Repo = $false } }
    $head = & $git -C $script:Repo log -1 --format='%h (%cr)' 2>$null
    $branch = & $git -C $script:Repo rev-parse --abbrev-ref HEAD 2>$null
    $behind = & $git -C $script:Repo rev-list --count 'HEAD..@{u}' 2>$null
    $fetched = Join-Path $script:Repo '.git\FETCH_HEAD'
    $when = if (Test-Path $fetched) { (Get-Item $fetched).LastWriteTime.ToString('g') } else { 'at clone' }
    return @{ Git = $true; Repo = $true; Head = $head; Branch = $branch; Behind = $behind; Checked = $when }
}

# ---------------------------------------------------------------- system check ----

function New-CheckRow($name, $level, $detail, $actionLabel, $action, $enabled) {
    $g = New-Object Windows.Controls.Grid
    $g.Margin = '0,0,0,12'
    foreach ($w in @('Auto', '*', 'Auto')) {
        $c = New-Object Windows.Controls.ColumnDefinition
        $c.Width = $w
        $g.ColumnDefinitions.Add($c)
    }
    $color = switch ($level) { 'ok' { '#3DFFB0' } 'warn' { '#FFC857' } 'busy' { '#2C8BFF' } default { '#FF4D6D' } }
    $dot = New-Object Windows.Shapes.Ellipse
    $dot.Width = 12; $dot.Height = 12; $dot.Margin = '2,5,14,0'; $dot.VerticalAlignment = 'Top'
    $dot.Fill = (New-Object Windows.Media.BrushConverter).ConvertFromString($color)
    $glow = New-Object Windows.Media.Effects.DropShadowEffect
    $glow.Color = [Windows.Media.ColorConverter]::ConvertFromString($color); $glow.BlurRadius = 10; $glow.ShadowDepth = 0
    $dot.Effect = $glow
    $g.Children.Add($dot) | Out-Null

    $sp = New-Object Windows.Controls.StackPanel
    [Windows.Controls.Grid]::SetColumn($sp, 1)
    $t1 = New-Object Windows.Controls.TextBlock
    $t1.Text = $name; $t1.FontSize = 15; $t1.FontWeight = 'SemiBold'
    $t2 = New-Object Windows.Controls.TextBlock
    $t2.Text = $detail; $t2.FontSize = 12; $t2.TextWrapping = 'Wrap'
    $t2.Foreground = $win.FindResource('Muted')
    $sp.Children.Add($t1) | Out-Null
    $sp.Children.Add($t2) | Out-Null
    $g.Children.Add($sp) | Out-Null

    if ($actionLabel) {
        $b = New-Object Windows.Controls.Button
        $b.Style = $win.FindResource('NeonButton')
        $b.Content = $actionLabel; $b.FontSize = 12; $b.Padding = '12,5'; $b.Margin = '12,0,0,0'
        $b.VerticalAlignment = 'Center'; $b.IsEnabled = $enabled
        $b.Add_Click($action)
        [Windows.Controls.Grid]::SetColumn($b, 2)
        $g.Children.Add($b) | Out-Null
    }
    $ui.CheckRows.Children.Add($g) | Out-Null
}

function Update-Checks {
    $ui.CheckRows.Children.Clear()
    $busy = { param($k) $script:Tasks.ContainsKey($k) }
    $building = (& $busy 'build') -or (& $busy 'diag') -or (& $busy 'sync') -or (& $busy 'clone')

    $rs = Get-RepoState
    if (& $busy 'git') { New-CheckRow 'VIctory source (GitHub)' 'busy' 'Installing Git...' $null $null $false }
    elseif (& $busy 'clone') { New-CheckRow 'VIctory source (GitHub)' 'busy' 'Cloning...' $null $null $false }
    elseif (& $busy 'sync') { New-CheckRow 'VIctory source (GitHub)' 'busy' 'Syncing with GitHub...' $null $null $false }
    elseif (-not $rs.Git) { New-CheckRow 'VIctory source (GitHub)' 'err' 'Git is needed to download VIctory and its updates.' 'INSTALL GIT' { Start-LauncherTask 'git' 'Install Git' $InstallGit } $true }
    elseif (-not $rs.Repo) {
        if (Test-Path $script:Repo) { New-CheckRow 'VIctory source (GitHub)' 'warn' "$($script:Repo) exists but is not a git clone - updates cannot be pulled." $null $null $false }
        else { New-CheckRow 'VIctory source (GitHub)' 'err' "Not downloaded yet. Clones into $($script:Repo)." 'CLONE' { Start-LauncherTask 'clone' 'Clone VIctory' (Get-CloneScript) } $true }
    }
    else {
        $syncAction = { Start-LauncherTask 'sync' 'Sync with GitHub' (Get-SyncScript) }
        $lvl = if ($rs.Behind -and [int]$rs.Behind -gt 0) { 'warn' } else { 'ok' }
        $txt = if ($lvl -eq 'warn') { "$($rs.Behind) update(s) on $($rs.Branch). You have $($rs.Head). Last checked $($rs.Checked)." } else { "$($rs.Branch) at $($rs.Head). Last checked $($rs.Checked)." }
        New-CheckRow 'VIctory source (GitHub)' $lvl $txt 'SYNC' $syncAction (-not $building)
    }

    # Already built and no build tools here: a run-only account (e.g. the restricted victory-runner,
    # which cannot write the source) - building happens from another account.
    $built = [bool]((Find-Victory 'release') -or (Find-Victory 'diag'))
    $cargo = Get-CargoPath
    if (& $busy 'rust') { New-CheckRow 'Rust toolchain' 'busy' 'Installing...' $null $null $false }
    elseif ($cargo) { New-CheckRow 'Rust toolchain' 'ok' "$cargo  (the repo pins its version; rustup fetches it on the first build)" $null $null $false }
    elseif ($built) { New-CheckRow 'Rust toolchain' 'ok' 'Not needed to play: VIctory is already built. Build and update it from your own account.' $null $null $false }
    else { New-CheckRow 'Rust toolchain' 'err' 'Needed to build victory.exe.' 'INSTALL' { Start-LauncherTask 'rust' 'Install Rust' $InstallRust } $true }

    $msvc = Get-MsvcPath
    if (& $busy 'msvc') { New-CheckRow 'C++ Build Tools (MSVC)' 'busy' 'Installing... (a few GB, can take a while)' $null $null $false }
    elseif ($msvc) { New-CheckRow 'C++ Build Tools (MSVC)' 'ok' $msvc $null $null $false }
    elseif ($built) { New-CheckRow 'C++ Build Tools (MSVC)' 'ok' 'Not needed to play: VIctory is already built.' $null $null $false }
    else { New-CheckRow 'C++ Build Tools (MSVC)' 'err' 'The linker Rust needs on Windows. A few GB.' 'INSTALL' { Start-LauncherTask 'msvc' 'Install C++ Build Tools' $InstallMsvc } $true }

    $canBuild = [bool]($cargo -and $msvc -and $rs.Repo -and -not $building)
    $prereq = if ($cargo -and $msvc -and $rs.Repo) { '' } else { ' - get the source, Rust and the C++ Build Tools first.' }
    $rel = Find-Victory 'release'
    if (& $busy 'build') { New-CheckRow 'victory.exe (release)' 'busy' 'Building... the first build takes several minutes.' $null $null $false }
    elseif ($rel) { New-CheckRow 'victory.exe (release)' 'ok' $rel 'REBUILD' { Start-LauncherTask 'build' 'Build VIctory (release)' (Get-BuildScript 'release') } $canBuild }
    else { New-CheckRow 'victory.exe (release)' 'err' "Not built yet$prereq Used by the GPU renderer." 'BUILD' { Start-LauncherTask 'build' 'Build VIctory (release)' (Get-BuildScript 'release') } $canBuild }

    $diag = Find-Victory 'diag'
    if (& $busy 'diag') { New-CheckRow 'victory.exe (diagnostics)' 'busy' 'Building...' $null $null $false }
    elseif ($diag) { New-CheckRow 'victory.exe (diagnostics)' 'ok' $diag 'REBUILD' { Start-LauncherTask 'diag' 'Build VIctory (diagnostics)' (Get-BuildScript 'diag') } $canBuild }
    else { New-CheckRow 'victory.exe (diagnostics)' 'warn' "Optional$prereq Needed for the software (WARP) renderer and debugging switches." 'BUILD' { Start-LauncherTask 'diag' 'Build VIctory (diagnostics)' (Get-BuildScript 'diag') } $canBuild }

    $dxil = Get-DxilPath
    if ($dxil) { New-CheckRow 'DXIL validator (optional)' 'ok' $dxil $null $null $false }
    else { New-CheckRow 'DXIL validator (optional)' 'warn' 'dxil.dll not found. Only used to validate translated shaders (translate --validate); not needed to play.' $null $null $false }

    if (-not $script:Hw) {
        $script:Hw = @{
            Avx2  = Test-Avx2
            Gpus  = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Virtual|Parsec|Basic Display|Basic Render|Remote|Hyper-V' } | ForEach-Object { $_.Name })
            RamGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
            PageGb = [math]::Round(((Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | Measure-Object AllocatedBaseSize -Sum).Sum) / 1024)
        }
    }
    if ($script:Hw.Avx2) { New-CheckRow 'CPU (AVX2)' 'ok' 'AVX2 available.' $null $null $false }
    else { New-CheckRow 'CPU (AVX2)' 'err' 'VIctory needs a CPU with AVX2. (In a VM, check the processor compatibility setting is off.)' $null $null $false }

    $gpus = $script:Hw.Gpus
    if ($gpus.Count -eq 0) { New-CheckRow 'Graphics card' 'warn' 'No hardware D3D12 GPU (e.g. a VM without GPU partitioning). Only the software (WARP) renderer can work.' $null $null $false }
    elseif (($gpus -join ' ') -match 'NVIDIA') { New-CheckRow 'Graphics card' 'warn' (($gpus -join ', ') + ' - needs shader model 6.6 and mesh shaders; some compute programs need 64-lane waves (AMD).') $null $null $false }
    else { New-CheckRow 'Graphics card' 'ok' (($gpus -join ', ') + ' - needs shader model 6.6 and mesh shaders.') $null $null $false }

    $ramGb = $script:Hw.RamGb; $pg = $script:Hw.PageGb
    if ($ramGb -lt 16) { New-CheckRow 'Memory' 'warn' "$ramGb GB RAM, $pg GB page file - the title needs several GB of free commit at startup. If crashes.log shows error 1455, raise the page file." $null $null $false }
    else { New-CheckRow 'Memory' 'ok' "$ramGb GB RAM, $pg GB page file." $null $null $false }

    Update-GameCard
}

# ---------------------------------------------------------------- game ----

# The build a run uses: diagnostics for WARP and for the scripted intro skip, else release.
function Get-RunBuild {
    $stable = [bool]$script:State.stableMode -and -not (Test-Ztrx)
    if ([bool]$script:State.warp -or [bool]$script:State.skipIntro -or $stable) { Find-Victory 'diag' } else { Find-Victory 'release' }
}

function Get-SandboxDir {
    $v = Get-ConfigValue 'data_dir'
    if ($v) { Split-Path $v } else { $null }
}

function Get-LogDir {
    $s = Get-SandboxDir
    if ($s) { Join-Path $s 'logs' } else { Join-Path $env:LOCALAPPDATA 'victory\logs' }
}

function Update-GameCard {
    $exe = $script:State.exe
    $useWarp = [bool]$script:State.warp
    $bin = Get-RunBuild
    if (-not $exe) {
        $ui.GameName.Text = 'No game selected'
        $ui.GameDetail.Text = "Press CHOOSE GAME and pick the title's exe or MicrosoftGame.config from your own unpacked copy.`nConfig: $($script:Config)"
    } else {
        $ui.GameName.Text = Split-Path $exe -Leaf
        $lines = @("Exe: $exe", "Config: $($script:Config)")
        if (-not (Test-Path $exe)) { $lines += 'This file is gone (moved or deleted).' }
        $ui.GameDetail.Text = $lines -join "`n"
    }
    $ui.RenderHint.Text = if ($useWarp) {
        'Software rendering through WARP (VICTORY_D3D12_WARP=1). Very slow, but cannot hang or reset the display driver.' + $(if (-not (Find-Victory 'diag')) { ' Build the diagnostics exe first.' } else { '' })
    } else {
        'Hardware D3D12. Needs shader model 6.6 + mesh shaders.' + $(if (-not $bin) { ' Build the ' + $(if ($script:State.skipIntro) { 'diagnostics' } else { 'release' }) + ' exe first.' } else { '' })
    }
    # ztrx has neither our Stable mode switches nor the window size one; only it has Faster.
    $z = Test-Ztrx
    $ui.StableMode.IsEnabled = -not $z
    $ui.ZtrxFast.IsEnabled = $z
    $ui.VersionHint.Text = if ($z) {
        "ztrx (github.com/Zettrox/ztrx, forked to Hynicon/ztrx): $($script:Repo). Own shader cache and saves - the first start translates every shader again. Stable mode does not apply to it. PRE-BUILD SHADERS fills its cache before PLAY."
    } else { "Our VIctory build with the local fixes: $($script:Repo)." }
    $running = $script:Tasks.ContainsKey('game')
    $ui.PlayBtn.IsEnabled = [bool]($exe -and (Test-Path $exe) -and $bin -and -not $running)
    $ui.PlayBtn.Content = if ($running) { 'RUNNING' } else { 'PLAY' }
    # Pre-build: versions whose victory.exe has the `prebuild` command.
    $canPrebuild = Test-Path (Join-Path $script:Repo 'apps\victory\src\prebuild.rs')
    $ui.PrebuildBtn.Visibility = if ($canPrebuild) { 'Visible' } else { 'Collapsed' }
    $ui.PrebuildBtn.IsEnabled = [bool]($canPrebuild -and $bin -and -not $running -and -not $script:Tasks.ContainsKey('prebuild'))
    $ui.ConfigBtn.IsEnabled = Test-Path $script:Config
    $ui.CheckCfgBtn.IsEnabled = [bool]((Find-Victory 'release') -or (Find-Victory 'diag'))
}

function Select-Game {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Choose the title''s exe or its MicrosoftGame.config'
    $dlg.Filter = 'Xbox game (*.exe, MicrosoftGame.config)|*.exe;MicrosoftGame.config|All files|*.*'
    if (-not $dlg.ShowDialog($win)) { return }
    $exe = Resolve-GameExe $dlg.FileName
    if (-not $exe) { Set-Status 'No MicrosoftGame.config with an Executable entry found there - pick the exe directly.'; return }
    if ((Split-Path $exe -Leaf) -ieq 'victory.exe') { Set-Status 'That is VIctory itself - pick the game''s exe.'; return }
    $full = [IO.Path]::GetFullPath($exe)
    if ($full.StartsWith([IO.Path]::GetFullPath($script:Repo), [StringComparison]::OrdinalIgnoreCase)) {
        Set-Status 'Game files must be outside the VIctory source folder (its asset policy refuses them).'; return
    }
    $script:State.exe = $full
    Set-GameDir (Split-Path $full)
    Save-State
    Update-GameCard
    Set-Status "Game set; game_dir written to $($script:Config)."
}

function Start-Game {
    $exe = $script:State.exe
    $useWarp = [bool]$script:State.warp
    $skip = [bool]$script:State.skipIntro
    $bin = Get-RunBuild
    if (-not $exe -or -not $bin) { return }
    $env:VICTORY_CONFIG = $script:Config
    if ($useWarp) { $env:VICTORY_D3D12_WARP = '1' } else { Remove-Item Env:VICTORY_D3D12_WARP -ErrorAction SilentlyContinue }
    # Skip intro: A (Enter) every 3 s from 6 to 45 s - through the start screen and intro
    # video into the story's loading screens (diagnostics build only).
    if ($skip) { $env:VICTORY_KEYS = ((6..45 | Where-Object { $_ % 3 -eq 0 }) | ForEach-Object { "${_}:Enter" }) -join ',' }
    else { Remove-Item Env:VICTORY_KEYS -ErrorAction SilentlyContinue }
    # Stable mode: ray tracing off, known problem passes skipped (see $script:StableSkips).
    if ([bool]$script:State.stableMode -and -not (Test-Ztrx)) {
        $env:VICTORY_RAY_TRACING = 'off'
        $env:VICTORY_SKIP_PIPELINES = $script:StableSkips
    } else {
        Remove-Item Env:VICTORY_RAY_TRACING, Env:VICTORY_SKIP_PIPELINES -ErrorAction SilentlyContinue
    }
    # Window client size (frames are scaled to it); none: the game's own size.
    if ($script:State.windowSize -match '^\d+x\d+$') { $env:VICTORY_WINDOW_SIZE = $script:State.windowSize }
    else { Remove-Item Env:VICTORY_WINDOW_SIZE -ErrorAction SilentlyContinue }
    # ztrx's Faster setting (its README: cuts frame time on its test machines).
    if ((Test-Ztrx) -and [bool]$script:State.fast) { $env:VICTORY_RELAY = '2' } else { Remove-Item Env:VICTORY_RELAY -ErrorAction SilentlyContinue }
    # GPU crash details whenever the diagnostics build runs.
    if ($bin -eq (Find-Victory 'diag')) { $env:VICTORY_D3D12_DRED = '1' } else { Remove-Item Env:VICTORY_D3D12_DRED -ErrorAction SilentlyContinue }
    $dxil = Get-DxilPath
    if ($dxil -and -not $env:VICTORY_DXIL) { $env:VICTORY_DXIL = $dxil }
    $runArgs = "run `"$exe`" --execute"
    if ($script:State.console -eq 'series-s') { $runArgs += ' --console series-s' }
    # Every run's output goes to a log file (the newest 10 are kept).
    $logs = Get-LogDir
    New-Item -ItemType Directory -Force $logs | Out-Null
    Get-ChildItem $logs -Filter 'victory-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 9 |
        ForEach-Object { Remove-Item $_.FullName -ErrorAction SilentlyContinue }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $p = Start-Process -FilePath $bin -ArgumentList $runArgs -WorkingDirectory (Split-Path $bin) -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $logs "victory-$stamp.out.log") -RedirectStandardError (Join-Path $logs "victory-$stamp.log") -PassThru
    [void]$p.Handle
    $script:Tasks['game'] = $p
    Set-Status "Starting $(Split-Path $exe -Leaf) with $($script:Versions[$script:State.version].Name)$(if ($useWarp) { ' on WARP' })$(if ($skip) { ', skipping the intro' })... (log: LOG button)"
    Update-GameCard
}

function Open-Log {
    $log = Get-ChildItem (Get-LogDir) -Filter 'victory-*.log' -ErrorAction SilentlyContinue | Where-Object Name -notmatch '\.out\.log$' |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($log) { Start-Process notepad.exe $log.FullName } else { Set-Status 'No run log yet - press PLAY first.' }
}

function Open-CrashLog {
    $data = Get-DataDir
    $log = if (Test-Path $data) { Get-ChildItem $data -Recurse -Filter 'crashes.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
    if ($log) { Start-Process notepad.exe $log.FullName } else { Set-Status "No crashes.log under $data yet." }
}

function Open-Path([string]$p) {
    if (Test-Path $p) { Start-Process $p } else { Set-Status "$p does not exist yet - run the game once." }
}

# ---------------------------------------------------------------- events ----

$ui.Header.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch { } })
$ui.MinBtn.Add_Click({ $win.WindowState = 'Minimized' })
$ui.CloseBtn.Add_Click({ $win.Close() })
$ui.PickBtn.Add_Click({ try { Select-Game } catch { Set-Status "Error: $_" } })
$ui.ConfigBtn.Add_Click({ Start-Process notepad.exe $script:Config })
$ui.CheckCfgBtn.Add_Click({
    $bin = if (Find-Victory 'release') { Find-Victory 'release' } else { Find-Victory 'diag' }
    Start-LauncherTask 'config' 'Check paths' "& '$bin' config"
})
$ui.SeriesX.Add_Checked({ $script:State.console = 'series-x'; Save-State })
$ui.SeriesS.Add_Checked({ $script:State.console = 'series-s'; Save-State })
$ui.RenderGpu.Add_Checked({ $script:State.warp = $false; Save-State; Update-GameCard })
$ui.RenderWarp.Add_Checked({ $script:State.warp = $true; Save-State; Update-GameCard })
$ui.PlayBtn.Add_Click({ try { Start-Game } catch { Set-Status "Error: $_" } })
$ui.CrashBtn.Add_Click({ Open-CrashLog })
$ui.LogBtn.Add_Click({ Open-Log })
$ui.WindowSize.Add_SelectionChanged({
    $item = $ui.WindowSize.SelectedItem
    if ($item) { $script:State.windowSize = [string]$item.Content; Save-State }
})
$ui.StableMode.Add_Checked({ $script:State.stableMode = $true; Save-State; Update-GameCard })
$ui.StableMode.Add_Unchecked({ $script:State.stableMode = $false; Save-State; Update-GameCard })
$ui.VerVictory.Add_Checked({ Set-Version 'victory'; Save-State; Update-Checks; Update-GameCard; Set-Status 'Version: VIctory (our build).' })
$ui.VerZtrx.Add_Checked({ Set-Version 'ztrx'; Save-State; Update-Checks; Update-GameCard; Set-Status 'Version: ztrx.' })
$ui.ZtrxFast.Add_Checked({ $script:State.fast = $true; Save-State })
$ui.ZtrxFast.Add_Unchecked({ $script:State.fast = $false; Save-State })
$ui.SkipIntro.Add_Checked({ $script:State.skipIntro = $true; Save-State; Update-GameCard })
$ui.SkipIntro.Add_Unchecked({ $script:State.skipIntro = $false; Save-State; Update-GameCard })
$ui.PrebuildBtn.Add_Click({
    # The cache is keyed by the exe, so the one PLAY will run.
    $bin = Get-RunBuild
    if (-not $bin) { Set-Status 'Build VIctory first.'; return }
    Start-LauncherTask 'prebuild' 'Pre-build shaders' "& '$bin' prebuild"
    Update-GameCard
})
$ui.DataBtn.Add_Click({ Open-Path (Get-DataDir) })
$ui.CacheBtn.Add_Click({ Open-Path (Get-CacheDir) })
$ui.RefreshBtn.Add_Click({ $script:Hw = $null; Update-Checks; Set-Status 'System check refreshed.' })

# watch running installs / builds / the game
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1.5)
$timer.Add_Tick({
    $done = @($script:Tasks.Keys | Where-Object { $script:Tasks[$_].HasExited })
    foreach ($k in $done) {
        $code = $script:Tasks[$k].ExitCode
        $script:Tasks.Remove($k)
        if ($k -eq 'game') {
            if ($code -eq 0) { Set-Status 'The game closed.' } else { Set-Status "VIctory ended with code $code - see CRASH LOG." }
        } else {
            if ($code -eq 0) { Set-Status 'Finished.' } else { Set-Status "That step failed (exit code $code) - see its window." }
        }
    }
    if ($done.Count -gt 0) { Update-Checks; Update-GameCard }
})
$timer.Start()

if (Get-SandboxDir) { $script:StateFile = Join-Path (Get-SandboxDir) 'launcher.json' }
Load-State
if ($script:State.console -eq 'series-s') { $ui.SeriesS.IsChecked = $true } else { $ui.SeriesX.IsChecked = $true }
# default to WARP when there is no hardware GPU (e.g. inside a VM)
$hasGpu = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Virtual|Parsec|Basic Display|Basic Render|Remote|Hyper-V' }).Count -gt 0
if (-not (Test-Path $script:StateFile) -and -not $hasGpu) { $script:State.warp = $true }
if ($script:State.warp) { $ui.RenderWarp.IsChecked = $true } else { $ui.RenderGpu.IsChecked = $true }
$ui.SkipIntro.IsChecked = [bool]$script:State.skipIntro
$ui.ZtrxFast.IsChecked = [bool]$script:State.fast
Set-Version ([string]$script:State.version)
if (Test-Ztrx) { $ui.VerZtrx.IsChecked = $true } else { $ui.VerVictory.IsChecked = $true }
$ui.StableMode.IsChecked = [bool]$script:State.stableMode
$want = if ($script:State.windowSize) { [string]$script:State.windowSize } else { "Game's own size" }
$ui.WindowSize.SelectedItem = @($ui.WindowSize.Items | Where-Object { [string]$_.Content -eq $want } | Select-Object -First 1)[0]
if (-not $ui.WindowSize.SelectedItem) { $ui.WindowSize.SelectedIndex = 2 }
Update-Checks
if (-not $ui.Status.Text) { Set-Status 'Ready.' }

# VICTORY_LAUNCHER_SCREENSHOT=<file.png>: render the window to a picture and exit (for checking the look)
if ($env:VICTORY_LAUNCHER_SCREENSHOT) {
    $win.Show()
    $win.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$win.ActualWidth), ([int]$win.ActualHeight), 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($win)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [IO.File]::Create($env:VICTORY_LAUNCHER_SCREENSHOT)
    $enc.Save($fs); $fs.Close()
    $win.Close()
    return
}
[void]$win.ShowDialog()
