param(
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LauncherMutex = $null
if (-not $SelfTest) {
    $script:LauncherMutex = New-Object System.Threading.Mutex($false, 'Global\HermesGuiLauncher_SingleInstance')
    if (-not $script:LauncherMutex.WaitOne(0, $false)) {
        $script:LauncherMutex.Dispose()
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show('Hermes 启动器已在运行中。', 'Hermes 启动器', 'OK', 'Information') | Out-Null
        exit 0
    }
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms

$script:LauncherVersion = 'Windows v2026.04.30.9'
$script:HermesWebUiHost = '127.0.0.1'
$script:HermesWebUiPort = 8648
$script:HermesWebUiNpmPackage = 'hermes-web-ui'
$script:HermesWebUiVersion = '0.4.9'
$script:NodeMinVersion = 'v23.0.0'
$script:NodeDownloadUrl = 'https://nodejs.org/dist/v23.11.0/node-v23.11.0-win-x64.zip'
$script:NodeExpectedDir = 'node-v23.11.0-win-x64'
$script:GatewayProcess = $null
$script:GatewayHermesExe = $null
$script:EnvWatcher = $null
$script:EnvWatcherTimer = $null
$script:LaunchTimer = $null
$script:LaunchState = $null

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class HermesLauncherWin32 {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@

# Hide the console (terminal) window immediately — only the WPF GUI should be visible
# Skip in SelfTest mode so JSON output remains visible in interactive use
if (-not $SelfTest) {
    $script:ConsoleHandle = [HermesLauncherWin32]::GetConsoleWindow()
    if ($script:ConsoleHandle -ne [IntPtr]::Zero) {
        [HermesLauncherWin32]::ShowWindow($script:ConsoleHandle, 0) | Out-Null  # SW_HIDE = 0
    }
}

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

function Get-HermesWebUiDefaults {
    $nodeRoot = Join-Path $env:LOCALAPPDATA 'hermes\nodejs'
    $nodeDir = Join-Path $nodeRoot $script:NodeExpectedDir
    $nodeExe = Join-Path $nodeDir 'node.exe'
    $npmCmd = Join-Path $nodeDir 'npm.cmd'
    $npmPrefix = Join-Path $env:LOCALAPPDATA 'hermes\npm-global'
    $webuiCmd = Join-Path $npmPrefix 'hermes-web-ui.cmd'
    $hermesHome = Join-Path $env:USERPROFILE '.hermes'
    $webuiHome = Join-Path $env:USERPROFILE '.hermes-web-ui'
    [pscustomobject]@{
        NodeRoot    = $nodeRoot
        NodeDir     = $nodeDir
        NodeExe     = $nodeExe
        NpmCmd      = $npmCmd
        NpmPrefix   = $npmPrefix
        WebUiCmd    = $webuiCmd
        Host        = $script:HermesWebUiHost
        Port        = $script:HermesWebUiPort
        Version     = $script:HermesWebUiVersion
        LogsDir     = Join-Path (Join-Path $hermesHome 'logs') 'webui'
        PidFile     = Join-Path $webuiHome 'server.pid'
        WebUiHome   = $webuiHome
    }
}

function Test-HermesWebUiInstalled {
    $webUi = Get-HermesWebUiDefaults
    $nodeOk = [bool](Test-Path $webUi.NodeExe)
    $cmdOk = [bool](Test-Path $webUi.WebUiCmd)
    [pscustomobject]@{
        Installed   = [bool]($nodeOk -and $cmdOk)
        NodeExists  = $nodeOk
        WebUiCmdExists = $cmdOk
    }
}

function Install-HermesNode {
    $webUi = Get-HermesWebUiDefaults
    if (Test-Path $webUi.NodeExe) {
        Add-LogLine 'Node.js 已存在，跳过下载。'
        return $true
    }

    if (-not (Test-Path $webUi.NodeRoot)) {
        New-Item -ItemType Directory -Path $webUi.NodeRoot -Force | Out-Null
    }

    $zipPath = Join-Path $env:TEMP ('node-' + [guid]::NewGuid().ToString('N') + '.zip')
    try {
        Add-LogLine '正在下载 Node.js（约 30MB，请稍候）...'
        Set-Footer '正在下载 Node.js...'
        Flush-UIRender
        $progressPref = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $script:NodeDownloadUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 180
        } finally {
            $ProgressPreference = $progressPref
        }
        if (-not (Test-Path $zipPath) -or (Get-Item $zipPath).Length -lt 1024) {
            throw '下载文件为空或不完整。'
        }

        Add-LogLine '正在解压 Node.js...'
        Set-Footer '正在解压 Node.js...'
        Flush-UIRender
        Expand-Archive -Path $zipPath -DestinationPath $webUi.NodeRoot -Force

        if (-not (Test-Path $webUi.NodeExe)) {
            throw "解压后未找到 node.exe：$($webUi.NodeExe)"
        }

        Add-LogLine 'Node.js 安装完成。'
        return $true
    } catch {
        Add-LogLine ('Node.js 安装失败：' + $_.Exception.Message)
        return $false
    } finally {
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-HermesWebUiInstalledVersion {
    <#
    .SYNOPSIS
    Read the installed hermes-web-ui version from its package.json.
    Returns $null if not installed.
    #>
    $webUi = Get-HermesWebUiDefaults
    $pkgJson = Join-Path $webUi.NpmPrefix 'node_modules\hermes-web-ui\package.json'
    if (-not (Test-Path $pkgJson)) { return $null }
    try {
        $pkg = Get-Content $pkgJson -Raw | ConvertFrom-Json
        return $pkg.version
    } catch {
        return $null
    }
}

function Install-HermesWebUi {
    $webUi = Get-HermesWebUiDefaults
    $existing = Test-HermesWebUiInstalled
    $needsInstall = -not $existing.Installed
    $needsUpgrade = $false

    if ($existing.Installed) {
        # Check if the installed version is older than the target version
        $installedVer = Get-HermesWebUiInstalledVersion
        if ($installedVer -and $installedVer -ne $script:HermesWebUiVersion) {
            $needsUpgrade = $true
            Add-LogLine ("hermes-web-ui 当前版本 {0}，目标版本 {1}，需要升级" -f $installedVer, $script:HermesWebUiVersion)
        }
        if (-not $needsUpgrade) {
            return [pscustomobject]@{ Installed = $true; Changed = $false; Message = 'hermes-web-ui 已安装且为最新版。' }
        }
    }

    # Step 1: Ensure portable Node.js is installed
    if (-not (Test-Path $webUi.NodeExe)) {
        $nodeOk = Install-HermesNode
        if (-not $nodeOk) {
            return [pscustomobject]@{ Installed = $false; Changed = $false; Message = 'Node.js 安装失败，无法继续。' }
        }
    }

    # Step 2: npm install -g hermes-web-ui@<version>
    if (-not (Test-Path $webUi.NpmPrefix)) {
        New-Item -ItemType Directory -Path $webUi.NpmPrefix -Force | Out-Null
    }

    $action = if ($needsUpgrade) { '升级' } else { '安装' }
    try {
        Add-LogLine ("正在{0} hermes-web-ui（约需 1-2 分钟）..." -f $action)
        Set-Footer ("正在{0} hermes-web-ui..." -f $action)
        Flush-UIRender
        $env:PATH = "$($webUi.NodeDir);$($webUi.NpmPrefix);$env:PATH"
        $npmArgs = @('install', '-g', "$($script:HermesWebUiNpmPackage)@$($script:HermesWebUiVersion)", '--prefix', $webUi.NpmPrefix)
        $proc = Start-Process -FilePath $webUi.NpmCmd -ArgumentList $npmArgs -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $env:TEMP 'hermes-npm-install.log') -RedirectStandardError (Join-Path $env:TEMP 'hermes-npm-install-err.log')
        if ($proc.ExitCode -ne 0) {
            $errLog = ''
            try { $errLog = Get-Content (Join-Path $env:TEMP 'hermes-npm-install-err.log') -Raw } catch { }
            throw "npm install 失败（退出码 $($proc.ExitCode)）。$errLog"
        }

        $check = Test-HermesWebUiInstalled
        if (-not $check.Installed) {
            throw ("{0}完成但未找到 hermes-web-ui 命令，请检查日志。" -f $action)
        }

        Add-LogLine ("hermes-web-ui {0}完成。" -f $action)
        return [pscustomobject]@{ Installed = $true; Changed = $true; Message = ("hermes-web-ui {0}完成。" -f $action) }
    } catch {
        return [pscustomobject]@{ Installed = $false; Changed = $false; Message = ("hermes-web-ui {0}失败：{1}" -f $action, $_.Exception.Message) }
    }
}

function Test-HermesWebUiHealth {
    try {
        $url = "http://$($script:HermesWebUiHost):$($script:HermesWebUiPort)/health"
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        return [pscustomobject]@{
            Healthy = $true
            Url     = "http://$($script:HermesWebUiHost):$($script:HermesWebUiPort)"
            Message = 'hermes-web-ui 正在运行。'
        }
    } catch {
        return [pscustomobject]@{
            Healthy = $false
            Url     = "http://$($script:HermesWebUiHost):$($script:HermesWebUiPort)"
            Message = 'hermes-web-ui 未响应。'
        }
    }
}

function Install-GatewayPlatformDeps {
    <#
    .SYNOPSIS
    Auto-install missing Python packages for messaging platforms configured in .env.
    Reads ~/.hermes/.env, checks which platforms are enabled, and installs their
    optional dependencies (e.g. lark-oapi for Feishu) via uv pip.
    Returns $true if any new package was installed (caller may need to restart gateway).
    #>
    param([string]$HermesInstallDir)

    $envFile = Join-Path $env:USERPROFILE '.hermes\.env'
    if (-not (Test-Path $envFile)) { return $false }
    $pythonExe = Join-Path $HermesInstallDir 'venv\Scripts\python.exe'
    if (-not (Test-Path $pythonExe)) { return $false }
    $anyInstalled = $false

    # Map: env-var-that-enables-platform → Python-import-test → pip-package-name
    $platformDeps = @(
        @{ EnvKey = 'FEISHU_APP_ID';       ImportTest = 'import lark_oapi';          Package = 'lark-oapi' }
        @{ EnvKey = 'TELEGRAM_BOT_TOKEN';   ImportTest = 'import telegram';           Package = 'python-telegram-bot' }
        @{ EnvKey = 'SLACK_BOT_TOKEN';      ImportTest = 'import slack_bolt';         Package = 'slack-bolt' }
        @{ EnvKey = 'DINGTALK_CLIENT_ID';   ImportTest = 'import dingtalk_stream';    Package = 'dingtalk-stream' }
        @{ EnvKey = 'DISCORD_BOT_TOKEN';    ImportTest = 'import discord';            Package = 'discord.py' }
    )

    # Read .env lines (skip comments and empty lines)
    $envLines = Get-Content $envFile -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '^\s*[A-Z]' }

    # Ensure GATEWAY_ALLOW_ALL_USERS=true is in .env — personal launcher needs
    # open access so Telegram/WeChat/etc. messages are not silently rejected.
    $hasAllowAll = $envLines | Where-Object { $_ -match '^\s*GATEWAY_ALLOW_ALL_USERS\s*=\s*true' }
    if (-not $hasAllowAll) {
        $anyPlatform = $envLines | Where-Object { $_ -match '^\s*(TELEGRAM_BOT_TOKEN|WEIXIN_ACCOUNT_ID|FEISHU_APP_ID|SLACK_BOT_TOKEN|DINGTALK_CLIENT_ID|DISCORD_BOT_TOKEN)\s*=\s*.+' }
        if ($anyPlatform) {
            try {
                Add-Content -Path $envFile -Value "`nGATEWAY_ALLOW_ALL_USERS=true" -Encoding UTF8
                Add-LogLine "已在 .env 中启用 GATEWAY_ALLOW_ALL_USERS=true"
            } catch {
                Add-LogLine ("写入 GATEWAY_ALLOW_ALL_USERS 失败：{0}" -f $_.Exception.Message)
            }
        }
    }

    foreach ($dep in $platformDeps) {
        # Check if this platform is configured in .env (uncommented, with a value)
        $configured = $envLines | Where-Object { $_ -match "^\s*$($dep.EnvKey)\s*=\s*.+" }
        if (-not $configured) { continue }

        # Check if the Python package is already installed
        $result = & $pythonExe -c $dep.ImportTest 2>&1
        if ($LASTEXITCODE -eq 0) { continue }

        # Package missing — install it
        Add-LogLine ("正在安装渠道依赖：{0}..." -f $dep.Package)
        try {
            $uvExe = Resolve-UvCommand
            # Also check uv inside the hermes venv Scripts dir
            if (-not $uvExe) {
                $venvUv = Join-Path $HermesInstallDir 'venv\Scripts\uv.exe'
                if (Test-Path $venvUv) { $uvExe = $venvUv }
            }
            if ($uvExe) {
                $installOutput = & $uvExe pip install $dep.Package --python $pythonExe 2>&1
                Add-LogLine ("uv 安装输出：{0}" -f ($installOutput | Select-Object -Last 3 | Out-String).Trim())
            } else {
                $installOutput = & $pythonExe -m pip install $dep.Package 2>&1
                Add-LogLine ("pip 安装输出：{0}" -f ($installOutput | Select-Object -Last 3 | Out-String).Trim())
            }
            if ($LASTEXITCODE -eq 0) {
                Add-LogLine ("{0} 安装成功" -f $dep.Package)
                $anyInstalled = $true
            } else {
                Add-LogLine ("{0} 安装失败（退出码 {1}），该渠道可能无法使用" -f $dep.Package, $LASTEXITCODE)
            }
        } catch {
            Add-LogLine ("{0} 安装失败：{1}" -f $dep.Package, $_.Exception.Message)
        }
    }
    return $anyInstalled
}

function Stop-ExistingGateway {
    <#
    .SYNOPSIS
    Kill any existing hermes gateway process and clean up the lock file.
    On Windows, 'hermes gateway run --replace' crashes with PermissionError
    when reading gateway.lock held by the running process (陷阱 #18).
    We must kill the process ourselves and remove the stale lock.
    Designed to be fast (no WMI queries, no long sleeps).
    #>
    $killed = $false
    # Kill process tracked by this launcher session
    if ($script:GatewayProcess -and -not $script:GatewayProcess.HasExited) {
        try {
            $oldPid = $script:GatewayProcess.Id
            Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
            Add-LogLine ("已停止 Gateway 进程（PID: {0}）" -f $oldPid)
            $killed = $true
        } catch { }
    }
    # Also kill any orphan hermes gateway processes (e.g. from a previous launcher session).
    # Use taskkill which is fast and doesn't need WMI.
    try {
        $result = cmd /c "taskkill /f /im hermes.exe 2>&1" | Out-String
        if ($result -match 'SUCCESS') {
            Add-LogLine "已停止残留 hermes 进程"
            $killed = $true
        }
    } catch { }
    # Kill orphan python.exe spawned by hermes gateway — hermes.exe is a thin
    # entry-point wrapper; the real gateway runs inside python.exe from the
    # hermes venv.  If we only kill hermes.exe, the child python.exe keeps the
    # API port occupied, forcing the next gateway to bind a different port.
    # The webui hardcodes its upstream to port 8642, so port drift → "未连接".
    $hermesVenvPython = Join-Path $env:LOCALAPPDATA 'hermes\hermes-agent\venv\Scripts\python.exe'
    try {
        $pythonProcs = Get-Process -Name 'python' -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $hermesVenvPython }
        foreach ($pp in $pythonProcs) {
            try {
                Stop-Process -Id $pp.Id -Force -ErrorAction SilentlyContinue
                Add-LogLine ("已停止 Gateway 子进程 python.exe（PID: {0}）" -f $pp.Id)
                $killed = $true
            } catch { }
        }
    } catch { }
    # Always remove gateway.lock — it may be stale from a crashed gateway.
    # Without cleanup, 'hermes gateway run' may fail reading the orphaned lock.
    $lockFile = Join-Path $env:USERPROFILE '.hermes\gateway.lock'
    if (Test-Path $lockFile) {
        if ($killed) { Start-Sleep -Milliseconds 500 }
        try {
            Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
            Add-LogLine "已清理 gateway.lock"
        } catch { }
    }
}

function Repair-GatewayApiPort {
    <#
    .SYNOPSIS
    Ensure config.yaml has api_server port = 8642 (the default).
    hermes-web-ui hardcodes upstream to http://127.0.0.1:8642.  If config.yaml
    has a different port, the gateway binds elsewhere and webui shows "未连接".
    The env var API_SERVER_PORT does NOT override config.yaml (config takes
    priority in the gateway code), so we must fix the file directly.
    #>
    $configFile = Join-Path $env:USERPROFILE '.hermes\config.yaml'
    if (-not (Test-Path $configFile)) { return }
    try {
        # Must read/write as UTF-8 — PowerShell 5.1 Set-Content defaults to GBK
        # on Chinese Windows, which corrupts non-ASCII YAML and crashes the gateway.
        $content = [System.IO.File]::ReadAllText($configFile, [System.Text.Encoding]::UTF8)
        # Match port: <number> under platforms.api_server.extra section
        # Only fix if it's NOT already 8642
        if ($content -match '(?m)(^\s+port:\s+)(\d+)' -and $Matches[2] -ne '8642') {
            $oldPort = $Matches[2]
            $content = $content -replace '(?m)(^\s+port:\s+)\d+', '${1}8642'
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($configFile, $content, $utf8NoBom)
            Add-LogLine ("已修复 config.yaml 端口：{0} → 8642（WebUI 要求）" -f $oldPort)
        }
    } catch {
        Add-LogLine ("config.yaml 端口修复跳过：{0}" -f $_.Exception.Message)
    }
}

function Start-HermesGateway {
    param(
        [string]$HermesInstallDir
    )
    $hermesExe = Join-Path $HermesInstallDir 'venv\Scripts\hermes.exe'
    if (-not (Test-Path $hermesExe)) { return }

    # Auto-install missing platform dependencies before starting gateway
    try { Install-GatewayPlatformDeps -HermesInstallDir $HermesInstallDir } catch {
        Add-LogLine ("渠道依赖检测跳过：{0}" -f $_.Exception.Message)
    }

    # Ensure gateway API port matches what webui expects (陷阱 #20)
    Repair-GatewayApiPort

    # Kill existing gateway first — 'hermes gateway run --replace' crashes on Windows
    # with PermissionError when reading gateway.lock (陷阱 #18).
    Stop-ExistingGateway

    try {
        $env:HERMES_HOME = Join-Path $env:USERPROFILE '.hermes'
        # Force UTF-8 for Python to avoid UnicodeEncodeError on Chinese Windows (GBK)
        $env:PYTHONIOENCODING = 'utf-8'
        # Personal launcher: allow all users by default so messaging platforms work out of the box
        $env:GATEWAY_ALLOW_ALL_USERS = 'true'
        # Also set env var as belt-and-suspenders (config.yaml takes priority in
        # gateway code, but env var covers cases where config has no port key)
        $env:API_SERVER_PORT = '8642'
        $proc = Start-Process -FilePath $hermesExe -ArgumentList @('gateway', 'run') -WindowStyle Hidden -PassThru
        $script:GatewayProcess = $proc
        $script:GatewayHermesExe = $hermesExe
        Add-LogLine ("Hermes Gateway 已启动（PID: {0}）" -f $proc.Id)

        # Write gateway.pid so hermes-web-ui's GatewayManager recognises this
        # gateway as "already running" and does NOT attempt its own start
        # (which would block and be killed after 30s — 陷阱 #22).
        $pidFile = Join-Path $env:USERPROFILE '.hermes\gateway.pid'
        try {
            $pidJson = '{{"pid": {0}, "kind": "hermes-gateway"}}' -f $proc.Id
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($pidFile, $pidJson, $utf8NoBom)
        } catch { }
    } catch {
        Add-LogLine ("Hermes Gateway 启动失败：{0}" -f $_.Exception.Message)
    }
}

function Restart-HermesGateway {
    <#
    .SYNOPSIS
    Kill the current gateway process and start a fresh one.
    Called by the .env file watcher when channel config changes.
    Must install platform deps before starting, same as Start-HermesGateway.
    #>
    Add-LogLine "检测到 .env 文件变化，准备重启 Gateway..."
    $hermesExe = $script:GatewayHermesExe
    if (-not $hermesExe -or -not (Test-Path $hermesExe)) {
        Add-LogLine "Gateway 可执行文件未找到，跳过重启"
        return
    }

    # Install platform deps for newly configured channels (e.g. python-telegram-bot)
    # hermes.exe is at hermes-agent\venv\Scripts\hermes.exe → need 3 levels up
    $hermesInstallDir = Split-Path (Split-Path (Split-Path $hermesExe -Parent) -Parent) -Parent
    try { Install-GatewayPlatformDeps -HermesInstallDir $hermesInstallDir } catch {
        Add-LogLine ("渠道依赖检测跳过：{0}" -f $_.Exception.Message)
    }

    try {
        # Kill existing gateway — don't use --replace (crashes on Windows, 陷阱 #18)
        Stop-ExistingGateway

        # Ensure env vars are set (same as Start-HermesGateway)
        $env:HERMES_HOME = Join-Path $env:USERPROFILE '.hermes'
        $env:PYTHONIOENCODING = 'utf-8'
        $env:GATEWAY_ALLOW_ALL_USERS = 'true'
        $env:API_SERVER_PORT = '8642'
        $proc = Start-Process -FilePath $hermesExe -ArgumentList @('gateway', 'run') -WindowStyle Hidden -PassThru
        $script:GatewayProcess = $proc
        Add-LogLine ("Gateway 已自动重启以加载新渠道配置（PID: {0}）" -f $proc.Id)

        # Write gateway.pid so webui's GatewayManager doesn't try to restart (陷阱 #22)
        $pidFile = Join-Path $env:USERPROFILE '.hermes\gateway.pid'
        try {
            $pidJson = '{{"pid": {0}, "kind": "hermes-gateway"}}' -f $proc.Id
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($pidFile, $pidJson, $utf8NoBom)
        } catch { }

        # Verify gateway stays alive after a short delay
        Start-Sleep -Milliseconds 3000
        if ($proc.HasExited) {
            Add-LogLine ("Gateway 进程启动后立即退出（退出码: {0}），渠道可能无法使用" -f $proc.ExitCode)
        } else {
            Add-LogLine "Gateway 进程运行正常"
        }
    } catch {
        Add-LogLine ("Gateway 自动重启失败：{0}" -f $_.Exception.Message)
    }
}

function Start-GatewayEnvWatcher {
    <#
    .SYNOPSIS
    Watch ~/.hermes/.env for writes and auto-restart gateway to pick up new config.
    Debounces rapid writes (2-second delay after last change).
    #>
    $envFile = Join-Path $env:USERPROFILE '.hermes\.env'
    $envDir  = Split-Path $envFile -Parent
    if (-not (Test-Path $envDir)) { return }

    # Dispose previous watcher if any
    if ($script:EnvWatcher) {
        try { $script:EnvWatcher.EnableRaisingEvents = $false; $script:EnvWatcher.Dispose() } catch { }
    }
    if ($script:EnvWatcherTimer) {
        try { $script:EnvWatcherTimer.Stop(); $script:EnvWatcherTimer.Dispose() } catch { }
    }

    $watcher = [System.IO.FileSystemWatcher]::new($envDir, '.env')
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite
    $watcher.IncludeSubdirectories = $false

    # Debounce timer: fires 2 seconds after the last .env write
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromSeconds(2)
    $timer.Add_Tick({
        $script:EnvWatcherTimer.Stop()
        Restart-HermesGateway
    })

    # Handler for both Changed and Created events — on fresh installs, .env may
    # not exist yet and webui creates it when user saves platform config.
    $onEnvModified = {
        # FileSystemWatcher fires on a thread-pool thread — must marshal to UI thread
        # to safely operate on DispatcherTimer (陷阱 #15)
        $window.Dispatcher.BeginInvoke([Action]{
            $script:EnvWatcherTimer.Stop()
            $script:EnvWatcherTimer.Start()
        })
    }
    $watcher.Add_Changed($onEnvModified)
    $watcher.Add_Created($onEnvModified)

    $watcher.EnableRaisingEvents = $true
    $script:EnvWatcher = $watcher
    $script:EnvWatcherTimer = $timer
}

function Start-HermesWebUiRuntime {
    param(
        [string]$HermesInstallDir
    )
    $webUi = Get-HermesWebUiDefaults
    if (-not (Test-Path $webUi.WebUiCmd)) {
        throw "未找到 hermes-web-ui 命令：$($webUi.WebUiCmd)"
    }

    # Start gateway BEFORE webui — on Windows, the webui's GatewayManager
    # calls 'hermes gateway restart' via execFileAsync with a 30-second
    # timeout.  Since 'gateway restart' calls run_gateway() which blocks
    # forever, the gateway is killed after 30s (陷阱 #22).
    # Our solution: start the gateway ourselves and write gateway.pid so
    # GatewayManager.detectStatus() finds it running and skips startAll().
    Start-HermesGateway -HermesInstallDir $HermesInstallDir

    # Build PATH: include Node.js, npm-global, and hermes venv\Scripts
    $pathParts = @($webUi.NodeDir, $webUi.NpmPrefix)
    if ($HermesInstallDir) {
        $venvScripts = Join-Path $HermesInstallDir 'venv\Scripts'
        if (Test-Path $venvScripts) {
            $pathParts += $venvScripts
            $env:HERMES_BIN = Join-Path $venvScripts 'hermes.exe'
        }
    }
    $env:PATH = ($pathParts -join ';') + ";$env:PATH"
    $env:PORT = [string]$webUi.Port
    # Tell npm to use our portable prefix so web-ui's built-in "npm install -g"
    # upgrade command installs into the correct directory instead of %APPDATA%\npm.
    $env:NPM_CONFIG_PREFIX = $webUi.NpmPrefix
    # Force UTF-8 for hermes Python commands spawned by webui's GatewayManager
    $env:PYTHONIOENCODING = 'utf-8'

    # Launch the start command without -Wait (it can hang with -RedirectStandardOutput)
    Start-Process -FilePath $webUi.WebUiCmd -ArgumentList @('start', $webUi.Port) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $env:TEMP 'hermes-webui-start.log') -RedirectStandardError (Join-Path $env:TEMP 'hermes-webui-start-err.log')

    # Poll health until webui is ready (up to 30 seconds)
    $deadline = (Get-Date).AddSeconds(30)
    $health = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 1500
        $health = Test-HermesWebUiHealth
        if ($health.Healthy) { break }
    }

    if (-not $health -or -not $health.Healthy) {
        throw "hermes-web-ui 启动后未能就绪。请检查日志。"
    }

    # Read token from webui's own token file for URL
    $tokenFile = Join-Path $webUi.WebUiHome '.token'
    $token = $null
    if (Test-Path $tokenFile) {
        try { $token = (Get-Content $tokenFile -Raw).Trim() } catch { }
    }
    $url = if ($token) { "http://$($webUi.Host):$($webUi.Port)/#/?token=$token" } else { "http://$($webUi.Host):$($webUi.Port)" }

    # Now that gateway + webui are both healthy, start watching .env for changes.
    # When hermes-web-ui saves channel config, it writes to .env then calls
    # 'hermes gateway restart' which fails on Windows (PermissionError on gateway.lock).
    # We work around this by detecting .env changes and restarting the gateway ourselves.
    Start-GatewayEnvWatcher

    return [pscustomobject]@{
        Port    = $webUi.Port
        Url     = $url
    }
}

