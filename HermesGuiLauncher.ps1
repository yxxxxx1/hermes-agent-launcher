param(
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class HermesLauncherWin32 {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
}
"@

function Get-HermesDefaults {
    $hermesHome = Join-Path $env:USERPROFILE '.hermes'
    $installRoot = Join-Path $env:LOCALAPPDATA 'hermes'
    $installDir = Join-Path $installRoot 'hermes-agent'
    $venvScripts = Join-Path $installDir 'venv\Scripts'
    [pscustomobject]@{
        HermesHome         = $hermesHome
        InstallRoot        = $installRoot
        InstallDir         = $installDir
        VenvScripts        = $venvScripts
        HermesExe          = Join-Path $venvScripts 'hermes.exe'
        PythonExe          = Join-Path $venvScripts 'python.exe'
        ConfigPath         = Join-Path $hermesHome 'config.yaml'
        EnvPath            = Join-Path $hermesHome '.env'
        LogsPath           = Join-Path $hermesHome 'logs'
        OfficialInstallUrl = 'https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1'
        OfficialRepoUrl    = 'https://github.com/NousResearch/hermes-agent'
        OfficialDocsUrl    = 'https://hermes-agent.nousresearch.com/docs'
    }
}

function Test-HermesInstalled {
    param(
        [string]$InstallDir,
        [string]$HermesHome
    )

    $hermesExe = Join-Path $InstallDir 'venv\Scripts\hermes.exe'
    $configPath = Join-Path $HermesHome 'config.yaml'
    $envPath = Join-Path $HermesHome '.env'

    [pscustomobject]@{
        Installed        = (Test-Path $hermesExe)
        HermesExe        = $hermesExe
        ConfigExists     = (Test-Path $configPath)
        EnvExists        = (Test-Path $envPath)
        RepoExists       = (Test-Path (Join-Path $InstallDir '.git'))
        InstallDirExists = (Test-Path $InstallDir)
    }
}

function Resolve-HermesCommand {
    param([string]$InstallDir)

    $candidates = @(
        (Join-Path $InstallDir 'venv\Scripts\hermes.exe'),
        (Join-Path $InstallDir 'hermes.exe')
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    $command = Get-Command hermes -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    return $null
}

function Resolve-UvCommand {
    $candidates = New-Object System.Collections.Generic.List[string]
    $command = Get-Command uv -ErrorAction SilentlyContinue
    if ($command) { $candidates.Add($command.Source) }
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\Scripts\uv.exe'))
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\Scripts\uv.exe'))
    $candidates.Add((Join-Path $env:USERPROFILE '.local\bin\uv.exe'))

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    return $null
}

function Get-WindowsInstallEnvironment {
    $pyLauncherVersions = $null
    $pythonVersion = $null
    $uvVersion = $null
    $wingetVersion = $null

    try {
        if (Get-Command py -ErrorAction SilentlyContinue) {
            $pyLauncherVersions = (& py -0p 2>$null | Out-String).Trim()
        }
    } catch { }

    try {
        if (Get-Command python -ErrorAction SilentlyContinue) {
            $pythonVersion = (& python --version 2>$null | Out-String).Trim()
        }
    } catch { }

    try {
        $uvCmd = Resolve-UvCommand
        if ($uvCmd) {
            $uvVersion = (& $uvCmd --version 2>$null | Out-String).Trim()
        }
    } catch { }

    try {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            $wingetVersion = (& winget --version 2>$null | Out-String).Trim()
        }
    } catch { }

    $allPythonText = @($pyLauncherVersions, $pythonVersion) -join "`n"
    $hasPython311 = $allPythonText -match '3\.11'
    $hasPython312 = $allPythonText -match '3\.12'
    $hasPython310 = $allPythonText -match '3\.10'
    $hasPython313 = $allPythonText -match '3\.13'
    $hasOnlyPython313 = $hasPython313 -and -not ($hasPython311 -or $hasPython312 -or $hasPython310)

    [pscustomobject]@{
        PyLauncherVersions = $pyLauncherVersions
        PythonVersion      = $pythonVersion
        UvVersion          = $uvVersion
        WingetVersion      = $wingetVersion
        HasPython311       = [bool]$hasPython311
        HasPython312       = [bool]$hasPython312
        HasPython310       = [bool]$hasPython310
        HasPython313       = [bool]$hasPython313
        HasOnlyPython313   = [bool]$hasOnlyPython313
    }
}

function Get-PreferredPythonVersionForInstall {
    param($InstallEnv)

    if ($InstallEnv.HasPython311) { return '3.11' }
    if ($InstallEnv.HasPython312) { return '3.12' }
    if ($InstallEnv.HasPython310) { return '3.10' }
    if ($InstallEnv.HasPython313) { return '3.13' }
    return '3.11'
}

function Get-OpenClawSources {
    $candidates = @(
        (Join-Path $env:USERPROFILE '.openclaw'),
        (Join-Path $env:USERPROFILE '.clawdbot'),
        (Join-Path $env:USERPROFILE '.moldbot')
    )

    @($candidates | Where-Object { Test-Path $_ })
}

function Test-HermesModelConfigured {
    param([string]$HermesHome)

    $configPath = Join-Path $HermesHome 'config.yaml'
    $envPath = Join-Path $HermesHome '.env'
    $authPath = Join-Path $HermesHome 'auth.json'
    $hasModelConfig = $false
    $hasApiKey = $false
    $configProvider = $null
    $configModel = $null
    $authProvider = $null
    $hasAuthCredential = $false

    if (Test-Path $configPath) {
        $configText = [System.IO.File]::ReadAllText($configPath)
        $hasModelConfig = $configText -match '(?m)^\s*model\s*:' -and $configText -match '(?m)^\s+default\s*:\s*\S+'

        if ($configText -match '(?m)^\s+provider\s*:\s*(\S+)') {
            $configProvider = $matches[1].Trim()
        } elseif ($configText -match '(?m)^\s*provider\s*:\s*(\S+)') {
            $configProvider = $matches[1].Trim()
        }

        if ($configText -match '(?m)^\s+default\s*:\s*(\S+)') {
            $configModel = $matches[1].Trim()
        } elseif ($configText -match '(?m)^\s+model\s*:\s*(\S+)') {
            $configModel = $matches[1].Trim()
            $hasModelConfig = $true
        }
    }

    if (Test-Path $envPath) {
        $envText = [System.IO.File]::ReadAllText($envPath)
        $hasApiKey = $envText -match '(?m)^\s*[A-Z0-9_]*API_KEY\s*=\s*[^#\s]+'
    }

    if (Test-Path $authPath) {
        try {
            $authData = Get-Content -Path $authPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($authData.active_provider) {
                $authProvider = [string]$authData.active_provider
            }

            if ($authProvider -and $authData.providers.$authProvider) {
                $providerEntry = $authData.providers.$authProvider
                if ($providerEntry.access_token -or $providerEntry.agent_key -or $providerEntry.api_key -or $providerEntry.refresh_token) {
                    $hasAuthCredential = $true
                }
            }
        } catch { }
    }

    if (-not $hasApiKey -and $hasAuthCredential) {
        if (-not $configProvider -or $configProvider -eq 'auto' -or ($authProvider -and $configProvider -eq $authProvider)) {
            $hasApiKey = $true
        }
    }

    [pscustomobject]@{
        HasModelConfig = [bool]$hasModelConfig
        HasApiKey      = [bool]$hasApiKey
        ReadyLikely    = [bool]($hasModelConfig -and $hasApiKey)
        Provider       = $configProvider
        Model          = $configModel
        AuthProvider   = $authProvider
        UsesAuthJson   = [bool]$hasAuthCredential
    }
}

function Ensure-HermesConfigScaffold {
    param(
        [string]$InstallDir,
        [string]$HermesHome
    )

    foreach ($dir in @('cron', 'sessions', 'logs', 'pairing', 'hooks', 'image_cache', 'audio_cache', 'memories', 'skills', 'whatsapp\session')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $HermesHome $dir) | Out-Null
    }

    $envPath = Join-Path $HermesHome '.env'
    if (-not (Test-Path $envPath)) {
        $exampleEnv = Join-Path $InstallDir '.env.example'
        if (Test-Path $exampleEnv) {
            Copy-Item $exampleEnv $envPath
        } else {
            New-Item -ItemType File -Force -Path $envPath | Out-Null
        }
    }

    $configPath = Join-Path $HermesHome 'config.yaml'
    if (-not (Test-Path $configPath)) {
        $exampleConfig = Join-Path $InstallDir 'cli-config.yaml.example'
        if (Test-Path $exampleConfig) {
            Copy-Item $exampleConfig $configPath
        } else {
            New-Item -ItemType File -Force -Path $configPath | Out-Null
        }
    }

    $soulPath = Join-Path $HermesHome 'SOUL.md'
    if (-not (Test-Path $soulPath)) {
        @'
# Hermes Agent Persona

在这里写入你希望 Hermes 使用的沟通风格。
'@ | Set-Content -Path $soulPath -Encoding UTF8
    }
}

function Start-InTerminal {
    param(
        [string]$CommandLine,
        [string]$WorkingDirectory,
        [string]$HermesHome
    )

    $bootstrapLines = @(
        '[Console]::InputEncoding = [System.Text.Encoding]::UTF8'
        '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8'
        '$OutputEncoding = [System.Text.Encoding]::UTF8'
        '$env:PYTHONIOENCODING = ''utf-8'''
        '$env:PYTHONUTF8 = ''1'''
        'chcp 65001 > $null'
    )
    if ($HermesHome) {
        $bootstrapLines += "`$env:HERMES_HOME = '$HermesHome'"
    }
    $bootstrapLines += "Set-Location -LiteralPath '$WorkingDirectory'"
    $bootstrapLines += $CommandLine

    $bootstrap = [string]::Join([Environment]::NewLine, $bootstrapLines)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
    Start-Process powershell.exe -PassThru -ArgumentList @('-NoExit', '-EncodedCommand', $encoded)
}

function Open-InExplorer {
    param([string]$Path)

    if (-not $Path) { return }
    if (Test-Path $Path) {
        Start-Process explorer.exe $Path | Out-Null
        return
    }

    $parent = Split-Path -Parent $Path
    if ($parent -and (Test-Path $parent)) {
        Start-Process explorer.exe $parent | Out-Null
    }
}

function Build-InstallArguments {
    param(
        [string]$ScriptPath,
        [string]$InstallDir,
        [string]$HermesHome,
        [string]$Branch,
        [bool]$NoVenv,
        [bool]$SkipSetup
    )

    $args = @('-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-InstallDir', $InstallDir, '-HermesHome', $HermesHome, '-Branch', $Branch)
    if ($NoVenv) { $args += '-NoVenv' }
    if ($SkipSetup) { $args += '-SkipSetup' }
    return $args
}