function Stop-HermesWebUiRuntime {
    $webUi = Get-HermesWebUiDefaults

    # Stop .env file watcher
    if ($script:EnvWatcher) {
        try { $script:EnvWatcher.EnableRaisingEvents = $false; $script:EnvWatcher.Dispose() } catch { }
        $script:EnvWatcher = $null
    }
    if ($script:EnvWatcherTimer) {
        try { $script:EnvWatcherTimer.Stop(); $script:EnvWatcherTimer.Dispose() } catch { }
        $script:EnvWatcherTimer = $null
    }

    # Stop gateway process if we started it
    if ($script:GatewayProcess -and -not $script:GatewayProcess.HasExited) {
        try {
            Stop-Process -Id $script:GatewayProcess.Id -Force -ErrorAction SilentlyContinue
        } catch { }
    }

    # Use webui's own stop command if available
    if (Test-Path $webUi.WebUiCmd) {
        try {
            $env:PATH = "$($webUi.NodeDir);$($webUi.NpmPrefix);$env:PATH"
            Start-Process -FilePath $webUi.WebUiCmd -ArgumentList @('stop') -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
            return $true
        } catch { }
    }

    # Fallback: kill by PID file
    if (Test-Path $webUi.PidFile) {
        try {
            $pid = [int](Get-Content -LiteralPath $webUi.PidFile -Raw).Trim()
            Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $webUi.PidFile -Force -ErrorAction SilentlyContinue
            return $true
        } catch { }
    }

    return $false
}

function Get-HermesWebUiStatus {
    $installStatus = Test-HermesWebUiInstalled
    $health = Test-HermesWebUiHealth
    [pscustomobject]@{
        Installed = $installStatus.Installed
        Healthy   = $health.Healthy
        Url       = $health.Url
        Version   = $script:HermesWebUiVersion
    }
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
    $configBaseUrl = $null
    $authProvider = $null
    $hasAuthCredential = $false

    if (Test-Path $configPath) {
        $configText = [System.IO.File]::ReadAllText($configPath)
        $modelBlock = Get-YamlTopLevelBlockText -Text $configText -BlockName 'model'

        if ($modelBlock) {
            $configProvider = Get-YamlBlockFieldValue -BlockText $modelBlock -FieldName 'provider'
            $configModel = Get-YamlBlockFieldValue -BlockText $modelBlock -FieldName 'default'
            if (-not $configModel) {
                $configModel = Get-YamlBlockFieldValue -BlockText $modelBlock -FieldName 'model'
            }
            $configBaseUrl = Get-YamlBlockFieldValue -BlockText $modelBlock -FieldName 'base_url'
            $hasModelConfig = [bool]$configModel

            # Bug 2: check api_key in config.yaml model block
            $configApiKey = Get-YamlBlockFieldValue -BlockText $modelBlock -FieldName 'api_key'
            if ($configApiKey) { $hasApiKey = $true }
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
    if (-not $hasApiKey -and $configProvider -eq 'custom' -and $configBaseUrl -match '^https?://(localhost|127\.0\.0\.1|0\.0\.0\.0)') {
        $hasApiKey = $true
    }

    [pscustomobject]@{
        HasModelConfig = [bool]$hasModelConfig
        HasApiKey      = [bool]$hasApiKey
        ReadyLikely    = [bool]($hasModelConfig -and $hasApiKey)
        Provider       = $configProvider
        Model          = $configModel
        BaseUrl        = $configBaseUrl
        AuthProvider   = $authProvider
        UsesAuthJson   = [bool]$hasAuthCredential
        Summary        = if (-not $hasModelConfig) { '未检测到默认模型配置。' } elseif (-not $hasApiKey) { '已检测到 provider / model，但还没有可用凭证或登录态。' } else { '已检测到 provider / model 与可用凭证。' }
    }
}

function Get-EnvAssignmentValue {
    param(
        [string]$Text,
        [string]$Name
    )

    if (-not $Text -or -not $Name) { return $null }
    $pattern = '(?m)^\s*' + [regex]::Escape($Name) + '\s*=\s*(.+?)\s*$'
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }
    return $null
}

function Get-YamlTopLevelBlockText {
    param(
        [string]$Text,
        [string]$BlockName
    )

    if (-not $Text -or -not $BlockName) { return $null }
    $lines = @($Text -split "`r?`n")
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match ('^' + [regex]::Escape($BlockName) + '\s*:\s*$')) {
            $start = $i + 1
            break
        }
    }
    if ($start -lt 0) { return $null }
    $end = $start
    while ($end -lt $lines.Count) {
        if ($lines[$end] -match '^\S') { break }
        $end++
    }
    if ($end -le $start) { return $null }
    return ($lines[$start..($end - 1)] -join "`n")
}

function Get-YamlBlockFieldValue {
    param(
        [string]$BlockText,
        [string]$FieldName
    )

    if (-not $BlockText -or -not $FieldName) { return $null }
    $pattern = '(?m)^\s+' + [regex]::Escape($FieldName) + '\s*:\s*(.+?)\s*$'
    $match = [regex]::Match($BlockText, $pattern)
    if (-not $match.Success) { return $null }
    $val = $match.Groups[1].Value.Trim()
    # Remove surrounding quotes
    if ($val.Length -ge 2 -and (($val[0] -eq '"' -and $val[-1] -eq '"') -or ($val[0] -eq "'" -and $val[-1] -eq "'"))) {
        $val = $val.Substring(1, $val.Length - 2)
    }
    # Strip inline comment (but not for URLs containing ://)
    if ($val -notmatch '://') {
        $commentIdx = $val.IndexOf(' #')
        if ($commentIdx -ge 0) { $val = $val.Substring(0, $commentIdx).TrimEnd() }
    } else {
        # For URLs: strip comment only after a space-hash sequence that follows the URL
        if ($val -match '^(\S+)\s+#') {
            $val = $matches[1]
        }
    }
    if ([string]::IsNullOrWhiteSpace($val)) { return $null }
    return $val
}

function Get-HermesPythonPath {
    param([string]$InstallDir)

    $candidates = @(
        (Join-Path $InstallDir 'venv\Scripts\python.exe'),
        (Join-Path $InstallDir 'python.exe')
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        return $python.Source
    }

    throw '未找到可用的 Python，可先完成 Hermes 安装。'
}

function Invoke-HermesPythonJson {
    param(
        [string]$InstallDir,
        [string]$HermesHome,
        [string]$PythonBody,
        [hashtable]$Payload
    )

    $pythonPath = Get-HermesPythonPath -InstallDir $InstallDir
    $payloadPath = Join-Path $env:TEMP ('hermes-launcher-payload-' + [guid]::NewGuid().ToString('N') + '.json')
    $scriptPath = Join-Path $env:TEMP ('hermes-launcher-helper-' + [guid]::NewGuid().ToString('N') + '.py')

    $fullPayload = @{}
    if ($Payload) {
        foreach ($key in $Payload.Keys) {
            $fullPayload[$key] = $Payload[$key]
        }
    }
    $fullPayload['InstallDir'] = $InstallDir
    $fullPayload['HermesHome'] = $HermesHome

    $json = $fullPayload | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($payloadPath, $json, [System.Text.Encoding]::UTF8)

    $indentedPythonBody = (($PythonBody -split "`r?`n") | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_)) {
            ''
        } else {
            '    ' + $_
        }
    }) -join [Environment]::NewLine

    $python = @"
import json, os, sys, traceback
payload_path = sys.argv[1]
with open(payload_path, 'r', encoding='utf-8-sig') as fh:
    payload = json.load(fh)
install_dir = payload.get('InstallDir', '')
hermes_home = payload.get('HermesHome', '')
if hermes_home:
    os.environ['HERMES_HOME'] = hermes_home
if install_dir and install_dir not in sys.path:
    sys.path.insert(0, install_dir)
try:
$indentedPythonBody
except SystemExit:
    raise
except Exception as exc:
    print(json.dumps({'ok': False, 'error': str(exc), 'traceback': traceback.format_exc()}, ensure_ascii=False))
    raise
"@
    [System.IO.File]::WriteAllText($scriptPath, $python, [System.Text.Encoding]::UTF8)

    try {
        $output = & $pythonPath $scriptPath $payloadPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw (($output | Out-String).Trim())
        }
        $raw = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }
        $jsonLine = $null
        $rawLines = @($raw -split "`r?`n")
        for ($index = $rawLines.Count - 1; $index -ge 0; $index--) {
            $trimmed = $rawLines[$index].Trim()
            if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
                $jsonLine = $trimmed
                break
            }
        }
        if (-not $jsonLine) {
            throw ("Python helper 未返回可解析的 JSON。原始输出：`n" + $raw)
        }
        return ($jsonLine | ConvertFrom-Json)
    } finally {
        Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-HermesAuthStatusSnapshot {
    param(
        [string]$InstallDir,
        [string]$HermesHome,
        [string]$ProviderId
    )

    if ($ProviderId -eq 'anthropic-account') {
        $claudeCreds = Join-Path $env:USERPROFILE '.claude\.credentials.json'
        $hermesOauth = Join-Path $HermesHome '.anthropic_oauth.json'
        $hasClaudeCreds = Test-Path $claudeCreds
        $hasHermesOauth = Test-Path $hermesOauth
        return [pscustomobject]@{
            logged_in = [bool]($hasClaudeCreds -or $hasHermesOauth)
            source = if ($hasClaudeCreds) { 'claude_code_credentials' } elseif ($hasHermesOauth) { 'hermes_oauth_file' } else { '' }
            auth_file = if ($hasClaudeCreds) { $claudeCreds } elseif ($hasHermesOauth) { $hermesOauth } else { '' }
        }
    }

    try {
        return Invoke-HermesPythonJson -InstallDir $InstallDir -HermesHome $HermesHome -Payload @{ ProviderId = $ProviderId } -PythonBody @"
from hermes_cli.auth import get_auth_status
status = get_auth_status(payload.get('ProviderId'))
print(json.dumps(status, ensure_ascii=False))
"@
    } catch {
        return [pscustomobject]@{
            logged_in = $false
            error = $_.Exception.Message
        }
    }
}

function Set-ClipboardTextSafe {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    [System.Windows.Forms.Clipboard]::SetText($Text)
}

function ConvertTo-PlainMap {
    param($InputObject)

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $map = @{}
        foreach ($key in $InputObject.Keys) {
            $map[[string]$key] = ConvertTo-PlainMap -InputObject $InputObject[$key]
        }
        return $map
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ,(ConvertTo-PlainMap -InputObject $item)
        }
        return $items
    }
    if ($InputObject -is [psobject]) {
        $properties = @($InputObject.PSObject.Properties | Where-Object {
            $_.MemberType -in @('NoteProperty','Property','AliasProperty','ScriptProperty')
        })
        if ($properties.Count -eq 0) {
            return $InputObject
        }
        $map = @{}
        foreach ($prop in $properties) {
            $map[$prop.Name] = ConvertTo-PlainMap -InputObject $prop.Value
        }
        if ($map.Count -gt 0) {
            return $map
        }
    }
    return $InputObject
}

function Get-ObjectPropertyValue {
    param(
        $InputObject,
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace($Name)) {
        return $Default
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    return $property.Value
}

function Open-BrowserUrlSafe {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return }
    Start-Process $Url | Out-Null
}

function Find-VisualDescendantByType {
    param(
        [Parameter(Mandatory = $true)]$Root,
        [Parameter(Mandatory = $true)][Type]$TargetType
    )

    if ($null -eq $Root -or $null -eq $TargetType) { return $null }

    $childCount = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Root)
    for ($index = 0; $index -lt $childCount; $index++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($Root, $index)
        if ($TargetType.IsInstanceOfType($child)) {
            return $child
        }
        $found = Find-VisualDescendantByType -Root $child -TargetType $TargetType
        if ($found) {
            return $found
        }
    }

    return $null
}

function Attach-MouseWheelScrolling {
    param(
        [Parameter(Mandatory = $true)]$Control,
        [Parameter(Mandatory = $true)]$ScrollViewer
    )

    if ($null -eq $Control -or $null -eq $ScrollViewer) { return }

    $Control.Add_PreviewMouseWheel({
        param($sender, $eventArgs)
        if ($null -eq $ScrollViewer) { return }

        $nextOffset = $ScrollViewer.VerticalOffset - ($eventArgs.Delta / 3.0)
        if ($nextOffset -lt 0) { $nextOffset = 0 }
        if ($nextOffset -gt $ScrollViewer.ScrollableHeight) { $nextOffset = $ScrollViewer.ScrollableHeight }

        $ScrollViewer.ScrollToVerticalOffset($nextOffset)
        $eventArgs.Handled = $true
    }.GetNewClosure())
}

function Update-EditableComboBoxAppearance {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Controls.ComboBox]$ComboBox
    )

    if ($null -eq $ComboBox) { return }

    try { $ComboBox.ApplyTemplate() } catch { }

    $editableTextBox = $ComboBox.Template.FindName('PART_EditableTextBox', $ComboBox)
    if (-not $editableTextBox) {
        $editableTextBox = Find-VisualDescendantByType -Root $ComboBox -TargetType ([System.Windows.Controls.TextBox])
    }
    if (-not $editableTextBox) { return }

    $editableTextBox.Foreground = ([System.Windows.Media.BrushConverter]::new()).ConvertFromString('#111111')
    $editableTextBox.Background = ([System.Windows.Media.BrushConverter]::new()).ConvertFromString('#FFFFFF')
    $editableTextBox.CaretBrush = [System.Windows.Media.Brushes]::Black
    $editableTextBox.SelectionBrush = ([System.Windows.Media.BrushConverter]::new()).ConvertFromString('#E5E7EB')
    $editableTextBox.SelectionOpacity = 1.0
    $editableTextBox.BorderThickness = [System.Windows.Thickness]::new(0)
    try {
        $editableTextBox.Resources[[System.Windows.SystemColors]::HighlightBrushKey] = ([System.Windows.Media.BrushConverter]::new()).ConvertFromString('#E5E7EB')
        $editableTextBox.Resources[[System.Windows.SystemColors]::HighlightTextBrushKey] = [System.Windows.Media.Brushes]::Black
        $editableTextBox.Resources[[System.Windows.SystemColors]::InactiveSelectionHighlightBrushKey] = ([System.Windows.Media.BrushConverter]::new()).ConvertFromString('#E5E7EB')
        $editableTextBox.Resources[[System.Windows.SystemColors]::InactiveSelectionHighlightTextBrushKey] = [System.Windows.Media.Brushes]::Black
    } catch { }
}

function Clear-EditableComboBoxSelection {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Controls.ComboBox]$ComboBox
    )

    if ($null -eq $ComboBox) { return }

    $editableTextBox = $ComboBox.Template.FindName('PART_EditableTextBox', $ComboBox)
    if (-not $editableTextBox) {
        $editableTextBox = Find-VisualDescendantByType -Root $ComboBox -TargetType ([System.Windows.Controls.TextBox])
    }
    if (-not $editableTextBox) { return }

    $editableTextBox.Dispatcher.BeginInvoke([action]{
        try {
            $editableTextBox.SelectionLength = 0
            $editableTextBox.SelectionStart = $editableTextBox.Text.Length
            $editableTextBox.CaretIndex = $editableTextBox.Text.Length
        } catch { }
    }, [System.Windows.Threading.DispatcherPriority]::Input) | Out-Null
}

function New-CodexLoginSession {
    param([string]$InstallDir, [string]$HermesHome)
    Invoke-HermesPythonJson -InstallDir $InstallDir -HermesHome $HermesHome -Payload @{} -PythonBody @"
import json, httpx
issuer = 'https://auth.openai.com'
client_id = 'app_EMoamEEZ73f0CkXaXp7hrann'
with httpx.Client(timeout=httpx.Timeout(15.0)) as client:
    resp = client.post(
        f'{issuer}/api/accounts/deviceauth/usercode',
        json={'client_id': client_id},
        headers={'Content-Type': 'application/json'},
    )
    resp.raise_for_status()
    data = resp.json()
print(json.dumps({
    'provider': 'openai-codex',
    'verification_url': f'{issuer}/codex/device',
    'user_code': data.get('user_code', ''),
    'device_auth_id': data.get('device_auth_id', ''),
    'interval': int(data.get('interval', 5) or 5),
}, ensure_ascii=False))
"@
}

function Complete-CodexLoginSession {
    param(
        [string]$InstallDir,
        [string]$HermesHome,
        $Session,
        [string]$ModelName
    )

    Invoke-HermesPythonJson -InstallDir $InstallDir -HermesHome $HermesHome -Payload @{
        Session = (ConvertTo-PlainMap -InputObject $Session)
        ModelName = $ModelName
    } -PythonBody @"
import json, httpx
from datetime import datetime, timezone
from hermes_cli.auth import _save_codex_tokens

session = payload.get('Session') or {}
issuer = 'https://auth.openai.com'
with httpx.Client(timeout=httpx.Timeout(15.0)) as client:
    poll_resp = client.post(
        f'{issuer}/api/accounts/deviceauth/token',
        json={
            'device_auth_id': session.get('device_auth_id', ''),
            'user_code': session.get('user_code', ''),
        },
        headers={'Content-Type': 'application/json'},
    )
    if poll_resp.status_code in (403, 404):
        print(json.dumps({'status': 'pending', 'message': '还未完成 OpenAI 登录授权。'}, ensure_ascii=False))
        raise SystemExit(0)
    poll_resp.raise_for_status()
    code_resp = poll_resp.json()
    authorization_code = code_resp.get('authorization_code', '')
    code_verifier = code_resp.get('code_verifier', '')
    token_resp = client.post(
        'https://auth.openai.com/oauth/token',
        data={
            'grant_type': 'authorization_code',
            'code': authorization_code,
            'redirect_uri': f'{issuer}/deviceauth/callback',
            'client_id': 'app_EMoamEEZ73f0CkXaXp7hrann',
            'code_verifier': code_verifier,
        },
        headers={'Content-Type': 'application/x-www-form-urlencoded'},
    )
    token_resp.raise_for_status()
    tokens = token_resp.json()
_save_codex_tokens(
    {
        'access_token': tokens.get('access_token', ''),
        'refresh_token': tokens.get('refresh_token', ''),
    },
    datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
)
print(json.dumps({
    'status': 'success',
    'provider': 'openai-codex',
    'message': 'OpenAI Codex 登录成功。',
}, ensure_ascii=False))
"@
}

function New-CopilotLoginSession {
    param([string]$InstallDir, [string]$HermesHome)
    Invoke-HermesPythonJson -InstallDir $InstallDir -HermesHome $HermesHome -Payload @{} -PythonBody @"
import json, urllib.parse, urllib.request
data = urllib.parse.urlencode({
    'client_id': 'Ov23li8tweQw6odWQebz',
    'scope': 'read:user',
}).encode()
req = urllib.request.Request(
    'https://github.com/login/device/code',
    data=data,
    headers={
        'Accept': 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': 'HermesAgent/1.0',
    },
)
with urllib.request.urlopen(req, timeout=15) as resp:
    device_data = json.loads(resp.read().decode())
print(json.dumps({
    'provider': 'copilot',
    'verification_url': device_data.get('verification_uri', 'https://github.com/login/device'),
    'user_code': device_data.get('user_code', ''),
    'device_code': device_data.get('device_code', ''),
    'interval': int(device_data.get('interval', 5) or 5),
}, ensure_ascii=False))
"@
}

function Complete-CopilotLoginSession {
    param([string]$InstallDir, [string]$HermesHome, $Session)
    Invoke-HermesPythonJson -InstallDir $InstallDir -HermesHome $HermesHome -Payload @{ Session = (ConvertTo-PlainMap -InputObject $Session) } -PythonBody @"
import json, urllib.parse, urllib.request
session = payload.get('Session') or {}
poll_data = urllib.parse.urlencode({
    'client_id': 'Ov23li8tweQw6odWQebz',
    'device_code': session.get('device_code', ''),
    'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
}).encode()
poll_req = urllib.request.Request(
    'https://github.com/login/oauth/access_token',
    data=poll_data,
    headers={
        'Accept': 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': 'HermesAgent/1.0',
    },
)
with urllib.request.urlopen(poll_req, timeout=15) as resp:
    result = json.loads(resp.read().decode())
if result.get('access_token'):
    print(json.dumps({'status': 'success', 'token': result.get('access_token', '')}, ensure_ascii=False))
else:
    error = result.get('error', '')
    if error == 'authorization_pending':
        print(json.dumps({'status': 'pending', 'message': '还未完成 GitHub 授权。'}, ensure_ascii=False))
    elif error == 'slow_down':
        print(json.dumps({'status': 'pending', 'message': 'GitHub 要求稍后再试。'}, ensure_ascii=False))
    else:
        print(json.dumps({'status': 'error', 'message': error or 'GitHub 登录失败。'}, ensure_ascii=False))
"@
}

function New-NousLoginSession {
    param([string]$InstallDir, [string]$HermesHome)
    Invoke-HermesPythonJson -InstallDir $InstallDir -HermesHome $HermesHome -Payload @{} -PythonBody @"
import json, httpx
portal_base_url = 'https://portal.nousresearch.com'
client_id = 'hermes-cli'
scope = 'inference:mint_agent_key'
with httpx.Client(timeout=httpx.Timeout(15.0)) as client:
    resp = client.post(
        f'{portal_base_url}/api/oauth/device/code',
        data={'client_id': client_id, 'scope': scope},
    )
    resp.raise_for_status()
    data = resp.json()
print(json.dumps({
    'provider': 'nous',
    'portal_base_url': portal_base_url,
    'inference_base_url': 'https://inference-api.nousresearch.com/v1',
    'client_id': client_id,
    'scope': scope,
    'device_code': data.get('device_code', ''),
    'user_code': data.get('user_code', ''),
    'verification_url': data.get('verification_uri_complete') or data.get('verification_uri', ''),
    'expires_in': int(data.get('expires_in', 900) or 900),
    'interval': int(data.get('interval', 5) or 5),
}, ensure_ascii=False))
"@
}

function Complete-NousLoginSession {
    param(
        [string]$InstallDir,
        [string]$HermesHome,
        $Session,
        [string]$ModelName
    )

    Invoke-HermesPythonJson -InstallDir $InstallDir -HermesHome $HermesHome -Payload @{
        Session = (ConvertTo-PlainMap -InputObject $Session)
        ModelName = $ModelName
    } -PythonBody @"
import json, httpx
from datetime import datetime, timezone
from hermes_cli.auth import (
    refresh_nous_oauth_from_state,
    _auth_store_lock,
    _load_auth_store,
    _save_provider_state,
    _save_auth_store,
)

session = payload.get('Session') or {}
portal_base_url = session.get('portal_base_url', 'https://portal.nousresearch.com').rstrip('/')
with httpx.Client(timeout=httpx.Timeout(15.0)) as client:
    response = client.post(
        f'{portal_base_url}/api/oauth/token',
        data={
            'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
            'client_id': session.get('client_id', 'hermes-cli'),
            'device_code': session.get('device_code', ''),
        },
    )
if response.status_code == 200:
    token_data = response.json()
elif response.status_code in (400, 401):
    try:
        payload_err = response.json()
    except Exception:
        payload_err = {}
    err = payload_err.get('error', '')
    if err in ('authorization_pending', 'slow_down'):
        print(json.dumps({'status': 'pending', 'message': '还未完成 Nous Portal 授权。'}, ensure_ascii=False))
        raise SystemExit(0)
    print(json.dumps({'status': 'error', 'message': payload_err.get('error_description') or err or 'Nous 登录失败。'}, ensure_ascii=False))
    raise SystemExit(0)
else:
    response.raise_for_status()

state = {
    'portal_base_url': portal_base_url,
    'inference_base_url': session.get('inference_base_url', 'https://inference-api.nousresearch.com/v1'),
    'client_id': session.get('client_id', 'hermes-cli'),
    'scope': session.get('scope', 'inference:mint_agent_key'),
    'access_token': token_data.get('access_token', ''),
    'refresh_token': token_data.get('refresh_token', ''),
    'token_type': token_data.get('token_type', 'Bearer'),
    'obtained_at': datetime.now(timezone.utc).isoformat(),
}
state = refresh_nous_oauth_from_state(state, force_mint=True)
with _auth_store_lock():
    auth_store = _load_auth_store()
    _save_provider_state(auth_store, 'nous', state)
    _save_auth_store(auth_store)
print(json.dumps({
    'status': 'success',
    'provider': 'nous',
    'message': 'Nous Portal 登录成功。',
}, ensure_ascii=False))
"@
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
        [string]$HermesHome,
        [bool]$DisablePythonUtf8Mode = $false
    )

    $bootstrapLines = @(
        '[Console]::InputEncoding = [System.Text.Encoding]::UTF8'
        '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8'
        '$OutputEncoding = [System.Text.Encoding]::UTF8'
        'chcp 65001 > $null'
    )
    if ($DisablePythonUtf8Mode) {
        $bootstrapLines += @(
            'Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue'
            '$env:PYTHONUTF8 = ''0'''
        )
    } else {
        $bootstrapLines += @(
            '$env:PYTHONIOENCODING = ''utf-8'''
            '$env:PYTHONUTF8 = ''1'''
        )
    }
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
        Start-Process explorer.exe -ArgumentList """$Path""" | Out-Null
        return
    }

    $parent = Split-Path -Parent $Path
    if ($parent -and (Test-Path $parent)) {
        Start-Process explorer.exe -ArgumentList """$parent""" | Out-Null
    }
}