function New-TempScriptFromUrl {
    param(
        [string]$Url,
        [string]$PreferredPythonVersion = '3.11'
    )

    $tempPath = Join-Path $env:TEMP ('hermes-install-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url
    if (-not $response.Content) {
        throw "未能从 $Url 下载到安装脚本内容。"
    }

    $content = $response.Content

    $rgOriginal = @'
    Write-Info "Checking ripgrep (fast file search)..."
    if (Get-Command rg -ErrorAction SilentlyContinue) {
        $version = rg --version | Select-Object -First 1
        Write-Success "$version found"
        $script:HasRipgrep = $true
    } else {
        $needRipgrep = $true
    }
'@
    $rgPatched = @'
    Write-Info "Checking ripgrep (fast file search)..."
    if (Get-Command rg -ErrorAction SilentlyContinue) {
        try {
            $version = rg --version | Select-Object -First 1
            Write-Success "$version found"
            $script:HasRipgrep = $true
        } catch {
            Write-Warn "ripgrep was found but could not be executed; will try to install a usable copy"
            $needRipgrep = $true
        }
    } else {
        $needRipgrep = $true
    }
'@
    if ($content.Contains($rgOriginal)) {
        $content = $content.Replace($rgOriginal, $rgPatched)
    }

    $pythonVersionOriginal = '$PythonVersion = "3.11"'
    $pythonVersionPatched = ('$PythonVersion = "{0}"' -f $PreferredPythonVersion)
    if ($content.Contains($pythonVersionOriginal)) {
        $content = $content.Replace($pythonVersionOriginal, $pythonVersionPatched)
    }

    $pythonWarnOriginal = 'Write-Info " Or: winget install Python.Python.3.11"'
    $pythonWarnPatched = @'
Write-Info " Or: winget install Python.Python.3.11"
Write-Info " GUI note: this launcher prefers reusing an already installed compatible Python before forcing a new Python download."
'@
    if ($content.Contains($pythonWarnOriginal)) {
        $content = $content.Replace($pythonWarnOriginal, $pythonWarnPatched)
    }

    $skipPattern = 'function Install-SystemPackages \{.*?# ============================================================================\s+# Installation\s+# ============================================================================'
    $skipReplacement = @'
function Install-SystemPackages {
    $script:HasRipgrep = $false
    $script:HasFfmpeg = $false
    Write-Info "Skipping optional ripgrep/ffmpeg auto-install in GUI launcher mode"
}

# ============================================================================
# Installation
# ============================================================================
'@
    $regex = [System.Text.RegularExpressions.Regex]::new($skipPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($regex.IsMatch($content)) {
        $content = $regex.Replace($content, $skipReplacement, 1)
    }

    $gatewayPromptOriginal = @'
    Write-Host ""
    Write-Info "Messaging platform token detected!"
    Write-Info "The gateway handles messaging platforms and cron job execution."
    Write-Host ""
    $response = Read-Host "Would you like to start the gateway now? [Y/n]"

    if ($response -eq "" -or $response -match "^[Yy]") {
        Write-Info "Starting gateway in background..."
        try {
            $logFile = "$HermesHome\logs\gateway.log"
            Start-Process -FilePath $hermesCmd -ArgumentList "gateway" `
                -RedirectStandardOutput $logFile `
                -RedirectStandardError "$HermesHome\logs\gateway-error.log" `
                -WindowStyle Hidden
            Write-Success "Gateway started! Your bot is now online."
            Write-Info "Logs: $logFile"
            Write-Info "To stop: close the gateway process from Task Manager"
        } catch {
            Write-Warn "Failed to start gateway. Run manually: hermes gateway"
        }
    } else {
        Write-Info "Skipped. Start the gateway later with: hermes gateway"
    }
'@
    $gatewayPromptPatched = @'
    Write-Host ""
    Write-Info "Messaging platform token detected!"
    Write-Info "Gateway startup is deferred to the GUI launcher."
    Write-Info "Skipped starting the gateway during installation. Start it later with: hermes gateway"
'@
    if ($content.Contains($gatewayPromptOriginal)) {
        $content = $content.Replace($gatewayPromptOriginal, $gatewayPromptPatched)
    }

    [System.IO.File]::WriteAllText($tempPath, $content, [System.Text.Encoding]::Unicode)
    return $tempPath
}

function Test-HermesGatewayReadiness {
    param(
        [string]$InstallDir,
        [string]$HermesHome
    )

    $pythonPath = Join-Path $InstallDir 'venv\Scripts\python.exe'
    $envPath = Join-Path $HermesHome '.env'
    $hasTelegramDependency = $false
    $hasTelegramToken = $false
    $hasAllowlist = $false
    $hasAllowAll = $false
    $connectedPlatforms = @()
    $missingDependencyPlatforms = @()
    $inspectedViaPython = $false

    if (Test-Path $pythonPath) {
        $oldErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            Push-Location $InstallDir
            & $pythonPath -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('telegram') else 1)" *> $null
            $hasTelegramDependency = ($LASTEXITCODE -eq 0)
        } catch {
            $hasTelegramDependency = $false
        } finally {
            Pop-Location
            $ErrorActionPreference = $oldErrorActionPreference
        }

        try {
            $gatewayProbe = @'
import importlib
import json
import os

skip_platforms = {"api_server", "webhook"}
module_map = {
    "telegram": "telegram",
    "discord": "discord",
    "slack": "slack",
    "matrix": "matrix",
    "dingtalk": "dingtalk",
    "feishu": "feishu",
    "wecom": "wecom",
    "signal": "signal",
    "mattermost": "mattermost",
    "email": "email",
    "sms": "sms",
    "whatsapp": "whatsapp",
    "bluebubbles": "bluebubbles",
    "weixin": "weixin",
    "homeassistant": "homeassistant",
}

from gateway.config import load_gateway_config

cfg = load_gateway_config()
connected = []
missing = []

for platform in cfg.get_connected_platforms():
    name = getattr(platform, "value", str(platform))
    if name in skip_platforms:
        continue
    connected.append(name)
    module_name = module_map.get(name)
    ok = True
    if module_name:
        try:
            mod = importlib.import_module(f"gateway.platforms.{module_name}")
            fn = next((getattr(mod, attr) for attr in dir(mod) if attr.startswith("check_") and attr.endswith("_requirements")), None)
            if callable(fn):
                ok = bool(fn())
        except Exception:
            ok = False
    if not ok:
        missing.append(name)

print(json.dumps({"connected": connected, "missing": missing}, ensure_ascii=False))
'@
            Push-Location $InstallDir
            $output = & $pythonPath -c $gatewayProbe 2>$null
            if ($output) {
                $probe = ($output | Select-Object -Last 1 | ConvertFrom-Json)
                if ($probe) {
                    $connectedPlatforms = @($probe.connected)
                    $missingDependencyPlatforms = @($probe.missing)
                    $inspectedViaPython = $true
                    if ($connectedPlatforms -contains 'telegram') {
                        $hasTelegramToken = $true
                        $hasTelegramDependency = -not ($missingDependencyPlatforms -contains 'telegram')
                    }
                }
            }
        } catch { }
        finally { Pop-Location }
    }

    if (Test-Path $envPath) {
        $envText = [System.IO.File]::ReadAllText($envPath)
        $hasTelegramToken = $envText -match '(?m)^\s*TELEGRAM_BOT_TOKEN\s*=\s*[^#\s]+'
        $hasAllowlist = $envText -match '(?m)^\s*(TELEGRAM|DISCORD|SLACK|WHATSAPP|MATRIX|DINGTALK|FEISHU|WEIXIN|BLUEBUBBLES)_ALLOWED_USERS\s*=\s*[^#\s]+'
        $hasAllowAll = ($envText -match '(?m)^\s*GATEWAY_ALLOW_ALL_USERS\s*=\s*true\s*$') -or
            ($envText -match '(?m)^\s*(WEIXIN_ALLOW_ALL_USERS)\s*=\s*true\s*$') -or
            ($envText -match '(?m)^\s*WEIXIN_DM_POLICY\s*=\s*(pairing|open|allowlist)\s*$')

        if (-not $inspectedViaPython) {
            $fallbackPlatforms = New-Object System.Collections.Generic.List[string]
            $platformPatterns = [ordered]@{
                telegram      = '(?m)^\s*TELEGRAM_BOT_TOKEN\s*=\s*[^#\s]+'
                discord       = '(?m)^\s*DISCORD_BOT_TOKEN\s*=\s*[^#\s]+'
                slack         = '(?m)^\s*SLACK_BOT_TOKEN\s*=\s*[^#\s]+'
                whatsapp      = '(?m)^\s*WHATSAPP_ENABLED\s*=\s*[^#\s]+'
                signal        = '(?m)^\s*SIGNAL_HTTP_URL\s*=\s*[^#\s]+'
                email         = '(?m)^\s*EMAIL_ADDRESS\s*=\s*[^#\s]+'
                sms           = '(?m)^\s*TWILIO_ACCOUNT_SID\s*=\s*[^#\s]+'
                matrix        = '(?m)^\s*MATRIX_HOMESERVER_URL\s*=\s*[^#\s]+'
                mattermost    = '(?m)^\s*MATTERMOST_URL\s*=\s*[^#\s]+'
                homeassistant = '(?m)^\s*HASS_TOKEN\s*=\s*[^#\s]+'
                dingtalk      = '(?m)^\s*DINGTALK_CLIENT_ID\s*=\s*[^#\s]+'
                feishu        = '(?m)^\s*FEISHU_APP_ID\s*=\s*[^#\s]+'
                wecom         = '(?m)^\s*WECOM_BOT_ID\s*=\s*[^#\s]+'
                weixin        = '(?m)^\s*WEIXIN_ACCOUNT_ID\s*=\s*[^#\s]+'
                bluebubbles   = '(?m)^\s*BLUEBUBBLES_SERVER_URL\s*=\s*[^#\s]+'
            }
            foreach ($entry in $platformPatterns.GetEnumerator()) {
                if ($envText -match $entry.Value) {
                    $fallbackPlatforms.Add($entry.Key) | Out-Null
                }
            }
            $connectedPlatforms = @($fallbackPlatforms.ToArray())
            if ($connectedPlatforms -contains 'telegram') {
                $hasTelegramDependency = $hasTelegramDependency
            }
        }
    }

    $needsDependencyInstall = ($missingDependencyPlatforms.Count -gt 0)
    $hasConfiguredChannel = ($connectedPlatforms.Count -gt 0)

    [pscustomobject]@{
        HasTelegramToken       = [bool]$hasTelegramToken
        HasTelegramDependency  = [bool]$hasTelegramDependency
        HasAllowlist           = [bool]$hasAllowlist
        HasAllowAll            = [bool]$hasAllowAll
        HasGatewayAccessPolicy = [bool]($hasAllowlist -or $hasAllowAll)
        HasConfiguredChannel   = [bool]$hasConfiguredChannel
        NeedsDependencyInstall = [bool]$needsDependencyInstall
        ConnectedPlatforms     = @($connectedPlatforms)
        MissingDependencyPlatforms = @($missingDependencyPlatforms)
    }
}

function Get-GatewayLockDirectory {
    $override = [Environment]::GetEnvironmentVariable('HERMES_GATEWAY_LOCK_DIR')
    if ($override) { return $override }
    if ($env:XDG_STATE_HOME) { return (Join-Path $env:XDG_STATE_HOME 'hermes\gateway-locks') }
    return (Join-Path $env:USERPROFILE '.local\state\hermes\gateway-locks')
}

function Clear-StaleGatewayRuntimeFiles {
    param([string]$HermesHome)

    if (-not $HermesHome) { return $false }

    $pidPath = Join-Path $HermesHome 'gateway.pid'
    $statePath = Join-Path $HermesHome 'gateway_state.json'
    if (-not (Test-Path $pidPath)) { return $false }

    $stale = $false
    try {
        $record = [System.IO.File]::ReadAllText($pidPath) | ConvertFrom-Json
        $gatewayPid = [int]$record.pid
        if (-not (Get-Process -Id $gatewayPid -ErrorAction SilentlyContinue)) {
            $stale = $true
        }
    } catch {
        $stale = $true
    }

    if ($stale) {
        Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
        Remove-Item $statePath -Force -ErrorAction SilentlyContinue
        return $true
    }

    return $false
}

function Clear-StaleGatewayScopeLocks {
    $lockDir = Get-GatewayLockDirectory
    if (-not $lockDir -or -not (Test-Path $lockDir)) {
        return [pscustomobject]@{ Count = 0; Names = @() }
    }

    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($lockFile in @(Get-ChildItem -LiteralPath $lockDir -Filter '*.lock' -File -ErrorAction SilentlyContinue)) {
        $remove = $false
        try {
            $record = [System.IO.File]::ReadAllText($lockFile.FullName) | ConvertFrom-Json
            $lockPid = [int]$record.pid
            if (-not $lockPid -or -not (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
                $remove = $true
            }
        } catch {
            $remove = $true
        }

        if ($remove) {
            try {
                Remove-Item -LiteralPath $lockFile.FullName -Force -ErrorAction Stop
                $removed.Add($lockFile.Name) | Out-Null
            } catch { }
        }
    }

    [pscustomobject]@{ Count = $removed.Count; Names = @($removed.ToArray()) }
}

function Get-GatewayRuntimeStatus {
    param([string]$HermesHome)

    $statePath = Join-Path $HermesHome 'gateway_state.json'
    $pidPath = Join-Path $HermesHome 'gateway.pid'
    $runtimeRecord = $null
    $runtimePid = $null
    $runtimeProcess = $null

    foreach ($path in @($statePath, $pidPath)) {
        if ($path -and (Test-Path $path)) {
            try {
                $runtimeRecord = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
                break
            } catch { }
        }
    }

    if ($runtimeRecord -and $runtimeRecord.pid) {
        try { $runtimePid = [int]$runtimeRecord.pid } catch { $runtimePid = $null }
        if ($runtimePid) {
            $runtimeProcess = Get-Process -Id $runtimePid -ErrorAction SilentlyContinue
        }
    }

    if ($runtimeProcess) {
        return [pscustomobject]@{
            State   = 'Running'
            Pid     = $runtimePid
            Alive   = $true
            Message = '已检测到 Hermes 消息网关正在运行。'
        }
    }

    if ($runtimeRecord -and $runtimeRecord.exit_reason) {
        return [pscustomobject]@{
            State   = 'Failed'
            Pid     = $runtimePid
            Alive   = $false
            Message = "最近一次网关退出原因：$($runtimeRecord.exit_reason)"
        }
    }

    if ($script:GatewayRuntimeState -eq 'Starting') {
        return [pscustomobject]@{
            State   = 'Starting'
            Pid     = $script:GatewayTerminalPid
            Alive   = [bool](Get-Process -Id $script:GatewayTerminalPid -ErrorAction SilentlyContinue)
            Message = if ($script:GatewayRuntimeMessage) { $script:GatewayRuntimeMessage } else { '消息网关刚刚启动，正在等待状态文件。' }
        }
    }

    if ($script:GatewayRuntimeState -eq 'Failed') {
        return [pscustomobject]@{
            State   = 'Failed'
            Pid     = $script:GatewayTerminalPid
            Alive   = $false
            Message = if ($script:GatewayRuntimeMessage) { $script:GatewayRuntimeMessage } else { '上一次消息网关启动失败。' }
        }
    }

    [pscustomobject]@{
        State   = 'Idle'
        Pid     = $null
        Alive   = $false
        Message = $null
    }
}

function Start-MessagingDependencyInstall {
    param(
        [string]$InstallDir,
        [string]$HermesHome
    )

    $uvCommand = Resolve-UvCommand
    if (-not $uvCommand) {
        [System.Windows.MessageBox]::Show('未找到 uv。请先重新运行“安装 / 更新 Hermes”，或确认 uv 已加入 PATH。', 'Hermes 启动器')
        return $false
    }

    $venvPath = Join-Path $InstallDir 'venv'
    if (-not (Test-Path $venvPath)) {
        [System.Windows.MessageBox]::Show('未找到 Hermes 虚拟环境。请先完成安装 / 更新 Hermes。', 'Hermes 启动器')
        return $false
    }

    $command = ("`$env:VIRTUAL_ENV = '{0}'; & '{1}' pip install -e '.[messaging]'" -f $venvPath, $uvCommand)
    $wrapperScript = New-ExternalTerminalCommandWrapper -WorkingDirectory $InstallDir -HermesHome $HermesHome -CommandLine $command -FailurePrompt '消息渠道依赖安装失败，'
    return (Start-Process powershell.exe -PassThru -WorkingDirectory $InstallDir -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapperScript))
}

function New-UninstallScript {
    param(
        [string]$InstallDir,
        [string]$HermesHome,
        [bool]$FullRemove
    )

    $tempPath = Join-Path $env:TEMP ('hermes-uninstall-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $modeLabel = if ($FullRemove) { '彻底卸载（删除 .hermes 数据）' } else { '标准卸载（保留 .hermes 数据）' }
    $fullRemoveLiteral = if ($FullRemove) { '$true' } else { '$false' }
    $scriptText = @"
`$ErrorActionPreference = 'Continue'
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
`$OutputEncoding = [System.Text.Encoding]::UTF8
`$env:PYTHONIOENCODING = 'utf-8'
`$env:PYTHONUTF8 = '1'
chcp 65001 > `$null

`$installDir = '$InstallDir'
`$hermesHome = '$HermesHome'
`$fullRemove = $fullRemoveLiteral

Write-Host ''
Write-Host '=== Hermes 卸载程序 ===' -ForegroundColor Cyan
Write-Host "安装目录: `$installDir"
Write-Host "数据目录: `$hermesHome"
Write-Host "卸载模式: $modeLabel"
Write-Host ("彻底卸载标记: " + [string]`$fullRemove)
Write-Host ''

Get-Process | Where-Object { `$_.Path -and (`$_.Path -like "`$installDir*" -or `$_.Path -like "*hermes*") } | ForEach-Object {
    try { Stop-Process -Id `$_.Id -Force -ErrorAction Stop } catch {}
}

Start-Sleep -Seconds 1

try {
    `$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (`$userPath) {
        `$filtered = (`$userPath -split ';' | Where-Object { `$_ -and `$_ -ne (Join-Path `$installDir 'venv\Scripts') }) -join ';'
        [Environment]::SetEnvironmentVariable('Path', `$filtered, 'User')
        Write-Host '已从用户 PATH 移除 Hermes 路径。' -ForegroundColor Green
    }
} catch {
    Write-Host "清理 PATH 失败: `$(`$_.Exception.Message)" -ForegroundColor Yellow
}

if (Test-Path `$installDir) {
    try {
        Remove-Item -LiteralPath `$installDir -Recurse -Force -ErrorAction Stop
        Write-Host '已删除安装目录。' -ForegroundColor Green
    } catch {
        Write-Host "删除安装目录失败: `$(`$_.Exception.Message)" -ForegroundColor Red
    }
}

if (`$fullRemove -and (Test-Path `$hermesHome)) {
    try {
        Remove-Item -LiteralPath `$hermesHome -Recurse -Force -ErrorAction Stop
        Write-Host '已删除 Hermes 数据目录。' -ForegroundColor Green
    } catch {
        Write-Host "直接删除数据目录失败: `$(`$_.Exception.Message)" -ForegroundColor Yellow
        try {
            `$archivePath = "`$hermesHome.pre-remove-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Move-Item -LiteralPath `$hermesHome -Destination `$archivePath -Force -ErrorAction Stop
            Write-Host "已将 Hermes 数据目录改名归档到: `$archivePath" -ForegroundColor Green
            Write-Host '后续重新安装不会继续复用旧 .hermes 数据。' -ForegroundColor Green
        } catch {
            Write-Host "归档数据目录也失败: `$(`$_.Exception.Message)" -ForegroundColor Red
        }
    }
} else {
    Write-Host '已保留 Hermes 数据目录。' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '卸载流程结束，可以关闭此窗口。' -ForegroundColor Cyan
"@

    [System.IO.File]::WriteAllText($tempPath, $scriptText, [System.Text.Encoding]::Unicode)
    return $tempPath
}

if ($SelfTest) {
    $defaults = Get-HermesDefaults
    $status = Test-HermesInstalled -InstallDir $defaults.InstallDir -HermesHome $defaults.HermesHome
    [pscustomobject]@{
        DefaultsLoaded = [bool]$defaults
        InstallDir     = $defaults.InstallDir
        HermesHome     = $defaults.HermesHome
        StatusChecked  = [bool]$status
    } | ConvertTo-Json -Compress
    exit 0
}

$defaults = Get-HermesDefaults

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Hermes Agent 桌面控制台"
        Height="930"
        Width="1400"
        MinHeight="820"
        MinWidth="1220"
        WindowStartupLocation="CenterScreen"
        Background="#0B1220"
        Foreground="#E2E8F0">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Padding="24" CornerRadius="20" Background="#111C33" BorderBrush="#24324F" BorderThickness="1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel>
                    <TextBlock FontSize="34" FontWeight="Bold" Text="Hermes Agent 桌面控制台"/>
                    <TextBlock Margin="0,10,0,0" FontSize="15" Foreground="#AFC3E3" TextWrapping="Wrap"
                               Text="面向普通 Windows 用户的 Hermes 控制台。安装、配置、启动和日常使用都可以在这里完成。"/>
                </StackPanel>
                <StackPanel Grid.Column="1" VerticalAlignment="Top">
                    <Button x:Name="BrowseHomeButton" Margin="0,0,0,10" Padding="18,10" Background="#1E293B" Foreground="#F8FAFC" BorderBrush="#475569" Content="打开数据目录"/>
                    <Button x:Name="BrowseInstallButton" Padding="18,10" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="打开安装目录"/>
                </StackPanel>
            </Grid>
        </Border>

        <Border Grid.Row="1" Margin="0,18,0,18" Padding="18" CornerRadius="18" Background="#101A2C" BorderBrush="#22314D" BorderThickness="1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="2.2*"/>
                    <ColumnDefinition Width="16"/>
                    <ColumnDefinition Width="1.2*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                    <TextBlock FontSize="13" Foreground="#7DD3FC" Text="当前状态"/>
                    <TextBlock x:Name="StatusHeadlineText" Margin="0,6,0,0" FontSize="24" FontWeight="SemiBold" Text="正在检测 Hermes 状态"/>
                    <TextBlock x:Name="StatusBodyText" Margin="0,10,0,0" Foreground="#CBD5E1" TextWrapping="Wrap" Text="启动器会综合安装、模型、OpenClaw 和消息网关状态，给出当前最合适的操作。"/>
                </StackPanel>
                <StackPanel Grid.Column="2">
                    <TextBlock FontSize="13" Foreground="#7DD3FC" Text="当前操作"/>
                    <TextBlock x:Name="RecommendationText" Margin="0,6,0,0" FontSize="18" FontWeight="SemiBold" Text="加载中"/>
                    <TextBlock x:Name="RecommendationHintText" Margin="0,10,0,0" Foreground="#CBD5E1" TextWrapping="Wrap"/>
                </StackPanel>
                <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="SecondaryActionButton" Margin="0,0,10,0" Padding="18,10" FontWeight="SemiBold" Background="#1E293B" Foreground="#F8FAFC" BorderBrush="#475569" Content="次要操作" Visibility="Collapsed"/>
                    <Button x:Name="RefreshButton" Margin="0,0,10,0" Padding="16,10" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="刷新状态"/>
                    <Button x:Name="PrimaryActionButton" Padding="18,10" FontWeight="SemiBold" Background="#22C55E" Foreground="#04110A" BorderBrush="#22C55E" Content="执行下一步"/>
                </StackPanel>
            </Grid>
        </Border>

        <Grid Grid.Row="2">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="300"/>
                <ColumnDefinition Width="18"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <StackPanel>
                    <Border Padding="16" CornerRadius="18" Background="#111827" BorderBrush="#22314D" BorderThickness="1">
                        <StackPanel>
                            <TextBlock FontSize="18" FontWeight="SemiBold" Text="步骤导航"/>
                            <TextBlock Margin="0,8,0,14" Foreground="#94A3B8" TextWrapping="Wrap" Text="从上到下执行即可。右侧会显示当前步骤说明和可直接执行的按钮。"/>
                            <Button x:Name="StageInstallButton" Margin="0,0,0,10" Padding="14,12" HorizontalContentAlignment="Left" Background="#0F172A" Foreground="#E2E8F0" BorderBrush="#334155" Content="1. 安装 Hermes"/>
                            <Button x:Name="StageOpenClawButton" Margin="0,0,0,10" Padding="14,12" HorizontalContentAlignment="Left" Background="#0F172A" Foreground="#E2E8F0" BorderBrush="#334155" Content="2. 迁移 OpenClaw"/>
                            <Button x:Name="StageModelButton" Margin="0,0,0,10" Padding="14,12" HorizontalContentAlignment="Left" Background="#0F172A" Foreground="#E2E8F0" BorderBrush="#334155" Content="3. 配置模型与 API Key"/>
                            <Button x:Name="StageCheckButton" Margin="0,0,0,10" Padding="14,12" HorizontalContentAlignment="Left" Background="#0F172A" Foreground="#E2E8F0" BorderBrush="#334155" Content="4. 快速检测与诊断"/>
                            <Button x:Name="StageLaunchButton" Margin="0,0,0,10" Padding="14,12" HorizontalContentAlignment="Left" Background="#0F172A" Foreground="#E2E8F0" BorderBrush="#334155" Content="5. 启动本地对话"/>
                            <Button x:Name="StageGatewayButton" Margin="0,0,0,10" Padding="14,12" HorizontalContentAlignment="Left" Background="#0F172A" Foreground="#E2E8F0" BorderBrush="#334155" Content="6. 配置并启动消息网关"/>
                            <Button x:Name="StageAdvancedButton" Padding="14,12" HorizontalContentAlignment="Left" Background="#0F172A" Foreground="#E2E8F0" BorderBrush="#334155" Content="7. 高级配置与维护"/>
                        </StackPanel>
                    </Border>

                    <Expander Margin="0,16,0,0" Padding="0" IsExpanded="True">
                        <Expander.Header>
                            <TextBlock Foreground="#E2E8F0" FontWeight="SemiBold" Text="安装设置"/>
                        </Expander.Header>
                        <Border Margin="0,10,0,0" Padding="16" CornerRadius="18" Background="#111827" BorderBrush="#22314D" BorderThickness="1">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="98"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>

                                <TextBlock Grid.Row="0" VerticalAlignment="Center" Foreground="#CBD5E1" Text="数据目录"/>
                                <TextBox x:Name="HermesHomeTextBox" Grid.Row="0" Grid.Column="1" Margin="10,0,0,10" Padding="8" Background="#0F172A" Foreground="White" BorderBrush="#334155"/>

                                <TextBlock Grid.Row="1" VerticalAlignment="Center" Foreground="#CBD5E1" Text="安装目录"/>
                                <TextBox x:Name="InstallDirTextBox" Grid.Row="1" Grid.Column="1" Margin="10,0,0,10" Padding="8" Background="#0F172A" Foreground="White" BorderBrush="#334155"/>

                                <TextBlock Grid.Row="2" VerticalAlignment="Center" Foreground="#CBD5E1" Text="Git 分支"/>
                                <Grid Grid.Row="2" Grid.Column="1" Margin="10,0,0,0">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBox x:Name="BranchTextBox" Grid.Column="0" Margin="0,0,10,0" Padding="8" Background="#0F172A" Foreground="White" BorderBrush="#334155" Text="main"/>
                                    <StackPanel Grid.Column="1" Orientation="Horizontal">
                                    <CheckBox x:Name="NoVenvCheckBox" Margin="0,0,14,0" VerticalAlignment="Center" Foreground="#CBD5E1" Content="NoVenv"/>
                                    <CheckBox x:Name="SkipSetupCheckBox" VerticalAlignment="Center" Foreground="#CBD5E1" IsChecked="True" Content="安装后不进入官方配置"/>
                                    </StackPanel>
                                </Grid>
                            </Grid>
                        </Border>
                    </Expander>

                    <Expander Margin="0,16,0,0" IsExpanded="True">
                        <Expander.Header>
                            <TextBlock Foreground="#E2E8F0" FontWeight="SemiBold" Text="官方资源"/>
                        </Expander.Header>
                        <Border Margin="0,10,0,0" Padding="16" CornerRadius="18" Background="#111827" BorderBrush="#22314D" BorderThickness="1">
                            <WrapPanel>
                                <Button x:Name="RepoButton" Margin="0,0,10,10" Padding="12,8" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="官方仓库"/>
                                <Button x:Name="DocsButton" Margin="0,0,10,10" Padding="12,8" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="官方文档"/>
                            </WrapPanel>
                        </Border>
                    </Expander>
                </StackPanel>
            </ScrollViewer>

            <Grid Grid.Column="2">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="16"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <Border Grid.Row="0" Padding="18" CornerRadius="18" Background="#111827" BorderBrush="#22314D" BorderThickness="1">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                    <TextBlock x:Name="DetailTitleText" FontSize="24" FontWeight="SemiBold" Text="当前步骤"/>
                        <TextBlock x:Name="DetailSummaryText" Grid.Row="1" Margin="0,10,0,0" Foreground="#CBD5E1" TextWrapping="Wrap"/>
                        <TextBlock x:Name="DetailChecklistText" Grid.Row="2" Margin="0,16,0,0" Foreground="#94A3B8" TextWrapping="Wrap"/>
                        <WrapPanel Grid.Row="3" Margin="0,18,0,0">
                            <Button x:Name="DetailAction1Button" Margin="0,0,10,10" Padding="14,10" Background="#22C55E" Foreground="#04110A" BorderBrush="#22C55E" Content="动作 1"/>
                            <Button x:Name="DetailAction2Button" Margin="0,0,10,10" Padding="14,10" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="动作 2"/>
                            <Button x:Name="DetailAction3Button" Margin="0,0,10,10" Padding="14,10" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="动作 3"/>
                            <Button x:Name="DetailAction4Button" Margin="0,0,10,10" Padding="14,10" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="动作 4"/>
                            <Button x:Name="DetailAction5Button" Margin="0,0,10,10" Padding="14,10" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="动作 5"/>
                            <Button x:Name="DetailAction6Button" Margin="0,0,10,10" Padding="14,10" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="动作 6"/>
                            <Button x:Name="DetailAction7Button" Margin="0,0,10,10" Padding="14,10" Background="#991B1B" Foreground="#F8FAFC" BorderBrush="#DC2626" Content="动作 7"/>
                        </WrapPanel>
                    </Grid>
                </Border>

                <Border Grid.Row="2" Padding="18" CornerRadius="18" Background="#020617" BorderBrush="#22314D" BorderThickness="1">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <DockPanel Grid.Row="0" LastChildFill="False">
                            <TextBlock DockPanel.Dock="Left" FontSize="18" FontWeight="SemiBold" Foreground="#F8FAFC" Text="运行日志"/>
                            <Button x:Name="ClearLogButton" DockPanel.Dock="Right" Padding="10,6" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="清空"/>
                        </DockPanel>
                        <TextBox x:Name="LogTextBox" Grid.Row="1" Margin="0,12,0,0" Background="#020617" Foreground="#E2E8F0" BorderThickness="0"
                                 FontFamily="Consolas" FontSize="13" AcceptsReturn="True" AcceptsTab="True"
                                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                                 IsReadOnly="True" TextWrapping="NoWrap"/>
                    </Grid>
                </Border>
            </Grid>
        </Grid>

        <Border Grid.Row="3" Margin="0,18,0,0" Padding="12,10" CornerRadius="12" Background="#101A2C" BorderBrush="#22314D" BorderThickness="1">
            <TextBlock x:Name="FooterText" Foreground="#94A3B8" Text="就绪"/>
        </Border>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$controls = @{}
foreach ($name in @(
    'RepoButton','DocsButton','StatusHeadlineText','StatusBodyText','RecommendationText','RecommendationHintText',
    'RefreshButton','PrimaryActionButton','SecondaryActionButton','StageInstallButton','StageOpenClawButton','StageModelButton','StageCheckButton',
    'StageLaunchButton','StageGatewayButton','StageAdvancedButton','HermesHomeTextBox','InstallDirTextBox','BranchTextBox',
    'BrowseHomeButton','BrowseInstallButton','NoVenvCheckBox','SkipSetupCheckBox','DetailTitleText','DetailSummaryText',
    'DetailChecklistText','DetailAction1Button','DetailAction2Button','DetailAction3Button','DetailAction4Button','DetailAction5Button','DetailAction6Button','DetailAction7Button',
    'ClearLogButton','LogTextBox','FooterText'
)) {
    $controls[$name] = $window.FindName($name)
}

$controls.HermesHomeTextBox.Text = $defaults.HermesHome
$controls.InstallDirTextBox.Text = $defaults.InstallDir
$controls.BranchTextBox.Text = 'main'
$controls.SkipSetupCheckBox.IsChecked = $true

$script:CrashLogPath = Join-Path $env:TEMP 'HermesGuiLauncher-crash.log'

function Write-CrashLog {
    param([string]$Message)

    try {
        $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
        [System.IO.File]::AppendAllText($script:CrashLogPath, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch { }
}

$window.Add_SourceInitialized({
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.add_UnhandledException({
        param($sender, $eventArgs)
        Write-CrashLog ("DispatcherUnhandledException: " + $eventArgs.Exception.ToString())
    })
    [AppDomain]::CurrentDomain.add_UnhandledException({
        param($sender, $eventArgs)
        Write-CrashLog ("UnhandledException: " + $eventArgs.ExceptionObject.ToString())
    })
})

$script:SelectedStage = 'Install'
$script:PrimaryActionId = 'refresh'
$script:GatewayRuntimeState = 'Idle'
$script:GatewayRuntimeMessage = $null
$script:GatewayTerminalPid = $null
$script:GatewayMonitorTimer = $null
$script:CurrentStatus = $null
$script:TrackedTaskProcess = $null
$script:TrackedTaskTimer = $null
$script:TrackedTaskName = $null
$script:TrackedTaskStdOutPath = $null
$script:TrackedTaskStdErrPath = $null
$script:TrackedTaskStatusPath = $null
$script:TrackedTaskPid = $null
$script:TrackedTaskStdOutLength = 0
$script:TrackedTaskStdErrLength = 0
$script:ExternalInstallProcess = $null
$script:ExternalInstallTimer = $null
$script:ExternalModelProcess = $null
$script:ExternalModelTimer = $null
$script:ExternalGatewaySetupProcess = $null
$script:ExternalGatewaySetupTimer = $null
$script:ExternalMessagingProcess = $null
$script:ExternalMessagingTimer = $null
$script:PendingGatewayStartAfterMessagingInstall = $false
$script:LocalChatVerificationPending = $false
$script:LocalChatVerified = $false

function Get-LauncherStatePath {
    param([string]$HermesHome)
    if (-not $HermesHome) { return $null }
    return (Join-Path $HermesHome 'launcher-state.json')
}

function Load-LauncherState {
    param([string]$HermesHome)

    $path = Get-LauncherStatePath -HermesHome $HermesHome
    if (-not $path -or -not (Test-Path $path)) {
        return [pscustomobject]@{
            LocalChatVerified = $false
            OpenClawPreviewed = $false
            OpenClawImported  = $false
        }
    }

    try {
        $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{
            LocalChatVerified = [bool]$data.local_chat_verified
            OpenClawPreviewed = [bool]$data.openclaw_previewed
            OpenClawImported  = [bool]$data.openclaw_imported
        }
    } catch {
        return [pscustomobject]@{
            LocalChatVerified = $false
            OpenClawPreviewed = $false
            OpenClawImported  = $false
        }
    }
}

function Save-LauncherState {
    param(
        [string]$HermesHome,
        [Nullable[bool]]$LocalChatVerified = $null,
        [Nullable[bool]]$OpenClawPreviewed = $null,
        [Nullable[bool]]$OpenClawImported = $null
    )

    $path = Get-LauncherStatePath -HermesHome $HermesHome
    if (-not $path) { return }

    try {
        $current = Load-LauncherState -HermesHome $HermesHome
        $parent = Split-Path -Parent $path
        if ($parent -and -not (Test-Path $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $payload = @{
            local_chat_verified = if ($null -ne $LocalChatVerified) { [bool]$LocalChatVerified } else { [bool]$current.LocalChatVerified }
            openclaw_previewed  = if ($null -ne $OpenClawPreviewed) { [bool]$OpenClawPreviewed } else { [bool]$current.OpenClawPreviewed }
            openclaw_imported   = if ($null -ne $OpenClawImported) { [bool]$OpenClawImported } else { [bool]$current.OpenClawImported }
            updated_at = (Get-Date).ToString('s')
        } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($path, $payload, [System.Text.Encoding]::UTF8)
    } catch { }
}

function Add-LogLine {
    param([string]$Text)

    $timestamp = Get-Date -Format 'HH:mm:ss'
    $controls.LogTextBox.AppendText(('[{0}] {1}' -f $timestamp, $Text) + [Environment]::NewLine)
    $controls.LogTextBox.ScrollToEnd()
}

function Add-ActionLog {
    param(
        [string]$Action,
        [string]$Result,
        [string]$Next
    )

    if ($Action) { Add-LogLine ("操作：{0}" -f $Action) }
    if ($Result) { Add-LogLine ("结果：{0}" -f $Result) }
    if ($Next) { Add-LogLine ("下一步：{0}" -f $Next) }
}

function Set-Footer {
    param([string]$Text)
    $controls.FooterText.Text = $Text
}

function Keep-LauncherVisible {
    $handle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
    try {
        $window.WindowState = 'Normal'
        $window.Topmost = $true
        [HermesLauncherWin32]::ShowWindowAsync($handle, 5) | Out-Null
        $window.Activate() | Out-Null
        [HermesLauncherWin32]::SetForegroundWindow($handle) | Out-Null
        Start-Sleep -Milliseconds 150
        $window.Topmost = $false
    } catch { }
}

function Stop-ExternalInstallTimer {
    if ($script:ExternalInstallTimer) {
        $script:ExternalInstallTimer.Stop()
        $script:ExternalInstallTimer = $null
    }
}

function Stop-ExternalModelTimer {
    if ($script:ExternalModelTimer) {
        $script:ExternalModelTimer.Stop()
        $script:ExternalModelTimer = $null
    }
}

function Stop-ExternalGatewaySetupTimer {
    if ($script:ExternalGatewaySetupTimer) {
        $script:ExternalGatewaySetupTimer.Stop()
        $script:ExternalGatewaySetupTimer = $null
    }
}

function Stop-ExternalMessagingTimer {
    if ($script:ExternalMessagingTimer) {
        $script:ExternalMessagingTimer.Stop()
        $script:ExternalMessagingTimer = $null
    }
}

function Start-ExternalInstallMonitor {
    param([System.Diagnostics.Process]$Process)

    Stop-ExternalInstallTimer
    $script:ExternalInstallProcess = $Process

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(2)
    $timer.Add_Tick({
        if (-not $script:ExternalInstallProcess) {
            Stop-ExternalInstallTimer
            return
        }

        $alive = $false
        try {
            $alive = -not $script:ExternalInstallProcess.HasExited
        } catch {
            $alive = $false
        }

        if ($alive) { return }

        $exitCode = 1
        try { $exitCode = $script:ExternalInstallProcess.ExitCode } catch { }

        $script:ExternalInstallProcess = $null
        Stop-ExternalInstallTimer

        if ($exitCode -eq 0) {
            Add-ActionLog -Action '安装 / 更新 Hermes' -Result '安装终端已自动关闭，安装过程结束' -Next '启动器已自动刷新状态，请按推荐步骤继续'
        } else {
            Add-ActionLog -Action '安装 / 更新 Hermes' -Result ("安装终端已结束，退出码：{0}" -f $exitCode) -Next '安装失败时终端通常会保留；如已关闭，请重新打开安装并查看终端报错'
        }
        Refresh-Status
    })
    $script:ExternalInstallTimer = $timer
    $timer.Start()
}

function New-ExternalHermesCommandWrapper {
    param(
        [string]$HermesCommand,
        [string[]]$CommandArguments,
        [string]$WorkingDirectory,
        [string]$HermesHome,
        [string]$FailurePrompt
    )

    $tempPath = Join-Path $env:TEMP ('hermes-command-wrapper-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $argLiteral = ($CommandArguments | ForEach-Object { "'" + ($_.Replace("'", "''")) + "'" }) -join ', '
    $wrapper = @"
`$ErrorActionPreference = 'Continue'
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
`$OutputEncoding = [System.Text.Encoding]::UTF8
`$env:PYTHONIOENCODING = 'utf-8'
`$env:PYTHONUTF8 = '1'
chcp 65001 > `$null
Set-Location -LiteralPath '$WorkingDirectory'
`$env:HERMES_HOME = '$HermesHome'
`$cmdArgs = @($argLiteral)
& '$HermesCommand' @cmdArgs
`$code = `$LASTEXITCODE
if (`$code -ne 0) {
    Write-Host ''
    Write-Host ('$FailurePrompt 退出码: ' + `$code) -ForegroundColor Red
    Write-Host '按 Enter 关闭此窗口。' -ForegroundColor Yellow
    [void](Read-Host)
}
exit `$code
"@
[System.IO.File]::WriteAllText($tempPath, $wrapper, [System.Text.Encoding]::Unicode)
return $tempPath
}

function New-ExternalTerminalCommandWrapper {
    param(
        [string]$WorkingDirectory,
        [string]$HermesHome,
        [string]$CommandLine,
        [string]$FailurePrompt
    )

    $tempPath = Join-Path $env:TEMP ('hermes-terminal-wrapper-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $wrapper = @"
`$ErrorActionPreference = 'Continue'
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
`$OutputEncoding = [System.Text.Encoding]::UTF8
`$env:PYTHONIOENCODING = 'utf-8'
`$env:PYTHONUTF8 = '1'
chcp 65001 > `$null
Set-Location -LiteralPath '$WorkingDirectory'
`$env:HERMES_HOME = '$HermesHome'
`$commandText = @'
$CommandLine
'@
Invoke-Expression `$commandText
`$code = `$LASTEXITCODE
if (`$code -ne 0) {
    Write-Host ''
    Write-Host ('$FailurePrompt 退出码: ' + `$code) -ForegroundColor Red
    Write-Host '按 Enter 关闭此窗口。' -ForegroundColor Yellow
    [void](Read-Host)
}
exit `$code
"@
    [System.IO.File]::WriteAllText($tempPath, $wrapper, [System.Text.Encoding]::Unicode)
    return $tempPath
}

function Start-ExternalModelMonitor {
    param([System.Diagnostics.Process]$Process)

    Stop-ExternalModelTimer
    $script:ExternalModelProcess = $Process

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(2)
    $timer.Add_Tick({
        if (-not $script:ExternalModelProcess) {
            Stop-ExternalModelTimer
            return
        }

        $alive = $false
        try {
            $alive = -not $script:ExternalModelProcess.HasExited
        } catch {
            $alive = $false
        }
        if ($alive) { return }

        $exitCode = 1
        try { $exitCode = $script:ExternalModelProcess.ExitCode } catch { }

        $script:ExternalModelProcess = $null
        Stop-ExternalModelTimer

        $state = Get-UiState
        if ($state.ModelStatus.ReadyLikely) {
            Add-ActionLog -Action '配置模型提供商' -Result '已检测到 provider/model 与 API Key，模型配置完成' -Next '继续执行本地对话测试'
        } elseif ($state.ModelStatus.HasModelConfig) {
            Add-ActionLog -Action '配置模型提供商' -Result '已检测到模型配置，但还没有确认 API Key' -Next '打开 .env 或重新运行模型配置，补全密钥'
        } elseif ($exitCode -eq 0) {
            Add-ActionLog -Action '配置模型提供商' -Result '配置终端已关闭，但还没有检测到有效模型配置' -Next '请重新运行模型配置，并确保最后保存生效'
        } else {
            Add-ActionLog -Action '配置模型提供商' -Result ("配置终端退出，退出码：{0}" -f $exitCode) -Next '查看终端报错后重试'
        }
        Refresh-Status
    })
    $script:ExternalModelTimer = $timer
    $timer.Start()
}

function Start-GatewayRuntimeLaunch {
    param(
        [string]$InstallDir,
        [string]$HermesHome,
        [string]$HermesCommand
    )

    $lockResult = Clear-StaleGatewayScopeLocks
    $runtimeCleared = Clear-StaleGatewayRuntimeFiles -HermesHome $HermesHome
    if ($lockResult.Count -gt 0) {
        Add-LogLine ("已清理失效锁文件：{0}" -f ($lockResult.Names -join ', '))
    }
    if ($runtimeCleared) {
        Add-LogLine '已清理旧的 gateway.pid / gateway_state.json。'
    }

    $script:GatewayRuntimeState = 'Starting'
    $script:GatewayRuntimeMessage = '已打开网关终端，启动器将在 3 秒后自动复检。'
    $proc = Start-InTerminal -WorkingDirectory $InstallDir -HermesHome $HermesHome -CommandLine ("& '$HermesCommand' gateway")
    if ($proc) {
        $script:GatewayTerminalPid = $proc.Id
    }
    Add-ActionLog -Action '启动消息网关' -Result '已打开网关终端，启动器将在 3 秒后自动复检' -Next '如报错，请先修复终端报错再试'
    Schedule-GatewayLaunchCheck -HermesHome $HermesHome
    Refresh-Status
}

function Start-ExternalGatewaySetupMonitor {
    param([System.Diagnostics.Process]$Process)

    Stop-ExternalGatewaySetupTimer
    $script:ExternalGatewaySetupProcess = $Process

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(2)
    $timer.Add_Tick({
        if (-not $script:ExternalGatewaySetupProcess) {
            Stop-ExternalGatewaySetupTimer
            return
        }

        $alive = $false
        try {
            $alive = -not $script:ExternalGatewaySetupProcess.HasExited
        } catch {
            $alive = $false
        }
        if ($alive) { return }

        $exitCode = 1
        try { $exitCode = $script:ExternalGatewaySetupProcess.ExitCode } catch { }

        $script:ExternalGatewaySetupProcess = $null
        Stop-ExternalGatewaySetupTimer

        $state = Get-UiState
        $platformText = if ($state.GatewayStatus.ConnectedPlatforms.Count -gt 0) { $state.GatewayStatus.ConnectedPlatforms -join '、' } else { '未识别到已配置渠道' }
        if ($state.GatewayStatus.HasConfiguredChannel) {
            Add-ActionLog -Action '配置消息渠道' -Result ("已检测到消息渠道配置：{0}" -f $platformText) -Next '下一步可直接点击“启动消息网关”，启动器会自动检查依赖并在需要时先安装'
        } elseif ($exitCode -eq 0) {
            Add-ActionLog -Action '配置消息渠道' -Result '配置终端已关闭，但还没有检测到有效消息渠道配置' -Next '请重新运行消息渠道配置，并确保最后保存生效'
        } else {
            Add-ActionLog -Action '配置消息渠道' -Result ("配置终端退出，退出码：{0}" -f $exitCode) -Next '查看终端报错后重试'
        }
        Refresh-Status
        Set-StageView 'Gateway'
    })
    $script:ExternalGatewaySetupTimer = $timer
    $timer.Start()
}

function Start-ExternalMessagingMonitor {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$InstallDir,
        [string]$HermesHome,
        [string]$HermesCommand
    )

    Stop-ExternalMessagingTimer
    $script:ExternalMessagingProcess = $Process

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(2)
    $timer.Add_Tick({
        if (-not $script:ExternalMessagingProcess) {
            Stop-ExternalMessagingTimer
            return
        }

        $alive = $false
        try {
            $alive = -not $script:ExternalMessagingProcess.HasExited
        } catch {
            $alive = $false
        }
        if ($alive) { return }

        $exitCode = 1
        try { $exitCode = $script:ExternalMessagingProcess.ExitCode } catch { }

        $script:ExternalMessagingProcess = $null
        Stop-ExternalMessagingTimer

        $state = Get-UiState
        if ($exitCode -eq 0 -and -not $state.GatewayStatus.NeedsDependencyInstall) {
            Add-ActionLog -Action '安装消息渠道依赖' -Result '消息渠道依赖安装完成' -Next '如果你是通过“启动消息网关”进入，启动器会继续自动启动网关'
            $shouldAutoStart = $script:PendingGatewayStartAfterMessagingInstall -and $state.GatewayStatus.HasConfiguredChannel -and [bool]$HermesCommand
            $script:PendingGatewayStartAfterMessagingInstall = $false
            Refresh-Status
            if ($shouldAutoStart) {
                Add-LogLine '依赖已就绪，继续启动消息网关。'
                Start-GatewayRuntimeLaunch -InstallDir $InstallDir -HermesHome $HermesHome -HermesCommand $HermesCommand
                return
            }
        } elseif ($exitCode -eq 0) {
            $script:PendingGatewayStartAfterMessagingInstall = $false
            Add-ActionLog -Action '安装消息渠道依赖' -Result '安装终端已关闭，但启动器仍检测到缺少依赖' -Next '请查看安装终端是否有报错，必要时重试'
            Refresh-Status
        } else {
            $script:PendingGatewayStartAfterMessagingInstall = $false
            Add-ActionLog -Action '安装消息渠道依赖' -Result ("依赖安装终端退出，退出码：{0}" -f $exitCode) -Next '查看终端报错并修复后重试'
            Refresh-Status
        }
        Set-StageView 'Gateway'
    })
    $script:ExternalMessagingTimer = $timer
    $timer.Start()
}

function New-ExternalInstallWrapperScript {
    param(
        [string]$InstallScriptPath,
        [string[]]$Arguments
    )

    $tempPath = Join-Path $env:TEMP ('hermes-install-wrapper-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $argLiteral = ($Arguments | ForEach-Object { "'" + ($_.Replace("'", "''")) + "'" }) -join ', '
    $wrapper = @"
`$ErrorActionPreference = 'Continue'
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
`$OutputEncoding = [System.Text.Encoding]::UTF8
`$env:PYTHONIOENCODING = 'utf-8'
`$env:PYTHONUTF8 = '1'
chcp 65001 > `$null
`$installArgs = @($argLiteral)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$InstallScriptPath' @installArgs
`$code = `$LASTEXITCODE
if (`$code -ne 0) {
    Write-Host ''
    Write-Host ('安装失败，退出码: ' + `$code) -ForegroundColor Red
    Write-Host '按 Enter 关闭此窗口。' -ForegroundColor Yellow
    [void](Read-Host)
}
exit `$code
"@
    [System.IO.File]::WriteAllText($tempPath, $wrapper, [System.Text.Encoding]::Unicode)
    return $tempPath
}

function Set-ButtonAction {
    param(
        [string]$ControlName,
        [string]$Label,
        [string]$ActionId,
        [bool]$Visible = $true,
        [bool]$Enabled = $true
    )

    $button = $controls[$ControlName]
    $button.Tag = $ActionId
    $button.Content = $Label
    $button.IsEnabled = $Enabled
    $button.Visibility = if ($Visible) { 'Visible' } else { 'Collapsed' }
}

function Set-PrimaryAction {
    param(
        [string]$ActionId,
        [string]$Label,
        [bool]$Enabled = $true
    )

    $script:PrimaryActionId = $ActionId
    $controls.PrimaryActionButton.Content = $Label
    $controls.PrimaryActionButton.IsEnabled = $Enabled
    if ($ActionId -eq 'refresh' -and $Label -eq '刷新状态') {
        $controls.PrimaryActionButton.Visibility = 'Collapsed'
    } else {
        $controls.PrimaryActionButton.Visibility = 'Visible'
    }
}

function Set-SecondaryAction {
    param(
        [string]$ActionId,
        [string]$Label,
        [bool]$Enabled = $true,
        [bool]$Visible = $true
    )

    $controls.SecondaryActionButton.Tag = $ActionId
    $controls.SecondaryActionButton.Content = $Label
    $controls.SecondaryActionButton.IsEnabled = $Enabled
    $controls.SecondaryActionButton.Visibility = if ($Visible) { 'Visible' } else { 'Collapsed' }
}

function Test-TrackedTaskRunning {
    if ($script:TrackedTaskStatusPath -and (Test-Path $script:TrackedTaskStatusPath)) {
        try {
            $status = Get-Content -Path $script:TrackedTaskStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($status.finished) { return $false }
        } catch { }
    }

    if ($script:TrackedTaskPid) {
        return [bool](Get-Process -Id $script:TrackedTaskPid -ErrorAction SilentlyContinue)
    }

    return $false
}

function Read-TrackedLogIncrement {
    param(
        [string]$Path,
        [ref]$Length
    )

    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    try {
        $fileStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $bytes = New-Object byte[] $fileStream.Length
            [void]$fileStream.Read($bytes, 0, $bytes.Length)
        } finally {
            $fileStream.Dispose()
        }
    } catch [System.IO.IOException] {
        return $null
    } catch {
        return $null
    }

    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $content = [System.Text.Encoding]::Unicode.GetString($bytes)
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $content = [System.Text.Encoding]::UTF8.GetString($bytes)
    } else {
        $content = [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    if ($content.Length -le $Length.Value) { return $null }
    $chunk = $content.Substring($Length.Value)
    $Length.Value = $content.Length
    return $chunk
}

function Stop-TrackedTaskTimer {
    if ($script:TrackedTaskTimer) {
        $script:TrackedTaskTimer.Stop()
        $script:TrackedTaskTimer = $null
    }
}

function Reset-TrackedTaskState {
    Stop-TrackedTaskTimer
    $script:TrackedTaskProcess = $null
    $script:TrackedTaskName = $null
    $script:TrackedTaskStdOutPath = $null
    $script:TrackedTaskStdErrPath = $null
    $script:TrackedTaskStatusPath = $null
    $script:TrackedTaskPid = $null
    $script:TrackedTaskStdOutLength = 0
    $script:TrackedTaskStdErrLength = 0
}

function Update-TrackedTaskLog {
    $outChunk = Read-TrackedLogIncrement -Path $script:TrackedTaskStdOutPath -Length ([ref]$script:TrackedTaskStdOutLength)
    if ($outChunk) {
        foreach ($line in ($outChunk -split "`r?`n")) {
            if ($line -ne '') { Add-LogLine $line }
        }
    }

    $errChunk = Read-TrackedLogIncrement -Path $script:TrackedTaskStdErrPath -Length ([ref]$script:TrackedTaskStdErrLength)
    if ($errChunk) {
        foreach ($line in ($errChunk -split "`r?`n")) {
            if ($line -ne '') { Add-LogLine ("[stderr] " + $line) }
        }
    }
}

function Start-TrackedProcess {
    param(
        [string]$TaskName,
        [string]$ScriptPath,
        [string[]]$ScriptArguments,
        [string]$WorkingDirectory
    )

    if (Test-TrackedTaskRunning) {
        throw '已有后台任务正在运行，请等待当前任务完成。'
    }

    $logPath = Join-Path $env:TEMP ('hermes-task-' + [guid]::NewGuid().ToString('N') + '.combined.log')
    $statusPath = Join-Path $env:TEMP ('hermes-task-' + [guid]::NewGuid().ToString('N') + '.status.json')
    $wrapperPath = Join-Path $env:TEMP ('hermes-task-wrapper-' + [guid]::NewGuid().ToString('N') + '.ps1')
    [System.IO.File]::WriteAllText($logPath, '', [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($statusPath, '{"finished":false,"exitCode":null}', [System.Text.Encoding]::UTF8)

    $argLiteral = ($ScriptArguments | ForEach-Object { "'" + ($_.Replace("'", "''")) + "'" }) -join ', '
    $wrapper = @"
`$ErrorActionPreference = 'Continue'
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
`$OutputEncoding = [System.Text.Encoding]::UTF8
`$env:PYTHONIOENCODING = 'utf-8'
`$env:PYTHONUTF8 = '1'
chcp 65001 > `$null
Set-Location -LiteralPath '$WorkingDirectory'
`$scriptArgs = @($argLiteral)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$ScriptPath' @scriptArgs *>> '$logPath'
`$code = `$LASTEXITCODE
@{
  finished = `$true
  exitCode = `$code
} | ConvertTo-Json -Compress | Set-Content -Path '$statusPath' -Encoding UTF8
exit `$code
"@
    [System.IO.File]::WriteAllText($wrapperPath, $wrapper, [System.Text.Encoding]::Unicode)

    $process = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapperPath)

    $script:TrackedTaskProcess = $null
    $script:TrackedTaskName = $TaskName
    $script:TrackedTaskStdOutPath = $logPath
    $script:TrackedTaskStdErrPath = $null
    $script:TrackedTaskStatusPath = $statusPath
    $script:TrackedTaskPid = $process.Id
    $script:TrackedTaskStdOutLength = 0
    $script:TrackedTaskStdErrLength = 0

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(700)
    $timer.Add_Tick({
        Update-TrackedTaskLog
        if (-not (Test-TrackedTaskRunning)) {
            Update-TrackedTaskLog
            $exitCode = 1
            if ($script:TrackedTaskStatusPath -and (Test-Path $script:TrackedTaskStatusPath)) {
                try {
                    $status = Get-Content -Path $script:TrackedTaskStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($null -ne $status.exitCode) {
                        $exitCode = [int]$status.exitCode
                    }
                } catch { }
            }
            $taskName = $script:TrackedTaskName
            Reset-TrackedTaskState
            if ($taskName -eq 'install') {
                if ($exitCode -eq 0) {
                    Add-ActionLog -Action '安装 / 更新 Hermes' -Result '安装任务已完成，启动器已自动刷新状态' -Next '根据推荐步骤继续配置模型、本地对话或消息网关'
                } else {
                    Add-ActionLog -Action '安装 / 更新 Hermes' -Result ("安装任务退出，退出码：{0}" -f $exitCode) -Next '查看日志中的最后几段报错，必要时改用外部终端安装'
                }
            } else {
                Add-LogLine ("后台任务结束：{0}（退出码 {1}）" -f $taskName, $exitCode)
            }
            Refresh-Status
        }
    })
    $script:TrackedTaskTimer = $timer
    $timer.Start()
}

function Get-UiState {
    $installDir = $controls.InstallDirTextBox.Text.Trim()
    $hermesHome = $controls.HermesHomeTextBox.Text.Trim()
    $status = Test-HermesInstalled -InstallDir $installDir -HermesHome $hermesHome
    if ($status.Installed -and (-not $status.ConfigExists -or -not $status.EnvExists)) {
        Ensure-HermesConfigScaffold -InstallDir $installDir -HermesHome $hermesHome
        $status = Test-HermesInstalled -InstallDir $installDir -HermesHome $hermesHome
    }

    $resolvedCommand = Resolve-HermesCommand -InstallDir $installDir
    $modelStatus = Test-HermesModelConfigured -HermesHome $hermesHome
    $openClawSources = @(Get-OpenClawSources)
    $gatewayStatus = Test-HermesGatewayReadiness -InstallDir $installDir -HermesHome $hermesHome
    $gatewayRuntime = Get-GatewayRuntimeStatus -HermesHome $hermesHome
    $launcherState = Load-LauncherState -HermesHome $hermesHome

    [pscustomobject]@{
        InstallDir      = $installDir
        HermesHome      = $hermesHome
        Branch          = $controls.BranchTextBox.Text.Trim()
        Status          = $status
        HermesCommand   = $resolvedCommand
        ModelStatus     = $modelStatus
        OpenClawSources = $openClawSources
        GatewayStatus   = $gatewayStatus
        GatewayRuntime  = $gatewayRuntime
        LauncherState   = $launcherState
    }
}

function Get-Recommendation {
    param($state)

    if ($script:ExternalModelProcess) {
        return [pscustomobject]@{
            Headline = '正在等待模型配置完成'
            Body     = '模型配置终端已打开。请在终端里完成模型提供方、模型名称和 API Key 配置；关闭后启动器会自动检查结果。'
            Hint     = '如果你已经保存并退出，等待几秒即可看到状态自动更新。'
            ActionId = 'refresh'
            Label    = '等待模型配置完成'
            Stage    = 'Model'
            Enabled  = $false
        }
    }

    if ($script:ExternalGatewaySetupProcess) {
        return [pscustomobject]@{
            Headline = '正在等待消息渠道配置完成'
            Body     = '消息渠道配置终端已打开。请在终端里完成渠道选择并保存；关闭后启动器会自动检查是否配置成功。'
            Hint     = '如果配置已经保存，等待几秒即可看到推荐步骤自动推进。'
            ActionId = 'refresh'
            Label    = '等待消息渠道配置完成'
            Stage    = 'Gateway'
            Enabled  = $false
        }
    }

    if ($script:ExternalMessagingProcess) {
        return [pscustomobject]@{
            Headline = '正在准备消息网关依赖'
            Body     = '正在安装消息渠道所需依赖。安装完成后，启动器会按当前流程自动继续下一步。'
            Hint     = '如终端保留未关闭，通常表示安装失败，请直接查看终端报错。'
            ActionId = 'refresh'
            Label    = '等待依赖安装完成'
            Stage    = 'Gateway'
            Enabled  = $false
        }
    }

    if (-not ($state.Status.Installed -or $state.HermesCommand)) {
        return [pscustomobject]@{
            Headline = '先完成安装'
            Body     = '当前没有检测到 Hermes 可执行文件，先执行安装或更新。'
            Hint     = '安装成功后刷新状态，如果检测到 OpenClaw，再决定是否迁移。'
            ActionId = 'install-external'
            Label    = '安装 / 更新 Hermes'
            Stage    = 'Install'
            Enabled  = $true
        }
    }

    if ($state.OpenClawSources.Count -gt 0 -and -not $state.ModelStatus.ReadyLikely) {
        if (-not $state.LauncherState.OpenClawImported) {
            if ($state.LauncherState.OpenClawPreviewed) {
                return [pscustomobject]@{
                    Headline = '继续导入 OpenClaw'
                    Body     = '已完成 OpenClaw 导入预览。确认无误后，可以继续正式导入。'
                    Hint     = '正式导入完成后，启动器会把主流程推进到模型配置或后续步骤。'
                    ActionId = 'openclaw-migrate'
                    Label    = '正式导入 OpenClaw'
                    Stage    = 'OpenClaw'
                    Enabled  = [bool]$state.HermesCommand
                }
            }

            return [pscustomobject]@{
                Headline = '优先预览 OpenClaw 导入'
                Body     = '已检测到 OpenClaw/Clawdbot/Moldbot 目录，建议先做预览导入，避免重复填写配置。'
                Hint     = '预览完成后，再决定是否正式导入。'
                ActionId = 'openclaw-preview'
                Label    = '预览导入 OpenClaw'
                Stage    = 'OpenClaw'
                Enabled  = [bool]$state.HermesCommand
            }
        }
    }

    if (-not $state.ModelStatus.ReadyLikely) {
        $modelGap = if ($state.ModelStatus.HasModelConfig -and -not $state.ModelStatus.HasApiKey) {
            '已检测到模型配置，但还没有检测到可用凭证（.env API Key 或 auth.json Provider 凭证）。'
        } else {
            'Hermes 已安装，但还没有看到完整的模型与密钥配置。'
        }
        return [pscustomobject]@{
            Headline = '配置模型与 API Key'
            Body     = $modelGap
            Hint     = '这里使用官方 `hermes model` 向导，不会进入完整 setup。'
            ActionId = 'model'
            Label    = '配置模型提供商'
            Stage    = 'Model'
            Enabled  = [bool]$state.HermesCommand
        }
    }

    if ($state.GatewayRuntime.State -eq 'Running') {
        return [pscustomobject]@{
            Headline = '消息网关正在运行'
            Body     = '已检测到 Hermes 消息网关进程。关闭网关终端后，消息渠道会离线。'
            Hint     = '如果只是继续使用，保持网关终端窗口打开即可。需要排错时再打开日志目录。'
            ActionId = 'refresh'
            Label    = '刷新状态'
            Stage    = 'Gateway'
            Enabled  = $true
        }
    }

    if ($state.GatewayRuntime.State -eq 'Starting') {
        return [pscustomobject]@{
            Headline = '正在启动消息网关'
            Body     = if ($state.GatewayRuntime.Message) { $state.GatewayRuntime.Message } else { '消息网关刚刚启动，正在等待状态回传。' }
            Hint     = '等待几秒，启动器会自动复检是否已成功进入运行状态。'
            ActionId = 'refresh'
            Label    = '等待消息网关启动'
            Stage    = 'Gateway'
            Enabled  = $false
        }
    }

    if ($script:LocalChatVerificationPending) {
        return [pscustomobject]@{
            Headline = '继续配置消息渠道'
            Body     = '本地对话终端已经打开。请先确认 Hermes 能正常回复，再继续配置微信、Telegram、Discord、Slack 等消息渠道。'
            Hint     = '如果你已经在终端完成了本地测试，可以直接继续下一步。'
            ActionId = 'confirm-local-chat'
            Label    = '继续配置消息渠道'
            Stage    = 'Launch'
            Enabled  = [bool]$state.HermesCommand
        }
    }

    if ($state.GatewayStatus.HasConfiguredChannel) {
        $platformText = $state.GatewayStatus.ConnectedPlatforms -join '、'
        $hint = if ($state.GatewayStatus.HasGatewayAccessPolicy) {
            '点击后会自动检查依赖；若缺失则先安装，随后继续启动消息网关。'
        } else {
            '点击后会自动检查依赖并启动网关。当前未检测到允许用户配置，网关虽可启动，但未授权用户会被拒绝。'
        }
        return [pscustomobject]@{
            Headline = '可以启动消息网关'
            Body     = "已检测到消息渠道配置：$platformText。"
            Hint     = $hint
            ActionId = 'gateway'
            Label    = '启动消息网关'
            Stage    = 'Gateway'
            Enabled  = [bool]$state.HermesCommand
        }
    }

    $localChatVerified = $script:LocalChatVerified -or [bool]$state.LauncherState.LocalChatVerified
    if (-not $localChatVerified) {
        return [pscustomobject]@{
            Headline = '先验证本地对话'
            Body     = '模型与 API Key 看起来已经就绪，建议先在本机终端里验证 Hermes 能否正常回答。'
            Hint     = '通过本地对话确认没问题后，再继续消息渠道配置。'
            ActionId = 'launch'
            Label    = '启动本地对话'
            Stage    = 'Launch'
            Enabled  = [bool]$state.HermesCommand
        }
    }

    [pscustomobject]@{
            Headline = '继续配置消息渠道'
            Body     = '模型配置和本地对话准备工作已完成，但当前还没有检测到有效的消息渠道配置。'
            Hint     = '运行消息渠道配置后，启动器会自动检测配置是否生效。'
        ActionId = 'gateway-setup'
        Label    = '配置消息渠道'
        Stage    = 'Gateway'
        Enabled  = [bool]$state.HermesCommand
    }
}

function Show-QuickCheckDialog {
    param($state)

    $items = New-Object System.Collections.Generic.List[string]
    $ok = New-Object System.Collections.Generic.List[string]
    $warn = New-Object System.Collections.Generic.List[string]

    if ($state.Status.Installed -or $state.HermesCommand) { $ok.Add('已检测到 Hermes 命令。') } else { $warn.Add('未检测到 Hermes 命令。') }
    if ($state.Status.ConfigExists) { $ok.Add('config.yaml 已存在。') } else { $warn.Add('config.yaml 尚未生成。') }
    if ($state.Status.EnvExists) { $ok.Add('.env 已存在。') } else { $warn.Add('.env 尚未生成。') }
    if ($state.ModelStatus.HasModelConfig) { $ok.Add('已检测到模型配置。') } else { $warn.Add('尚未确认模型配置。') }
    if ($state.ModelStatus.HasApiKey) { $ok.Add('已检测到 API Key。') } else { $warn.Add('尚未检测到 API Key。') }
    if ($state.OpenClawSources.Count -gt 0) { $ok.Add("已检测到 OpenClaw 来源：$($state.OpenClawSources -join '; ')") } else { $items.Add('未检测到 OpenClaw 默认目录，可直接跳过迁移。') }
    if ($state.GatewayRuntime.State -eq 'Running') { $ok.Add('消息网关正在运行。') }
    elseif ($state.GatewayStatus.HasTelegramToken) { $items.Add('已检测到 Telegram Token，可继续配置消息网关。') }
    else { $items.Add('未检测到 Telegram Token，不影响本地聊天。') }

    $summary = @()
    if ($ok.Count -gt 0) {
        $summary += '已就绪项：'
        $summary += ($ok | ForEach-Object { "• $_" })
    }
    if ($warn.Count -gt 0) {
        $summary += ''
        $summary += '待处理项：'
        $summary += ($warn | ForEach-Object { "• $_" })
    }
    if ($items.Count -gt 0) {
        $summary += ''
        $summary += '说明：'
        $summary += ($items | ForEach-Object { "• $_" })
    }

    [System.Windows.MessageBox]::Show(($summary -join [Environment]::NewLine), '快速检测结果')
}

function Get-UseModeActions {
    param($state)

    $localAction = [pscustomobject]@{
        ActionId = 'launch'
        Label    = '开始本地对话'
        Enabled  = [bool]$state.HermesCommand
    }

    if ($state.GatewayRuntime.State -eq 'Running') {
        return [pscustomobject]@{
            Active  = $true
            Title   = '开始对话'
            Hint    = '用户安装完毕后，可以通过本地对话或消息网关继续和 Hermes 交互。消息网关已在线，本地对话可随时再次打开。'
            Primary = $localAction
            Secondary = [pscustomobject]@{
                ActionId = 'refresh'
                Label    = '消息网关运行中'
                Enabled  = $false
            }
        }
    }

    if ($state.GatewayStatus.HasConfiguredChannel) {
        return [pscustomobject]@{
            Active  = $true
            Title   = '开始对话'
            Hint    = '本地对话可立即使用；如果希望脱离电脑继续通过手机或消息平台对话，直接启动消息网关。'
            Primary = $localAction
            Secondary = [pscustomobject]@{
                ActionId = 'gateway'
                Label    = '启动消息网关'
                Enabled  = [bool]$state.HermesCommand
            }
        }
    }

    if ($state.ModelStatus.ReadyLikely) {
        return [pscustomobject]@{
            Active  = $true
            Title   = '开始对话'
            Hint    = '本地对话可以立即开始；如果希望通过微信、Telegram、Discord 等渠道继续对话，再去配置消息渠道。'
            Primary = $localAction
            Secondary = [pscustomobject]@{
                ActionId = 'gateway-setup'
                Label    = '配置消息渠道'
                Enabled  = [bool]$state.HermesCommand
            }
        }
    }

    return [pscustomobject]@{
        Active = $false
    }
}

function Schedule-GatewayLaunchCheck {
    param([string]$HermesHome)

    if ($script:GatewayMonitorTimer) {
        $script:GatewayMonitorTimer.Stop()
        $script:GatewayMonitorTimer = $null
    }

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(3)
    $timer.Add_Tick({
        try {
            if ($script:GatewayMonitorTimer) {
                $script:GatewayMonitorTimer.Stop()
                $script:GatewayMonitorTimer = $null
            }

            $runtime = Get-GatewayRuntimeStatus -HermesHome $controls.HermesHomeTextBox.Text.Trim()
            if ($runtime.State -eq 'Running') {
                $script:GatewayRuntimeState = 'Running'
                $script:GatewayRuntimeMessage = $runtime.Message
                Add-ActionLog -Action '消息网关复检' -Result 'Hermes 网关已进入运行状态' -Next '保持网关终端运行，如需排查可打开日志目录'
            } else {
                $script:GatewayRuntimeState = 'Failed'
                if (-not $runtime.Message) {
                    $script:GatewayRuntimeMessage = '没有检测到网关保持运行，请查看刚打开的终端输出。'
                } else {
                    $script:GatewayRuntimeMessage = $runtime.Message
                }
                Add-ActionLog -Action '消息网关复检' -Result '未检测到 Hermes 网关稳定运行' -Next '查看终端报错，修复后重新启动消息网关'
            }
            Refresh-Status
        } catch {
            $script:GatewayRuntimeState = 'Failed'
            $script:GatewayRuntimeMessage = $_.Exception.Message
            Add-ActionLog -Action '消息网关复检' -Result '复检时出现异常' -Next $_.Exception.Message
            Refresh-Status
        }
    })
    $script:GatewayMonitorTimer = $timer
    $timer.Start()
}

function Refresh-Status {
    $script:CurrentStatus = Get-UiState
    $script:LocalChatVerified = [bool]$script:CurrentStatus.LauncherState.LocalChatVerified -or $script:LocalChatVerified
    $recommendation = Get-Recommendation -state $script:CurrentStatus
    $useMode = Get-UseModeActions -state $script:CurrentStatus

    $controls.StatusHeadlineText.Text = $recommendation.Headline
    $controls.StatusBodyText.Text = $recommendation.Body
    if ($useMode.Active -and -not $script:ExternalGatewaySetupProcess -and -not $script:ExternalMessagingProcess -and -not $script:ExternalModelProcess -and -not $script:LocalChatVerificationPending) {
        $controls.RecommendationText.Text = $useMode.Title
        $controls.RecommendationHintText.Text = $useMode.Hint
        Set-PrimaryAction -ActionId $useMode.Primary.ActionId -Label $useMode.Primary.Label -Enabled $useMode.Primary.Enabled
        Set-SecondaryAction -ActionId $useMode.Secondary.ActionId -Label $useMode.Secondary.Label -Enabled $useMode.Secondary.Enabled -Visible $true
    } else {
        $controls.RecommendationText.Text = $recommendation.Label
        $controls.RecommendationHintText.Text = $recommendation.Hint
        Set-PrimaryAction -ActionId $recommendation.ActionId -Label $recommendation.Label -Enabled $recommendation.Enabled
        Set-SecondaryAction -ActionId '' -Label '' -Enabled $false -Visible $false
    }

    if (-not $script:SelectedStage) {
        $script:SelectedStage = $recommendation.Stage
    }

    Set-StageView -StageId $script:SelectedStage
    Set-Footer ("Hermes 命令路径：{0}" -f $(if ($script:CurrentStatus.HermesCommand) { $script:CurrentStatus.HermesCommand } else { '未找到' }))
}

function Set-StageHighlight {
    param([string]$Selected)

    $map = @{
        Install   = 'StageInstallButton'
        OpenClaw  = 'StageOpenClawButton'
        Model     = 'StageModelButton'
        Check     = 'StageCheckButton'
        Launch    = 'StageLaunchButton'
        Gateway   = 'StageGatewayButton'
        Advanced  = 'StageAdvancedButton'
    }

    foreach ($entry in $map.GetEnumerator()) {
        $button = $controls[$entry.Value]
        if ($entry.Key -eq $Selected) {
            $button.Background = '#22C55E'
            $button.Foreground = '#04110A'
            $button.BorderBrush = '#22C55E'
        } else {
            $button.Background = '#0F172A'
            $button.Foreground = '#E2E8F0'
            $button.BorderBrush = '#334155'
        }
    }
}

function Set-StageView {
    param([string]$StageId)

    $script:SelectedStage = $StageId
    Set-StageHighlight -Selected $StageId
    $state = $script:CurrentStatus
    if (-not $state) { return }

    Set-ButtonAction 'DetailAction5Button' '' '' $false
    Set-ButtonAction 'DetailAction6Button' '' '' $false
    Set-ButtonAction 'DetailAction7Button' '' '' $false

    switch ($StageId) {
        'Install' {
            $controls.DetailTitleText.Text = '步骤 1：安装 Hermes'
            $controls.DetailSummaryText.Text = '当前只保留外部终端安装这条稳定路径。安装脚本会跳过官方 setup 菜单，也不会在安装结束时追问是否启动消息网关。'
            $controls.DetailChecklistText.Text = "检查点`n• 安装目录和数据目录是否正确`n• Git 分支通常保持 main`n• 默认勾选【安装后不进入官方配置】`n• 目录入口固定在顶部，不在这里重复显示"
            Set-ButtonAction 'DetailAction1Button' '安装 / 更新 Hermes' 'install-external'
            Set-ButtonAction 'DetailAction2Button' '' '' $false
            Set-ButtonAction 'DetailAction3Button' '' '' $false
            Set-ButtonAction 'DetailAction4Button' '' '' $false
        }
        'OpenClaw' {
            $controls.DetailTitleText.Text = '步骤 2：迁移 OpenClaw'
            if ($state.OpenClawSources.Count -gt 0) {
                if ($state.LauncherState.OpenClawImported) {
                    $controls.DetailSummaryText.Text = "已检测到来源目录：$($state.OpenClawSources -join '; ')。已记录为完成过 OpenClaw 导入；如需重新迁移，可手动再次执行。"
                } elseif ($state.LauncherState.OpenClawPreviewed) {
                    $controls.DetailSummaryText.Text = "已检测到来源目录：$($state.OpenClawSources -join '; ')。你已经完成过预览导入，确认无误后可继续正式导入。"
                } else {
                    $controls.DetailSummaryText.Text = "已检测到来源目录：$($state.OpenClawSources -join '; ')。建议先预览导入，再执行正式导入。"
                }
            } else {
                $controls.DetailSummaryText.Text = '当前未检测到 OpenClaw 默认目录。如果你不是从 OpenClaw 迁移，可以跳过这一步。'
            }
            if ($state.LauncherState.OpenClawImported) {
                $controls.DetailChecklistText.Text = "检查点`n• 当前已记录为完成导入`n• 如需重新迁移，可再次预览或正式导入`n• 如归档失败，先关闭占用该目录的程序"
            } elseif ($state.LauncherState.OpenClawPreviewed) {
                $controls.DetailChecklistText.Text = "检查点`n• 已完成预览导入`n• 确认无误后再执行正式导入`n• 导入会迁移模型、API Key、记忆、技能及部分渠道配置"
            } else {
                $controls.DetailChecklistText.Text = "检查点`n• 先预览，再正式导入`n• 导入会迁移模型、API Key、记忆、技能及部分渠道配置`n• 如归档失败，先关闭占用该目录的程序"
            }
            Set-ButtonAction 'DetailAction1Button' '预览导入 OpenClaw' 'openclaw-preview' $true ([bool]$state.HermesCommand)
            Set-ButtonAction 'DetailAction2Button' '正式导入 OpenClaw' 'openclaw-migrate' $true ([bool]$state.HermesCommand)
            Set-ButtonAction 'DetailAction3Button' '' '' $false
            Set-ButtonAction 'DetailAction4Button' '' '' $false
        }
        'Model' {
            $controls.DetailTitleText.Text = '步骤 3：配置模型与 API Key'
            $controls.DetailSummaryText.Text = '基础对话必须先完成这一步。这里走官方 `hermes model` 流程，不进入完整 setup；终端关闭后，启动器会自动检查配置结果。'
            $controls.DetailChecklistText.Text = "检查点`n• 选择模型提供方和模型`n• 填写对应 API Key`n• 如需手动查看 config.yaml 或 .env，可在左侧维护工具打开"
            Set-ButtonAction 'DetailAction1Button' '配置模型提供商' 'model' $true ([bool]$state.HermesCommand)
            Set-ButtonAction 'DetailAction2Button' '' '' $false
            Set-ButtonAction 'DetailAction3Button' '' '' $false
            Set-ButtonAction 'DetailAction4Button' '' '' $false
        }
        'Check' {
            $controls.DetailTitleText.Text = '步骤 4：快速检测与诊断'
            $controls.DetailSummaryText.Text = '普通用户先看中文快速检测结论。需要排错时，再运行官方 `doctor` 查看详细英文诊断。'
            $controls.DetailChecklistText.Text = "检查点`n• 是否找到 Hermes 命令`n• 是否检测到模型与 API Key`n• 是否具备消息网关依赖与允许用户配置"
            Set-ButtonAction 'DetailAction1Button' '快速检测' 'quick-check'
            Set-ButtonAction 'DetailAction2Button' '运行 doctor' 'doctor' $true ([bool]$state.HermesCommand)
            Set-ButtonAction 'DetailAction3Button' '' '' $false
            Set-ButtonAction 'DetailAction4Button' '' '' $false
        }
        'Launch' {
            $controls.DetailTitleText.Text = '步骤 5：启动本地对话'
            if ($script:LocalChatVerificationPending) {
                $controls.DetailSummaryText.Text = '本地对话终端已经打开。请先测试一轮对话，确认 Hermes 能正常回复，再继续配置消息渠道。'
                $controls.DetailChecklistText.Text = "检查点`n• 本地对话终端已打开`n• 已发送至少一条消息进行验证`n• 验证通过后点击继续配置消息渠道"
                Set-ButtonAction 'DetailAction1Button' '继续配置消息渠道' 'confirm-local-chat' $true ([bool]$state.HermesCommand)
                Set-ButtonAction 'DetailAction2Button' '再次打开本地对话' 'launch' $true ([bool]$state.HermesCommand)
                Set-ButtonAction 'DetailAction3Button' '' '' $false
                Set-ButtonAction 'DetailAction4Button' '' '' $false
            } else {
                $controls.DetailSummaryText.Text = '先在本机终端里验证 Hermes 能否正常回答。这一步通过后，再继续配置消息渠道。'
                $controls.DetailChecklistText.Text = "检查点`n• 成功启动本地对话终端`n• 输入问题后能收到正常回复`n• 若失败，回到检测与模型配置步骤"
                Set-ButtonAction 'DetailAction1Button' '启动本地对话' 'launch' $true ([bool]$state.HermesCommand)
                Set-ButtonAction 'DetailAction2Button' '快速检测' 'quick-check'
                Set-ButtonAction 'DetailAction3Button' '' '' $false
                Set-ButtonAction 'DetailAction4Button' '' '' $false
            }
        }
        'Gateway' {
            $controls.DetailTitleText.Text = '步骤 6：配置并启动消息网关'
            if ($script:ExternalGatewaySetupProcess) {
                $controls.DetailSummaryText.Text = '消息渠道配置终端已经打开。关闭终端后，启动器会自动检查是否配置成功。'
                $controls.DetailChecklistText.Text = "检查点`n• 在官方 gateway setup 中保存配置`n• 关闭终端后等待启动器自动刷新`n• 若未识别成功，重新运行消息渠道配置"
                Set-ButtonAction 'DetailAction1Button' '重新打开消息渠道配置' 'gateway-setup' $true ([bool]$state.HermesCommand)
                Set-ButtonAction 'DetailAction2Button' '' '' $false
                Set-ButtonAction 'DetailAction3Button' '' '' $false
                Set-ButtonAction 'DetailAction4Button' '' '' $false
            } elseif ($script:ExternalMessagingProcess) {
                $controls.DetailSummaryText.Text = '正在安装消息渠道依赖。安装成功后，如果这次是从“启动消息网关”进入，启动器会自动继续启动消息网关。'
                $controls.DetailChecklistText.Text = "检查点`n• 等待依赖安装终端完成`n• 成功后自动刷新推荐`n• 失败时直接查看终端报错"
                Set-ButtonAction 'DetailAction1Button' '' '' $false
                Set-ButtonAction 'DetailAction2Button' '' '' $false
                Set-ButtonAction 'DetailAction3Button' '' '' $false
                Set-ButtonAction 'DetailAction4Button' '' '' $false
            } elseif ($state.GatewayRuntime.State -eq 'Running') {
                $controls.DetailSummaryText.Text = '消息网关已经在线。保持网关终端窗口运行，消息渠道才能持续接收和回复。'
                $controls.DetailChecklistText.Text = "检查点`n• 不要关闭网关终端窗口`n• 如需改渠道，先重新运行消息渠道配置`n• 日志目录入口固定放在左侧维护工具"
                Set-ButtonAction 'DetailAction1Button' '重新配置消息渠道' 'gateway-setup' $true ([bool]$state.HermesCommand)
                Set-ButtonAction 'DetailAction2Button' '' '' $false
                Set-ButtonAction 'DetailAction3Button' '' '' $false
                Set-ButtonAction 'DetailAction4Button' '' '' $false
            } elseif ($state.GatewayStatus.HasConfiguredChannel) {
                $platformText = $state.GatewayStatus.ConnectedPlatforms -join '、'
                $dependencyText = if ($state.GatewayStatus.NeedsDependencyInstall) {
                    '点击“启动消息网关”后，启动器会先安装缺失依赖，再自动继续启动网关。'
                } else {
                    '点击“启动消息网关”会直接开启网关。'
                }
                $allowText = if ($state.GatewayStatus.HasGatewayAccessPolicy) {
                    '已检测到允许用户配置。'
                } else {
                    '当前未检测到允许用户配置，网关虽可启动，但未授权用户会被拒绝。'
                }
                $controls.DetailSummaryText.Text = "已检测到消息渠道配置：$platformText。$dependencyText"
                $controls.DetailChecklistText.Text = "检查点`n• 已识别渠道配置：$platformText`n• $allowText`n• 启动后保持网关终端窗口运行"
                Set-ButtonAction 'DetailAction1Button' '启动消息网关' 'gateway' $true ([bool]$state.HermesCommand)
                Set-ButtonAction 'DetailAction2Button' '重新配置消息渠道' 'gateway-setup' $true ([bool]$state.HermesCommand)
                Set-ButtonAction 'DetailAction3Button' '手动安装渠道依赖' 'install-messaging' $true ([bool]$state.HermesCommand)
                Set-ButtonAction 'DetailAction4Button' '' '' $false
            } else {
                $controls.DetailSummaryText.Text = '还没有检测到有效的消息渠道配置。完成配置后，启动器会自动把推荐操作推进到“启动消息网关”。'
                $controls.DetailChecklistText.Text = "检查点`n• 先运行 gateway setup 配置渠道`n• 关闭终端后等待启动器自动检测`n• 检测成功后再启动消息网关"
                Set-ButtonAction 'DetailAction1Button' '配置消息渠道' 'gateway-setup' $true ([bool]$state.HermesCommand)
                Set-ButtonAction 'DetailAction2Button' '' '' $false
                Set-ButtonAction 'DetailAction3Button' '' '' $false
                Set-ButtonAction 'DetailAction4Button' '' '' $false
            }
        }
        'Advanced' {
            $controls.DetailTitleText.Text = '步骤 7：高级配置与维护'
            $controls.DetailSummaryText.Text = '这里放的是增强能力和维护动作，不是基础对话的必需项。需要手动排查、查看配置文件、更新、重装时，再进入这里。'
            $controls.DetailChecklistText.Text = "包括`n• 查看 config.yaml / .env / 日志`n• Tools 能力配置`n• 完整 setup 与 update`n• 卸载 / 重装"
            Set-ButtonAction 'DetailAction1Button' '打开 config.yaml' 'open-config' $true (Test-Path (Join-Path $state.HermesHome 'config.yaml'))
            Set-ButtonAction 'DetailAction2Button' '打开 .env' 'open-env' $true (Test-Path (Join-Path $state.HermesHome '.env'))
            Set-ButtonAction 'DetailAction3Button' '打开日志目录' 'open-logs' $true (Test-Path (Join-Path $state.HermesHome 'logs'))
            Set-ButtonAction 'DetailAction4Button' '运行 update' 'update' $true ([bool]$state.HermesCommand)
            Set-ButtonAction 'DetailAction5Button' '配置 tools' 'tools' $true ([bool]$state.HermesCommand)
            Set-ButtonAction 'DetailAction6Button' '完整 setup' 'full-setup' $true ([bool]$state.HermesCommand)
            Set-ButtonAction 'DetailAction7Button' '卸载 / 重装' 'uninstall' $true
        }
    }
}

function Invoke-AppAction {
    param([string]$ActionId)

    $state = Get-UiState
    $script:CurrentStatus = $state
    $installDir = $state.InstallDir
    $hermesHome = $state.HermesHome
    $hermesCommand = $state.HermesCommand

    switch ($ActionId) {
        'refresh' {
            Refresh-Status
            Add-ActionLog -Action '刷新状态' -Result $controls.StatusHeadlineText.Text -Next $controls.RecommendationText.Text
        }
        'browse-home' {
            Open-InExplorer -Path $hermesHome
            Add-ActionLog -Action '打开数据目录' -Result '已请求打开 Hermes 数据目录' -Next '可查看 .env、config.yaml 和 logs'
        }
        'browse-install' {
            Open-InExplorer -Path $installDir
            Add-ActionLog -Action '打开安装目录' -Result '已请求打开 Hermes 安装目录' -Next '可查看仓库源码与 venv'
        }
        'install-external' {
            if (-not $installDir -or -not $hermesHome -or -not $state.Branch) {
                [System.Windows.MessageBox]::Show('安装目录、数据目录和 Git 分支不能为空。', 'Hermes 启动器')
                return
            }
            try {
                $installEnv = Get-WindowsInstallEnvironment
                $preferredPythonVersion = Get-PreferredPythonVersionForInstall -InstallEnv $installEnv
                Keep-LauncherVisible
                $tempScript = New-TempScriptFromUrl -Url $defaults.OfficialInstallUrl -PreferredPythonVersion $preferredPythonVersion
                $args = Build-InstallArguments -ScriptPath $tempScript -InstallDir $installDir -HermesHome $hermesHome -Branch $state.Branch -NoVenv ([bool]$controls.NoVenvCheckBox.IsChecked) -SkipSetup ([bool]$controls.SkipSetupCheckBox.IsChecked)
                $wrapperScript = New-ExternalInstallWrapperScript -InstallScriptPath $tempScript -Arguments $args
                $proc = Start-Process powershell.exe -PassThru -WorkingDirectory $env:TEMP -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapperScript)
                Start-ExternalInstallMonitor -Process $proc
                Add-ActionLog -Action '安装 / 更新 Hermes' -Result '已打开独立 PowerShell 安装终端。安装成功会自动关闭，失败会保留终端供查看报错。' -Next '安装结束后启动器会自动刷新状态'
                Add-LogLine ('安装器将优先使用的 Python 目标版本: ' + $preferredPythonVersion)
                if ($installEnv.HasOnlyPython313) {
                    Add-LogLine '安装前环境提示：当前只检测到 Python 3.13。GUI 安装器会先尝试复用本机 3.13，而不是强制下载 3.11。'
                }
                if ($installEnv.PyLauncherVersions) {
                    Add-LogLine ('py 已检测到的 Python 版本: ' + ($installEnv.PyLauncherVersions -replace "`r?`n", ' | '))
                }
                if ($installEnv.PythonVersion) {
                    Add-LogLine ('python --version: ' + $installEnv.PythonVersion)
                }
                if ($installEnv.UvVersion) {
                    Add-LogLine ('uv 版本: ' + $installEnv.UvVersion)
                } else {
                    Add-LogLine 'uv 版本: 未检测到，官方安装脚本会尝试自动安装 uv。'
                }
                if ($installEnv.WingetVersion) {
                    Add-LogLine ('winget 版本: ' + $installEnv.WingetVersion)
                } else {
                    Add-LogLine 'winget 版本: 未检测到。若 uv 自动安装 Python 失败，建议手动安装 Python 3.11。'
                }
            } catch {
                Add-ActionLog -Action '改用外部终端安装' -Result ('启动安装脚本失败：' + $_.Exception.Message) -Next '检查网络或终端报错后重试'
            }
        }
        'openclaw-preview' {
            if (-not $hermesCommand) {
                [System.Windows.MessageBox]::Show('未找到 Hermes 命令，请先安装 Hermes。', 'Hermes 启动器')
                return
            }
            Start-InTerminal -WorkingDirectory $installDir -HermesHome $hermesHome -CommandLine ("& '$hermesCommand' claw migrate --dry-run") | Out-Null
            Save-LauncherState -HermesHome $hermesHome -OpenClawPreviewed $true
            Add-ActionLog -Action '预览导入 OpenClaw' -Result '已打开 dry-run 终端，不会写入配置' -Next '确认预览结果后，可继续正式导入 OpenClaw'
            Refresh-Status
        }
        'openclaw-migrate' {
            if (-not $hermesCommand) {
                [System.Windows.MessageBox]::Show('未找到 Hermes 命令，请先安装 Hermes。', 'Hermes 启动器')
                return
            }
            $confirm = [System.Windows.MessageBox]::Show('正式导入会把 OpenClaw/Clawdbot/Moldbot 的模型、API Key、记忆和部分渠道配置迁移到 Hermes。是否继续？', '确认导入 OpenClaw', 'YesNo', 'Warning')
            if ($confirm -ne 'Yes') {
                Add-LogLine '已取消 OpenClaw 正式导入。'
                return
            }
            Start-InTerminal -WorkingDirectory $installDir -HermesHome $hermesHome -CommandLine ("& '$hermesCommand' claw migrate --preset full") | Out-Null
            Save-LauncherState -HermesHome $hermesHome -OpenClawPreviewed $true -OpenClawImported $true
            Add-ActionLog -Action '正式导入 OpenClaw' -Result '已打开正式迁移终端' -Next '导入完成后，主流程会继续推进到模型配置或后续步骤'
            Refresh-Status
        }
        'model' {
            if (-not $hermesCommand) {
                [System.Windows.MessageBox]::Show('未找到 Hermes 命令，请先安装 Hermes。', 'Hermes 启动器')
                return
            }
            try {
                $wrapperScript = New-ExternalHermesCommandWrapper -HermesCommand $hermesCommand -CommandArguments @('model') -WorkingDirectory $installDir -HermesHome $hermesHome -FailurePrompt '模型配置失败，'
                $proc = Start-Process powershell.exe -PassThru -WorkingDirectory $installDir -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapperScript)
                Start-ExternalModelMonitor -Process $proc
                Add-ActionLog -Action '配置模型提供商' -Result '已打开 `hermes model` 配置终端。关闭终端后，启动器会自动检测配置结果。' -Next '在终端里完成 provider、model 与 API Key 配置'
                Refresh-Status
            } catch {
                Add-ActionLog -Action '配置模型提供商' -Result ('启动模型配置终端失败：' + $_.Exception.Message) -Next '检查环境后重试'
            }
        }
        'quick-check' {
            Show-QuickCheckDialog -state $state
            Add-ActionLog -Action '快速检测' -Result '已显示中文检测结论' -Next '根据窗口中的待处理项继续操作'
        }
        'doctor' {
            if (-not $hermesCommand) {
                [System.Windows.MessageBox]::Show('未找到 Hermes 命令，请先安装 Hermes。', 'Hermes 启动器')
                return
            }
            Start-InTerminal -WorkingDirectory $installDir -HermesHome $hermesHome -CommandLine ("& '$hermesCommand' doctor") | Out-Null
            Add-ActionLog -Action '运行 doctor' -Result '已打开官方诊断终端' -Next '根据终端输出修复问题后再刷新状态'
        }
        'launch' {
            if (-not $hermesCommand) {
                [System.Windows.MessageBox]::Show('未找到 Hermes 命令，请先安装 Hermes。', 'Hermes 启动器')
                return
            }
            $script:LocalChatVerificationPending = $true
            Start-InTerminal -WorkingDirectory $installDir -HermesHome $hermesHome -CommandLine ("& '$hermesCommand'") | Out-Null
            Add-ActionLog -Action '启动本地对话' -Result '已打开 Hermes 本地对话终端' -Next '请先在终端里测试一轮对话，确认正常后继续配置消息渠道'
            Refresh-Status
        }
        'confirm-local-chat' {
            if (-not $hermesCommand) {
                [System.Windows.MessageBox]::Show('未找到 Hermes 命令，请先安装 Hermes。', 'Hermes 启动器')
                return
            }
            $script:LocalChatVerificationPending = $false
            $script:LocalChatVerified = $true
            Save-LauncherState -HermesHome $hermesHome -LocalChatVerified $true
            $script:SelectedStage = 'Gateway'
            try {
                $wrapperScript = New-ExternalTerminalCommandWrapper -WorkingDirectory $installDir -HermesHome $hermesHome -CommandLine ("& '$hermesCommand' gateway setup") -FailurePrompt '消息渠道配置失败，'
                $proc = Start-Process powershell.exe -PassThru -WorkingDirectory $installDir -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapperScript)
                Start-ExternalGatewaySetupMonitor -Process $proc
                Add-ActionLog -Action '确认本地对话已验证' -Result '已直接打开消息渠道配置终端。关闭终端后，启动器会自动检测配置结果。' -Next '若识别到已配置渠道，推荐操作会自动推进到“启动消息网关”'
                Refresh-Status
                Set-StageView 'Gateway'
            } catch {
                Add-ActionLog -Action '确认本地对话已验证' -Result ('启动消息渠道配置终端失败：' + $_.Exception.Message) -Next '检查环境后重试'
            }
        }
        'gateway-setup' {
            if (-not $hermesCommand) {
                [System.Windows.MessageBox]::Show('未找到 Hermes 命令，请先安装 Hermes。', 'Hermes 启动器')
                return
            }
            try {
                $wrapperScript = New-ExternalTerminalCommandWrapper -WorkingDirectory $installDir -HermesHome $hermesHome -CommandLine ("& '$hermesCommand' gateway setup") -FailurePrompt '消息渠道配置失败，'
                $proc = Start-Process powershell.exe -PassThru -WorkingDirectory $installDir -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapperScript)
                Start-ExternalGatewaySetupMonitor -Process $proc
                Add-ActionLog -Action '配置消息渠道' -Result '已打开 `hermes gateway setup` 配置终端。关闭终端后，启动器会自动检测配置结果。' -Next '如配置成功，推荐操作会自动推进到“启动消息网关”'
                Refresh-Status
            } catch {
                Add-ActionLog -Action '配置消息渠道' -Result ('启动消息渠道配置终端失败：' + $_.Exception.Message) -Next '检查环境后重试'
            }
        }
        'install-messaging' {
            $proc = Start-MessagingDependencyInstall -InstallDir $installDir -HermesHome $hermesHome
            if ($proc) {
                $script:PendingGatewayStartAfterMessagingInstall = $false
                Start-ExternalMessagingMonitor -Process $proc -InstallDir $installDir -HermesHome $hermesHome -HermesCommand $hermesCommand
                Add-ActionLog -Action '安装消息渠道依赖' -Result '已打开依赖安装终端。关闭终端后，启动器会自动检测安装结果。' -Next '依赖装好后再启动消息网关'
                Refresh-Status
            }
        }
        'gateway' {
            if (-not $hermesCommand) {
                [System.Windows.MessageBox]::Show('未找到 Hermes 命令，请先安装 Hermes。', 'Hermes 启动器')
                return
            }
            if (-not $state.GatewayStatus.HasConfiguredChannel) {
                [System.Windows.MessageBox]::Show('还没有检测到已配置的消息渠道，请先运行“配置消息渠道”。', 'Hermes 启动器')
                return
            }
            if ($state.GatewayStatus.NeedsDependencyInstall) {
                $proc = Start-MessagingDependencyInstall -InstallDir $installDir -HermesHome $hermesHome
                if ($proc) {
                    $script:PendingGatewayStartAfterMessagingInstall = $true
                    Start-ExternalMessagingMonitor -Process $proc -InstallDir $installDir -HermesHome $hermesHome -HermesCommand $hermesCommand
                    Add-ActionLog -Action '启动消息网关' -Result '已检测到缺少消息渠道依赖，正在先安装依赖。安装完成后，启动器会自动继续启动网关。' -Next '请等待依赖安装终端完成'
                    Refresh-Status
                }
                return
            }
            Start-GatewayRuntimeLaunch -InstallDir $installDir -HermesHome $hermesHome -HermesCommand $hermesCommand
        }
        'open-config' {
            $path = Join-Path $hermesHome 'config.yaml'
            if (Test-Path $path) {
                Start-Process $path | Out-Null
                Add-ActionLog -Action '打开 config.yaml' -Result '已打开配置文件' -Next '保存后返回启动器刷新状态'
            }
        }
        'open-env' {
            $path = Join-Path $hermesHome '.env'
            if (Test-Path $path) {
                Start-Process $path | Out-Null
                Add-ActionLog -Action '打开 .env' -Result '已打开环境变量文件' -Next '保存后返回启动器刷新状态'
            }
        }
        'open-logs' {
            Open-InExplorer -Path (Join-Path $hermesHome 'logs')
            Add-ActionLog -Action '打开日志目录' -Result '已请求打开 logs 目录' -Next '可查看运行日志或网关日志'
        }
        'update' {
            if (-not $hermesCommand) { return }
            Start-InTerminal -WorkingDirectory $installDir -HermesHome $hermesHome -CommandLine ("& '$hermesCommand' update") | Out-Null
            Add-ActionLog -Action '运行 update' -Result '已打开 `hermes update` 终端' -Next '更新后回到启动器刷新状态'
        }
        'tools' {
            if (-not $hermesCommand) { return }
            Start-InTerminal -WorkingDirectory $installDir -HermesHome $hermesHome -CommandLine ("& '$hermesCommand' tools") | Out-Null
            Add-ActionLog -Action '配置 tools' -Result '已打开 `hermes tools` 终端' -Next '按需配置联网搜索、浏览器、图片和语音能力'
        }
        'full-setup' {
            if (-not $hermesCommand) { return }
            Start-InTerminal -WorkingDirectory $installDir -HermesHome $hermesHome -CommandLine ("& '$hermesCommand' setup") | Out-Null
            Add-ActionLog -Action '完整 setup' -Result '已打开 `hermes setup` 终端' -Next '完成后回到启动器刷新状态'
        }
        'uninstall' {
            $choiceMessage = "点击【是】执行标准卸载：仅删除程序，保留 .hermes 数据。`n点击【否】执行彻底卸载：删除程序，并删除或归档 .hermes 数据。"
            $choice = [System.Windows.MessageBox]::Show($choiceMessage, '卸载 Hermes', [System.Windows.MessageBoxButton]::YesNoCancel, [System.Windows.MessageBoxImage]::Warning)
            if ($choice -eq [System.Windows.MessageBoxResult]::Cancel) { return }
            $fullRemove = ($choice -eq [System.Windows.MessageBoxResult]::No)
            $scriptPath = New-UninstallScript -InstallDir $installDir -HermesHome $hermesHome -FullRemove $fullRemove
            Start-Process powershell.exe -ArgumentList @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) | Out-Null
            if ($fullRemove) {
                Add-ActionLog -Action '卸载 / 重装' -Result '已打开彻底卸载终端，目标是删除或归档 .hermes 数据目录' -Next '卸载完成后回到启动器刷新状态，确认状态回到未安装'
            } else {
                Add-ActionLog -Action '卸载 / 重装' -Result '已打开标准卸载终端，会保留 .hermes 数据目录' -Next '卸载完成后回到启动器刷新状态'
            }
        }
    }
}

$controls.ClearLogButton.Add_Click({ $controls.LogTextBox.Clear() })
$controls.RepoButton.Add_Click({ Start-Process $defaults.OfficialRepoUrl | Out-Null; Add-ActionLog -Action '打开官方仓库' -Result '已在浏览器中打开 GitHub 仓库' -Next '需要查看官方源码时再使用' })
$controls.DocsButton.Add_Click({ Start-Process $defaults.OfficialDocsUrl | Out-Null; Add-ActionLog -Action '打开官方文档' -Result '已在浏览器中打开 Hermes 文档' -Next '需要核对命令和配置项时再使用' })
$controls.BrowseHomeButton.Add_Click({ Invoke-AppAction 'browse-home' })
$controls.BrowseInstallButton.Add_Click({ Invoke-AppAction 'browse-install' })
$controls.RefreshButton.Add_Click({ Invoke-AppAction 'refresh' })
$controls.PrimaryActionButton.Add_Click({ Invoke-AppAction $script:PrimaryActionId })
$controls.SecondaryActionButton.Add_Click({
    if ($controls.SecondaryActionButton.Tag) {
        Invoke-AppAction ([string]$controls.SecondaryActionButton.Tag)
    }
})

foreach ($pair in @(
    @{ Control = 'StageInstallButton'; Stage = 'Install' },
    @{ Control = 'StageOpenClawButton'; Stage = 'OpenClaw' },
    @{ Control = 'StageModelButton'; Stage = 'Model' },
    @{ Control = 'StageCheckButton'; Stage = 'Check' },
    @{ Control = 'StageLaunchButton'; Stage = 'Launch' },
    @{ Control = 'StageGatewayButton'; Stage = 'Gateway' },
    @{ Control = 'StageAdvancedButton'; Stage = 'Advanced' }
)) {
    $controls[$pair.Control].Add_Click({
        param($sender, $args)
        $name = $sender.Name
        switch ($name) {
            'StageInstallButton' { Set-StageView 'Install' }
            'StageOpenClawButton' { Set-StageView 'OpenClaw' }
            'StageModelButton' { Set-StageView 'Model' }
            'StageCheckButton' { Set-StageView 'Check' }
            'StageLaunchButton' { Set-StageView 'Launch' }
            'StageGatewayButton' { Set-StageView 'Gateway' }
            'StageAdvancedButton' { Set-StageView 'Advanced' }
        }
    })
}

foreach ($buttonName in @('DetailAction1Button','DetailAction2Button','DetailAction3Button','DetailAction4Button','DetailAction5Button','DetailAction6Button','DetailAction7Button')) {
    $controls[$buttonName].Add_Click({
        param($sender, $args)
        if ($sender.Tag) {
            Invoke-AppAction ([string]$sender.Tag)
        }
    })
}

Add-LogLine '启动器已就绪。'
Refresh-Status
$window.ShowDialog() | Out-Null