function Confirm-TerminalAction {
    param(
        [string]$ActionTitle,
        [string[]]$UserSteps,
        [string]$SuccessHint = '执行完成后回到启动器继续下一步。',
        [string]$FailureHint = '如果看到报错，请先不要关闭终端，把报错内容反馈出来。'
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("即将打开终端：$ActionTitle")
    $lines.Add('')
    $lines.Add('你需要做的事：')
    foreach ($step in @($UserSteps | Where-Object { $_ })) {
        $lines.Add("• $step")
    }
    $lines.Add('')
    $lines.Add("完成后：$SuccessHint")
    $lines.Add("如遇报错：$FailureHint")
    $lines.Add('')
    $lines.Add('是否继续？')

    $message = [string]::Join([Environment]::NewLine, $lines)
    $choice = [System.Windows.MessageBox]::Show(
        $message,
        'Hermes 启动器',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Information
    )
    return ($choice -eq [System.Windows.MessageBoxResult]::Yes)
}

# ============================================================================
# 多源安装支持（Mirror Fallback）
# 检测网络环境 + 镜像源配置 + 自动 fallback 下载
# ============================================================================

function Test-NetworkEnvironment {
    # 测试 raw.githubusercontent.com 是否可达（5 秒超时）
    # 返回 "overseas"（可达，用官方源）或 "china"（不可达，用镜像源）
    $testUrl = 'https://raw.githubusercontent.com'
    try {
        $req = [System.Net.HttpWebRequest]::Create($testUrl)
        $req.Method = 'HEAD'
        $req.Timeout = 5000
        $req.AllowAutoRedirect = $true
        $resp = $req.GetResponse()
        $resp.Close()
        return 'overseas'
    } catch [System.Net.WebException] {
        # 用 WebExceptionStatus 判断，不用消息文本（避免中文 Windows 错误消息匹配问题）
        $webEx = $_ -as [System.Management.Automation.ErrorRecord]
        $status = $null
        if ($webEx -and $webEx.Exception -is [System.Net.WebException]) {
            $status = ([System.Net.WebException]$webEx.Exception).Status
        }
        # 如果是超时或连接失败，说明在国内网络
        if ($status -eq [System.Net.WebExceptionStatus]::Timeout -or
            $status -eq [System.Net.WebExceptionStatus]::ConnectFailure -or
            $status -eq [System.Net.WebExceptionStatus]::NameResolutionFailure -or
            $status -eq [System.Net.WebExceptionStatus]::SendFailure -or
            $status -eq [System.Net.WebExceptionStatus]::ReceiveFailure -or
            $status -eq [System.Net.WebExceptionStatus]::ConnectionClosed) {
            return 'china'
        }
        # 其他 WebException（如 403）说明能连上，算 overseas
        return 'overseas'
    } catch {
        # 任何其他异常默认当作国内（保守策略，优先保证安装成功）
        return 'china'
    }
}

function Get-MirrorConfig {
    # 返回各下载源的镜像配置（写死优先级：阿里>清华>中科大/豆瓣，ghproxy>其他）
    [pscustomobject]@{
        # GitHub raw 文件镜像：用于下载 install.ps1
        # 格式：直接替换 raw.githubusercontent.com
        GitHubRaw = @(
            'https://raw.githubusercontent.com',           # 官方（overseas 首选）
            'https://raw.gitmirror.com',                   # gitmirror
            'https://gh.api.99988866.xyz/https://raw.githubusercontent.com',  # 99988866 代理
            'https://ghproxy.cn/https://raw.githubusercontent.com'            # ghproxy.cn
        )
        # GitHub 仓库镜像：用于 git clone（注入到安装脚本 env）
        GitHubRepo = @(
            'https://github.com',                          # 官方（overseas 首选）
            'https://kgithub.com',                         # kgithub
            'https://hub.gitmirror.com'                    # gitmirror
        )
        # PyPI 镜像：注入 PIP_INDEX_URL 环境变量
        PyPI = @(
            'https://pypi.org/simple/',                    # 官方（overseas 首选）
            'https://mirrors.aliyun.com/pypi/simple/',     # 阿里（国内首选）
            'https://pypi.tuna.tsinghua.edu.cn/simple/',   # 清华
            'https://pypi.mirrors.ustc.edu.cn/simple/'     # 中科大
        )
        # npm 镜像：注入 NPM_CONFIG_REGISTRY 环境变量
        Npm = @(
            'https://registry.npmjs.org',                  # 官方（overseas 首选）
            'https://registry.npmmirror.com',              # 淘宝镜像（国内首选）
            'https://r.cnpmjs.org'                         # cnpm
        )
    }
}

function Invoke-WithMirrorFallback {
    # 执行下载操作，主源失败时自动 fallback 到下一个镜像，每源最多重试 2 次
    param(
        [string[]]$Urls,          # 按优先级排列的 URL 列表（第一个是首选）
        [scriptblock]$DownloadAction,  # 接受 $url 参数的下载动作
        [string]$ActionDescription = '下载',
        [scriptblock]$OnFallback = $null  # 可选：切换到下一源时的回调，接受 ($fromUrl, $toUrl, $attemptIndex) 参数
    )

    $lastException = $null
    $urlIndex = 0
    foreach ($url in $Urls) {
        $retryCount = 0
        while ($retryCount -lt 2) {
            try {
                $result = & $DownloadAction $url
                return $result
            } catch {
                $lastException = $_
                $retryCount++
                if ($retryCount -lt 2) {
                    # 同一个源的第一次失败，短暂等待后重试
                    Start-Sleep -Seconds 2
                }
            }
        }
        # 该源 2 次都失败，尝试下一个镜像
        $urlIndex++
        if ($OnFallback -ne $null -and $urlIndex -lt $Urls.Count) {
            try { & $OnFallback $url $Urls[$urlIndex] $urlIndex } catch { }
        }
    }

    # 所有镜像源都失败
    throw "已尝试所有镜像源，请检查网络连接。上次错误：$($lastException.Exception.Message)"
}

function Build-InstallArguments {
    param(
        [string]$InstallDir,
        [string]$HermesHome,
        [string]$Branch,
        [bool]$NoVenv,
        [bool]$SkipSetup
    )

    $scriptArgs = @('-InstallDir', $InstallDir, '-HermesHome', $HermesHome, '-Branch', $Branch)
    if ($NoVenv) { $scriptArgs += '-NoVenv' }
    if ($SkipSetup) { $scriptArgs += '-SkipSetup' }
    return $scriptArgs
}

function New-TempScriptFromUrl {
    param(
        [string]$Url,
        [string]$NetworkEnv = 'overseas',   # 'overseas' 或 'china'，由 Test-NetworkEnvironment 传入
        [scriptblock]$OnFallback = $null    # 可选：切换源时的日志回调，透传给 Invoke-WithMirrorFallback
    )

    $tempPath = Join-Path $env:TEMP ('hermes-install-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $mirrorCfg = Get-MirrorConfig

    # 根据网络环境，构造下载 URL 候选列表（官方源 或 镜像替换）
    if ($NetworkEnv -eq 'china') {
        # 将原 URL 中的 raw.githubusercontent.com 替换为各镜像域名
        $candidateUrls = @()
        foreach ($base in $mirrorCfg.GitHubRaw) {
            if ($base -eq 'https://raw.githubusercontent.com') {
                $candidateUrls += $Url
            } else {
                # 对于代理型镜像（URL 以 /https:// 结尾），直接拼接原始 URL
                if ($base -match '/https?://$') {
                    $candidateUrls += $base + $Url
                } else {
                    # 域名替换型：把 raw.githubusercontent.com 换掉
                    $candidateUrls += $Url -replace 'https://raw\.githubusercontent\.com', $base
                }
            }
        }
        # 国内网络：从第二个开始（跳过官方），官方放最后兜底
        $orderedUrls = @($candidateUrls[1..($candidateUrls.Count - 1)]) + @($candidateUrls[0])
    } else {
        # 海外网络：直接用官方 URL
        $orderedUrls = @($Url)
    }

    # 使用 Invoke-WithMirrorFallback 下载
    $content = Invoke-WithMirrorFallback -Urls $orderedUrls -ActionDescription '下载安装脚本' -OnFallback $OnFallback -DownloadAction {
        param($downloadUrl)
        $resp = Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -TimeoutSec 30
        if (-not $resp.Content) {
            throw "未能从 $downloadUrl 下载到安装脚本内容。"
        }
        return $resp.Content
    }

    if (-not $content) {
        throw "已尝试所有镜像源，请检查网络连接。"
    }

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

    # === 国内网络：在安装脚本开头注入 PyPI 和 npm 镜像环境变量 ===
    # 通过在脚本顶部插入 $env: 赋值，让 pip / uv / npm 自动使用国内镜像
    # 不修改上游逻辑，只是预先设置环境变量（上游 pip/uv 会读取这些变量）
    if ($NetworkEnv -eq 'china') {
        $pypiMirror = $mirrorCfg.PyPI[1]   # 阿里源（国内首选）
        $npmMirror  = $mirrorCfg.Npm[1]    # 淘宝 npmmirror（国内首选）
        $mirrorHeader = @"
# === 由 Hermes 启动器注入：国内镜像源配置 ===
`$env:PIP_INDEX_URL = '$pypiMirror'
`$env:UV_INDEX_URL = '$pypiMirror'
`$env:UV_EXTRA_INDEX_URL = ''
`$env:NPM_CONFIG_REGISTRY = '$npmMirror'
`$env:UV_DEFAULT_INDEX = '$pypiMirror'
Write-Host '[Hermes 启动器] 已切换到国内镜像源，加速安装...' -ForegroundColor Cyan
# === 镜像源配置结束 ===

"@
        $content = $mirrorHeader + $content
    }

    [System.IO.File]::WriteAllText($tempPath, $content, (New-Object System.Text.UTF8Encoding $true))
    return $tempPath
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

    [System.IO.File]::WriteAllText($tempPath, $scriptText, (New-Object System.Text.UTF8Encoding $true))
    return $tempPath
}

if ($SelfTest) {
    $defaults = Get-HermesDefaults
    $status = Test-HermesInstalled -InstallDir $defaults.InstallDir -HermesHome $defaults.HermesHome
    $resolvedHermes = Resolve-HermesCommand -InstallDir $defaults.InstallDir
    $resolvedUv = Resolve-UvCommand
    $webUiStatus = Get-HermesWebUiStatus
    [pscustomobject]@{
        SelfTest       = $true
        LauncherVersion = $script:LauncherVersion
        DefaultsLoaded = [bool]$defaults
        HermesHome     = $defaults.HermesHome
        InstallRoot    = $defaults.InstallRoot
        InstallDir     = $defaults.InstallDir
        ConfigPath     = $defaults.ConfigPath
        EnvPath        = $defaults.EnvPath
        LogsPath       = $defaults.LogsPath
        HermesCommand  = $resolvedHermes
        UvCommand      = $resolvedUv
        StatusChecked  = [bool]$status
        Status         = $status
        WebUi          = [pscustomobject]@{
            Version   = $script:HermesWebUiVersion
            Installed = [bool]$webUiStatus.Installed
            Healthy   = [bool]$webUiStatus.Healthy
            Url       = $webUiStatus.Url
        }
    } | ConvertTo-Json -Depth 4 -Compress | Write-Output
    exit 0
}

$defaults = Get-HermesDefaults

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Hermes Agent"
        Height="780"
        Width="1040"
        MinHeight="720"
        MinWidth="960"
        WindowStartupLocation="CenterScreen"
        Background="#0B1220"
        Foreground="#E2E8F0">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Padding="20,16" CornerRadius="20" Background="#111C33" BorderBrush="#24324F" BorderThickness="1">
            <TextBlock FontSize="28" FontWeight="Bold" Text="Hermes Agent"/>
        </Border>

        <Grid Grid.Row="1" Margin="0,18,0,0">
            <Grid.RowDefinitions>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <Grid>
                    <Border x:Name="InstallModePanel" Visibility="Visible" Padding="24" CornerRadius="20" Background="#101A2C" BorderBrush="#22314D" BorderThickness="1">
                        <StackPanel>
                            <Border x:Name="InstallPathCardBorder" Padding="18" CornerRadius="18" Background="#111827" BorderBrush="#22314D" BorderThickness="1">
                                <StackPanel>
                                    <TextBlock FontSize="18" FontWeight="SemiBold" Text="安装位置确认"/>
                                    <TextBlock x:Name="InstallPathSummaryText" Margin="0,10,0,0" Foreground="#CBD5E1" TextWrapping="Wrap"/>
                                    <TextBlock x:Name="InstallLocationNoticeText" Margin="0,10,0,0" Foreground="#94A3B8" TextWrapping="Wrap" Text="安装完成后，可在“更多设置”中查看或调整。"/>
                                    <WrapPanel Margin="0,16,0,0">
                                        <Button x:Name="ChangeInstallLocationButton" Margin="0,0,10,10" Padding="14,10" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="更改安装位置"/>
                                        <Button x:Name="ConfirmInstallLocationButton" Margin="0,0,10,10" Padding="14,10" Background="#1E293B" Foreground="#F8FAFC" BorderBrush="#475569" Content="确认安装位置"/>
                                    </WrapPanel>
                                </StackPanel>
                            </Border>

                            <Border x:Name="InstallSettingsEditorBorder" Margin="0,16,0,0" Padding="18" CornerRadius="18" Background="#111827" BorderBrush="#22314D" BorderThickness="1" Visibility="Collapsed">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="96"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>

                                    <TextBlock Grid.Row="0" VerticalAlignment="Center" Foreground="#CBD5E1" Text="数据目录"/>
                                    <TextBox x:Name="HermesHomeTextBox" Grid.Row="0" Grid.Column="1" Margin="10,0,0,10" Padding="8" Background="#0F172A" Foreground="White" BorderBrush="#334155"/>

                                    <TextBlock Grid.Row="1" VerticalAlignment="Center" Foreground="#CBD5E1" Text="安装目录"/>
                                    <TextBox x:Name="InstallDirTextBox" Grid.Row="1" Grid.Column="1" Margin="10,0,0,10" Padding="8" Background="#0F172A" Foreground="White" BorderBrush="#334155"/>

                                    <TextBlock Grid.Row="2" VerticalAlignment="Center" Foreground="#CBD5E1" Text="Git 分支"/>
                                    <TextBox x:Name="BranchTextBox" Grid.Row="2" Grid.Column="1" Margin="10,0,0,10" Padding="8" Background="#0F172A" Foreground="White" BorderBrush="#334155" Text="main"/>

                                    <StackPanel Grid.Row="3" Grid.Column="1" Margin="10,0,0,0">
                                        <StackPanel Orientation="Horizontal">
                                            <CheckBox x:Name="NoVenvCheckBox" Margin="0,0,14,0" VerticalAlignment="Center" Foreground="#CBD5E1" Content="NoVenv"/>
                                            <CheckBox x:Name="SkipSetupCheckBox" VerticalAlignment="Center" Foreground="#CBD5E1" IsChecked="True" Content="安装后不进入官方 setup"/>
                                        </StackPanel>
                                        <WrapPanel Margin="0,14,0,0">
                                            <Button x:Name="SaveInstallSettingsButton" Margin="0,0,10,10" Padding="14,10" Background="#1E293B" Foreground="#F8FAFC" BorderBrush="#475569" Content="保存更改"/>
                                            <Button x:Name="ResetInstallSettingsButton" Margin="0,0,10,10" Padding="14,10" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="恢复默认"/>
                                        </WrapPanel>
                                    </StackPanel>
                                </Grid>
                            </Border>

                            <Border x:Name="InstallTaskCardBorder" Margin="0,16,0,0" Padding="18" CornerRadius="18" Background="#111827" BorderBrush="#22314D" BorderThickness="1">
                                <StackPanel>
                                    <TextBlock x:Name="InstallTaskTitleText" FontSize="24" FontWeight="SemiBold" Text="安装 Hermes"/>
                                    <TextBlock x:Name="InstallTaskBodyText" Margin="0,10,0,0" Foreground="#CBD5E1" TextWrapping="Wrap" Text="启动器会先自动检查环境，再执行安装；失败时会直接告诉你卡在哪一步。"/>
                                    <WrapPanel Margin="0,18,0,0">
                                        <Button x:Name="StartInstallPageButton" Margin="0,0,10,10" Padding="18,10" FontWeight="SemiBold" Background="#22C55E" Foreground="#04110A" BorderBrush="#22C55E" Content="开始安装"/>
                                        <Button x:Name="InstallRequirementsButton" Margin="0,0,10,10" Padding="14,10" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="查看安装要求"/>
                                        <Button x:Name="InstallRefreshButton" Margin="0,0,10,10" Padding="14,10" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="刷新状态"/>
                                    </WrapPanel>
                                </StackPanel>
                            </Border>

                            <Border x:Name="InstallProgressCardBorder" Margin="0,16,0,0" Padding="18" CornerRadius="18" Background="#111827" BorderBrush="#22314D" BorderThickness="1">
                                <StackPanel>
                                    <TextBlock x:Name="InstallProgressTitleText" FontSize="18" FontWeight="SemiBold" Text="安装进度"/>
                                    <TextBlock x:Name="InstallProgressText" Margin="0,12,0,0" Foreground="#CBD5E1" TextWrapping="Wrap"/>
                                    <TextBlock x:Name="InstallFailureSummaryText" Margin="0,16,0,0" Foreground="#FCA5A5" TextWrapping="Wrap" Visibility="Collapsed"/>
                                </StackPanel>
                            </Border>

                            <Border x:Name="OpenClawPostInstallBorder" Margin="0,16,0,0" Padding="18" CornerRadius="18" Background="#111827" BorderBrush="#22314D" BorderThickness="1" Visibility="Collapsed">
                                <StackPanel>
                                    <TextBlock FontSize="24" FontWeight="SemiBold" Text="检测到旧版 OpenClaw 配置"/>
                                    <TextBlock x:Name="OpenClawPostInstallText" Margin="0,10,0,0" Foreground="#CBD5E1" TextWrapping="Wrap"
                                               Text="Hermes 支持导入旧版 OpenClaw 配置。你可以现在迁移，也可以先跳过，之后再从“更多设置”里手动迁移。"/>
                                    <WrapPanel Margin="0,18,0,0">
                                        <Button x:Name="OpenClawImportButton" Margin="0,0,10,10" Padding="18,10" FontWeight="SemiBold" Background="#22C55E" Foreground="#04110A" BorderBrush="#22C55E" Content="立即迁移"/>
                                        <Button x:Name="OpenClawSkipButton" Margin="0,0,10,10" Padding="14,10" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="暂不迁移"/>
                                    </WrapPanel>
                                </StackPanel>
                            </Border>

                        </StackPanel>
                    </Border>

                    <Grid x:Name="HomeModePanel" Visibility="Collapsed">
                        <Border Padding="30" CornerRadius="20" Background="#101A2C" BorderBrush="#22314D" BorderThickness="1">
                            <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                                <TextBlock x:Name="StatusHeadlineText" FontSize="30" FontWeight="SemiBold" Text="已就绪" TextAlignment="Center" HorizontalAlignment="Center"/>
                                <TextBlock x:Name="StatusBodyText" Margin="0,12,0,0" Foreground="#AFC3E3" TextWrapping="Wrap" TextAlignment="Center" HorizontalAlignment="Center"/>
                                <WrapPanel Margin="0,24,0,0" HorizontalAlignment="Center">
                                    <Button x:Name="PrimaryActionButton" Margin="0,0,12,12" Padding="20,12" MinWidth="140" FontWeight="SemiBold" Background="#22C55E" Foreground="#04110A" BorderBrush="#22C55E" Content="开始使用"/>
                                    <Button x:Name="StageModelButton" Visibility="Collapsed" Width="0" Height="0" Padding="0" Margin="0" BorderThickness="0"/>
                                    <Button x:Name="StageAdvancedButton" Margin="0,0,0,12" Padding="16,12" Background="#0F172A" Foreground="#E2E8F0" BorderBrush="#334155" Content="更多设置"/>
                                </WrapPanel>
                                <TextBlock x:Name="RecommendationText" Margin="0,18,0,0" Foreground="#94A3B8" TextAlignment="Center" HorizontalAlignment="Center"/>
                                <TextBlock x:Name="RecommendationHintText" Visibility="Collapsed"/>
                                <Button x:Name="SecondaryActionButton" Visibility="Collapsed" Width="0" Height="0" Padding="0" Margin="0" BorderThickness="0"/>
                                <Button x:Name="RefreshButton" Visibility="Collapsed" Width="0" Height="0" Padding="0" Margin="0" BorderThickness="0"/>
                            </StackPanel>
                        </Border>
                    </Grid>
                </Grid>
            </ScrollViewer>

            <Border x:Name="LogSectionBorder" Grid.Row="1" Margin="0,14,0,0" Padding="14" CornerRadius="18" Background="#020617" BorderBrush="#22314D" BorderThickness="1" MaxHeight="190">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <DockPanel Grid.Row="0" LastChildFill="False">
                        <TextBlock DockPanel.Dock="Left" FontSize="15" FontWeight="SemiBold" Foreground="#F8FAFC" Text="安装日志"/>
                        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                            <Button x:Name="CopyFeedbackButton" Margin="0,0,10,0" Padding="10,6" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="复制反馈信息"/>
                            <Button x:Name="ClearLogButton" Padding="10,6" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="清空"/>
                        </StackPanel>
                    </DockPanel>
                    <TextBox x:Name="LogTextBox" Grid.Row="1" Margin="0,10,0,0" MinHeight="72" MaxHeight="120" Background="#020617" Foreground="#E2E8F0" BorderThickness="0"
                             FontFamily="Consolas" FontSize="13" AcceptsReturn="True" AcceptsTab="True"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                             IsReadOnly="True" TextWrapping="NoWrap"/>
                </Grid>
            </Border>
        </Grid>

        <Border x:Name="FooterBorder" Grid.Row="2" Margin="0,18,0,0" Padding="12,10" CornerRadius="12" Background="#101A2C" BorderBrush="#22314D" BorderThickness="1">
            <TextBlock x:Name="FooterText" Foreground="#94A3B8" Text="就绪"/>
        </Border>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$window.Title = "Hermes Agent 桌面控制台 - $($script:LauncherVersion)"

$controls = @{}
foreach ($name in @(
    'InstallModePanel','HomeModePanel','InstallPathCardBorder','InstallTaskCardBorder','InstallProgressCardBorder','InstallProgressTitleText','OpenClawPostInstallBorder','OpenClawPostInstallText','OpenClawImportButton','OpenClawSkipButton','InstallPathSummaryText','InstallLocationNoticeText','InstallSettingsEditorBorder',
    'ChangeInstallLocationButton','ConfirmInstallLocationButton','SaveInstallSettingsButton','ResetInstallSettingsButton',
    'InstallTaskTitleText','InstallTaskBodyText','StartInstallPageButton','InstallRequirementsButton','InstallRefreshButton',
    'InstallProgressText','InstallFailureSummaryText','StatusHeadlineText','StatusBodyText','RecommendationText','RecommendationHintText',
    'RefreshButton','PrimaryActionButton','SecondaryActionButton','StageModelButton','StageAdvancedButton',
    'HermesHomeTextBox','InstallDirTextBox','BranchTextBox','NoVenvCheckBox','SkipSetupCheckBox',
    'LogSectionBorder','CopyFeedbackButton','ClearLogButton','LogTextBox','FooterBorder','FooterText'
)) {
    $controls[$name] = $window.FindName($name)
}

$controls.HermesHomeTextBox.Text = $defaults.HermesHome
$controls.InstallDirTextBox.Text = $defaults.InstallDir
$controls.BranchTextBox.Text = 'main'
$controls.SkipSetupCheckBox.IsChecked = $true

$script:CrashLogPath = Join-Path $env:TEMP 'HermesGuiLauncher-crash.log'
$script:InstallLocationConfirmed = $false
$script:InstallPreflightConfirmed = $false
$script:LauncherWindowMode = $null

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
        $eventArgs.Handled = $true  # 防止未捕获异常导致进程崩溃（陷阱 #1）
    })
    [AppDomain]::CurrentDomain.add_UnhandledException({
        param($sender, $eventArgs)
        Write-CrashLog ("UnhandledException: " + $eventArgs.ExceptionObject.ToString())
    })
})

$script:PrimaryActionId = 'refresh'
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
$script:InstallPrimaryActionId = 'install-external'
$script:InstallSecondaryActionId = 'open-docs'
$script:InstallTertiaryActionId = 'refresh'
$script:PreflightCache = $null
$script:PreflightCacheTime = [datetime]::MinValue
$script:PreflightCacheTtlSeconds = 30
$script:PreflightCacheDir = ''
$script:PreflightCacheHome = ''
$script:RefreshDebounceTimer = $null
$script:RefreshDebounceDelayMs = 300

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
            OpenClawSkipped   = $false
        }
    }

    try {
        $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{
            LocalChatVerified = [bool]$data.local_chat_verified
            OpenClawPreviewed = [bool]$data.openclaw_previewed
            OpenClawImported  = [bool]$data.openclaw_imported
            OpenClawSkipped   = [bool]$data.openclaw_skipped
        }
    } catch {
        return [pscustomobject]@{
            LocalChatVerified = $false
            OpenClawPreviewed = $false
            OpenClawImported  = $false
            OpenClawSkipped   = $false
        }
    }
}

function Save-LauncherState {
    param(
        [string]$HermesHome,
        [Nullable[bool]]$LocalChatVerified = $null,
        [Nullable[bool]]$OpenClawPreviewed = $null,
        [Nullable[bool]]$OpenClawImported = $null,
        [Nullable[bool]]$OpenClawSkipped = $null
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
            openclaw_skipped    = if ($null -ne $OpenClawSkipped) { [bool]$OpenClawSkipped } else { [bool]$current.OpenClawSkipped }
            updated_at = (Get-Date).ToString('s')
        } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($path, $payload, [System.Text.Encoding]::UTF8)
    } catch { }
}

function Add-LogLine {
    param([string]$Text)

    $timestamp = Get-Date -Format 'HH:mm:ss'
    $controls.LogTextBox.AppendText(('[{0}] {1}' -f $timestamp, $Text) + [Environment]::NewLine)
    $maxLines = 500
    $lineCount = $controls.LogTextBox.LineCount
    if ($lineCount -gt $maxLines) {
        $trimTo = $lineCount - $maxLines
        $charIndex = $controls.LogTextBox.GetCharacterIndexFromLineIndex($trimTo)
        if ($charIndex -gt 0) {
            $controls.LogTextBox.Select(0, $charIndex)
            $controls.LogTextBox.SelectedText = ''
            $controls.LogTextBox.Select($controls.LogTextBox.Text.Length, 0)
        }
    }
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

function Flush-UIRender {
    <#
    .SYNOPSIS
    Force WPF to process all pending UI updates (layout, render, data binding).
    Call before any long-running synchronous operation so the user sees progress.
    Uses DispatcherFrame (standard WPF pattern) instead of DoEvents() to avoid
    reentrancy risk (陷阱 #1).
    #>
    try {
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{ $frame.Continue = $false }
        )
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    } catch { }
}

function Start-LaunchAsync {
    <#
    .SYNOPSIS
    Kick off the async launch state machine.
    Disables the primary button and starts a DispatcherTimer that drives
    install → start → open-browser through non-blocking phases.
    #>
    param([string]$InstallDir, [string]$HermesCommand)

    $controls.PrimaryActionButton.IsEnabled = $false

    # Check if webui already running — if so, just open browser (fast path, no blocking)
    $health = Test-HermesWebUiHealth
    if ($health.Healthy) {
        # Start .env watcher so webui config changes trigger gateway restart
        Start-GatewayEnvWatcher

        # Ensure config port is correct, gateway is alive, and deps installed.
        Repair-GatewayApiPort

        # Check if any gateway is running
        $gatewayAlive = $script:GatewayProcess -and -not $script:GatewayProcess.HasExited
        if (-not $gatewayAlive) {
            $gatewayAlive = [bool](Get-Process -Name 'hermes' -ErrorAction SilentlyContinue)
        }

        $depsInstalled = $false
        try {
            $depsInstalled = Install-GatewayPlatformDeps -HermesInstallDir $InstallDir
        } catch {
            Add-LogLine ("渠道依赖检测跳过：{0}" -f $_.Exception.Message)
        }

        if (-not $gatewayAlive) {
            Add-LogLine "Gateway 未在运行，正在启动..."
            Start-HermesGateway -HermesInstallDir $InstallDir
        } elseif ($depsInstalled) {
            Add-LogLine "检测到新安装的渠道依赖，正在重启 Gateway..."
            Restart-HermesGateway
        }

        Open-BrowserUrlSafe -Url $health.Url
        Add-ActionLog -Action '开始使用' -Result ("已打开 hermes-web-ui：{0}" -f $health.Url) -Next '在浏览器中完成模型配置和对话'
        $controls.PrimaryActionButton.IsEnabled = $true
        return
    }

    $script:LaunchState = @{
        Phase           = 'check-install'
        InstallDir      = $InstallDir
        HermesCommand   = $HermesCommand
        WebClient       = $null
        DownloadZipPath = $null
        DownloadDone    = $false
        DownloadError   = $null
        NpmProcess      = $null
        HealthDeadline  = $null
    }

    Add-ActionLog -Action '开始使用' -Result '正在检查环境...' -Next '请稍候'
    Set-Footer '正在检查环境...'

    if (-not $script:LaunchTimer) {
        $script:LaunchTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:LaunchTimer.Interval = [TimeSpan]::FromMilliseconds(800)
        $script:LaunchTimer.Add_Tick({ Step-LaunchSequence })
    }
    $script:LaunchTimer.Start()
}

function Stop-LaunchAsync {
    param([string]$ErrorMessage)
    if ($script:LaunchTimer) { $script:LaunchTimer.Stop() }
    $script:LaunchState = $null
    $controls.PrimaryActionButton.IsEnabled = $true
    Set-Footer ''
    if ($ErrorMessage) {
        Add-ActionLog -Action '开始使用' -Result ('失败：' + $ErrorMessage) -Next '可改用命令行对话'
        $message = @(
            'hermes-web-ui 启动失败。'
            ''
            $ErrorMessage
            ''
            '可以先改用命令行对话。'
            ''
            '是否现在打开命令行对话？'
        ) -join [Environment]::NewLine
        $choice = [System.Windows.MessageBox]::Show($message, 'hermes-web-ui', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($choice -eq [System.Windows.MessageBoxResult]::Yes) {
            Invoke-AppAction 'launch-cli'
        }
    }
}

function Step-LaunchSequence {
    <#
    .SYNOPSIS
    State machine tick — called every 800ms by LaunchTimer.
    Each phase does a small non-blocking check/action and returns immediately,
    keeping the WPF UI responsive throughout the install+start process.
    #>
    $s = $script:LaunchState
    if (-not $s) { $script:LaunchTimer.Stop(); return }

    try {
        switch ($s.Phase) {
            # ── Phase 1: Check if web-ui is already installed ──
            'check-install' {
                $installStatus = Test-HermesWebUiInstalled
                if ($installStatus.Installed) {
                    # Check if upgrade needed
                    $installedVer = Get-HermesWebUiInstalledVersion
                    if ($installedVer -and $installedVer -ne $script:HermesWebUiVersion) {
                        Add-LogLine ("hermes-web-ui 当前版本 {0}，目标版本 {1}，需要升级" -f $installedVer, $script:HermesWebUiVersion)
                        $s.Phase = 'npm-install'
                    } else {
                        $s.Phase = 'start-gateway'
                    }
                } else {
                    $webUi = Get-HermesWebUiDefaults
                    if (Test-Path $webUi.NodeExe) {
                        $s.Phase = 'npm-install'
                    } else {
                        $s.Phase = 'download-node'
                    }
                }
            }

            # ── Phase 2: Download Node.js (async via WebClient) ──
            'download-node' {
                if (-not $s.WebClient) {
                    # Start async download
                    $webUi = Get-HermesWebUiDefaults
                    if (-not (Test-Path $webUi.NodeRoot)) {
                        New-Item -ItemType Directory -Path $webUi.NodeRoot -Force | Out-Null
                    }
                    $zipPath = Join-Path $env:TEMP ('node-' + [guid]::NewGuid().ToString('N') + '.zip')
                    $s.DownloadZipPath = $zipPath
                    $s.DownloadDone = $false
                    $s.DownloadError = $null

                    $wc = [System.Net.WebClient]::new()
                    $wc.Add_DownloadFileCompleted({
                        param($sender, $e)
                        $script:LaunchState.DownloadDone = $true
                        if ($e.Error) { $script:LaunchState.DownloadError = $e.Error.Message }
                    })
                    $s.WebClient = $wc

                    Add-ActionLog -Action '开始使用' -Result '正在下载 Node.js（约 30MB）...' -Next '下载完成后自动继续'
                    Set-Footer '正在下载 Node.js...'
                    Add-LogLine '正在下载 Node.js...'
                    $wc.DownloadFileAsync([Uri]$script:NodeDownloadUrl, $zipPath)
                    return
                }

                # Poll download status
                if (-not $s.DownloadDone) { return }

                # Download finished
                $s.WebClient.Dispose()
                $s.WebClient = $null

                if ($s.DownloadError) {
                    throw ("Node.js 下载失败：{0}" -f $s.DownloadError)
                }
                if (-not (Test-Path $s.DownloadZipPath) -or (Get-Item $s.DownloadZipPath).Length -lt 1024) {
                    throw '下载文件为空或不完整。'
                }

                Add-LogLine '正在解压 Node.js...'
                Set-Footer '正在解压 Node.js...'
                $webUi = Get-HermesWebUiDefaults
                Expand-Archive -Path $s.DownloadZipPath -DestinationPath $webUi.NodeRoot -Force
                Remove-Item $s.DownloadZipPath -Force -ErrorAction SilentlyContinue

                if (-not (Test-Path $webUi.NodeExe)) {
                    throw "解压后未找到 node.exe：$($webUi.NodeExe)"
                }
                Add-LogLine 'Node.js 安装完成。'
                $s.Phase = 'npm-install'
            }

            # ── Phase 3: npm install hermes-web-ui (background process) ──
            'npm-install' {
                if (-not $s.NpmProcess) {
                    $webUi = Get-HermesWebUiDefaults
                    if (-not (Test-Path $webUi.NpmPrefix)) {
                        New-Item -ItemType Directory -Path $webUi.NpmPrefix -Force | Out-Null
                    }
                    $env:PATH = "$($webUi.NodeDir);$($webUi.NpmPrefix);$env:PATH"
                    $npmArgs = @('install', '-g', "$($script:HermesWebUiNpmPackage)@$($script:HermesWebUiVersion)", '--prefix', $webUi.NpmPrefix)

                    Add-ActionLog -Action '开始使用' -Result '正在安装 hermes-web-ui（约需 1-2 分钟）...' -Next '安装完成后自动启动'
                    Set-Footer '正在安装 hermes-web-ui...'
                    Add-LogLine ("正在安装 hermes-web-ui@{0}..." -f $script:HermesWebUiVersion)

                    $s.NpmProcess = Start-Process -FilePath $webUi.NpmCmd -ArgumentList $npmArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $env:TEMP 'hermes-npm-install.log') -RedirectStandardError (Join-Path $env:TEMP 'hermes-npm-install-err.log')
                    return
                }

                # Poll npm process
                if (-not $s.NpmProcess.HasExited) { return }

                if ($s.NpmProcess.ExitCode -ne 0) {
                    $errLog = ''
                    try { $errLog = Get-Content (Join-Path $env:TEMP 'hermes-npm-install-err.log') -Raw } catch { }
                    throw ("npm install 失败（退出码 {0}）。{1}" -f $s.NpmProcess.ExitCode, $errLog)
                }

                $check = Test-HermesWebUiInstalled
                if (-not $check.Installed) {
                    throw '安装完成但未找到 hermes-web-ui 命令，请检查日志。'
                }
                Add-LogLine 'hermes-web-ui 安装完成。'
                $s.Phase = 'start-gateway'
            }

            # ── Phase 4: Start gateway + platform deps ──
            'start-gateway' {
                Set-Footer '正在启动 Hermes Gateway...'
                Add-LogLine '正在启动 Gateway...'
                Start-HermesGateway -HermesInstallDir $s.InstallDir
                $s.Phase = 'start-webui'
            }

            # ── Phase 5: Start web-ui process ──
            'start-webui' {
                $webUi = Get-HermesWebUiDefaults
                if (-not (Test-Path $webUi.WebUiCmd)) {
                    throw "未找到 hermes-web-ui 命令：$($webUi.WebUiCmd)"
                }

                # Set up environment
                $pathParts = @($webUi.NodeDir, $webUi.NpmPrefix)
                $venvScripts = Join-Path $s.InstallDir 'venv\Scripts'
                if (Test-Path $venvScripts) {
                    $pathParts += $venvScripts
                    $env:HERMES_BIN = Join-Path $venvScripts 'hermes.exe'
                }
                $env:PATH = ($pathParts -join ';') + ";$env:PATH"
                $env:PORT = [string]$webUi.Port
                $env:NPM_CONFIG_PREFIX = $webUi.NpmPrefix
                $env:PYTHONIOENCODING = 'utf-8'

                Add-ActionLog -Action '开始使用' -Result '正在启动 hermes-web-ui...' -Next '等待服务就绪'
                Set-Footer '正在启动 hermes-web-ui...'
                Add-LogLine '正在启动 hermes-web-ui...'

                Start-Process -FilePath $webUi.WebUiCmd -ArgumentList @('start', $webUi.Port) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $env:TEMP 'hermes-webui-start.log') -RedirectStandardError (Join-Path $env:TEMP 'hermes-webui-start-err.log')

                $s.HealthDeadline = (Get-Date).AddSeconds(30)
                $s.Phase = 'wait-healthy'
            }

            # ── Phase 6: Poll health check ──
            'wait-healthy' {
                $health = Test-HermesWebUiHealth
                if ($health.Healthy) {
                    $script:LaunchTimer.Stop()

                    # Read token for URL
                    $webUi = Get-HermesWebUiDefaults
                    $tokenFile = Join-Path $webUi.WebUiHome '.token'
                    $token = $null
                    if (Test-Path $tokenFile) {
                        try { $token = (Get-Content $tokenFile -Raw).Trim() } catch { }
                    }
                    $url = if ($token) { "http://$($webUi.Host):$($webUi.Port)/#/?token=$token" } else { "http://$($webUi.Host):$($webUi.Port)" }

                    Open-BrowserUrlSafe -Url $url
                    Add-ActionLog -Action '开始使用' -Result ("已打开 hermes-web-ui：{0}" -f $url) -Next '在浏览器中完成模型配置和对话'
                    Set-Footer ''

                    $hermesHome = Join-Path $env:USERPROFILE '.hermes'
                    Save-LauncherState -HermesHome $hermesHome -LocalChatVerified $true
                    Start-GatewayEnvWatcher
                    Refresh-Status
                    $controls.PrimaryActionButton.IsEnabled = $true
                    $script:LaunchState = $null
                    return
                }

                if ((Get-Date) -gt $s.HealthDeadline) {
                    throw 'hermes-web-ui 启动后未能就绪（30 秒超时）。请检查日志。'
                }
                # Keep polling on next tick
            }
        }
    } catch {
        Stop-LaunchAsync -ErrorMessage $_.Exception.Message
    }
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

function Start-ExternalInstallMonitor {
    param([System.Diagnostics.Process]$Process)

    Stop-ExternalInstallTimer
    $script:ExternalInstallProcess = $Process

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(2)
    $timer.Add_Tick({
        try {
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
                $recentLog = @()
                if ($controls.LogTextBox.Text) {
                    $lines = $controls.LogTextBox.Text -split "`r?`n"
                    $recentLog = @($lines | Select-Object -Last 10)
                }
                $failSummary = @(
                    "安装失败（退出码 $exitCode）"
                    ''
                    '失败阶段：执行官方安装脚本'
                    "可能原因：网络超时、依赖安装失败或权限不足"
                    '建议操作：查看安装终端中的具体报错信息，修复后重试'
                    ''
                    '最近日志：'
                    ($recentLog -join "`n")
                    ''
                    '可点击下方"复制反馈信息"发送给开发者排查。'
                ) -join "`n"
                $controls.InstallFailureSummaryText.Text = $failSummary
                $controls.InstallFailureSummaryText.Visibility = 'Visible'
            }
            Refresh-Status
        } catch {
            Add-LogLine ("安装监视器异常：{0}" -f $_.Exception.Message)
            Stop-ExternalInstallTimer
        }
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
[System.IO.File]::WriteAllText($tempPath, $wrapper, (New-Object System.Text.UTF8Encoding $true))
return $tempPath
}

function New-ExternalTerminalCommandWrapper {
    param(
        [string]$WorkingDirectory,
        [string]$HermesHome,
        [string]$CommandLine,
        [string]$FailurePrompt,
        [bool]$DisablePythonUtf8Mode = $false
    )

    $tempPath = Join-Path $env:TEMP ('hermes-terminal-wrapper-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $pythonEnvBlock = if ($DisablePythonUtf8Mode) {
@"
Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
`$env:PYTHONUTF8 = '0'
"@
    } else {
@"
`$env:PYTHONIOENCODING = 'utf-8'
`$env:PYTHONUTF8 = '1'
"@
    }
    $wrapper = @"
`$ErrorActionPreference = 'Continue'
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
`$OutputEncoding = [System.Text.Encoding]::UTF8
$pythonEnvBlock
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
    [System.IO.File]::WriteAllText($tempPath, $wrapper, (New-Object System.Text.UTF8Encoding $true))
    return $tempPath
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
`$code = 0
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$InstallScriptPath' @installArgs
    `$code = `$LASTEXITCODE
} catch {
    Write-Host ''
    Write-Host (`$_.Exception.Message) -ForegroundColor Red
    `$code = 1
}
if (`$code -ne 0) {
    Write-Host ''
    Write-Host ('安装过程出错，退出码: ' + `$code) -ForegroundColor Red
    Write-Host '请截图或复制上方报错信息，反馈给开发者。' -ForegroundColor Yellow
    Write-Host '按 Enter 关闭此窗口。' -ForegroundColor Yellow
    [void](Read-Host)
} else {
    Write-Host ''
    Write-Host '安装脚本已执行完成。' -ForegroundColor Green
    Write-Host '如果上方有报错信息，请截图反馈。窗口将在 5 秒后自动关闭...' -ForegroundColor Yellow
    Start-Sleep -Seconds 5
}
exit `$code
"@
    [System.IO.File]::WriteAllText($tempPath, $wrapper, (New-Object System.Text.UTF8Encoding $true))
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

function Set-LauncherWindowMode {
    param(
        [ValidateSet('Install','Home')]
        [string]$Mode
    )

    if ($script:LauncherWindowMode -eq $Mode) { return }

    switch ($Mode) {
        'Install' {
            $window.MinWidth = 960
            $window.MinHeight = 720
            if ($window.WindowState -ne 'Maximized') {
                $window.Width = 1040
                $window.Height = 780
            }
        }
        'Home' {
            $window.MinWidth = 860
            $window.MinHeight = 520
            if ($window.WindowState -ne 'Maximized') {
                $window.Width = 920
                $window.Height = 560
            }
        }
    }

    $script:LauncherWindowMode = $Mode
}

function New-SubPanelWindow {
    param(
        [string]$Title,
        [int]$Width = 760,
        [int]$Height = 500
    )

    [xml]$dialogXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title"
        Width="$Width"
        Height="$Height"
        MinWidth="680"
        MinHeight="420"
        WindowStartupLocation="CenterOwner"
        Background="#0B1220"
        Foreground="#E2E8F0"
        ResizeMode="CanResize">
    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <DockPanel Grid.Row="0" LastChildFill="False" Margin="0,0,0,16">
            <TextBlock x:Name="DialogTitleText" DockPanel.Dock="Left" FontSize="24" FontWeight="SemiBold" Text="$Title"/>
            <Button x:Name="DialogCloseButton" DockPanel.Dock="Right" Padding="12,8" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="关闭"/>
        </DockPanel>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="DialogContentPanel"/>
        </ScrollViewer>
    </Grid>
</Window>
"@

    $dialogReader = New-Object System.Xml.XmlNodeReader $dialogXaml
    $dialog = [Windows.Markup.XamlReader]::Load($dialogReader)
    $dialog.Owner = $window
    $closeDialog = $dialog
    $dialog.FindName('DialogCloseButton').Add_Click({ $closeDialog.Close() }.GetNewClosure())

    return [pscustomobject]@{
        Window       = $dialog
        ContentPanel = $dialog.FindName('DialogContentPanel')
    }
}

function Add-SubPanelSection {
    param(
        $DialogWindow,
        $Container,
        [string]$Title,
        [string]$Body,
        [object[]]$Actions = @()
    )

    $border = New-Object System.Windows.Controls.Border
    $border.Margin = '0,0,0,14'
    $border.Padding = '18'
    $border.CornerRadius = '18'
    $border.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#111827')
    $border.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#22314D')
    $border.BorderThickness = '1'

    $stack = New-Object System.Windows.Controls.StackPanel

    $titleBlock = New-Object System.Windows.Controls.TextBlock
    $titleBlock.FontSize = 18
    $titleBlock.FontWeight = 'SemiBold'
    $titleBlock.Text = $Title
    [void]$stack.Children.Add($titleBlock)

    if ($Body) {
        $bodyBlock = New-Object System.Windows.Controls.TextBlock
        $bodyBlock.Margin = '0,10,0,0'
        $bodyBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#CBD5E1')
        $bodyBlock.TextWrapping = 'Wrap'
        $bodyBlock.Text = $Body
        [void]$stack.Children.Add($bodyBlock)
    }

    if ($Actions.Count -gt 0) {
        $panel = New-Object System.Windows.Controls.WrapPanel
        $panel.Margin = '0,16,0,0'
        foreach ($action in $Actions) {
            $hasDanger = [bool]($action.PSObject.Properties['Danger'] -and $action.Danger)
            $hasPrimary = [bool]($action.PSObject.Properties['Primary'] -and $action.Primary)
            $button = New-Object System.Windows.Controls.Button
            $button.Margin = '0,0,10,10'
            $button.Padding = '14,10'
            $button.Content = $action.Label
            $button.IsEnabled = [bool]$action.Enabled
            if ($hasDanger) {
                $button.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#991B1B')
                $button.Foreground = [System.Windows.Media.Brushes]::White
                $button.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#DC2626')
            } elseif ($hasPrimary) {
                $button.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#22C55E')
                $button.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#04110A')
                $button.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#22C55E')
            } else {
                $button.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0F172A')
                $button.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#CBD5E1')
                $button.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#334155')
            }

            $actionId = [string]$action.ActionId
            if ($actionId) {
                $targetDialog = $DialogWindow
                $button.Add_Click({
                    $targetDialog.Close()
                    Invoke-AppAction $actionId
                }.GetNewClosure())
            }
            [void]$panel.Children.Add($button)
        }
        [void]$stack.Children.Add($panel)
    }

    $border.Child = $stack
    [void]$Container.Children.Add($border)
}

function Show-AdvancedPanel {
    $script:CurrentStatus = Get-UiState
    $state = $script:CurrentStatus
    if (-not $state) { return }

    $dialogRef = New-SubPanelWindow -Title '更多设置' -Width 780 -Height 560

    Add-SubPanelSection -DialogWindow $dialogRef.Window -Container $dialogRef.ContentPanel -Title '配置文件' -Body '' -Actions @(
        [pscustomobject]@{ Label = '打开 config.yaml'; ActionId = 'open-config'; Enabled = (Test-Path (Join-Path $state.HermesHome 'config.yaml')); Primary = $true },
        [pscustomobject]@{ Label = '打开 .env'; ActionId = 'open-env'; Enabled = (Test-Path (Join-Path $state.HermesHome '.env')) }
    )
    Add-SubPanelSection -DialogWindow $dialogRef.Window -Container $dialogRef.ContentPanel -Title '目录' -Body '' -Actions @(
        [pscustomobject]@{ Label = '查看安装位置'; ActionId = 'show-install-paths'; Enabled = $true; Primary = $true },
        [pscustomobject]@{ Label = '打开数据目录'; ActionId = 'browse-home'; Enabled = (Test-Path $state.HermesHome) },
        [pscustomobject]@{ Label = '打开安装目录'; ActionId = 'browse-install'; Enabled = (Test-Path $state.InstallDir) },
        [pscustomobject]@{ Label = '打开日志目录'; ActionId = 'open-logs'; Enabled = (Test-Path (Join-Path $state.HermesHome 'logs')) }
    )
    $webUiDefaults = Get-HermesWebUiDefaults
    $webUiBody = if ($state.WebUiStatus.Healthy) {
        "hermes-web-ui 正在运行：$($state.WebUiStatus.Url)"
    } elseif ($state.WebUiStatus.Installed) {
        "hermes-web-ui 已安装，版本：$($script:HermesWebUiVersion)。"
    } else {
        'hermes-web-ui 尚未安装。点击【开始使用】会自动安装。'
    }
    Add-SubPanelSection -DialogWindow $dialogRef.Window -Container $dialogRef.ContentPanel -Title 'hermes-web-ui' -Body $webUiBody -Actions @(
        [pscustomobject]@{ Label = '开始使用'; ActionId = 'launch'; Enabled = [bool]$state.HermesCommand; Primary = $true },
        [pscustomobject]@{ Label = '打开 WebUI 日志'; ActionId = 'open-webui-logs'; Enabled = (Test-Path $webUiDefaults.LogsDir) },
        [pscustomobject]@{ Label = '打开 WebUI 目录'; ActionId = 'open-webui-dir'; Enabled = (Test-Path $webUiDefaults.WebUiHome) },
        [pscustomobject]@{ Label = '打开命令行对话'; ActionId = 'launch-cli'; Enabled = [bool]$state.HermesCommand }
    )
    Add-SubPanelSection -DialogWindow $dialogRef.Window -Container $dialogRef.ContentPanel -Title '维护' -Body '' -Actions @(
        [pscustomobject]@{ Label = '刷新状态'; ActionId = 'refresh'; Enabled = $true },
        [pscustomobject]@{ Label = '运行 update'; ActionId = 'update'; Enabled = [bool]$state.HermesCommand },
        [pscustomobject]@{ Label = '完整 setup'; ActionId = 'full-setup'; Enabled = [bool]$state.HermesCommand },
        [pscustomobject]@{ Label = '配置 tools'; ActionId = 'tools'; Enabled = [bool]$state.HermesCommand }
    )
    $openClawSources = @(Get-OpenClawSources)
    if ($openClawSources.Count -gt 0) {
        $clawBody = if ($state.LauncherState.OpenClawImported) {
            '已记录为完成过旧版配置迁移。如需再次迁移，可以重新执行。'
        } elseif ($state.LauncherState.OpenClawSkipped) {
            '之前跳过了旧版配置迁移，你现在可以随时重新执行。'
        } else {
            '检测到旧版 OpenClaw 配置目录。可先预览，再执行正式迁移。'
        }
        Add-SubPanelSection -DialogWindow $dialogRef.Window -Container $dialogRef.ContentPanel -Title '旧版配置迁移' -Body $clawBody -Actions @(
            [pscustomobject]@{ Label = '预览迁移'; ActionId = 'openclaw-preview'; Enabled = [bool]$state.HermesCommand },
            [pscustomobject]@{ Label = '正式迁移'; ActionId = 'openclaw-migrate'; Enabled = [bool]$state.HermesCommand; Primary = $true }
        )
    }
    Add-SubPanelSection -DialogWindow $dialogRef.Window -Container $dialogRef.ContentPanel -Title '参考' -Body '' -Actions @(
        [pscustomobject]@{ Label = '官方文档'; ActionId = 'open-docs'; Enabled = $true },
        [pscustomobject]@{ Label = '官方仓库'; ActionId = 'open-repo'; Enabled = $true }
    )
    Add-SubPanelSection -DialogWindow $dialogRef.Window -Container $dialogRef.ContentPanel -Title '风险操作' -Body '' -Actions @(
        [pscustomobject]@{ Label = '卸载 / 重装'; ActionId = 'uninstall'; Enabled = $true; Danger = $true }
    )

    [void]$dialogRef.Window.ShowDialog()
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
    [System.IO.File]::WriteAllText($wrapperPath, $wrapper, (New-Object System.Text.UTF8Encoding $true))

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
        try {
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
                Add-ActionLog -Action '安装 / 更新 Hermes' -Result '安装任务已完成，启动器已自动刷新状态' -Next '根据推荐步骤继续配置模型、本地对话或消息渠道'
                    } else {
                        Add-ActionLog -Action '安装 / 更新 Hermes' -Result ("安装任务退出，退出码：{0}" -f $exitCode) -Next '查看日志中的最后几段报错，必要时改用外部终端安装'
                    }
                } else {
                    Add-LogLine ("后台任务结束：{0}（退出码 {1}）" -f $taskName, $exitCode)
                }
                Refresh-Status
            }
        } catch {
            Add-LogLine ("后台任务监视器异常：{0}" -f $_.Exception.Message)
        }
    })
    $script:TrackedTaskTimer = $timer
    $timer.Start()
}

function Get-CachedPreflight {
    param(
        [string]$InstallDir,
        [string]$HermesHome,
        [switch]$ForceRefresh
    )
    $now = [datetime]::Now
    $expired = ($now - $script:PreflightCacheTime).TotalSeconds -ge $script:PreflightCacheTtlSeconds
    $dirChanged = $InstallDir -ne $script:PreflightCacheDir -or $HermesHome -ne $script:PreflightCacheHome
    if (-not $ForceRefresh -and -not $expired -and -not $dirChanged -and $script:PreflightCache) {
        return $script:PreflightCache
    }
    $result = Test-InstallPreflight -InstallDir $InstallDir -HermesHome $HermesHome
    $script:PreflightCache = $result
    $script:PreflightCacheTime = $now
    $script:PreflightCacheDir = $InstallDir
    $script:PreflightCacheHome = $HermesHome
    return $result
}

function Test-InstallPreflight {
    param(
        [string]$InstallDir,
        [string]$HermesHome
    )

    $blocking = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $passed = New-Object System.Collections.Generic.List[string]

    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCommand) {
        $passed.Add('已检测到 Git。') | Out-Null
    } else {
        $blocking.Add('未检测到 Git。官方安装脚本需要 Git 才能拉取仓库。') | Out-Null
    }

    $pythonCommand = @(
        (Get-Command py -ErrorAction SilentlyContinue),
        (Get-Command python -ErrorAction SilentlyContinue)
    ) | Where-Object { $_ } | Select-Object -First 1
    if ($pythonCommand) {
        $passed.Add(("已检测到 Python 命令：{0}" -f $pythonCommand.Name)) | Out-Null
    } else {
        $warnings.Add('未检测到 Python 命令。官方安装脚本会尝试自动安装。') | Out-Null
    }

    if (Resolve-UvCommand) {
        $passed.Add('已检测到 uv。') | Out-Null
    } else {
        $warnings.Add('未检测到 uv。安装脚本可能会自行安装，但网络较慢时容易失败。') | Out-Null
    }

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $passed.Add('已检测到 winget。') | Out-Null
    } else {
        $warnings.Add('未检测到 winget。如缺失系统依赖，可能需要手动安装。') | Out-Null
    }

    foreach ($dir in @($HermesHome, (Split-Path -Parent $InstallDir))) {
        if (-not $dir) { continue }
        try {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $probe = Join-Path $dir ('.write-test-' + [guid]::NewGuid().ToString('N') + '.tmp')
            [System.IO.File]::WriteAllText($probe, 'ok')
            Remove-Item $probe -Force -ErrorAction SilentlyContinue
            $passed.Add(("目录可写：{0}" -f $dir)) | Out-Null
        } catch {
            $blocking.Add(("目录不可写：{0}" -f $dir)) | Out-Null
        }
    }

    # 残留目录检测：安装目录存在但不是 git 仓库 → 上次安装中途失败留下的残留
    # 上游 install.ps1 遇到这种情况会直接报错退出，所以必须在安装前清理
    if (Test-Path $InstallDir) {
        $gitDir = Join-Path $InstallDir '.git'
        if (-not (Test-Path $gitDir)) {
            $staleRemoved = $false
            # 方法 1：PowerShell Remove-Item
            try {
                Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
                $staleRemoved = $true
            } catch { }
            # 方法 2：cmd /c rd
            if (-not $staleRemoved) {
                try {
                    cmd /c "rd /s /q `"$InstallDir`"" 2>&1 | Out-Null
                    if (-not (Test-Path $InstallDir)) { $staleRemoved = $true }
                } catch { }
            }
            # 方法 3：robocopy 空目录镜像（能处理超过 260 字符的长路径）
            if (-not $staleRemoved) {
                try {
                    $emptyDir = Join-Path $env:TEMP ('hermes-empty-' + [guid]::NewGuid().ToString('N'))
                    New-Item -ItemType Directory -Force -Path $emptyDir | Out-Null
                    robocopy $emptyDir $InstallDir /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /nc /ns /np 2>&1 | Out-Null
                    Remove-Item $emptyDir -Force -ErrorAction SilentlyContinue
                    cmd /c "rd /s /q `"$InstallDir`"" 2>&1 | Out-Null
                    if (-not (Test-Path $InstallDir)) { $staleRemoved = $true }
                } catch { }
            }
            if ($staleRemoved) {
                $warnings.Add(("已自动清理上次安装失败残留的目录：{0}" -f $InstallDir)) | Out-Null
            } else {
                # 自动清理失败 → 弹窗帮用户打开目录所在的文件夹
                $parentDir = Split-Path -Parent $InstallDir
                $dirName = Split-Path -Leaf $InstallDir
                $staleMsg = ("上次安装未完成，留下了残留目录，需要删除后才能重新安装。`n`n" +
                     "路径：{0}`n`n" +
                     "点击「确定」为你打开该目录所在的文件夹，请删除其中的「{1}」文件夹后，回到启动器点击「重新检测」。") -f $InstallDir, $dirName
                $msgResult = [System.Windows.MessageBox]::Show($staleMsg, 'Hermes 启动器', 'OKCancel', 'Warning')
                if ($msgResult -eq 'OK') {
                    Start-Process explorer.exe -ArgumentList "/select,`"$InstallDir`""
                }
                $blocking.Add('需要先删除上次安装失败残留的目录（已打开文件夹），删除后点击"重新检测"。') | Out-Null
            }
        }
    }

    # 网络检测：先测官方源，如果官方源不通则检查是否有镜像源可用
    # （多源支持后，官方源不通 = 国内网络，会自动用镜像，不应阻塞安装）
    $networkOk = $false
    $networkEnvResult = 'unknown'
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Uri $defaults.OfficialInstallUrl -Method Head -TimeoutSec 8
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) {
            $passed.Add('已检测到官方安装脚本下载地址可访问。') | Out-Null
            $networkOk = $true
            $networkEnvResult = 'overseas'
        } else {
            $warnings.Add(("安装脚本地址返回状态异常：{0}" -f $resp.StatusCode)) | Out-Null
        }
    } catch {
        # 官方源不通 → 检测是否为国内网络（会用镜像源），不硬性阻塞
        $mirrorCfg = Get-MirrorConfig
        $mirrorReachable = $false
        foreach ($mirrorBase in $mirrorCfg.GitHubRaw[1..2]) {
            try {
                $mirrorUrl = $defaults.OfficialInstallUrl -replace 'https://raw\.githubusercontent\.com', $mirrorBase
                if ($mirrorBase -match '/https?://$') { $mirrorUrl = $mirrorBase + $defaults.OfficialInstallUrl }
                $mResp = Invoke-WebRequest -UseBasicParsing -Uri $mirrorUrl -Method Head -TimeoutSec 6
                if ($mResp.StatusCode -ge 200 -and $mResp.StatusCode -lt 400) {
                    $mirrorReachable = $true
                    break
                }
            } catch { }
        }
        if ($mirrorReachable) {
            $passed.Add('官方安装脚本地址不可访问，但国内镜像源可用。安装将自动切换到国内镜像。') | Out-Null
            $networkOk = $true
            $networkEnvResult = 'china'
        } else {
            $blocking.Add('访问官方安装脚本及所有镜像源均失败。请检查网络连接后重试。') | Out-Null
        }
    }

    [pscustomobject]@{
        Passed   = @($passed.ToArray())
        Warnings = @($warnings.ToArray())
        Blocking = @($blocking.ToArray())
        HasGit   = [bool]$gitCommand
        HasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
        NetworkOk = $networkOk
        NetworkEnv = $networkEnvResult
        CanInstall = ($blocking.Count -eq 0)
    }
}

function Set-InstallActionButtons {
    param(
        [string]$PrimaryActionId,
        [string]$PrimaryLabel,
        [bool]$PrimaryEnabled,
        [string]$SecondaryActionId,
        [string]$SecondaryLabel,
        [bool]$SecondaryEnabled,
        [string]$TertiaryActionId,
        [string]$TertiaryLabel,
        [bool]$TertiaryEnabled
    )

    $script:InstallPrimaryActionId = $PrimaryActionId
    $script:InstallSecondaryActionId = $SecondaryActionId
    $script:InstallTertiaryActionId = $TertiaryActionId

    $controls.StartInstallPageButton.Content = $PrimaryLabel
    $controls.StartInstallPageButton.IsEnabled = $PrimaryEnabled
    if ($PrimaryEnabled) {
        $controls.StartInstallPageButton.Background = '#22C55E'
        $controls.StartInstallPageButton.BorderBrush = '#22C55E'
        $controls.StartInstallPageButton.Foreground = '#04110A'
    } else {
        $controls.StartInstallPageButton.Background = '#1E293B'
        $controls.StartInstallPageButton.BorderBrush = '#334155'
        $controls.StartInstallPageButton.Foreground = '#94A3B8'
    }

    $controls.InstallRequirementsButton.Content = $SecondaryLabel
    $controls.InstallRequirementsButton.IsEnabled = $SecondaryEnabled -and -not [string]::IsNullOrWhiteSpace($SecondaryActionId)
    $controls.InstallRequirementsButton.Visibility = if ([string]::IsNullOrWhiteSpace($SecondaryLabel)) { 'Collapsed' } else { 'Visible' }

    $controls.InstallRefreshButton.Content = $TertiaryLabel
    $controls.InstallRefreshButton.IsEnabled = $TertiaryEnabled -and -not [string]::IsNullOrWhiteSpace($TertiaryActionId)
    $controls.InstallRefreshButton.Visibility = if ([string]::IsNullOrWhiteSpace($TertiaryLabel)) { 'Collapsed' } else { 'Visible' }
}

function Test-OpenClawPending {
    param($state)

    return [bool](
        ($state.Status.Installed -or $state.HermesCommand) -and
        $state.OpenClawSources.Count -gt 0 -and
        -not $state.LauncherState.OpenClawImported -and
        -not $state.LauncherState.OpenClawSkipped
    )
}

function Get-InstallFeedbackText {
    $state = Get-UiState
    $preflight = Get-CachedPreflight -InstallDir $state.InstallDir -HermesHome $state.HermesHome
    $recentLog = @()
    if ($controls.LogTextBox.Text) {
        $lines = $controls.LogTextBox.Text -split "`r?`n"
        $recentLog = @($lines | Select-Object -Last 40)
    }

    @(
        "Hermes Launcher Version: $script:LauncherVersion"
        "InstallDir: $($state.InstallDir)"
        "HermesHome: $($state.HermesHome)"
        "HermesCommand: $(if ($state.HermesCommand) { $state.HermesCommand } else { 'not found' })"
        "ModelReady: $($state.ModelStatus.ReadyLikely)"
        "WebUiInstalled: $($state.WebUiStatus.Installed)"
        "WebUiHealthy: $($state.WebUiStatus.Healthy)"
        ""
        "[Blocking]"
        ($preflight.Blocking -join [Environment]::NewLine)
        ""
        "[Warnings]"
        ($preflight.Warnings -join [Environment]::NewLine)
        ""
        "[RecentLog]"
        ($recentLog -join [Environment]::NewLine)
    ) -join [Environment]::NewLine
}

function Update-InstallPathSummary {
    $controls.InstallPathSummaryText.Text = "数据目录：$($controls.HermesHomeTextBox.Text.Trim())`n安装目录：$($controls.InstallDirTextBox.Text.Trim())"
}

function Show-InstallLocationDialog {
    [xml]$dialogXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="更改安装位置"
        Width="760"
        Height="430"
        MinWidth="700"
        MinHeight="380"
        WindowStartupLocation="CenterOwner"
        Background="#0B1220"
        Foreground="#E2E8F0"
        ResizeMode="NoResize">
    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" FontSize="24" FontWeight="SemiBold" Text="更改安装位置"/>
        <Grid Grid.Row="1" Margin="0,18,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="96"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" VerticalAlignment="Center" Foreground="#CBD5E1" Text="数据目录"/>
            <Grid Grid.Row="0" Grid.Column="1" Margin="10,0,0,10">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBox x:Name="DialogHermesHomeTextBox" Grid.Column="0" Padding="8" Background="#0F172A" Foreground="White" BorderBrush="#334155"/>
                <Button x:Name="BrowseHermesHomeButton" Grid.Column="1" Margin="10,0,0,0" Padding="12,8" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="选择目录"/>
            </Grid>
            <TextBlock Grid.Row="1" VerticalAlignment="Center" Foreground="#CBD5E1" Text="安装目录"/>
            <Grid Grid.Row="1" Grid.Column="1" Margin="10,0,0,10">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBox x:Name="DialogInstallDirTextBox" Grid.Column="0" Padding="8" Background="#0F172A" Foreground="White" BorderBrush="#334155"/>
                <Button x:Name="BrowseInstallDirButton" Grid.Column="1" Margin="10,0,0,0" Padding="12,8" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="选择目录"/>
            </Grid>
            <Expander Grid.Row="2" Grid.ColumnSpan="2" Margin="0,6,0,0" Foreground="#CBD5E1" Header="高级选项" IsExpanded="False">
                <StackPanel Margin="0,8,0,0">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="96"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock VerticalAlignment="Center" Foreground="#CBD5E1" Text="Git 分支"/>
                        <TextBox x:Name="DialogBranchTextBox" Grid.Column="1" Margin="10,0,0,10" Padding="8" Background="#0F172A" Foreground="White" BorderBrush="#334155"/>
                    </Grid>
                    <StackPanel Orientation="Horizontal" Margin="96,4,0,0">
                        <CheckBox x:Name="DialogNoVenvCheckBox" Margin="0,0,14,0" VerticalAlignment="Center" Foreground="#CBD5E1" Content="NoVenv"/>
                        <CheckBox x:Name="DialogSkipSetupCheckBox" VerticalAlignment="Center" Foreground="#CBD5E1" Content="安装后不进入官方 setup"/>
                    </StackPanel>
                    <TextBlock Margin="96,10,0,0" Foreground="#94A3B8" TextWrapping="Wrap" Text="保存后需要重新确认安装位置，然后再开始安装。"/>
                </StackPanel>
            </Expander>
        </Grid>
        <WrapPanel Grid.Row="2" Margin="0,18,0,0" HorizontalAlignment="Right">
            <Button x:Name="DialogResetButton" Margin="0,0,10,0" Padding="14,10" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="恢复默认"/>
            <Button x:Name="DialogCancelButton" Margin="0,0,10,0" Padding="14,10" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="取消"/>
            <Button x:Name="DialogSaveButton" Padding="14,10" Background="#1E293B" Foreground="#F8FAFC" BorderBrush="#475569" Content="保存更改"/>
        </WrapPanel>
    </Grid>
</Window>
"@

    $dialogReader = New-Object System.Xml.XmlNodeReader $dialogXaml
    $dialog = [Windows.Markup.XamlReader]::Load($dialogReader)
    $dialog.Owner = $window

    $homeBox = $dialog.FindName('DialogHermesHomeTextBox')
    $installBox = $dialog.FindName('DialogInstallDirTextBox')
    $branchBox = $dialog.FindName('DialogBranchTextBox')
    $noVenvCheck = $dialog.FindName('DialogNoVenvCheckBox')
    $skipSetupCheck = $dialog.FindName('DialogSkipSetupCheckBox')
    $browseHomeButton = $dialog.FindName('BrowseHermesHomeButton')
    $browseInstallButton = $dialog.FindName('BrowseInstallDirButton')
    $resetButton = $dialog.FindName('DialogResetButton')
    $cancelButton = $dialog.FindName('DialogCancelButton')
    $saveButton = $dialog.FindName('DialogSaveButton')

    $homeBox.Text = $controls.HermesHomeTextBox.Text
    $installBox.Text = $controls.InstallDirTextBox.Text
    $branchBox.Text = $controls.BranchTextBox.Text
    $noVenvCheck.IsChecked = $controls.NoVenvCheckBox.IsChecked
    $skipSetupCheck.IsChecked = $controls.SkipSetupCheckBox.IsChecked

    $defaultHome = $defaults.HermesHome
    $defaultInstall = $defaults.InstallDir
    $defaultBranch = 'main'

    $selectFolderPath = {
        param([string]$InitialPath)

        $dialogRef = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialogRef.ShowNewFolderButton = $true
        if (-not [string]::IsNullOrWhiteSpace($InitialPath) -and (Test-Path $InitialPath)) {
            $dialogRef.SelectedPath = $InitialPath
        }
        if ($dialogRef.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialogRef.SelectedPath
        }
        return $null
    }.GetNewClosure()

    $resetTarget = $dialog
    $browseHomeButton.Add_Click({
        $selected = & $selectFolderPath $homeBox.Text
        if ($selected) { $homeBox.Text = $selected }
    }.GetNewClosure())
    $browseInstallButton.Add_Click({
        $selected = & $selectFolderPath $installBox.Text
        if ($selected) { $installBox.Text = $selected }
    }.GetNewClosure())
    $resetButton.Add_Click({
        $homeBox.Text = $defaultHome
        $installBox.Text = $defaultInstall
        $branchBox.Text = $defaultBranch
        $noVenvCheck.IsChecked = $false
        $skipSetupCheck.IsChecked = $true
    }.GetNewClosure())
    $cancelButton.Add_Click({ $resetTarget.Close() }.GetNewClosure())
    $saveButton.Add_Click({
        $controls.HermesHomeTextBox.Text = $homeBox.Text.Trim()
        $controls.InstallDirTextBox.Text = $installBox.Text.Trim()
        $controls.BranchTextBox.Text = $branchBox.Text.Trim()
        $controls.NoVenvCheckBox.IsChecked = [bool]$noVenvCheck.IsChecked
        $controls.SkipSetupCheckBox.IsChecked = [bool]$skipSetupCheck.IsChecked
        $script:InstallLocationConfirmed = $false
        Update-InstallPathSummary
        Add-ActionLog -Action '保存安装位置' -Result '已保存安装路径和安装选项' -Next '确认安装位置后再开始安装'
        Refresh-Status
        $dialog.Close()
    }.GetNewClosure())

    [void]$dialog.ShowDialog()
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
    $launcherState = Load-LauncherState -HermesHome $hermesHome
    $webUiStatus = Get-HermesWebUiStatus

    [pscustomobject]@{
        InstallDir      = $installDir
        HermesHome      = $hermesHome
        Branch          = $controls.BranchTextBox.Text.Trim()
        Status          = $status
        HermesCommand   = $resolvedCommand
        ModelStatus     = $modelStatus
        OpenClawSources = $openClawSources
        LauncherState   = $launcherState
        WebUiStatus     = $webUiStatus
    }
}

function Get-Recommendation {
    param($state)

    if (-not ($state.Status.Installed -or $state.HermesCommand)) {
        return [pscustomobject]@{
            Headline = '先完成安装'
            Body     = '当前没有检测到 Hermes 可执行文件，先执行安装或更新。'
            Hint     = '安装成功后刷新状态，再继续使用。'
            ActionId = 'install-external'
            Label    = '安装 / 更新 Hermes'
            Stage    = 'Install'
            Enabled  = $true
        }
    }

    if ($state.OpenClawSources.Count -gt 0 -and -not $state.ModelStatus.ReadyLikely) {
        return [pscustomobject]@{
            Headline = '可迁移旧版 OpenClaw 配置'
            Body     = '已检测到旧版 OpenClaw 配置目录。Hermes 支持按官方命令预览迁移或正式迁移。'
            Hint     = '如果你不是从旧版迁移，可以跳过，直接继续使用。'
            ActionId = 'openclaw-migrate'
            Label    = '迁移旧版配置'
            Stage    = 'Migration'
            Enabled  = [bool]$state.HermesCommand
        }
    }

    [pscustomobject]@{
        Headline = '已就绪'
        Body     = '点击"开始使用"打开 hermes-web-ui，在浏览器中完成模型配置和对话。'
        Hint     = '所有模型配置和对话都在 hermes-web-ui 中完成。'
        ActionId = 'launch'
        Label    = '开始使用'
        Stage    = 'Launch'
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
    if ($state.ModelStatus.HasApiKey) { $ok.Add('已检测到可用凭证或登录态。') } else { $warn.Add('尚未检测到可用凭证或登录态。') }
    if ($state.OpenClawSources.Count -gt 0) { $items.Add("已检测到旧版配置目录：$($state.OpenClawSources -join '; ')。可按需迁移。") }
    if ($state.WebUiStatus.Healthy) { $ok.Add('hermes-web-ui 正在运行。') }
    elseif ($state.WebUiStatus.Installed) { $items.Add('hermes-web-ui 已安装，当前未运行。') }
    else { $items.Add('hermes-web-ui 尚未安装，点击"开始使用"会自动安装。') }

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

    $launchAction = [pscustomobject]@{
        ActionId = 'launch'
        Label    = '开始使用'
        Enabled  = [bool]$state.HermesCommand
    }

    return [pscustomobject]@{
        Active  = $true
        Title   = '开始使用'
        Hint    = '点击"开始使用"打开 hermes-web-ui，在浏览器中配置模型和开始对话。'
        Primary = $launchAction
    }
}

function Request-StatusRefresh {
    if (-not $script:RefreshDebounceTimer) {
        $script:RefreshDebounceTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:RefreshDebounceTimer.Interval = [TimeSpan]::FromMilliseconds($script:RefreshDebounceDelayMs)
        $script:RefreshDebounceTimer.Add_Tick({
            $script:RefreshDebounceTimer.Stop()
            try { Refresh-Status } catch { Add-LogLine ("状态刷新异常：{0}" -f $_.Exception.Message) }
        })
    }
    $script:RefreshDebounceTimer.Stop()
    $script:RefreshDebounceTimer.Start()
}

function Refresh-Status {
    $script:CurrentStatus = Get-UiState
    Update-InstallPathSummary

    $isInstalled = [bool]($script:CurrentStatus.Status.Installed -or $script:CurrentStatus.HermesCommand)
    $pendingOpenClaw = Test-OpenClawPending -state $script:CurrentStatus
    if ((-not $isInstalled) -or $pendingOpenClaw) {
        Set-LauncherWindowMode -Mode 'Install'
        $controls.InstallModePanel.Visibility = 'Visible'
        $controls.HomeModePanel.Visibility = 'Collapsed'
        $controls.LogSectionBorder.Visibility = 'Visible'
        $controls.FooterBorder.Visibility = 'Visible'

        $preflight = Get-CachedPreflight -InstallDir $script:CurrentStatus.InstallDir -HermesHome $script:CurrentStatus.HermesHome
        $installRunning = $false
        if ($script:ExternalInstallProcess) {
            try { $installRunning = -not $script:ExternalInstallProcess.HasExited } catch { $installRunning = $false }
        }

        $controls.OpenClawPostInstallBorder.Visibility = 'Collapsed'
        $controls.InstallTaskCardBorder.Visibility = 'Visible'
        $controls.InstallProgressCardBorder.Visibility = 'Visible'
        $controls.InstallPathCardBorder.Visibility = 'Collapsed'
        $controls.InstallSettingsEditorBorder.Visibility = 'Collapsed'

        if ($pendingOpenClaw) {
            $controls.InstallTaskCardBorder.Visibility = 'Collapsed'
            $controls.InstallProgressCardBorder.Visibility = 'Collapsed'
            $controls.InstallPathCardBorder.Visibility = 'Collapsed'
            $controls.OpenClawPostInstallBorder.Visibility = 'Visible'
            $controls.OpenClawPostInstallText.Text = '检测到旧版 OpenClaw 配置。Hermes 支持按官方方式迁移旧版模型、密钥和部分配置；如果暂时不迁移，也可以先开始使用。'
            $controls.OpenClawImportButton.IsEnabled = [bool]$script:CurrentStatus.HermesCommand
            $controls.OpenClawSkipButton.IsEnabled = $true
        } elseif ($installRunning) {
            $controls.InstallProgressTitleText.Text = '执行进度'
            $controls.InstallTaskTitleText.Text = '第 3 步：正在安装 Hermes'
            $controls.InstallTaskBodyText.Text = '官方安装终端已经打开。成功时终端会自动关闭；如果失败，终端会保留，日志区也会记录安装摘要。'
            $controls.InstallProgressText.Text = @(
                '✓ 第 1 步：环境检测已通过'
                '✓ 第 2 步：安装位置已确认'
                '→ 第 3 步：官方安装脚本执行中'
            ) -join [Environment]::NewLine
            $controls.InstallFailureSummaryText.Visibility = 'Collapsed'
            $controls.InstallFailureSummaryText.Text = ''
            Set-InstallActionButtons -PrimaryActionId 'refresh' -PrimaryLabel '安装进行中' -PrimaryEnabled $false -SecondaryActionId 'open-docs' -SecondaryLabel '查看官方文档' -SecondaryEnabled $true -TertiaryActionId 'refresh' -TertiaryLabel '刷新状态' -TertiaryEnabled $true
        } elseif (-not $script:InstallPreflightConfirmed -or -not $preflight.CanInstall) {
            $controls.InstallProgressTitleText.Text = '检测结果'
            $controls.InstallTaskTitleText.Text = '第 1 步：环境检测'
            $controls.InstallTaskBodyText.Text = '先确认当前机器能顺利跑通官方安装脚本。Python、uv、Node 之类缺失时，官方脚本通常会自动补齐；Git、网络和目录权限异常才是会直接卡死安装的硬阻塞。建议使用默认安装路径，遇到目录权限异常时优先恢复默认。'
            $preflightLines = New-Object System.Collections.Generic.List[string]
            if ($preflight.Blocking.Count -gt 0) {
                $preflightLines.Add('阻塞项：') | Out-Null
                foreach ($item in $preflight.Blocking) { $preflightLines.Add("• $item") | Out-Null }
            } else {
                $preflightLines.Add('阻塞项：无') | Out-Null
            }
            $preflightLines.Add('') | Out-Null
            $preflightLines.Add('自动处理项：') | Out-Null
            $preflightLines.Add("• Python：$(if ((@($preflight.Passed | Where-Object { $_ -like '已检测到 Python*' })).Count -gt 0) { '已检测到' } else { '缺失时官方安装脚本会自动处理' })") | Out-Null
            $preflightLines.Add("• uv：$(if ((@($preflight.Passed | Where-Object { $_ -eq '已检测到 uv。' })).Count -gt 0) { '已检测到' } else { '缺失时官方安装脚本会自动处理' })") | Out-Null
            if ($preflight.Warnings.Count -gt 0) {
                $preflightLines.Add('') | Out-Null
                $preflightLines.Add('提示：') | Out-Null
                foreach ($item in $preflight.Warnings) { $preflightLines.Add("• $item") | Out-Null }
            }
            $controls.InstallProgressText.Text = ($preflightLines -join [Environment]::NewLine)

            if ($preflight.CanInstall) {
                $controls.InstallFailureSummaryText.Visibility = if ($preflight.Warnings.Count -gt 0) { 'Visible' } else { 'Collapsed' }
                $controls.InstallFailureSummaryText.Text = if ($preflight.Warnings.Count -gt 0) { "提示：`n• " + ($preflight.Warnings -join "`n• ") } else { '' }
                Set-InstallActionButtons -PrimaryActionId 'preflight-confirm' -PrimaryLabel '环境没问题，继续' -PrimaryEnabled $true -SecondaryActionId 'open-docs' -SecondaryLabel '查看安装说明' -SecondaryEnabled $true -TertiaryActionId 'refresh' -TertiaryLabel '重新检测' -TertiaryEnabled $true
            } else {
                $controls.InstallFailureSummaryText.Visibility = 'Visible'
                $hasDirBlocking = (@($preflight.Blocking | Where-Object { $_ -like '目录不可写*' })).Count -gt 0
                $blockingText = "阻塞项：`n• " + ($preflight.Blocking -join "`n• ")
                if ($hasDirBlocking) {
                    $blockingText += "`n`n建议：点击下方更改安装位置按钮，恢复默认路径后重新检测。"
                }
                $controls.InstallFailureSummaryText.Text = $blockingText
                $primaryAction = if (-not $preflight.HasGit) { 'open-git-download' } elseif ($hasDirBlocking) { 'change-location' } else { 'open-docs' }
                $primaryLabel = if (-not $preflight.HasGit) { '打开 Git 下载页' } elseif ($hasDirBlocking) { '更改安装位置' } else { '查看解决说明' }
                $secondaryAction = if (-not $preflight.HasGit) { 'install-git' } else { 'open-docs' }
                $secondaryLabel = if (-not $preflight.HasGit) { '自动安装 Git' } else { '查看官方文档' }
                $secondaryEnabled = if (-not $preflight.HasGit) { $preflight.HasWinget } else { $true }
                Set-InstallActionButtons -PrimaryActionId $primaryAction -PrimaryLabel $primaryLabel -PrimaryEnabled $true -SecondaryActionId $secondaryAction -SecondaryLabel $secondaryLabel -SecondaryEnabled $secondaryEnabled -TertiaryActionId 'refresh' -TertiaryLabel '重新检测' -TertiaryEnabled $true
            }
        } elseif (-not $script:InstallLocationConfirmed) {
            $controls.InstallTaskCardBorder.Visibility = 'Collapsed'
            $controls.InstallPathCardBorder.Visibility = 'Visible'
            $controls.InstallProgressTitleText.Text = '流程进度'
            $controls.InstallProgressText.Text = @(
                '✓ 第 1 步：环境检测已通过'
                '→ 第 2 步：确认数据目录与安装目录'
                '○ 第 3 步：执行官方安装'
            ) -join [Environment]::NewLine
            $controls.InstallFailureSummaryText.Visibility = 'Collapsed'
            $controls.InstallFailureSummaryText.Text = ''
            $controls.InstallLocationNoticeText.Text = '安装完成后，这些路径会收纳到“更多设置”里查看。基础使用阶段不需要反复关注它们。'
            $controls.ChangeInstallLocationButton.IsEnabled = $true
            $controls.ConfirmInstallLocationButton.IsEnabled = $true
            $controls.ConfirmInstallLocationButton.Content = '确认安装位置'
            Set-InstallActionButtons -PrimaryActionId 'location-confirm' -PrimaryLabel '位置已确认，继续安装' -PrimaryEnabled $true -SecondaryActionId 'change-location' -SecondaryLabel '更改安装位置' -SecondaryEnabled $true -TertiaryActionId 'refresh' -TertiaryLabel '刷新状态' -TertiaryEnabled $true
        } else {
            $controls.InstallTaskCardBorder.Visibility = 'Visible'
            $controls.InstallProgressTitleText.Text = '安装前确认'
            $controls.InstallTaskTitleText.Text = '第 3 步：开始安装'
            $controls.InstallTaskBodyText.Text = '环境和路径都已确认。点击开始后，启动器会在独立 PowerShell 终端里调用官方安装脚本；成功会自动关闭，失败会保留终端，方便直接把报错反馈回来。'
            $controls.InstallProgressText.Text = @(
                '✓ 第 1 步：环境检测已通过'
                '✓ 第 2 步：安装位置已确认'
                '→ 第 3 步：等待执行官方安装'
            ) -join [Environment]::NewLine
            $controls.InstallFailureSummaryText.Visibility = if ($preflight.Warnings.Count -gt 0) { 'Visible' } else { 'Collapsed' }
            $controls.InstallFailureSummaryText.Text = if ($preflight.Warnings.Count -gt 0) { "提示：`n• " + ($preflight.Warnings -join "`n• ") } else { '' }
            Set-InstallActionButtons -PrimaryActionId 'install-external' -PrimaryLabel '开始安装' -PrimaryEnabled $true -SecondaryActionId 'change-location' -SecondaryLabel '更改安装位置' -SecondaryEnabled $true -TertiaryActionId 'refresh' -TertiaryLabel '刷新状态' -TertiaryEnabled $true
        }
    } else {
        Set-LauncherWindowMode -Mode 'Home'
        $controls.InstallModePanel.Visibility = 'Collapsed'
        $controls.HomeModePanel.Visibility = 'Visible'
        $controls.LogSectionBorder.Visibility = 'Collapsed'
        $controls.FooterBorder.Visibility = 'Collapsed'

        $controls.StatusHeadlineText.Text = '已就绪'
        $controls.StatusBodyText.Text = '点击”开始使用”打开 hermes-web-ui，在浏览器中完成模型配置和对话。'

        Set-PrimaryAction -ActionId 'launch' -Label '开始使用' -Enabled ([bool]$script:CurrentStatus.HermesCommand)
        Set-SecondaryAction -ActionId '' -Label '' -Enabled $false -Visible $false
        $controls.RecommendationText.Text = ''
        $controls.RecommendationHintText.Text = ''
    }
    Set-Footer ("Hermes 命令路径：{0}" -f $(if ($script:CurrentStatus.HermesCommand) { $script:CurrentStatus.HermesCommand } else { '未找到' }))
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
            if ($controls.InstallModePanel.Visibility -eq 'Visible') {
                Add-ActionLog -Action '刷新状态' -Result $controls.InstallTaskTitleText.Text -Next ($controls.InstallTaskBodyText.Text -replace '\r?\n', ' ')
            } else {
                Add-ActionLog -Action '刷新状态' -Result $controls.StatusHeadlineText.Text -Next ($controls.RecommendationText.Text -replace '\r?\n', '；')
            }
        }
        'browse-home' {
            Open-InExplorer -Path $hermesHome
            Add-ActionLog -Action '打开数据目录' -Result '已请求打开 Hermes 数据目录' -Next '可查看 .env、config.yaml 和 logs'
        }
        'browse-install' {
            Open-InExplorer -Path $installDir
            Add-ActionLog -Action '打开安装目录' -Result '已请求打开 Hermes 安装目录' -Next '可查看仓库源码与 venv'
        }
        'show-install-paths' {
            $message = @(
                "数据目录：$hermesHome"
                "安装目录：$installDir"
                ''
                '安装完成后可以继续从这里查看这些路径。'
                '如需改成新的安装位置，建议先卸载，再按新路径重新安装。'
            ) -join [Environment]::NewLine
            [System.Windows.MessageBox]::Show($message, '安装位置')
            Add-ActionLog -Action '查看安装位置' -Result '已显示当前数据目录和安装目录' -Next '如需调整，建议先卸载后按新路径重装'
        }
        'preflight-confirm' {
            $preflight = Get-CachedPreflight -InstallDir $installDir -HermesHome $hermesHome -ForceRefresh
            if (-not $preflight.CanInstall) {
                Add-ActionLog -Action '确认环境检测' -Result '环境检测仍存在阻塞项，不能继续' -Next ($preflight.Blocking -join '；')
                Refresh-Status
                return
            }
            $script:InstallPreflightConfirmed = $true
            Add-ActionLog -Action '确认环境检测' -Result '当前环境满足安装条件' -Next '继续确认安装位置'
            Refresh-Status
        }
        'change-location' {
            Show-InstallLocationDialog
        }
        'location-confirm' {
            $script:InstallLocationConfirmed = $true
            Add-ActionLog -Action '确认安装位置' -Result '已确认当前数据目录和安装目录' -Next '下一步可直接开始安装'
            Refresh-Status
        }
        'open-git-download' {
            Start-Process 'https://git-scm.com/download/win' | Out-Null
            Add-ActionLog -Action '打开 Git 下载页' -Result '已在浏览器中打开 Git for Windows 下载页' -Next '安装完成后回到启动器重新检测环境'
        }
        'install-git' {
            if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
                [System.Windows.MessageBox]::Show('未检测到 winget，无法自动安装 Git。请改用浏览器下载安装。', 'Hermes 启动器')
                return
            }
            if (-not (Confirm-TerminalAction -ActionTitle '自动安装 Git' -UserSteps @('等待 winget 自动下载并安装 Git。', '如果终端提示确认安装，请输入 Y 或按提示继续。', '安装完成后回到启动器点击“重新检测”。') -SuccessHint 'Git 安装好后，回到启动器重新检测环境。' -FailureHint '若网络较差或安装失败，终端会保留，可按终端报错改用浏览器安装 Git。')) {
                Add-ActionLog -Action '自动安装 Git' -Result '已取消打开终端' -Next '如需继续，可再次点击“自动安装 Git”'
                return
            }
            Start-InTerminal -WorkingDirectory $env:TEMP -HermesHome $hermesHome -CommandLine 'winget install --id Git.Git -e --source winget' | Out-Null
            Add-ActionLog -Action '自动安装 Git' -Result '已打开 winget 安装 Git 终端' -Next 'Git 安装完成后回到启动器重新检测环境'
        }
        'install-external' {
            if (-not $installDir -or -not $hermesHome -or -not $state.Branch) {
                [System.Windows.MessageBox]::Show('安装目录、数据目录和 Git 分支不能为空。', 'Hermes 启动器')
                return
            }
            if (-not $script:InstallPreflightConfirmed) {
                [System.Windows.MessageBox]::Show('请先完成环境检测并确认通过，再继续安装。', 'Hermes 启动器')
                return
            }
            if (-not $script:InstallLocationConfirmed) {
                [System.Windows.MessageBox]::Show('请先确认安装位置，再开始安装。', 'Hermes 启动器')
                return
            }
            $preflight = Test-InstallPreflight -InstallDir $installDir -HermesHome $hermesHome
            if (-not $preflight.CanInstall) {
                $controls.InstallFailureSummaryText.Visibility = 'Visible'
                $controls.InstallFailureSummaryText.Text = "阻塞项：`n• " + ($preflight.Blocking -join "`n• ")
                Add-ActionLog -Action '开始安装' -Result '安装前检测未通过' -Next ($preflight.Blocking -join '；')
                Refresh-Status
                return
            }
            try {
                if (-not (Confirm-TerminalAction -ActionTitle '安装 / 更新 Hermes' -UserSteps @('等待官方安装脚本执行完成。', '安装成功时终端会自动关闭。', '如果终端停住并显示报错，请保留终端，把报错和日志反馈出来。') -SuccessHint '安装结束后，启动器会自动刷新状态。' -FailureHint '失败时终端会保留，日志文件路径也会写入右侧日志区。')) {
                    Add-ActionLog -Action '安装 / 更新 Hermes' -Result '已取消打开终端' -Next '确认安装位置后，可再次点击“开始安装”'
                    return
                }
                Keep-LauncherVisible
                # 复用 preflight 中已完成的网络检测结果，避免重复等待
                $networkEnv = $preflight.NetworkEnv
                if ($networkEnv -eq 'china') {
                    Add-LogLine '网络检测：当前网络环境下，已自动切换到国内加速通道。'
                } elseif ($networkEnv -eq 'overseas') {
                    Add-LogLine '网络检测：网络畅通，使用官方源安装。'
                } else {
                    Add-LogLine '网络状态未知，将尝试直连官方源...'
                }
                # fallback 日志回调：切换源时写日志，让用户在日志区看到
                $fallbackLogger = {
                    param($fromUrl, $toUrl, $attemptIndex)
                    Add-LogLine "镜像源 $attemptIndex 失败，正在尝试备用源..."
                }
                $tempScript = New-TempScriptFromUrl -Url $defaults.OfficialInstallUrl -NetworkEnv $networkEnv -OnFallback $fallbackLogger
                $installArgs = Build-InstallArguments -InstallDir $installDir -HermesHome $hermesHome -Branch $state.Branch -NoVenv ([bool]$controls.NoVenvCheckBox.IsChecked) -SkipSetup ([bool]$controls.SkipSetupCheckBox.IsChecked)
                $wrapperScript = New-ExternalInstallWrapperScript -InstallScriptPath $tempScript -Arguments $installArgs
                $proc = Start-Process powershell.exe -PassThru -WorkingDirectory $env:TEMP -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapperScript)
                Start-ExternalInstallMonitor -Process $proc
                Add-ActionLog -Action '安装 / 更新 Hermes' -Result '已打开独立 PowerShell 安装终端。成功时终端会在 5 秒后自动关闭，失败时会保留终端供查看报错。' -Next '安装结束后启动器会自动刷新状态'
            } catch {
                Add-ActionLog -Action '改用外部终端安装' -Result ('启动安装脚本失败：' + $_.Exception.Message) -Next '检查网络连接或稍后重试；如持续失败请联系作者'
            }
        }
        'openclaw-preview' {
            if (-not $hermesCommand) {
                [System.Windows.MessageBox]::Show('未找到 Hermes 命令，请先安装 Hermes。', 'Hermes 启动器')
                return
            }
            if (-not (Confirm-TerminalAction -ActionTitle '预览旧版配置迁移结果' -UserSteps @('查看终端里会迁移哪些旧版配置。', '这个预览不会真正写入数据。', '看完后关闭终端，再决定是否执行正式迁移。') -SuccessHint '预览完成后回到启动器，可继续正式迁移。')) {
                Add-ActionLog -Action '预览迁移旧版配置' -Result '已取消打开终端' -Next '如需查看预览，可再次点击“预览迁移”'
                return
            }
            Start-InTerminal -WorkingDirectory $installDir -HermesHome $hermesHome -CommandLine ("& '$hermesCommand' claw migrate --dry-run") | Out-Null
            Save-LauncherState -HermesHome $hermesHome -OpenClawPreviewed $true
            Add-ActionLog -Action '预览迁移旧版配置' -Result '已打开官方 dry-run 终端，不会写入配置。' -Next '确认结果后，可继续正式迁移'
            Refresh-Status
        }
        'openclaw-migrate' {
            if (-not $hermesCommand) {
                [System.Windows.MessageBox]::Show('未找到 Hermes 命令，请先安装 Hermes。', 'Hermes 启动器')
                return
            }
            if (-not (Confirm-TerminalAction -ActionTitle '迁移旧版 OpenClaw 配置' -UserSteps @('等待官方迁移命令执行完成。', '迁移期间不要手动关闭终端。', '迁移完成后回到启动器刷新状态。') -SuccessHint '迁移完成后，就可以继续模型配置或开始对话。')) {
                Add-ActionLog -Action '迁移旧版 OpenClaw 配置' -Result '已取消打开终端' -Next '如需继续迁移，可再次点击“迁移旧版配置”'
                return
            }
            Start-InTerminal -WorkingDirectory $installDir -HermesHome $hermesHome -CommandLine ("& '$hermesCommand' claw migrate --preset full") | Out-Null
            Save-LauncherState -HermesHome $hermesHome -OpenClawPreviewed $true -OpenClawImported $true -OpenClawSkipped $false
            Add-ActionLog -Action '迁移旧版 OpenClaw 配置' -Result '已打开官方迁移终端。' -Next '迁移完成后回到启动器刷新状态'
            Refresh-Status
        }
        'openclaw-skip' {
            Save-LauncherState -HermesHome $hermesHome -OpenClawSkipped $true
            Add-ActionLog -Action '跳过旧版配置迁移' -Result '已跳过迁移。' -Next '现在可以继续模型配置或直接开始本地对话'
            Refresh-Status
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
            if (-not (Confirm-TerminalAction -ActionTitle '运行官方诊断' -UserSteps @('等待 doctor 输出检查结果。', '根据终端提示查看缺失依赖或配置问题。', '看完后回到启动器再刷新状态。') -SuccessHint '诊断窗口可以手动关闭。')) {
                Add-ActionLog -Action '运行 doctor' -Result '已取消打开终端' -Next '如需诊断，可再次点击“运行 doctor”'
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
            Start-LaunchAsync -InstallDir $installDir -HermesCommand $hermesCommand
        }
        'launch-webui' {
            Invoke-AppAction 'launch'
        }
        'launch-cli' {
            if (-not $hermesCommand) {
                [System.Windows.MessageBox]::Show('未找到 Hermes 命令，请先安装 Hermes。', 'Hermes 启动器')
                return
            }
            if (-not (Confirm-TerminalAction -ActionTitle '开始本地对话' -UserSteps @('终端打开后，直接在里面和 Hermes 对话。', '结束对话时可输入 exit，或按 Ctrl+C。') -SuccessHint '关闭终端后回到启动器。')) {
                Add-ActionLog -Action '开始命令行对话' -Result '已取消打开终端' -Next '准备好后可再次点击”打开命令行对话”'
                return
            }
            Start-InTerminal -WorkingDirectory $installDir -HermesHome $hermesHome -CommandLine (“& '$hermesCommand'”) | Out-Null
            Add-ActionLog -Action '开始命令行对话' -Result '已打开 Hermes 本地对话终端' -Next '如需通过 hermes-web-ui 对话，可点击”开始使用”'
            Refresh-Status
        }
        'open-webui-logs' {
            $webUiDefaults = Get-HermesWebUiDefaults
            Open-InExplorer -Path $webUiDefaults.LogsDir
            Add-ActionLog -Action '打开 WebUI 日志' -Result '已请求打开 WebUI 日志目录' -Next '可查看 stdout/stderr 日志'
        }
        'open-webui-dir' {
            $webUiDefaults = Get-HermesWebUiDefaults
            Open-InExplorer -Path $webUiDefaults.WebUiHome
            Add-ActionLog -Action '打开 WebUI 目录' -Result '已请求打开 WebUI 安装目录' -Next '可查看 hermes-web-ui 文件'
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
        'open-docs' {
            Start-Process $defaults.OfficialDocsUrl | Out-Null
            Add-ActionLog -Action '打开官方文档' -Result '已在浏览器中打开 Hermes 文档' -Next '需要核对命令和配置项时再使用'
        }
        'open-repo' {
            Start-Process $defaults.OfficialRepoUrl | Out-Null
            Add-ActionLog -Action '打开官方仓库' -Result '已在浏览器中打开 Hermes GitHub 仓库' -Next '需要查看源码或官方 README 时再使用'
        }
        'update' {
            if (-not $hermesCommand) { return }
            if (-not (Confirm-TerminalAction -ActionTitle '更新 Hermes' -UserSteps @('等待 update 执行完成。', '更新结束后回到启动器刷新状态。') -SuccessHint '更新窗口可以在确认完成后手动关闭。')) {
                Add-ActionLog -Action '运行 update' -Result '已取消打开终端' -Next '需要时可再次点击“运行 update”'
                return
            }
            Start-InTerminal -WorkingDirectory $installDir -HermesHome $hermesHome -CommandLine ("& '$hermesCommand' update") | Out-Null
            Add-ActionLog -Action '运行 update' -Result '已打开 `hermes update` 终端' -Next '更新后回到启动器刷新状态'
        }
        'tools' {
            if (-not $hermesCommand) { return }
            if (-not (Confirm-TerminalAction -ActionTitle '配置 Tools 能力' -UserSteps @('按终端提示选择要启用的联网搜索、浏览器、图片或语音能力。', '需要的 API Key 请按提示填写。', '配置完成后关闭终端，回到启动器继续。') -SuccessHint '配置完 tools 后，可再运行 doctor 或直接使用。')) {
                Add-ActionLog -Action '配置 tools' -Result '已取消打开终端' -Next '需要时可再次点击“配置 tools”'
                return
            }
            Start-InTerminal -WorkingDirectory $installDir -HermesHome $hermesHome -CommandLine ("& '$hermesCommand' tools") | Out-Null
            Add-ActionLog -Action '配置 tools' -Result '已打开 `hermes tools` 终端' -Next '按需配置联网搜索、浏览器、图片和语音能力'
        }
        'full-setup' {
            if (-not $hermesCommand) { return }
            if (-not (Confirm-TerminalAction -ActionTitle '运行完整 setup' -UserSteps @('按官方 setup 菜单逐项完成配置。', '这个过程会涉及模型、渠道和其他能力的完整重配。', '完成后关闭终端，再回到启动器刷新状态。') -SuccessHint '完整 setup 更适合高级用户或重装场景。')) {
                Add-ActionLog -Action '完整 setup' -Result '已取消打开终端' -Next '需要时可再次点击“完整 setup”'
                return
            }
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
$controls.CopyFeedbackButton.Add_Click({
    [System.Windows.Clipboard]::SetText((Get-InstallFeedbackText))
    Add-ActionLog -Action '复制反馈信息' -Result '已复制当前状态、安装检测结果和最近日志' -Next '直接发给开发者即可'
})
$controls.RefreshButton.Add_Click({ Invoke-AppAction 'refresh' })
$controls.PrimaryActionButton.Add_Click({ Invoke-AppAction $script:PrimaryActionId })
$controls.SecondaryActionButton.Add_Click({
    if ($controls.SecondaryActionButton.Tag) {
        Invoke-AppAction ([string]$controls.SecondaryActionButton.Tag)
    }
})
$controls.StartInstallPageButton.Add_Click({
    if ($script:InstallPrimaryActionId) {
        Invoke-AppAction $script:InstallPrimaryActionId
    }
})
$controls.InstallRefreshButton.Add_Click({
    if ($script:InstallTertiaryActionId) {
        Invoke-AppAction $script:InstallTertiaryActionId
    }
})
$controls.InstallRequirementsButton.Add_Click({
    if ($script:InstallSecondaryActionId) {
        Invoke-AppAction $script:InstallSecondaryActionId
    }
})
$controls.ChangeInstallLocationButton.Add_Click({
    Show-InstallLocationDialog
})
$controls.ConfirmInstallLocationButton.Add_Click({
    Invoke-AppAction 'location-confirm'
})
$controls.SaveInstallSettingsButton.Add_Click({
    $script:InstallLocationConfirmed = $false
    $controls.InstallSettingsEditorBorder.Visibility = 'Collapsed'
    Update-InstallPathSummary
    Add-ActionLog -Action '保存安装位置' -Result '已保存安装路径和安装选项' -Next '确认安装位置后再开始安装'
    Request-StatusRefresh
})
$controls.ResetInstallSettingsButton.Add_Click({
    $controls.HermesHomeTextBox.Text = $defaults.HermesHome
    $controls.InstallDirTextBox.Text = $defaults.InstallDir
    $controls.BranchTextBox.Text = 'main'
    $controls.NoVenvCheckBox.IsChecked = $false
    $controls.SkipSetupCheckBox.IsChecked = $true
    $script:InstallLocationConfirmed = $false
    Update-InstallPathSummary
})
$controls.StageModelButton.Add_Click({ Invoke-AppAction 'launch' })
$controls.StageAdvancedButton.Add_Click({ Show-AdvancedPanel })
$controls.OpenClawImportButton.Add_Click({ Invoke-AppAction 'openclaw-migrate' })
$controls.OpenClawSkipButton.Add_Click({ Invoke-AppAction 'openclaw-skip' })

$controls.HermesHomeTextBox.Add_TextChanged({
    $script:InstallPreflightConfirmed = $false
    $script:InstallLocationConfirmed = $false
    Update-InstallPathSummary
    Request-StatusRefresh
})
$controls.InstallDirTextBox.Add_TextChanged({
    $script:InstallPreflightConfirmed = $false
    $script:InstallLocationConfirmed = $false
    Update-InstallPathSummary
    Request-StatusRefresh
})
$controls.BranchTextBox.Add_TextChanged({
    $script:InstallLocationConfirmed = $false
    Update-InstallPathSummary
    Request-StatusRefresh
})

Add-LogLine ("启动器已就绪。版本：{0}" -f $script:LauncherVersion)
try {
    Refresh-Status
} catch {
    Add-LogLine ("启动时状态刷新失败：{0}" -f $_.Exception.Message)
}
try {
    $window.ShowDialog() | Out-Null
} finally {
    try { Stop-HermesWebUiRuntime | Out-Null } catch { }
    if ($script:LauncherMutex) {
        $script:LauncherMutex.ReleaseMutex()
        $script:LauncherMutex.Dispose()
    }
}
