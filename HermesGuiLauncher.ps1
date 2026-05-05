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

$script:LauncherVersion = 'Windows v2026.05.04.18'

# P1-2-LITE fix: strict mode 下必须预初始化，否则 Stop-InstallSpinner 读未设置变量会抛
$script:InstallSpinnerTimer  = $null
$script:InstallSpinnerFrames = @()
$script:InstallSpinnerIdx    = 0

# === UI 字体路径（任务 012：bundle Quicksand 圆体 + 中文走 Microsoft YaHei UI） ===
# WPF FontFamily 多 family fallback 链：英文/数字走 Quicksand，中文走 YaHei UI；字体目录缺失时退回纯系统字体。
$script:UiFontFolder = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'assets\fonts' } else { Join-Path (Get-Location).Path 'assets\fonts' }
$script:UiFontBundleAvailable = $false
try {
    if (Test-Path (Join-Path $script:UiFontFolder 'Quicksand-Regular.ttf')) {
        $script:UiFontBundleAvailable = $true
    }
} catch { $script:UiFontBundleAvailable = $false }

if ($script:UiFontBundleAvailable) {
    # WPF 字体路径写法：file:///D:/.../assets/fonts/#Quicksand（最后必须有 / 再 #FamilyName）
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $folderWithSep = if ($script:UiFontFolder.EndsWith($sep)) { $script:UiFontFolder } else { $script:UiFontFolder + $sep }
    $folderUri = ([System.Uri]::new($folderWithSep)).AbsoluteUri
    $script:UiFontFamily = "$folderUri#Quicksand, Microsoft YaHei UI, Segoe UI Variable Display, Segoe UI"
} else {
    $script:UiFontFamily = 'Microsoft YaHei UI, Segoe UI Variable Display, Segoe UI'
}
$script:UiMonoFontFamily = 'JetBrains Mono, Cascadia Code, Consolas, Microsoft YaHei UI'

$script:HermesWebUiHost = '127.0.0.1'
$script:HermesWebUiPort = 8648
$script:HermesWebUiNpmPackage = 'hermes-web-ui'
$script:HermesWebUiVersion = '0.5.9'
$script:NodeMinVersion = 'v23.0.0'
$script:NodeDownloadUrl = 'https://nodejs.org/dist/v23.11.0/node-v23.11.0-win-x64.zip'
$script:NodeExpectedDir = 'node-v23.11.0-win-x64'
$script:GatewayProcess = $null
$script:GatewayHermesExe = $null
$script:EnvWatcher = $null
$script:EnvWatcherTimer = $null
# 任务 014 Bug A：FileSystemWatcher 在防病毒拦截 / 跨盘符 / 网络盘等场景可能失效，
# 加 60 秒 polling 兜底，靠 LastWriteTimeUtc + Length 比较检测 .env 变化。
$script:EnvWatcherPollingTimer = $null
$script:EnvWatcherLastSig       = $null
# 任务 014 Bug A：渠道依赖最近一次安装失败信息（用于 Home Mode 红色横幅 + 详情弹窗）
$script:LastDepInstallFailure = $null
$script:LaunchTimer = $null
$script:LaunchState = $null

# === 匿名遥测（任务 011） ===
# Worker 自定义域名（任务 011 返工 F3）。绑定方式见 worker/wrangler.toml [[routes]]。
# 不再使用 *.workers.dev 子域，PM 部署后无需回头改代码重打包。
$script:TelemetryEndpoint        = 'https://telemetry.aisuper.win/api/telemetry'
$script:TelemetryHttpClient      = $null
$script:TelemetryHttpClientInited = $false
$script:AnonymousId              = $null
$script:CachedTelemetrySettings  = $null
$script:LauncherStartTimeUtc     = [DateTime]::UtcNow
$script:TelemetryFiredFlags      = @{}

try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { }

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

# ====================================================================
# 匿名遥测（任务 011）
# 所有函数全程 try-catch 吞异常，绝不影响主 UI（陷阱 #1）。
# 隐私：上报前所有字符串走 Sanitize-TelemetryString 脱敏。
# ====================================================================

function Get-TelemetryStorageInfo {
    $dir = Join-Path $env:APPDATA 'HermesLauncher'
    return @{
        Dir        = $dir
        IdFile     = (Join-Path $dir 'anonymous_id')
        SettingsFile = (Join-Path $dir 'settings.json')
    }
}

function Get-OrCreateAnonymousId {
    if ($script:AnonymousId) { return $script:AnonymousId }
    try {
        $info = Get-TelemetryStorageInfo
        if (Test-Path $info.IdFile) {
            $existing = ([System.IO.File]::ReadAllText($info.IdFile)).Trim()
            if ($existing -match '^[A-Za-z0-9-]{8,64}$') {
                $script:AnonymousId = $existing
                return $existing
            }
        }
        if (-not (Test-Path $info.Dir)) {
            New-Item -ItemType Directory -Path $info.Dir -Force | Out-Null
        }
        $newId = [guid]::NewGuid().ToString('N')  # 32 hex chars
        # UTF-8 无 BOM（陷阱 #21）
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($info.IdFile, $newId, $utf8)
        $script:AnonymousId = $newId
        return $newId
    } catch {
        $sessId = 'session-' + [guid]::NewGuid().ToString('N').Substring(0, 16)
        $script:AnonymousId = $sessId
        return $sessId
    }
}

function Load-TelemetrySettings {
    try {
        $info = Get-TelemetryStorageInfo
        if (Test-Path $info.SettingsFile) {
            $json = [System.IO.File]::ReadAllText($info.SettingsFile)
            $obj = $json | ConvertFrom-Json
            $hasTelemetry = $obj.PSObject.Properties['telemetry_enabled']
            $hasConsent = $obj.PSObject.Properties['first_run_consent_shown']
            return [pscustomobject]@{
                TelemetryEnabled     = if ($hasTelemetry) { [bool]$obj.telemetry_enabled } else { $true }
                FirstRunConsentShown = if ($hasConsent) { [bool]$obj.first_run_consent_shown } else { $false }
            }
        }
    } catch { }
    return [pscustomobject]@{ TelemetryEnabled = $true; FirstRunConsentShown = $false }
}

function Save-TelemetrySettings {
    param(
        $TelemetryEnabled,
        $FirstRunConsentShown
    )
    try {
        $current = Load-TelemetrySettings
        $info = Get-TelemetryStorageInfo
        if (-not (Test-Path $info.Dir)) {
            New-Item -ItemType Directory -Path $info.Dir -Force | Out-Null
        }
        $payload = [ordered]@{
            telemetry_enabled       = if ($PSBoundParameters.ContainsKey('TelemetryEnabled')) { [bool]$TelemetryEnabled } else { [bool]$current.TelemetryEnabled }
            first_run_consent_shown = if ($PSBoundParameters.ContainsKey('FirstRunConsentShown')) { [bool]$FirstRunConsentShown } else { [bool]$current.FirstRunConsentShown }
        } | ConvertTo-Json -Compress
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($info.SettingsFile, $payload, $utf8)
        $script:CachedTelemetrySettings = $null
    } catch { }
}

function Get-TelemetryEnabled {
    if ($null -eq $script:CachedTelemetrySettings) {
        $script:CachedTelemetrySettings = Load-TelemetrySettings
    }
    return [bool]$script:CachedTelemetrySettings.TelemetryEnabled
}

function Set-TelemetryEnabled {
    param([bool]$Enabled)
    Save-TelemetrySettings -TelemetryEnabled $Enabled
}

function Get-FirstRunConsentShown {
    if ($null -eq $script:CachedTelemetrySettings) {
        $script:CachedTelemetrySettings = Load-TelemetrySettings
    }
    return [bool]$script:CachedTelemetrySettings.FirstRunConsentShown
}

function Mark-FirstRunConsentShown {
    Save-TelemetrySettings -FirstRunConsentShown $true
}

function Get-WindowsVersionCategory {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $caption = [string]$os.Caption
        if ($caption -match 'Server') { return 'Windows-Server' }
        # Windows 11 detection: BuildNumber >= 22000
        $build = 0
        [int]::TryParse([string]$os.BuildNumber, [ref]$build) | Out-Null
        if ($build -ge 22000) { return 'Windows-11' }
        if ($caption -match 'Windows 10' -or ($build -ge 10000 -and $build -lt 22000)) { return 'Windows-10' }
        if ($caption -match 'Windows 8') { return 'Windows-8' }
        if ($caption -match 'Windows 7') { return 'Windows-7' }
        return 'Windows-Other'
    } catch {
        return 'unknown'
    }
}

function Get-MemoryCategory {
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $totalGb = [math]::Round([double]$cs.TotalPhysicalMemory / 1GB, 0)
        if ($totalGb -lt 8) { return 'lt-8gb' }
        if ($totalGb -le 16) { return '8-16gb' }
        return 'gt-16gb'
    } catch {
        return 'unknown'
    }
}

function Sanitize-TelemetryString {
    param([object]$Text)
    if ($null -eq $Text) { return '' }
    $s = [string]$Text
    if (-not $s) { return '' }
    # 0. URL 编码先解码再让后面的路径/用户名规则接得住（任务 011 返工 F1）
    #    必须放在 §3 路径规则之前，否则 %5CUsers%5C74431 这类 escape 字符串绕过路径正则
    $s = $s -replace '%5C','\' -replace '%5c','\' -replace '%2F','/' -replace '%2f','/' -replace '%3A',':' -replace '%3a',':'
    # 1. 已知敏感字段：sk-xxx / api_key=xxx / token=xxx / password=xxx / Bearer xxx
    $s = [regex]::Replace($s, '(sk-|sk_)[A-Za-z0-9_\-]+',                      '${1}<REDACTED>')
    # GitHub PAT 全家（ghp_/gho_/ghu_/ghs_/ghr_，任务 011 返工 F1）
    $s = [regex]::Replace($s, '\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}',      '${1}_<REDACTED>')
    # Google API key（AIza... + 30+ 字符，任务 011 返工 F1）
    $s = [regex]::Replace($s, '\bAIza[0-9A-Za-z_\-]{30,}',                     '<REDACTED>')
    $s = [regex]::Replace($s, '(api[_-]?key\s*[=:]\s*)\S+',                    '${1}<REDACTED>', 'IgnoreCase')
    $s = [regex]::Replace($s, '(token\s*[=:]\s*)\S+',                          '${1}<REDACTED>', 'IgnoreCase')
    $s = [regex]::Replace($s, '(password\s*[=:]\s*)\S+',                       '${1}<REDACTED>', 'IgnoreCase')
    $s = [regex]::Replace($s, '(secret\s*[=:]\s*)\S+',                         '${1}<REDACTED>', 'IgnoreCase')
    $s = [regex]::Replace($s, '(Bearer\s+)\S+',                                '${1}<REDACTED>', 'IgnoreCase')
    $s = [regex]::Replace($s, '(Authorization\s*[=:]\s*)\S+',                  '${1}<REDACTED>', 'IgnoreCase')
    # JSON 风格 password / token / secret / api_key（任务 011 返工 F1）
    $s = [regex]::Replace($s, '"(password|token|secret|api[_-]?key)"\s*:\s*"[^"]*"', '"$1":"<REDACTED>"', 'IgnoreCase')
    # 2. 用户名（来自 $env:USERNAME），最长优先替换
    try {
        $username = $env:USERNAME
        if ($username -and $username.Length -ge 2) {
            $s = [regex]::Replace($s, [regex]::Escape($username), '<USER>', 'IgnoreCase')
        }
    } catch { }
    # 3. 用户路径段：C:\Users\xxx\... 和 POSIX /home/xxx/, /Users/xxx/, 以及 C:/Users/xxx/（正斜杠）
    $s = [regex]::Replace($s, '([A-Za-z]:\\Users\\)[^\\\s/]+',  '${1}<USER>', 'IgnoreCase')
    $s = [regex]::Replace($s, '([A-Za-z]:/Users/)[^/\\\s]+',    '${1}<USER>', 'IgnoreCase')
    $s = [regex]::Replace($s, '(/(?:Users|home)/)[^/\s]+',      '${1}<USER>', 'IgnoreCase')
    # 4. 邮箱
    $s = [regex]::Replace($s, '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', '<EMAIL>')
    # 5. IPv4 + IPv6（任务 011 返工 F1：补 IPv6 粗匹配）
    $s = [regex]::Replace($s, '\b(?:\d{1,3}\.){3}\d{1,3}\b', '<IP>')
    $s = [regex]::Replace($s, '(?<![A-Za-z0-9])(?:[0-9a-fA-F]{1,4}:){2,}[0-9a-fA-F:]+', '<IP>')
    # 6. 截断
    if ($s.Length -gt 500) { $s = $s.Substring(0, 500) + '...' }
    return $s
}

function Sanitize-TelemetryProperties {
    param([hashtable]$Properties)
    $out = @{}
    if (-not $Properties) { return $out }
    foreach ($key in @($Properties.Keys)) {
        $value = $Properties[$key]
        if ($null -eq $value) { continue }
        if ($value -is [bool] -or $value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) {
            $out[[string]$key] = $value
        } elseif ($value -is [array] -or $value -is [System.Collections.IList]) {
            $list = @()
            foreach ($item in $value) {
                if ($item -is [string]) { $list += (Sanitize-TelemetryString $item) }
                elseif ($item -is [bool] -or $item -is [int] -or $item -is [long] -or $item -is [double]) { $list += $item }
                else { $list += (Sanitize-TelemetryString ([string]$item)) }
            }
            $out[[string]$key] = $list
        } else {
            $out[[string]$key] = Sanitize-TelemetryString ([string]$value)
        }
    }
    return $out
}

function Initialize-TelemetryHttpClient {
    if ($script:TelemetryHttpClientInited) { return }
    $script:TelemetryHttpClientInited = $true
    try {
        if ([System.Net.Http.HttpClient]) {
            $handler = New-Object System.Net.Http.HttpClientHandler
            try { $handler.AllowAutoRedirect = $true } catch { }
            $client = New-Object System.Net.Http.HttpClient($handler)
            $client.Timeout = [TimeSpan]::FromSeconds(8)
            $script:TelemetryHttpClient = $client
        }
    } catch {
        $script:TelemetryHttpClient = $null
    }
}

function Send-Telemetry {
    <#
    .SYNOPSIS
    异步上报一个匿名事件。失败完全静默。
    .PARAMETER EventName
    事件名（必须匹配 Worker 端 VALID_EVENTS 白名单）
    .PARAMETER Properties
    任意 hashtable，上报前会脱敏所有字符串
    .PARAMETER FailureReason
    失败事件的 reason，自动放入 properties.reason 并脱敏
    #>
    param(
        [Parameter(Mandatory = $true)][string]$EventName,
        [hashtable]$Properties,
        [string]$FailureReason
    )
    try {
        if (-not (Get-TelemetryEnabled)) { return }
        if (-not $script:TelemetryEndpoint) { return }

        $props = Sanitize-TelemetryProperties -Properties $Properties
        if ($PSBoundParameters.ContainsKey('FailureReason') -and $FailureReason) {
            $props['reason'] = Sanitize-TelemetryString $FailureReason
        }

        $payload = [ordered]@{
            event_name       = $EventName
            anonymous_id     = Get-OrCreateAnonymousId
            version          = $script:LauncherVersion
            os_version       = Get-WindowsVersionCategory
            memory_category  = Get-MemoryCategory
            client_timestamp = [int][double](([DateTimeOffset](Get-Date)).ToUnixTimeSeconds())
            properties       = $props
        }
        $json = $payload | ConvertTo-Json -Depth 5 -Compress

        Initialize-TelemetryHttpClient
        if (-not $script:TelemetryHttpClient) { return }

        $content = New-Object System.Net.Http.StringContent($json, [System.Text.UTF8Encoding]::new($false), 'application/json')
        $task = $script:TelemetryHttpClient.PostAsync($script:TelemetryEndpoint, $content)
        # Fire-and-forget continuation — dispose content + 吞所有异常
        $task.ContinueWith({
            param($t)
            try { $content.Dispose() } catch { }
            if ($t.IsFaulted) {
                try { $t.Exception.Handle({ param($e) $true }) } catch { }
            }
        }) | Out-Null
    } catch {
        # 绝不能让上报失败抛到 UI 线程（陷阱 #1）
    }
}

function Send-TelemetryOnce {
    <#
    .SYNOPSIS
    单次会话内只触发一次同名事件，避免重复上报（如 webui_started 在多次健康检查时只发 1 次）
    #>
    param(
        [Parameter(Mandatory = $true)][string]$EventName,
        [hashtable]$Properties,
        [string]$FailureReason
    )
    try {
        if ($script:TelemetryFiredFlags.ContainsKey($EventName) -and $script:TelemetryFiredFlags[$EventName]) {
            return
        }
        $script:TelemetryFiredFlags[$EventName] = $true
        $params = @{ EventName = $EventName }
        if ($PSBoundParameters.ContainsKey('Properties')) { $params.Properties = $Properties }
        if ($PSBoundParameters.ContainsKey('FailureReason')) { $params.FailureReason = $FailureReason }
        Send-Telemetry @params
    } catch { }
}

function Get-LauncherUptimeSeconds {
    try {
        return [int]([DateTime]::UtcNow - $script:LauncherStartTimeUtc).TotalSeconds
    } catch { return 0 }
}

# === 匿名遥测结束 ===


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
    # 任务 014 Bug B (v2026.05.04.5):改用 TCP 端口探测代替 Invoke-WebRequest /health。
    # 见陷阱 #42。Windows IPv4 loopback 上 .NET Invoke-WebRequest / HttpClient 第一次连接
    # 固定 ~1.4 秒延迟(curl / 浏览器没有),launcher 用 -TimeoutSec 1 几乎必超时,导致:
    #   - SelfTest 永远 WebUi.Healthy:false
    #   - 启动后 30 秒等 /health 通过必超时 → 弹窗"hermes-web-ui 启动失败"
    # 但 webui 实际完全正常(浏览器能加载,curl 瞬间 200)。
    # TCP 端口探测 0-22ms 瞬间完成,语义"webui 已绑端口"=用户浏览器能连,准确度足够。
    $url = "http://$($script:HermesWebUiHost):$($script:HermesWebUiPort)"
    $portUp = $false
    $tcp = $null
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $task = $tcp.ConnectAsync($script:HermesWebUiHost, $script:HermesWebUiPort)
        if ($task.Wait(500) -and $tcp.Connected) { $portUp = $true }
    } catch { } finally {
        if ($tcp) { try { $tcp.Close() } catch { } }
    }
    if ($portUp) {
        return [pscustomobject]@{
            Healthy = $true
            Url     = $url
            Message = 'hermes-web-ui 正在运行。'
        }
    }
    return [pscustomobject]@{
        Healthy = $false
        Url     = $url
        Message = 'hermes-web-ui 未响应。'
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

    # Map: env-var-that-enables-platform → Python module name → pip-package-name
    # 任务 014 Bug A.4: 改用 ModuleName + 严格 __file__ 校验,防止其他同名模块（如 tqdm.contrib.telegram
    # 之类不在 site-packages 根的同名模块）让 import 成功但实际目标包没装 → 误判跳过安装。
    # PM 真机 v2026.05.04.1/2026.05.04.2 仍踩到的 bug:webui 显示"Telegram 已配置",但 site-packages 里
    # 没有 python-telegram-bot,gateway 日志一直 "No adapter available for telegram"。
    $platformDeps = @(
        @{ EnvKey = 'FEISHU_APP_ID';       ModuleName = 'lark_oapi';        Package = 'lark-oapi' }
        @{ EnvKey = 'TELEGRAM_BOT_TOKEN';   ModuleName = 'telegram';         Package = 'python-telegram-bot' }
        @{ EnvKey = 'SLACK_BOT_TOKEN';      ModuleName = 'slack_bolt';       Package = 'slack-bolt' }
        @{ EnvKey = 'DINGTALK_CLIENT_ID';   ModuleName = 'dingtalk_stream';  Package = 'dingtalk-stream' }
        @{ EnvKey = 'DISCORD_BOT_TOKEN';    ModuleName = 'discord';          Package = 'discord.py' }
    )

    # 任务 014 Bug A.4: 严格校验某个 Python 模块是否真的装在 venv site-packages 里。
    # 不能只看 import 是否成功 —— 真机复现:`import telegram` 在不装 python-telegram-bot 时仍可能
    # succeed(被 cwd / PYTHONPATH / sys.path 上的同名文件兜住),launcher 误以为已装跳过 install。
    # 现在校验 module.__file__ 必须在 venv site-packages 里,否则视同未装。
    $expectedSitePackages = (Join-Path $HermesInstallDir 'venv\Lib\site-packages').ToLower()
    $expectedSitePackagesEsc = $expectedSitePackages.Replace('\', '\\')
    $verifyTemplate = @"
import sys
try:
    m = __import__('{0}')
    p = (getattr(m, '__file__', '') or '').lower()
    expected = '{1}'
    if p and expected in p:
        print('OK')
    else:
        print('PATH_MISMATCH:' + str(p))
        sys.exit(2)
except ImportError as e:
    print('IMPORT_ERROR:' + str(e))
    sys.exit(1)
except Exception as e:
    print('UNEXPECTED_ERROR:' + str(e))
    sys.exit(3)
"@

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

    # 任务 014 Bug A.3：渠道 EnvKey → 中文展示名（失败横幅文案用）
    $channelLabels = @{
        'FEISHU_APP_ID'      = '飞书'
        'TELEGRAM_BOT_TOKEN' = 'Telegram'
        'SLACK_BOT_TOKEN'    = 'Slack'
        'DINGTALK_CLIENT_ID' = '钉钉'
        'DISCORD_BOT_TOKEN'  = 'Discord'
    }

    # 任务 014 Bug A.5 (v2026.05.04.4 紧急修复): 全文件级别 $ErrorActionPreference='Stop'
    # 会让 native command (uv / python) 写 stderr 时被 PowerShell 包成 NativeCommandError 抛异常,
    # 直接进 catch 块 → install 根本没等跑完就报"安装失败"。
    # uv pip install 的进度信息("Using Python 3.13.12 environment at: ...")是写 stderr 的,必触发。
    # 修复:在 foreach 期间局部切 EAP='Continue',只看 $LASTEXITCODE,出函数前 finally 还原。
    # 见陷阱 #41。
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
    foreach ($dep in $platformDeps) {
        # Check if this platform is configured in .env (uncommented, with a value)
        $configured = $envLines | Where-Object { $_ -match "^\s*$($dep.EnvKey)\s*=\s*.+" }
        if (-not $configured) { continue }

        # 任务 014 Bug A.4: 严格校验,不再只看 exit code(防止 cwd 同名模块伪造已装)
        $verifyScript = $verifyTemplate -f $dep.ModuleName, $expectedSitePackagesEsc
        $result = & $pythonExe -c $verifyScript 2>&1
        $verifyOk = ($LASTEXITCODE -eq 0 -and ($result -join '') -match 'OK')
        if ($verifyOk) {
            # 任务 014 Bug A.3：该渠道依赖已就绪 → 清除以前的失败记录（如有）
            if ($script:LastDepInstallFailure -and $script:LastDepInstallFailure.EnvKey -eq $dep.EnvKey) {
                $script:LastDepInstallFailure = $null
            }
            continue
        }
        # 记录原因(用于诊断:是 ImportError 还是 PATH_MISMATCH)
        $verifyReason = ($result -join ' | ')
        Add-LogLine ("渠道依赖 {0} 严格校验未通过: {1}" -f $dep.Package, $verifyReason)

        # Package missing — install it
        Add-LogLine ("正在安装渠道依赖：{0}..." -f $dep.Package)
        $installFailed = $false
        $exitCode = -1
        $installOutputText = ''
        try {
            $uvExe = Resolve-UvCommand
            # Also check uv inside the hermes venv Scripts dir
            if (-not $uvExe) {
                $venvUv = Join-Path $HermesInstallDir 'venv\Scripts\uv.exe'
                if (Test-Path $venvUv) { $uvExe = $venvUv }
            }
            if ($uvExe) {
                $installOutput = & $uvExe pip install $dep.Package --python $pythonExe 2>&1
                $installOutputText = ($installOutput | Out-String)
                Add-LogLine ("uv 安装输出：{0}" -f ($installOutput | Select-Object -Last 3 | Out-String).Trim())
            } else {
                $installOutput = & $pythonExe -m pip install $dep.Package 2>&1
                $installOutputText = ($installOutput | Out-String)
                Add-LogLine ("pip 安装输出：{0}" -f ($installOutput | Select-Object -Last 3 | Out-String).Trim())
            }
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0) {
                # 任务 014 Bug A.4: 安装"成功"后再用严格校验确认包真的进了 venv site-packages。
                # 防止 uv exit 0 但实际什么也没装(cache 命中但已损坏 / 网络代理静默吞失败 / 装到全局 site-packages 而非 venv)。
                $postVerifyScript = $verifyTemplate -f $dep.ModuleName, $expectedSitePackagesEsc
                $postVerifyResult = & $pythonExe -c $postVerifyScript 2>&1
                $postVerifyOk = ($LASTEXITCODE -eq 0 -and ($postVerifyResult -join '') -match 'OK')
                if ($postVerifyOk) {
                    Add-LogLine ("{0} 安装成功(已严格校验包路径)" -f $dep.Package)
                    $anyInstalled = $true
                    # 任务 014 Bug A.3：本渠道刚装上 → 清除失败记录
                    if ($script:LastDepInstallFailure -and $script:LastDepInstallFailure.EnvKey -eq $dep.EnvKey) {
                        $script:LastDepInstallFailure = $null
                    }
                } else {
                    $installFailed = $true
                    $postVerifyReason = ($postVerifyResult -join ' | ')
                    $installOutputText = $installOutputText + "`n[POST-VERIFY-FAILED] " + $postVerifyReason
                    Add-LogLine ("{0} 安装命令 exit 0 但严格校验仍未通过: {1}" -f $dep.Package, $postVerifyReason)
                }
            } else {
                $installFailed = $true
                Add-LogLine ("{0} 安装失败（退出码 {1}），该渠道可能无法使用" -f $dep.Package, $exitCode)
            }
        } catch {
            $installFailed = $true
            $installOutputText = $_.Exception.ToString()
            Add-LogLine ("{0} 安装失败：{1}" -f $dep.Package, $_.Exception.Message)
        }

        # 任务 014 Bug A.3：失败时显式上报 + 写 $script:LastDepInstallFailure（让 UI 横幅显示）
        if ($installFailed) {
            $label = if ($channelLabels.ContainsKey($dep.EnvKey)) { $channelLabels[$dep.EnvKey] } else { $dep.Package }
            $errTail = ''
            try {
                $allLines = $installOutputText -split "`r?`n" | Where-Object { $_ -ne $null -and $_ -ne '' }
                $tailLines = @($allLines | Select-Object -Last 50)
                $errTail = ($tailLines -join [Environment]::NewLine)
            } catch { $errTail = [string]$installOutputText }

            $script:LastDepInstallFailure = [pscustomobject]@{
                EnvKey       = $dep.EnvKey
                ChannelLabel = $label
                Package      = $dep.Package
                ExitCode     = $exitCode
                ErrorTail    = $errTail
                Timestamp    = (Get-Date).ToString('s')
            }

            try {
                Send-Telemetry -EventName 'platform_dep_install_failed' -Properties @{
                    channel    = $dep.EnvKey
                    package    = $dep.Package
                    exit_code  = $exitCode
                    error_tail = $errTail
                }
            } catch { }
        }
    }
    } finally {
        # 任务 014 Bug A.5: 还原 EAP,防止泄漏到调用方
        $ErrorActionPreference = $savedErrorActionPreference
    }
    return $anyInstalled
}

function Show-DepInstallFailureDialog {
    <#
    .SYNOPSIS
    任务 014 Bug A.3：弹窗显示最近一次渠道依赖安装失败的详细错误尾部 + 复制按钮。
    点击 Home Mode 红色横幅 / 「查看详情」按钮触发。
    #>
    try {
        if (-not $script:LastDepInstallFailure) {
            [System.Windows.MessageBox]::Show('当前没有需要查看的渠道依赖错误。', 'Hermes 启动器') | Out-Null
            return
        }
        $info = $script:LastDepInstallFailure
        $body = @(
            ("渠道：{0}" -f $info.ChannelLabel)
            ("Python 包：{0}" -f $info.Package)
            ("退出码：{0}" -f $info.ExitCode)
            ("时间：{0}" -f $info.Timestamp)
            ''
            '错误尾部（最后 50 行）：'
            ([string]$info.ErrorTail)
        ) -join [Environment]::NewLine

        $dlgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="渠道依赖安装失败"
        Width="720" Height="520"
        WindowStartupLocation="CenterOwner"
        Background="#FFFAF4">
    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" FontSize="18" FontWeight="Bold" Foreground="#3C2814"
                   Text="渠道依赖安装失败"/>
        <TextBox Grid.Row="1" x:Name="DepErrorBox" Margin="0,12,0,0"
                 IsReadOnly="True" TextWrapping="NoWrap"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                 FontFamily="Consolas" FontSize="12"
                 Background="#FFF1EB" Foreground="#3C2814"
                 BorderBrush="#E5BFA0" BorderThickness="1" Padding="10"/>
        <WrapPanel Grid.Row="2" Margin="0,12,0,0" HorizontalAlignment="Right">
            <Button x:Name="DepCopyButton" Margin="0,0,10,0" Padding="14,8" Content="复制错误内容"/>
            <Button x:Name="DepCloseButton" Padding="14,8" Content="关闭"/>
        </WrapPanel>
    </Grid>
</Window>
'@
        $reader = New-Object System.Xml.XmlNodeReader ([xml]$dlgXaml)
        $dlg = [Windows.Markup.XamlReader]::Load($reader)
        try { $dlg.Owner = $window } catch { }
        $box = $dlg.FindName('DepErrorBox')
        $copyBtn = $dlg.FindName('DepCopyButton')
        $closeBtn = $dlg.FindName('DepCloseButton')
        if ($box) { $box.Text = $body }
        if ($copyBtn) {
            $copyBtn.Add_Click({
                try { [System.Windows.Clipboard]::SetText($body) } catch { }
            }.GetNewClosure())
        }
        if ($closeBtn) { $closeBtn.Add_Click({ $dlg.Close() }.GetNewClosure()) }
        [void]$dlg.ShowDialog()
    } catch {
        try { Add-LogLine ("打开渠道依赖错误对话框失败：{0}" -f $_.Exception.Message) } catch { }
    }
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
    #
    # IMPORTANT (陷阱 #39): venv python.exe on Windows is a stub launcher that
    # re-execs the system Python. Get-Process.Path returns the resolved real
    # interpreter (e.g. ...Programs\Python\Python313\python.exe), NOT the venv
    # stub path.  So filtering by Path equality MISSES the actual gateway
    # worker.  We must filter by CommandLine instead, via Win32_Process.
    $venvScriptsPath = Join-Path $env:LOCALAPPDATA 'hermes\hermes-agent\venv\Scripts'
    try {
        # CIM/WMI returns CommandLine which is stable across stub→real-python re-exec
        $pythonProcs = Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*$venvScriptsPath*" }
        foreach ($pp in $pythonProcs) {
            try {
                Stop-Process -Id $pp.ProcessId -Force -ErrorAction SilentlyContinue
                Add-LogLine ("已停止 Gateway 子进程 python.exe（PID: {0}）" -f $pp.ProcessId)
                $killed = $true
            } catch { }
        }
    } catch { }
    # Always remove gateway.lock — it may be stale from a crashed gateway.
    # Without cleanup, 'hermes gateway run' may fail reading the orphaned lock.
    # Wait longer for OS to release lock file handle held by the killed worker.
    # 500ms is too tight on slow disks; orphan python's file handle may still be
    # in the kernel-side close path → Remove-Item below silently fails →
    # next gateway start hits "lock is held" and suicides.
    $lockFile = Join-Path $env:USERPROFILE '.hermes\gateway.lock'
    if (Test-Path $lockFile) {
        if ($killed) { Start-Sleep -Milliseconds 1500 }
        # Retry up to 3 times in case lock is still held briefly after kill.
        for ($i = 0; $i -lt 3; $i++) {
            try {
                Remove-Item $lockFile -Force -ErrorAction Stop
                Add-LogLine "已清理 gateway.lock"
                break
            } catch {
                if ($i -eq 2) {
                    Add-LogLine ("gateway.lock 清理失败：{0}（新 gateway 可能拒绝启动）" -f $_.Exception.Message)
                }
                Start-Sleep -Milliseconds 500
            }
        }
    }
}

function Repair-GatewayApiPort {
    <#
    .SYNOPSIS
    Ensure config.yaml has platforms.api_server with port 8642.
    hermes-web-ui hardcodes upstream to http://127.0.0.1:8642.  If config.yaml
    has a different port, the gateway binds elsewhere and webui shows "未连接".
    The env var API_SERVER_PORT does NOT override config.yaml (config takes
    priority in the gateway code), so we must fix the file directly.

    任务 014 Bug G (v2026.05.04.9):新装的 hermes-agent default config.yaml
    可能完全没有 platforms.api_server 块 → gateway 启动跳过 api_server →
    端口 8642 没人监听 → webui 显示"未连接"。
    本函数在缺失时主动追加 api_server 块,见陷阱 #46。

    三种状态都要处理:
    1. config.yaml 完全没 platforms 块 → 追加完整 platforms + api_server
    2. 有 platforms 但没 api_server 子块 → 在 platforms: 之后插入 api_server
    3. 有 api_server 但 port 不对 → 修 port (原有逻辑)
    #>
    $configFile = Join-Path $env:USERPROFILE '.hermes\config.yaml'
    if (-not (Test-Path $configFile)) { return }
    try {
        # Must read/write as UTF-8 — PowerShell 5.1 Set-Content defaults to GBK
        # on Chinese Windows, which corrupts non-ASCII YAML and crashes the gateway.
        $content = [System.IO.File]::ReadAllText($configFile, [System.Text.Encoding]::UTF8)
        $modified = $false
        $apiServerSubBlock = "  api_server:`n    extra:`n      port: 8642`n      host: 127.0.0.1`n    enabled: true`n    key: ""`"`n    cors_origins: ""*`"`n"
        # 用 PowerShell 字符串拼接构造 YAML,避免 here-string 缩进困扰
        $apiServerSubBlock = "  api_server:" + [Environment]::NewLine +
                             "    extra:" + [Environment]::NewLine +
                             "      port: 8642" + [Environment]::NewLine +
                             "      host: 127.0.0.1" + [Environment]::NewLine +
                             "    enabled: true" + [Environment]::NewLine +
                             "    key: """"" + [Environment]::NewLine +
                             "    cors_origins: ""*""" + [Environment]::NewLine

        if ($content -notmatch '(?m)^platforms:') {
            # 状态 1:整个 platforms 块缺失 → 追加 platforms + api_server
            if (-not $content.EndsWith([Environment]::NewLine)) { $content += [Environment]::NewLine }
            $content += "platforms:" + [Environment]::NewLine + $apiServerSubBlock
            $modified = $true
            Add-LogLine "已在 config.yaml 添加 platforms.api_server 块（WebUI 要求）"
        } elseif ($content -notmatch '(?ms)^platforms:.*?^\s+api_server:') {
            # 状态 2:platforms 块存在但缺 api_server → 紧跟 platforms: 后插入 api_server 子块
            $content = $content -replace '(?m)^platforms:\s*\r?\n', ('platforms:' + [Environment]::NewLine + $apiServerSubBlock)
            $modified = $true
            Add-LogLine "已在 config.yaml 的 platforms 块添加 api_server 子块（WebUI 要求）"
        } elseif ($content -match '(?m)(^\s+port:\s+)(\d+)' -and $Matches[2] -ne '8642') {
            # 状态 3:已有 api_server 但 port 错 → 修 port
            $oldPort = $Matches[2]
            $content = $content -replace '(?m)(^\s+port:\s+)\d+', '${1}8642'
            $modified = $true
            Add-LogLine ("已修复 config.yaml 端口：{0} → 8642（WebUI 要求）" -f $oldPort)
        }
        if ($modified) {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($configFile, $content, $utf8NoBom)
        }
    } catch {
        Add-LogLine ("config.yaml 端口/api_server 修复跳过：{0}" -f $_.Exception.Message)
    }
}

function Test-PythonSyntax {
    <#
    .SYNOPSIS
    Verify a Python file has valid syntax using the hermes venv Python.
    Returns $true if syntax is OK, $false if broken or unverifiable.
    #>
    param([string]$FilePath, [string]$PythonExe)
    if (-not $PythonExe -or -not (Test-Path $PythonExe)) { return $false }
    try {
        $result = & $PythonExe -c "import py_compile; py_compile.compile(r'$FilePath', doraise=True)" 2>&1
        return $LASTEXITCODE -eq 0
    } catch { return $false }
}

function Restore-CorruptedUpstreamFiles {
    <#
    .SYNOPSIS
    Pre-flight: restore any Python files corrupted by a previous bad patch.
    Must run BEFORE gateway starts — if these files have syntax errors,
    gateway crashes on import.  Only restores, never patches.
    #>
    param([string]$HermesInstallDir)
    $pythonExe = Join-Path $HermesInstallDir 'venv\Scripts\python.exe'
    if (-not (Test-Path $pythonExe)) { return }
    $gitDir = Join-Path $HermesInstallDir '.git'
    if (-not (Test-Path $gitDir)) { return }

    $filesToCheck = @(
        'tools\environments\base.py',
        'tools\environments\local.py',
        'tools\browser_tool.py'
    )
    foreach ($relPath in $filesToCheck) {
        $fullPath = Join-Path $HermesInstallDir $relPath
        if (-not (Test-Path $fullPath)) { continue }
        if (-not (Test-PythonSyntax -FilePath $fullPath -PythonExe $pythonExe)) {
            $gitRelPath = $relPath.Replace('\', '/')
            try {
                Push-Location $HermesInstallDir
                & git checkout -- $gitRelPath 2>$null
                Pop-Location
                Add-LogLine ("已自动恢复被损坏的上游文件：{0}" -f $gitRelPath)
            } catch {
                Pop-Location
                Add-LogLine ("恢复文件失败：{0} - {1}" -f $gitRelPath, $_.Exception.Message)
            }
        }
    }
}

function Repair-HermesUpstreamForWindows {
    <#
    .SYNOPSIS
    Auto-patch hermes-agent upstream Python files for Windows compatibility.
    Fixes: WSL bash cwd paths (#24), select.select on pipes (#25),
    browser .cmd lookup (#26).  Safe to re-run (idempotent).

    SAFETY: Each file is backed up before patching.  After patching,
    Python syntax is verified.  If verification fails, the backup is
    restored — the original file is never left broken.
    Only writes if at least one replacement actually matched.
    #>
    param([string]$HermesInstallDir)
    $toolsDir = Join-Path $HermesInstallDir 'tools\environments'
    $browserFile = Join-Path $HermesInstallDir 'tools\browser_tool.py'
    $localFile = Join-Path $toolsDir 'local.py'
    $baseFile = Join-Path $toolsDir 'base.py'
    $pythonExe = Join-Path $HermesInstallDir 'venv\Scripts\python.exe'
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $patched = @()

    # Pre-check is now handled by Restore-CorruptedUpstreamFiles (called
    # before gateway start).  No need to duplicate here.

    # Helper: normalize line endings to match the target file.
    # PowerShell here-strings use CRLF on Windows, but git may checkout
    # Python files with LF only.  Mismatched line endings cause .Contains()
    # to fail silently — the patch never applies.
    function NormalizePatternToFile([string]$FileContent, [string]$Pattern) {
        $fileHasCRLF = $FileContent.Contains("`r`n")
        $patternHasCRLF = $Pattern.Contains("`r`n")
        if ($fileHasCRLF -and -not $patternHasCRLF) {
            return $Pattern.Replace("`n", "`r`n")
        } elseif (-not $fileHasCRLF -and $patternHasCRLF) {
            return $Pattern.Replace("`r`n", "`n")
        }
        return $Pattern
    }

    # --- P1: local.py — POSIX-to-Windows path conversion (陷阱 #24) ---
    if (Test-Path $localFile) {
        $src = [System.IO.File]::ReadAllText($localFile, $utf8)
        $original = $src
        if ($src -notmatch '_posix_to_win_path') {
            $actuallyChanged = $false
            # Insert _posix_to_win_path() before _find_bash()
            $marker = NormalizePatternToFile $src 'def _find_bash() -> str:'
            if ($src.Contains($marker)) {
                $patchFn = NormalizePatternToFile $src @'
def _posix_to_win_path(posix_path: str) -> str:
    import re
    m = re.match(r'^/mnt/([a-zA-Z])(/.*)?$', posix_path)
    if m:
        drive = m.group(1).upper()
        rest = (m.group(2) or '').replace('/', '\\')
        return f"{drive}:{rest or chr(92)}"
    m = re.match(r'^/([a-zA-Z])(/.*)?$', posix_path)
    if m:
        drive = m.group(1).upper()
        rest = (m.group(2) or '').replace('/', '\\')
        return f"{drive}:{rest or chr(92)}"
    return posix_path


'@
                $src = $src.Replace($marker, ($patchFn + $marker))
                $actuallyChanged = $true
            }

            # Patch _update_cwd to convert paths
            $oldCwd = NormalizePatternToFile $src '            if cwd_path:
                self.cwd = cwd_path'
            $newCwd = NormalizePatternToFile $src '            if cwd_path:
                if _IS_WINDOWS:
                    cwd_path = _posix_to_win_path(cwd_path)
                    if cwd_path.startswith(''/''):
                        cwd_path = os.environ.get(''USERPROFILE'', os.getcwd())
                self.cwd = cwd_path'
            if ($src.Contains($oldCwd)) {
                $src = $src.Replace($oldCwd, $newCwd)
                $actuallyChanged = $true
            }

            # Patch _run_bash to convert cwd before Popen
            $oldPopen = NormalizePatternToFile $src '        proc = subprocess.Popen(
            args,
            text=True,
            env=run_env,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
            preexec_fn=None if _IS_WINDOWS else os.setsid,
            cwd=self.cwd,
        )'
            $newPopen = NormalizePatternToFile $src '        effective_cwd = self.cwd
        if _IS_WINDOWS and effective_cwd.startswith(''/''):
            effective_cwd = _posix_to_win_path(effective_cwd)
            if effective_cwd.startswith(''/''):
                effective_cwd = os.environ.get(''USERPROFILE'', os.getcwd())

        proc = subprocess.Popen(
            args,
            text=True,
            env=run_env,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
            preexec_fn=None if _IS_WINDOWS else os.setsid,
            cwd=effective_cwd,
        )'
            if ($src.Contains($oldPopen)) {
                $src = $src.Replace($oldPopen, $newPopen)
                $actuallyChanged = $true
            }

            # Only write if something actually changed, and verify syntax
            if ($actuallyChanged) {
                [System.IO.File]::WriteAllText($localFile, $src, $utf8)
                if (-not (Test-PythonSyntax -FilePath $localFile -PythonExe $pythonExe)) {
                    Add-LogLine "local.py 补丁后语法校验失败，已回滚"
                    [System.IO.File]::WriteAllText($localFile, $original, $utf8)
                } else {
                    $patched += 'local.py (P1: path conversion)'
                }
            }
        }
    }

    # --- P2: base.py — select.select Windows fix + cwd extraction (陷阱 #24 #25) ---
    if (Test-Path $baseFile) {
        $src = [System.IO.File]::ReadAllText($baseFile, $utf8)
        $original = $src
        $changed = $false

        # P2a: Add platform import if missing
        if ($src -match 'import select' -and $src -notmatch 'import platform') {
            $importSelect = NormalizePatternToFile $src 'import select'
            $importBoth = NormalizePatternToFile $src "import platform`nimport select"
            $src = $src.Replace($importSelect, $importBoth)
            $changed = $true
        }

        # P2b: Fix _drain() to use os.read on Windows instead of select.select
        if ($src -notmatch '_is_windows = platform') {
            $oldDrain = NormalizePatternToFile $src '        def _drain():
            fd = proc.stdout.fileno()
            idle_after_exit = 0
            try:
                while True:
                    try:
                        ready, _, _ = select.select([fd], [], [], 0.1)
                    except (ValueError, OSError):
                        break  # fd already closed
                    if ready:
                        try:
                            chunk = os.read(fd, 4096)
                        except (ValueError, OSError):
                            break
                        if not chunk:
                            break  # true EOF — all writers closed
                        output_chunks.append(decoder.decode(chunk))
                        idle_after_exit = 0
                    elif proc.poll() is not None:
                        # bash is gone and the pipe was idle for ~100ms.  Give
                        # it two more cycles to catch any buffered tail, then
                        # stop — otherwise we wait forever on a grandchild pipe.
                        idle_after_exit += 1
                        if idle_after_exit >= 3:
                            break'
            $newDrain = NormalizePatternToFile $src '        def _drain():
            fd = proc.stdout.fileno()
            idle_after_exit = 0
            _is_windows = platform.system() == "Windows"
            try:
                if _is_windows:
                    while True:
                        try:
                            chunk = os.read(fd, 4096)
                        except (ValueError, OSError):
                            break
                        if not chunk:
                            break
                        output_chunks.append(decoder.decode(chunk))
                else:
                    while True:
                        try:
                            ready, _, _ = select.select([fd], [], [], 0.1)
                        except (ValueError, OSError):
                            break  # fd already closed
                        if ready:
                            try:
                                chunk = os.read(fd, 4096)
                            except (ValueError, OSError):
                                break
                            if not chunk:
                                break  # true EOF — all writers closed
                            output_chunks.append(decoder.decode(chunk))
                            idle_after_exit = 0
                        elif proc.poll() is not None:
                            idle_after_exit += 1
                            if idle_after_exit >= 3:
                                break'
            if ($src.Contains($oldDrain)) {
                $src = $src.Replace($oldDrain, $newDrain)
                $changed = $true
            }
        }

        # P2c: Fix CWD for WSL bash — Windows paths like C:\Users\YG must become
        # /mnt/c/Users/YG before being passed to bash's `cd`.  Without Git Bash,
        # hermes falls back to WSL bash which cannot handle Windows paths → exit 126.
        # Approach: add _win_cwd_for_bash() helper, patch init_session and _wrap_command.
        if ($src -notmatch '_win_cwd_for_bash') {
            # Insert helper method before _quote_cwd_for_cd
            $markerLine = NormalizePatternToFile $src '    def _quote_cwd_for_cd(cwd: str) -> str:'
            if ($src.Contains($markerLine)) {
                $helperCode = NormalizePatternToFile $src @'
    def _win_cwd_for_bash(self, cwd: str) -> str:
        """If using WSL bash on Windows, convert C:\\X to /mnt/c/X for cd."""
        import re as _re
        if platform.system() != "Windows" or not (len(cwd) >= 2 and cwd[1] == ":"):
            return cwd
        bash = os.environ.get("HERMES_GIT_BASH_PATH", "")
        if bash and os.path.isfile(bash):
            return cwd
        m = _re.match(r'^([a-zA-Z]):[/\\](.*)$', cwd)
        if m:
            drive = m.group(1).lower()
            rest = m.group(2).replace('\\', '/')
            return f"/mnt/{drive}/{rest}".rstrip('/') or f"/mnt/{drive}"
        return cwd

    @staticmethod
'@
                # Handle both LF and CRLF for the @staticmethod + marker combination
                $nl = if ($src.Contains("`r`n")) { "`r`n" } else { "`n" }
                $staticMarker = "    @staticmethod" + $nl + $markerLine
                if ($src.Contains($staticMarker)) {
                    $src = $src.Replace($staticMarker, $helperCode + $nl + $markerLine)
                    $changed = $true
                }
            }

            # Patch init_session: convert CWD for WSL bash
            $oldInit = NormalizePatternToFile $src '        _quoted_cwd = shlex.quote(self.cwd)'
            $newInit = NormalizePatternToFile $src '        _quoted_cwd = shlex.quote(self._win_cwd_for_bash(self.cwd))'
            if ($src.Contains($oldInit)) {
                $src = $src.Replace($oldInit, $newInit)
                $changed = $true
            }

            # Patch _wrap_command: convert CWD for WSL bash before quoting
            $oldWrap = NormalizePatternToFile $src '        quoted_cwd = self._quote_cwd_for_cd(cwd)'
            $newWrap = NormalizePatternToFile $src '        cwd = self._win_cwd_for_bash(cwd)
        quoted_cwd = self._quote_cwd_for_cd(cwd)'
            if ($src.Contains($oldWrap)) {
                $src = $src.Replace($oldWrap, $newWrap)
                $changed = $true
            }
        }

        # P2d: Fix _extract_cwd_from_output to convert POSIX paths
        $oldExtract = NormalizePatternToFile $src '        if cwd_path:
            self.cwd = cwd_path'
        $newExtract = NormalizePatternToFile $src '        if cwd_path:
            if platform.system() == "Windows" and cwd_path.startswith("/"):
                try:
                    from tools.environments.local import _posix_to_win_path
                    cwd_path = _posix_to_win_path(cwd_path)
                    if cwd_path.startswith("/"):
                        cwd_path = os.environ.get("USERPROFILE", os.getcwd())
                except ImportError:
                    pass
            self.cwd = cwd_path'
        if ($src.Contains($oldExtract)) {
            $src = $src.Replace($oldExtract, $newExtract)
            $changed = $true
        }

        if ($changed) {
            [System.IO.File]::WriteAllText($baseFile, $src, $utf8)
            if (-not (Test-PythonSyntax -FilePath $baseFile -PythonExe $pythonExe)) {
                Add-LogLine "base.py 补丁后语法校验失败，已回滚"
                [System.IO.File]::WriteAllText($baseFile, $original, $utf8)
            } else {
                $patched += 'base.py (P2: select fix + cwd)'
            }
        }
    }

    # --- P3: browser_tool.py — .cmd lookup on Windows (陷阱 #26) ---
    if (Test-Path $browserFile) {
        $src = [System.IO.File]::ReadAllText($browserFile, $utf8)
        $original = $src
        if ($src -match 'agent-browser"' -and $src -notmatch 'agent-browser\.cmd') {
            $actuallyChanged = $false
            # Add platform import
            if ($src -match 'import atexit' -and $src -notmatch 'import platform') {
                $importAtexit = NormalizePatternToFile $src 'import atexit'
                $importBoth = NormalizePatternToFile $src "import atexit`nimport platform"
                $src = $src.Replace($importAtexit, $importBoth)
                $actuallyChanged = $true
            }
            # Fix node_modules/.bin/ lookup
            $oldBin = NormalizePatternToFile $src '    local_bin = repo_root / "node_modules" / ".bin" / "agent-browser"
    if local_bin.exists():'
            $newBin = NormalizePatternToFile $src '    if platform.system() == "Windows":
        local_bin = repo_root / "node_modules" / ".bin" / "agent-browser.cmd"
    else:
        local_bin = repo_root / "node_modules" / ".bin" / "agent-browser"
    if local_bin.exists():'
            if ($src.Contains($oldBin)) {
                $src = $src.Replace($oldBin, $newBin)
                $actuallyChanged = $true
            }

            if ($actuallyChanged) {
                [System.IO.File]::WriteAllText($browserFile, $src, $utf8)
                if (-not (Test-PythonSyntax -FilePath $browserFile -PythonExe $pythonExe)) {
                    Add-LogLine "browser_tool.py 补丁后语法校验失败，已回滚"
                    [System.IO.File]::WriteAllText($browserFile, $original, $utf8)
                } else {
                    $patched += 'browser_tool.py (P3: .cmd lookup)'
                }
            }
        }
    }

    if ($patched.Count -gt 0) {
        Add-LogLine ("已自动修补上游兼容性问题：{0}" -f ($patched -join ', '))
    }
}

function Repair-HermesProfileDirectory {
    <#
    .SYNOPSIS
    任务 015：清理 ~/.hermes/profiles/ 下的乱码目录(GBK→UTF-8 解码错误产物，
    上游 hermes-web-ui < 0.5.0 在 Windows 中文环境下创建 profile 时编码错误)。
    同时写 active_profile=default，强制 webui 的 hermes-profile.js 走 default
    路径(~/.hermes/.env)，避免它去操作不存在的 profile 子目录。
    根因：webui 的 GatewayManager 扫描乱码目录时持续报 ENOENT + UnicodeEncodeError，
    干扰 PUT /api/hermes/config/credentials 的写入路径，导致 .env 永远不被更新。
    #>
    $hermesHome = Join-Path $env:USERPROFILE '.hermes'
    if (-not (Test-Path $hermesHome)) { return }

    # 1. 写 active_profile=default(覆盖式写入，无 BOM)
    $activeProfileFile = Join-Path $hermesHome 'active_profile'
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($activeProfileFile, 'default', $utf8NoBom)
    } catch {
        Add-LogLine ("写 active_profile 失败：{0}" -f $_.Exception.Message)
    }

    # 2. 清乱码 profile 目录(目录名只允许 ASCII 字母/数字/下划线/连字符；
    # 任何非此字符集的目录视为 GBK→UTF-8 编码事故产物，删除)
    $profilesDir = Join-Path $hermesHome 'profiles'
    if (-not (Test-Path $profilesDir)) { return }
    try {
        $cleanedCount = 0
        Get-ChildItem -LiteralPath $profilesDir -Directory -ErrorAction Stop | ForEach-Object {
            $name = $_.Name
            if ($name -notmatch '^[A-Za-z0-9_\-]+$') {
                try {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                    $cleanedCount++
                } catch {
                    Add-LogLine ("清理乱码 profile 失败：{0}" -f $_.Exception.Message)
                }
            }
        }
        if ($cleanedCount -gt 0) {
            Add-LogLine ("已清理 {0} 个乱码 profile 目录(防 webui 编码 bug)" -f $cleanedCount)
            try { Send-Telemetry -EventName 'profile_dir_repaired' -Properties @{ count = $cleanedCount } } catch { }
        }
    } catch {
        Add-LogLine ("扫描 profiles 目录失败：{0}" -f $_.Exception.Message)
    }
}

function Start-HermesGateway {
    param(
        [string]$HermesInstallDir
    )
    $hermesExe = Join-Path $HermesInstallDir 'venv\Scripts\hermes.exe'
    if (-not (Test-Path $hermesExe)) { return }

    # 任务 015：每次启 gateway 前清乱码 profile 目录 + 写 active_profile=default。
    # 即使本会话清过，webui 仍可能在运行中触发新的乱码目录创建，需防御性重清。
    try { Repair-HermesProfileDirectory } catch { }

    # Auto-install missing platform dependencies before starting gateway
    try { Install-GatewayPlatformDeps -HermesInstallDir $HermesInstallDir } catch {
        Add-LogLine ("渠道依赖检测跳过：{0}" -f $_.Exception.Message)
    }

    # Ensure gateway API port matches what webui expects (陷阱 #20)
    Repair-GatewayApiPort

    # Pre-flight: restore any Python files corrupted by a previous bad patch.
    # A broken base.py/local.py causes gateway to crash on import (SyntaxError).
    try { Restore-CorruptedUpstreamFiles -HermesInstallDir $HermesInstallDir } catch {
        Add-LogLine ("文件预检跳过：{0}" -f $_.Exception.Message)
    }

    # NOTE: upstream Python patching (Repair-HermesUpstreamForWindows) is deliberately
    # NOT called here.  Those patches fix terminal-tool issues (#24 #25 #26) but are
    # not needed for gateway operation.  Applying them during gateway startup risks
    # corrupting Python files on machines with a different hermes-agent version,
    # which kills the gateway entirely.  Patches are applied after gateway health
    # is confirmed, in a safe deferred step.

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
        # Force Git Bash for terminal tool — System32\bash.exe is WSL bash whose
        # pwd returns /mnt/c/... paths that Python cannot use as cwd (WinError 267)
        $gitBash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
        if (Test-Path $gitBash) { $env:HERMES_GIT_BASH_PATH = $gitBash }
        $hermesHome = Join-Path $env:USERPROFILE '.hermes'
        $proc = Start-Process -FilePath $hermesExe -ArgumentList @('gateway', 'run') -WindowStyle Hidden -PassThru -WorkingDirectory $hermesHome
        $script:GatewayProcess = $proc
        $script:GatewayHermesExe = $hermesExe
        Add-LogLine ("Hermes Gateway 已启动（PID: {0}）" -f $proc.Id)
        try { Send-TelemetryOnce -EventName 'gateway_started' } catch { }

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
        try { Send-Telemetry -EventName 'gateway_failed' -FailureReason $_.Exception.Message } catch { }
    }
}

function Restart-HermesGateway {
    <#
    .SYNOPSIS
    Kill the current gateway process and start a fresh one.
    Called by the .env file watcher when channel config changes.
    Must install platform deps before starting, same as Start-HermesGateway.

    任务 014 Bug E/F (v2026.05.04.8):新增 -RetryCount 参数 + post-verify。
    Restart 完后调 Test-GatewayConnectedPlatformsMatchEnv 验证 platform 数,
    mismatch 触发自动重试 1 次(防止 lock held / install fail 等 race)。
    #>
    param([int]$RetryCount = 0)
    if ($RetryCount -eq 0) {
        Add-LogLine "检测到 .env 文件变化，准备重启 Gateway..."
    } else {
        Add-LogLine ("第 {0} 次重试 Gateway 重启..." -f $RetryCount)
    }
    $hermesExe = $script:GatewayHermesExe
    # 任务 014 Bug A.2（陷阱 #27 升级版）：当 $script:GatewayHermesExe 为 null（例如
    # 上次启动器没走 fast path 初始化，或 polling 抢先于 fast path 初始化触发），
    # 不再 silently skip。先从 InstallDir 推导，再 fallback 到默认 LOCALAPPDATA 路径。
    if (-not $hermesExe -or -not (Test-Path $hermesExe)) {
        $candidates = New-Object System.Collections.Generic.List[string]
        try {
            if ($controls -and $controls.InstallDirTextBox) {
                $textInstallDir = $controls.InstallDirTextBox.Text.Trim()
                if ($textInstallDir) {
                    $candidates.Add((Join-Path $textInstallDir 'venv\Scripts\hermes.exe'))
                }
            }
        } catch { }
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'hermes\hermes-agent\venv\Scripts\hermes.exe'))
        $hermesExe = $null
        foreach ($candidate in $candidates) {
            if ($candidate -and (Test-Path $candidate)) {
                $hermesExe = $candidate
                break
            }
        }
        if (-not $hermesExe) {
            Add-LogLine "Gateway 可执行文件未找到（已尝试 InstallDir + 默认路径），跳过重启"
            try { Send-Telemetry -EventName 'unexpected_error' -FailureReason 'restart_gateway_skipped: hermes.exe not found' -Properties @{ source = 'env_watcher' } } catch { }
            return
        }
        $script:GatewayHermesExe = $hermesExe
        Add-LogLine ("Gateway 可执行文件已从 InstallDir 推导：{0}" -f $hermesExe)
    }

    # 任务 015：Restart 路径也清乱码 profile + 写 active_profile=default
    try { Repair-HermesProfileDirectory } catch { }

    # Install platform deps for newly configured channels (e.g. python-telegram-bot)
    # hermes.exe is at hermes-agent\venv\Scripts\hermes.exe → need 3 levels up
    $hermesInstallDir = Split-Path (Split-Path (Split-Path $hermesExe -Parent) -Parent) -Parent
    try { Install-GatewayPlatformDeps -HermesInstallDir $hermesInstallDir } catch {
        Add-LogLine ("渠道依赖检测跳过：{0}" -f $_.Exception.Message)
    }
    # 任务 014 Bug A.3：刷新 UI（依赖装失败时让红色横幅立即显示）
    try { Request-StatusRefresh } catch { }

    # Ensure port is correct before restart (陷阱 #20)
    Repair-GatewayApiPort

    try {
        # Kill existing gateway — don't use --replace (crashes on Windows, 陷阱 #18)
        Stop-ExistingGateway

        # Ensure env vars are set (same as Start-HermesGateway)
        $env:HERMES_HOME = Join-Path $env:USERPROFILE '.hermes'
        $env:PYTHONIOENCODING = 'utf-8'
        $env:GATEWAY_ALLOW_ALL_USERS = 'true'
        $env:API_SERVER_PORT = '8642'
        $gitBash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
        if (Test-Path $gitBash) { $env:HERMES_GIT_BASH_PATH = $gitBash }
        $hermesHome = Join-Path $env:USERPROFILE '.hermes'
        $proc = Start-Process -FilePath $hermesExe -ArgumentList @('gateway', 'run') -WindowStyle Hidden -PassThru -WorkingDirectory $hermesHome
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
        $earlyExit = $proc.HasExited
        if ($earlyExit) {
            Add-LogLine ("Gateway 进程启动后立即退出（退出码: {0}），渠道可能无法使用" -f $proc.ExitCode)
        } else {
            Add-LogLine "Gateway 进程运行正常"
        }

        # 任务 014 Bug E/F (v2026.05.04.8):post-verify 验证 platform 数匹配
        # 早退场景(lock held)直接判失败;活着的等多 5 秒让所有 platform connect
        # 见陷阱 #45。
        if ($RetryCount -lt 1) {
            $needsRetry = $false
            if ($earlyExit) {
                # 进程立即退出,几乎肯定是 lock held(陷阱 #18) → retry 前给 OS 多时间释放
                Add-LogLine "Gateway 早退,等待 5 秒后再重试..."
                Start-Sleep -Seconds 5
                $needsRetry = $true
            } else {
                # 进程活着,等 connect 完所有 platform 再读 log 比对
                Start-Sleep -Seconds 5
                if (-not (Test-GatewayConnectedPlatformsMatchEnv)) {
                    $needsRetry = $true
                }
            }
            if ($needsRetry) {
                Add-LogLine "Gateway 验证未通过,自动重试 1 次..."
                Restart-HermesGateway -RetryCount 1
                return
            }
        }
    } catch {
        Add-LogLine ("Gateway 自动重启失败：{0}" -f $_.Exception.Message)
    }
}

function Get-EnvFileSignature {
    # 任务 014 Bug A.1：用 LastWriteTimeUtc + Length 作为 .env 文件签名，便于 polling 比较。
    # 不读全文 + hash，避免 60 秒 polling 频繁占用磁盘 IO；mtime + size 已足够检测变化。
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
        $info = Get-Item -LiteralPath $Path -ErrorAction Stop
        return ('{0}|{1}' -f $info.LastWriteTimeUtc.Ticks, $info.Length)
    } catch { return 'error' }
}

function Test-GatewayConfigStale {
    <#
    .SYNOPSIS
    任务 014 Bug D (v2026.05.04.7):检测当前运行的 gateway 是否在用过期 .env。
    返回 $true = .env 比 gateway.lock 新,gateway 加载的是旧配置,需要 restart。
    返回 $false = .env 没变,或 lock 不存在(gateway 没在跑)。

    场景:用户在 webui 里配了新平台(微信/钉钉/飞书等)→ webui 写 .env →
          mtime 更新。如果 launcher 当时不在跑(没人 watch .env),gateway
          也不会自动重启,继续用启动时的旧 .env → "Gateway running with N platform(s)"
          少一个 → webui 显示"已配置"但 gateway 收不到消息。

    见陷阱 #44。
    #>
    try {
        $envFile = Join-Path $env:USERPROFILE '.hermes\.env'
        $lockFile = Join-Path $env:USERPROFILE '.hermes\gateway.lock'
        if (-not (Test-Path -LiteralPath $envFile)) { return $false }
        if (-not (Test-Path -LiteralPath $lockFile)) { return $false }  # gateway 没在跑,不算 stale
        $envInfo = Get-Item -LiteralPath $envFile -ErrorAction Stop
        $lockInfo = Get-Item -LiteralPath $lockFile -ErrorAction Stop
        # .env mtime > lock mtime → gateway 是用旧 .env 启动的
        return ($envInfo.LastWriteTimeUtc -gt $lockInfo.LastWriteTimeUtc)
    } catch {
        return $false
    }
}

function Test-GatewayConnectedPlatformsMatchEnv {
    <#
    .SYNOPSIS
    任务 014 Bug E/F (v2026.05.04.8):验证 gateway 实际 connect 的平台数
    跟 .env 配置的 messaging platforms 数是否一致。
    返回 $true  = 一致(健康) / 无法判定(放行,不阻塞)
    返回 $false = mismatch(需要再次 Restart)

    应用场景:Restart-HermesGateway 之后 post-verify。
    - Stop-ExistingGateway 杀进程失败 → 新 gateway 启动失败 lock held → 仍是旧 platform 数 → mismatch
    - Install-GatewayPlatformDeps 装包失败 → 新 gateway import 失败 silent skip → platform 数少 → mismatch
    - 任何 race / 网络瞬时问题 → 最终结果不对 → 这里捕获

    实现:解析 .env 配置的 messaging platforms,读 gateway.log 最新一行
         "Gateway running with N platform(s)",对比 N - 1(api_server) 跟配置数。

    见陷阱 #45。
    #>
    try {
        $envFile = Join-Path $env:USERPROFILE '.hermes\.env'
        if (-not (Test-Path -LiteralPath $envFile)) { return $true }  # 没 .env 不判定

        # 解析 .env 配置的 messaging platforms
        $envLines = Get-Content $envFile -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '^\s*[A-Z]' }
        # 关键变量 → platform name (HashSet 去重,避免一个平台多个变量重复计数)
        $platformVarMap = @(
            @{ Var = 'TELEGRAM_BOT_TOKEN';   Name = 'telegram' }
            @{ Var = 'WEIXIN_TOKEN';         Name = 'weixin'   }
            @{ Var = 'WEIXIN_ACCOUNT_ID';    Name = 'weixin'   }
            @{ Var = 'FEISHU_APP_ID';        Name = 'feishu'   }
            @{ Var = 'SLACK_BOT_TOKEN';      Name = 'slack'    }
            @{ Var = 'DINGTALK_CLIENT_ID';   Name = 'dingtalk' }
            @{ Var = 'DISCORD_BOT_TOKEN';    Name = 'discord'  }
            @{ Var = 'WECOM_BOT_ID';         Name = 'wecom'    }
        )
        $configuredSet = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($pc in $platformVarMap) {
            $line = $envLines | Where-Object { $_ -match "^\s*$($pc.Var)\s*=\s*\S" }
            if ($line) { [void]$configuredSet.Add($pc.Name) }
        }
        $configuredCount = $configuredSet.Count
        if ($configuredCount -eq 0) { return $true }  # 没配置 messaging,不判定

        # 读 gateway.log 最新一行 "Gateway running with N platform(s)"
        $gatewayLog = Join-Path $env:USERPROFILE '.hermes\logs\gateway.log'
        if (-not (Test-Path -LiteralPath $gatewayLog)) { return $true }
        $logTail = Get-Content $gatewayLog -Tail 100 -ErrorAction SilentlyContinue
        $lastRunningCount = -1
        foreach ($line in $logTail) {
            if ($line -match 'Gateway running with (\d+) platform') {
                $lastRunningCount = [int]$matches[1]
            }
        }
        if ($lastRunningCount -lt 0) { return $true }  # 没找到不判定

        # gateway 实际连 = api_server (1) + messaging platforms (N)
        $expected = 1 + $configuredCount
        if ($lastRunningCount -lt $expected) {
            Add-LogLine ("Gateway 实际 connect {0} 个平台, .env 配置 {1} 个 messaging 平台 (期望 {2}), 不匹配" -f $lastRunningCount, $configuredCount, $expected)
            return $false
        }
        return $true
    } catch {
        return $true  # 出错放行,不阻塞 launcher 主流程
    }
}

function Start-GatewayEnvWatcher {
    <#
    .SYNOPSIS
    Watch ~/.hermes/.env for writes and auto-restart gateway to pick up new config.
    Debounces rapid writes (2-second delay after last change).
    任务 014 Bug A.1：除 FileSystemWatcher 外，加 60 秒 polling 兜底，
    覆盖防病毒拦截 / 跨盘符 / 网络盘等 watcher 失效的场景。
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
    if ($script:EnvWatcherPollingTimer) {
        try { $script:EnvWatcherPollingTimer.Stop(); $script:EnvWatcherPollingTimer.Dispose() } catch { }
    }

    $watcher = [System.IO.FileSystemWatcher]::new($envDir, '.env')
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite
    $watcher.IncludeSubdirectories = $false

    # Debounce timer: fires 2 seconds after the last .env write
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromSeconds(2)
    $timer.Add_Tick({
        $script:EnvWatcherTimer.Stop()
        # 任务 014 Bug A.1：刷新 polling 基线签名，避免 watcher 触发后 polling 又重复触发一次
        try { $script:EnvWatcherLastSig = Get-EnvFileSignature -Path (Join-Path $env:USERPROFILE '.hermes\.env') } catch { }
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

    # 任务 014 Bug A.1：60 秒 polling 兜底（同一 dispatcher 线程，无并发问题）。
    # 第一次启动时把当前签名写入基线，避免 polling 上来就误判为 changed。
    $script:EnvWatcherLastSig = Get-EnvFileSignature -Path $envFile
    $polling = [System.Windows.Threading.DispatcherTimer]::new()
    $polling.Interval = [TimeSpan]::FromSeconds(60)
    $polling.Add_Tick({
        try {
            $envFilePoll = Join-Path $env:USERPROFILE '.hermes\.env'
            $sig = Get-EnvFileSignature -Path $envFilePoll
            if ($sig -ne $script:EnvWatcherLastSig) {
                Add-LogLine ".env polling 兜底检测到变化（watcher 可能未触发），准备重启 Gateway..."
                $script:EnvWatcherLastSig = $sig
                # 走与 watcher 相同的 debounce 流程，避免快速连续触发
                if ($script:EnvWatcherTimer) {
                    $script:EnvWatcherTimer.Stop()
                    $script:EnvWatcherTimer.Start()
                } else {
                    Restart-HermesGateway
                }
            }
        } catch {
            try { Add-LogLine (".env polling 兜底异常：{0}" -f $_.Exception.Message) } catch { }
        }
    })
    $script:EnvWatcherPollingTimer = $polling
    $polling.Start()
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

    # Wait for gateway to become healthy before starting webui.
    # Without this, webui's GatewayManager.detectStatus() may find the
    # gateway not ready → startAll() → 30s timeout kill (陷阱 #22).
    $gwDeadline = (Get-Date).AddSeconds(15)
    $gwReady = $false
    while ((Get-Date) -lt $gwDeadline) {
        Start-Sleep -Milliseconds 1000
        try {
            $null = Invoke-RestMethod -Uri 'http://127.0.0.1:8642/health' -TimeoutSec 2 -ErrorAction Stop
            Add-LogLine 'Gateway 健康检查通过，启动 WebUI...'
            $gwReady = $true
            break
        } catch { }
    }
    if (-not $gwReady) {
        Add-LogLine 'Gateway 健康检查超时（15秒），仍继续启动 WebUI'
    }

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
    # Fix webui terminal: its shell detector uses existsSync("powershell.exe")
    # which only checks CWD, not PATH.  Setting SHELL to the full path fixes it.
    if (-not $env:SHELL) {
        $env:SHELL = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
        if (-not $env:SHELL) { $env:SHELL = 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe' }
    }

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
    # 任务 014 Bug A.1：关闭 polling 兜底 timer
    if ($script:EnvWatcherPollingTimer) {
        try { $script:EnvWatcherPollingTimer.Stop(); $script:EnvWatcherPollingTimer.Dispose() } catch { }
        $script:EnvWatcherPollingTimer = $null
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
    # 任务 014 Bug C：用户机器无默认浏览器 / shell 注册损坏时，Start-Process 可能抛
    # FileNotFoundException 或 Win32Exception，必须吞掉避免冲到 dispatcher 未捕获处理器。
    try {
        Start-Process $Url | Out-Null
    } catch {
        try { Add-LogLine ("打开浏览器失败：{0}" -f $_.Exception.Message) } catch { }
        try { Send-Telemetry -EventName 'unexpected_error' -FailureReason ('open_browser: ' + $_.Exception.GetType().FullName + ': ' + $_.Exception.Message) -Properties @{ source = 'open_browser' } } catch { }
    }
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
    # 任务 014 Bug C：explorer.exe 调用极少抛错，但 Path 含特殊字符 / 权限异常时仍可能炸。
    # 全段 try-catch 防 dispatcher 未捕获。
    # QA Patch M2：catch 块对齐 Open-BrowserUrlSafe，上报具体 reason，便于 Dashboard 反查
    try {
        if (Test-Path $Path) {
            Start-Process explorer.exe -ArgumentList """$Path""" | Out-Null
            return
        }
        $parent = Split-Path -Parent $Path
        if ($parent -and (Test-Path $parent)) {
            Start-Process explorer.exe -ArgumentList """$parent""" | Out-Null
        }
    } catch {
        try { Add-LogLine ("打开资源管理器失败：{0}" -f $_.Exception.Message) } catch { }
        try { Send-Telemetry -EventName 'unexpected_error' -FailureReason ('open_explorer: ' + $_.Exception.GetType().FullName + ': ' + $_.Exception.Message) -Properties @{ source = 'open_explorer' } } catch { }
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
    # 任务 014 Bug H (v2026.05.04.12):
    # - 把 hermes.aisuper.win 自建镜像放在第 0 位（国内 Cloudflare 可达性 ~99%,远超社区镜像）
    # - 加 ghfast.top / gh-proxy.com 等 2026 仍活跃的社区镜像,提升兜底覆盖率
    # 见陷阱 #47。
    [pscustomobject]@{
        # GitHub raw 文件镜像：用于下载 install.ps1
        # 格式：直接替换 raw.githubusercontent.com 或拼接代理前缀
        GitHubRaw = @(
            'https://hermes.aisuper.win/mirror',           # 自建镜像（国内首选,启动器自己控制）
            'https://raw.githubusercontent.com',           # 官方（overseas 首选）
            'https://raw.gitmirror.com',                   # gitmirror
            'https://gh.api.99988866.xyz/https://raw.githubusercontent.com',  # 99988866 代理
            'https://ghproxy.cn/https://raw.githubusercontent.com',           # ghproxy.cn
            'https://ghfast.top/https://raw.githubusercontent.com',           # ghfast (2026 活跃)
            'https://gh-proxy.com/https://raw.githubusercontent.com'          # gh-proxy.com
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
        # 任务 014 Bug H (v2026.05.04.12): GitHubRaw[0] 现在是自建 hermes.aisuper.win,
        # GitHubRaw[1] 是 raw.githubusercontent.com 官方。国内网络: 自建[0] → 社区[2..n] → 官方[1] 兜底
        $orderedUrls = @($candidateUrls[0]) + @($candidateUrls[2..($candidateUrls.Count - 1)]) + @($candidateUrls[1])
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
        # 任务 014 Bug J (v2026.05.04.14):自建镜像 hermes.aisuper.win 的 .ps1 文件
        # Cloudflare Pages 默认 Content-Type: application/octet-stream → Invoke-WebRequest
        # 把 $resp.Content 解析为 byte[],ToString 后变成空格分隔的 decimal 数字串
        # ("35 32 61 61 ...") → 子 powershell parse 报 "Unexpected token '32'" 失败。
        # 修复:byte[] 显式 UTF-8 decode 成 string,跟之前 GitHub raw 返回 text/plain
        # 时的行为一致。见陷阱 #48。
        if ($resp.Content -is [byte[]]) {
            return [System.Text.Encoding]::UTF8.GetString($resp.Content)
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
`$env:UV_EXTRA_INDEX_URL = 'https://pypi.tuna.tsinghua.edu.cn/simple/'
`$env:NPM_CONFIG_REGISTRY = '$npmMirror'
`$env:UV_DEFAULT_INDEX = '$pypiMirror'
Write-Host '[Hermes 启动器] 已切换到国内镜像源，加速安装...' -ForegroundColor Cyan
# === 镜像源配置结束 ===

"@
        # 任务 014 Bug K (v2026.05.04.15):必须插到 param() 块之后!
        # PowerShell 要求 param() 是脚本第一个非注释/空行语句。
        # 之前的 `$content = $mirrorHeader + $content` 把 $env: 赋值拼在 param 块前,
        # 导致 parser 把 param 块里的 [string]$Branch = "main" 当成普通赋值表达式,
        # 报 "The assignment expression is not valid / InvalidLeftHandSide"。
        # 见陷阱 #49。
        $paramEndRegex = [regex]::new('(?s)^.*?param\s*\([^)]*\)\s*[\r\n]+')
        $paramMatch = $paramEndRegex.Match($content)
        if ($paramMatch.Success) {
            $headerEnd = $paramMatch.Length
            # 用 substring 拼接,避免 [regex]::Replace 把 $mirrorHeader 里 `$env:` 之类当成反向引用
            $content = $content.Substring(0, $headerEnd) + $mirrorHeader + $content.Substring($headerEnd)
        } else {
            # fallback: 找不到 param 块时仍按旧方式拼(install.ps1 改了结构时不至于裸崩)
            Add-LogLine '警告:install.ps1 没找到 param 块,镜像注入可能失效'
            $content = $mirrorHeader + $content
        }
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
        Background="#F2F0E8"
        Foreground="#262621"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType">
    <Window.Resources>
        <!-- ========== Color Tokens (Mac LauncherPalette 映射，任务 012) ========== -->
        <SolidColorBrush x:Key="BgAppBrush" Color="#F2F0E8"/>
        <SolidColorBrush x:Key="BgAppSecondaryBrush" Color="#EBE8E0"/>
        <SolidColorBrush x:Key="BgGlowBrush" Color="#F4C98A"/>
        <SolidColorBrush x:Key="SurfacePrimaryBrush" Color="#FAF8F2"/>
        <SolidColorBrush x:Key="SurfaceSecondaryBrush" Color="#F4F0E8"/>
        <SolidColorBrush x:Key="SurfaceTertiaryBrush" Color="#F0E8DE"/>
        <SolidColorBrush x:Key="SurfaceHoverBrush" Color="#F2E6D6"/>
        <SolidColorBrush x:Key="TextPrimaryBrush" Color="#262621"/>
        <SolidColorBrush x:Key="TextSecondaryBrush" Color="#5E594F"/>
        <SolidColorBrush x:Key="TextTertiaryBrush" Color="#897F75"/>
        <SolidColorBrush x:Key="TextOnAccentBrush" Color="#FCFCF7"/>
        <SolidColorBrush x:Key="AccentPrimaryBrush" Color="#D9772B"/>
        <SolidColorBrush x:Key="AccentSoftBrush" Color="#F2B56B"/>
        <SolidColorBrush x:Key="AccentDeepBrush" Color="#A85420"/>
        <SolidColorBrush x:Key="AccentTintBrush" Color="#1AD9772B"/>
        <SolidColorBrush x:Key="AccentBorderBrush" Color="#52A85420"/>
        <SolidColorBrush x:Key="SuccessBrush" Color="#4F8F7A"/>
        <SolidColorBrush x:Key="SuccessSoftBrush" Color="#DBEDE5"/>
        <SolidColorBrush x:Key="WarningBrush" Color="#C78A3A"/>
        <SolidColorBrush x:Key="WarningSoftBrush" Color="#F4E8D2"/>
        <SolidColorBrush x:Key="DangerBrush" Color="#C25E52"/>
        <SolidColorBrush x:Key="DangerSoftBrush" Color="#F7E0D8"/>
        <SolidColorBrush x:Key="LineSoftBrush" Color="#0F000000"/>
        <SolidColorBrush x:Key="LineSofterBrush" Color="#0A000000"/>
        <SolidColorBrush x:Key="LogBgBrush" Color="#1F1A14"/>
        <SolidColorBrush x:Key="LogTextBrush" Color="#EBE8E0"/>

        <LinearGradientBrush x:Key="AccentGradientBrush" StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#E58236" Offset="0"/>
            <GradientStop Color="#D9772B" Offset="0.6"/>
            <GradientStop Color="#C76819" Offset="1"/>
        </LinearGradientBrush>

        <LinearGradientBrush x:Key="ProgressFillBrush" StartPoint="0,0" EndPoint="1,0">
            <GradientStop Color="#A85420" Offset="0"/>
            <GradientStop Color="#D9772B" Offset="0.6"/>
            <GradientStop Color="#F2B56B" Offset="1"/>
        </LinearGradientBrush>

        <!-- ========== Font ========== -->
        <FontFamily x:Key="UiFont">$($script:UiFontFamily)</FontFamily>
        <FontFamily x:Key="MonoFont">$($script:UiMonoFontFamily)</FontFamily>

        <!-- ========== Default Styles ========== -->
        <Style TargetType="TextBlock">
            <Setter Property="FontFamily" Value="{StaticResource UiFont}"/>
            <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="TextOptions.TextFormattingMode" Value="Display"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="FontFamily" Value="{StaticResource UiFont}"/>
            <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="FontFamily" Value="{StaticResource UiFont}"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="FontFamily" Value="{StaticResource UiFont}"/>
            <Setter Property="Foreground" Value="{StaticResource TextSecondaryBrush}"/>
        </Style>

        <Style x:Key="PrimaryButtonStyle" TargetType="Button">
            <Setter Property="FontFamily" Value="{StaticResource UiFont}"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="14.5"/>
            <Setter Property="Foreground" Value="{StaticResource TextOnAccentBrush}"/>
            <Setter Property="Background" Value="{StaticResource AccentGradientBrush}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="22,12"/>
            <Setter Property="MinHeight" Value="44"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}"
                                CornerRadius="12" Padding="{TemplateBinding Padding}"
                                BorderBrush="Transparent" BorderThickness="0">
                            <Border.Effect>
                                <DropShadowEffect Color="#A85420" Opacity="0.32" BlurRadius="14" ShadowDepth="3"/>
                            </Border.Effect>
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="{StaticResource SurfaceTertiaryBrush}"/>
                                <Setter Property="Foreground" Value="{StaticResource TextTertiaryBrush}"/>
                                <Setter TargetName="ButtonBorder" Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Color="#000000" Opacity="0" BlurRadius="0" ShadowDepth="0"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SecondaryButtonStyle" TargetType="Button">
            <Setter Property="FontFamily" Value="{StaticResource UiFont}"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="13.5"/>
            <Setter Property="Foreground" Value="{StaticResource AccentDeepBrush}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="{StaticResource AccentDeepBrush}"/>
            <Setter Property="BorderThickness" Value="1.5"/>
            <Setter Property="Padding" Value="20,10"/>
            <Setter Property="MinHeight" Value="42"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                CornerRadius="11"
                                Padding="{TemplateBinding Padding}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="TextButtonStyle" TargetType="Button">
            <Setter Property="FontFamily" Value="{StaticResource UiFont}"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Foreground" Value="{StaticResource TextSecondaryBrush}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="14,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                CornerRadius="8"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="AboutButtonStyle" TargetType="Button" BasedOn="{StaticResource SecondaryButtonStyle}">
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="14,6"/>
            <Setter Property="MinHeight" Value="34"/>
        </Style>

        <Style x:Key="LogSubButtonStyle" TargetType="Button">
            <Setter Property="FontFamily" Value="{StaticResource UiFont}"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Padding" Value="9,4"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="#33EBE8E0"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="#EBE8E0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="6"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="WarmProgressBarStyle" TargetType="ProgressBar">
            <Setter Property="Background" Value="{StaticResource SurfaceTertiaryBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource ProgressFillBrush}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Height" Value="7"/>
            <Setter Property="Minimum" Value="0"/>
            <Setter Property="Maximum" Value="100"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Border Background="{TemplateBinding Background}" CornerRadius="999" ClipToBounds="True">
                            <Grid>
                                <Border x:Name="PART_Track"/>
                                <Border x:Name="PART_Indicator" HorizontalAlignment="Left"
                                        Background="{TemplateBinding Foreground}" CornerRadius="999"/>
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <StackPanel Grid.Row="0" Margin="34,28,34,0">
            <DockPanel LastChildFill="True">
                <Button x:Name="AboutButton" DockPanel.Dock="Right" VerticalAlignment="Center"
                        Style="{StaticResource AboutButtonStyle}" Content="关于"/>
                <StackPanel VerticalAlignment="Center">
                    <TextBlock x:Name="BrandTitleText" Text="Hermes Agent" FontSize="28" FontWeight="Bold"
                               Foreground="{StaticResource TextPrimaryBrush}"/>
                    <TextBlock x:Name="BrandSubtitleText" Margin="0,4,0,0" FontSize="12.5"
                               Foreground="{StaticResource TextTertiaryBrush}"
                               Text="更聪明的个人 AI 助理"/>
                </StackPanel>
            </DockPanel>

            <Border x:Name="TelemetryConsentBanner" Margin="0,16,0,0" Padding="14,10"
                    CornerRadius="12"
                    Background="{StaticResource SurfaceSecondaryBrush}"
                    BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1"
                    Visibility="Collapsed">
                <DockPanel LastChildFill="True">
                    <Button x:Name="TelemetryConsentDismissButton" DockPanel.Dock="Right"
                            Style="{StaticResource TextButtonStyle}" Content="知道了"/>
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Border Width="22" Height="22" CornerRadius="11"
                                Background="{StaticResource AccentTintBrush}" Margin="0,0,12,0">
                            <TextBlock Text="i" FontFamily="Times New Roman" FontStyle="Italic" FontSize="13"
                                       FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"
                                       Foreground="{StaticResource AccentDeepBrush}"/>
                        </Border>
                        <TextBlock VerticalAlignment="Center" FontSize="12.5" TextWrapping="Wrap"
                                   Foreground="{StaticResource TextSecondaryBrush}"
                                   Text="我们会上报匿名安装数据帮助改进产品，可在「关于」里关闭。"/>
                    </StackPanel>
                </DockPanel>
            </Border>
        </StackPanel>

        <!-- Main Content -->
        <ScrollViewer Grid.Row="1" Margin="34,18,34,0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <Grid>
                <!-- ========== Install Mode ========== -->
                <Border x:Name="InstallModePanel" Visibility="Visible">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="1.4*"/>
                            <ColumnDefinition Width="20"/>
                            <ColumnDefinition Width="1*"/>
                        </Grid.ColumnDefinitions>

                        <StackPanel Grid.Column="0">
                            <Border x:Name="InstallTaskCardBorder"
                                    Padding="28,26"
                                    CornerRadius="16"
                                    Background="{StaticResource SurfacePrimaryBrush}"
                                    BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                                <Border.Effect>
                                    <DropShadowEffect Color="#3C2814" Opacity="0.06" BlurRadius="18" ShadowDepth="3"/>
                                </Border.Effect>
                                <StackPanel>
                                    <Border x:Name="InstallTaskStepTagBorder" HorizontalAlignment="Left"
                                            CornerRadius="999" Padding="10,4"
                                            Background="{StaticResource AccentTintBrush}">
                                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                            <Border Width="16" Height="16" CornerRadius="8"
                                                    Background="{StaticResource AccentPrimaryBrush}" Margin="0,0,7,0">
                                                <TextBlock x:Name="InstallTaskStepTagNum" Text="1" FontSize="10"
                                                           FontWeight="Bold"
                                                           Foreground="{StaticResource TextOnAccentBrush}"
                                                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                            </Border>
                                            <TextBlock x:Name="InstallTaskStepTagText" Text="环境检测"
                                                       FontSize="11" FontWeight="Bold"
                                                       Foreground="{StaticResource AccentDeepBrush}"
                                                       VerticalAlignment="Center"/>
                                        </StackPanel>
                                    </Border>

                                    <TextBlock x:Name="InstallTaskTitleText" Margin="0,16,0,0"
                                               FontSize="26" FontWeight="Bold" TextWrapping="Wrap"
                                               Foreground="{StaticResource TextPrimaryBrush}"
                                               Text="环境检测"/>
                                    <TextBlock x:Name="InstallTaskBodyText" Margin="0,12,0,0"
                                               FontSize="13.5" TextWrapping="Wrap" LineHeight="20"
                                               Foreground="{StaticResource TextSecondaryBrush}"
                                               Text="启动器会先自动检查环境，再执行安装；失败时会直接告诉你卡在哪一步。"/>

                                    <Border x:Name="InstallCurrentStageBorder" Margin="0,16,0,0"
                                            Padding="14,11" CornerRadius="11"
                                            Background="{StaticResource SurfaceSecondaryBrush}"
                                            BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1"
                                            Visibility="Collapsed">
                                        <DockPanel LastChildFill="True">
                                            <TextBlock x:Name="InstallCurrentStageDetail" DockPanel.Dock="Right"
                                                       FontSize="11.5"
                                                       Foreground="{StaticResource TextTertiaryBrush}"
                                                       VerticalAlignment="Center"/>
                                            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                                <Ellipse Width="7" Height="7" Margin="0,0,10,0"
                                                         Fill="{StaticResource AccentPrimaryBrush}"/>
                                                <TextBlock x:Name="InstallCurrentStageText"
                                                           FontSize="13" FontWeight="SemiBold"
                                                           Foreground="{StaticResource TextPrimaryBrush}"/>
                                            </StackPanel>
                                        </DockPanel>
                                    </Border>

                                    <ProgressBar x:Name="InstallProgressBar" Margin="0,12,0,0"
                                                 Style="{StaticResource WarmProgressBarStyle}"
                                                 Value="0" Visibility="Collapsed"/>

                                    <UniformGrid x:Name="InstallSubStepsPanel" Margin="0,14,0,0"
                                                 Rows="1" Columns="4" Visibility="Collapsed">
                                        <Border x:Name="InstallSubStep1Border" Margin="0,0,5,0" CornerRadius="9"
                                                Background="{StaticResource SurfaceSecondaryBrush}"
                                                BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                                            <TextBlock x:Name="InstallSubStep1Text" Text="环境检查"
                                                       Margin="6,8" TextAlignment="Center"
                                                       FontSize="11" FontWeight="SemiBold"
                                                       Foreground="{StaticResource TextTertiaryBrush}"/>
                                        </Border>
                                        <Border x:Name="InstallSubStep2Border" Margin="2.5,0,2.5,0" CornerRadius="9"
                                                Background="{StaticResource SurfaceSecondaryBrush}"
                                                BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                                            <TextBlock x:Name="InstallSubStep2Text" Text="下载依赖"
                                                       Margin="6,8" TextAlignment="Center"
                                                       FontSize="11" FontWeight="SemiBold"
                                                       Foreground="{StaticResource TextTertiaryBrush}"/>
                                        </Border>
                                        <Border x:Name="InstallSubStep3Border" Margin="2.5,0,2.5,0" CornerRadius="9"
                                                Background="{StaticResource SurfaceSecondaryBrush}"
                                                BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                                            <TextBlock x:Name="InstallSubStep3Text" Text="安装组件"
                                                       Margin="6,8" TextAlignment="Center"
                                                       FontSize="11" FontWeight="SemiBold"
                                                       Foreground="{StaticResource TextTertiaryBrush}"/>
                                        </Border>
                                        <Border x:Name="InstallSubStep4Border" Margin="5,0,0,0" CornerRadius="9"
                                                Background="{StaticResource SurfaceSecondaryBrush}"
                                                BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                                            <TextBlock x:Name="InstallSubStep4Text" Text="启动服务"
                                                       Margin="6,8" TextAlignment="Center"
                                                       FontSize="11" FontWeight="SemiBold"
                                                       Foreground="{StaticResource TextTertiaryBrush}"/>
                                        </Border>
                                    </UniformGrid>

                                    <WrapPanel Margin="0,20,0,0">
                                        <Button x:Name="StartInstallPageButton" Margin="0,0,10,8"
                                                Style="{StaticResource PrimaryButtonStyle}" Content="开始安装"/>
                                        <Button x:Name="InstallRequirementsButton" Margin="0,0,10,8"
                                                Style="{StaticResource SecondaryButtonStyle}" Content="查看安装要求"/>
                                        <Button x:Name="InstallRefreshButton" Margin="0,0,0,8"
                                                Style="{StaticResource TextButtonStyle}" Content="刷新状态"/>
                                    </WrapPanel>
                                </StackPanel>
                            </Border>

                            <Border x:Name="InstallPathCardBorder" Margin="0,16,0,0"
                                    Padding="26,22" CornerRadius="16"
                                    Background="{StaticResource SurfacePrimaryBrush}"
                                    BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1"
                                    Visibility="Collapsed">
                                <Border.Effect>
                                    <DropShadowEffect Color="#3C2814" Opacity="0.06" BlurRadius="18" ShadowDepth="3"/>
                                </Border.Effect>
                                <StackPanel>
                                    <Border HorizontalAlignment="Left" CornerRadius="999" Padding="10,4"
                                            Background="{StaticResource AccentTintBrush}">
                                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                            <Border Width="16" Height="16" CornerRadius="8"
                                                    Background="{StaticResource AccentPrimaryBrush}" Margin="0,0,7,0">
                                                <TextBlock Text="2" FontSize="10" FontWeight="Bold"
                                                           Foreground="{StaticResource TextOnAccentBrush}"
                                                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                            </Border>
                                            <TextBlock Text="位置确认" FontSize="11" FontWeight="Bold"
                                                       Foreground="{StaticResource AccentDeepBrush}"
                                                       VerticalAlignment="Center"/>
                                        </StackPanel>
                                    </Border>
                                    <TextBlock Margin="0,16,0,0" FontSize="22" FontWeight="Bold"
                                               Foreground="{StaticResource TextPrimaryBrush}"
                                               Text="确认安装位置"/>
                                    <TextBlock Margin="0,10,0,0" FontSize="13" TextWrapping="Wrap" LineHeight="19"
                                               Foreground="{StaticResource TextSecondaryBrush}"
                                               Text="Hermes 会装在下面这两个位置。多数人保持默认就好；如果 C 盘空间紧张可以改到 D 盘。"/>
                                    <TextBlock x:Name="InstallPathSummaryText" Margin="0,16,0,0"
                                               FontFamily="{StaticResource MonoFont}" FontSize="12"
                                               Foreground="{StaticResource TextPrimaryBrush}" TextWrapping="Wrap"/>
                                    <TextBlock x:Name="InstallLocationNoticeText" Margin="0,12,0,0" FontSize="12"
                                               Foreground="{StaticResource TextTertiaryBrush}" TextWrapping="Wrap"
                                               Text="安装完成后，可在“更多设置”中查看或调整。"/>
                                    <WrapPanel Margin="0,18,0,0">
                                        <Button x:Name="ConfirmInstallLocationButton" Margin="0,0,10,8"
                                                Style="{StaticResource PrimaryButtonStyle}" Content="位置已确认，继续"/>
                                        <Button x:Name="ChangeInstallLocationButton" Margin="0,0,10,8"
                                                Style="{StaticResource SecondaryButtonStyle}" Content="更改安装位置"/>
                                    </WrapPanel>
                                </StackPanel>
                            </Border>

                            <!-- 死代码（保留 collapsed） -->
                            <Border x:Name="InstallSettingsEditorBorder" Margin="0,16,0,0"
                                    Padding="18" CornerRadius="14"
                                    Background="{StaticResource SurfaceSecondaryBrush}"
                                    BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1"
                                    Visibility="Collapsed">
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
                                    <TextBlock Grid.Row="0" VerticalAlignment="Center"
                                               Foreground="{StaticResource TextSecondaryBrush}" Text="数据目录"/>
                                    <TextBox x:Name="HermesHomeTextBox" Grid.Row="0" Grid.Column="1"
                                             Margin="10,0,0,8" Padding="8"
                                             Background="{StaticResource SurfacePrimaryBrush}"
                                             Foreground="{StaticResource TextPrimaryBrush}"
                                             BorderBrush="{StaticResource LineSoftBrush}"/>
                                    <TextBlock Grid.Row="1" VerticalAlignment="Center"
                                               Foreground="{StaticResource TextSecondaryBrush}" Text="安装目录"/>
                                    <TextBox x:Name="InstallDirTextBox" Grid.Row="1" Grid.Column="1"
                                             Margin="10,0,0,8" Padding="8"
                                             Background="{StaticResource SurfacePrimaryBrush}"
                                             Foreground="{StaticResource TextPrimaryBrush}"
                                             BorderBrush="{StaticResource LineSoftBrush}"/>
                                    <TextBlock Grid.Row="2" VerticalAlignment="Center"
                                               Foreground="{StaticResource TextSecondaryBrush}" Text="Git 分支"/>
                                    <TextBox x:Name="BranchTextBox" Grid.Row="2" Grid.Column="1"
                                             Margin="10,0,0,8" Padding="8"
                                             Background="{StaticResource SurfacePrimaryBrush}"
                                             Foreground="{StaticResource TextPrimaryBrush}"
                                             BorderBrush="{StaticResource LineSoftBrush}" Text="main"/>
                                    <StackPanel Grid.Row="3" Grid.Column="1" Margin="10,0,0,0">
                                        <StackPanel Orientation="Horizontal">
                                            <CheckBox x:Name="NoVenvCheckBox" Margin="0,0,14,0" VerticalAlignment="Center" Content="NoVenv"/>
                                            <CheckBox x:Name="SkipSetupCheckBox" VerticalAlignment="Center"
                                                      IsChecked="True" Content="安装后不进入官方 setup"/>
                                        </StackPanel>
                                        <WrapPanel Margin="0,12,0,0">
                                            <Button x:Name="SaveInstallSettingsButton" Margin="0,0,10,8"
                                                    Style="{StaticResource SecondaryButtonStyle}" Content="保存更改"/>
                                            <Button x:Name="ResetInstallSettingsButton" Margin="0,0,10,8"
                                                    Style="{StaticResource TextButtonStyle}" Content="恢复默认"/>
                                        </WrapPanel>
                                    </StackPanel>
                                </Grid>
                            </Border>

                            <Border x:Name="InstallProgressCardBorder" Margin="0,16,0,0"
                                    Padding="22,20" CornerRadius="16"
                                    Background="{StaticResource SurfaceSecondaryBrush}"
                                    BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                                <StackPanel>
                                    <TextBlock x:Name="InstallProgressTitleText" FontSize="14" FontWeight="Bold"
                                               Foreground="{StaticResource TextSecondaryBrush}"
                                               Text="检测结果"/>
                                    <TextBlock x:Name="InstallProgressText" Margin="0,12,0,0" FontSize="13"
                                               TextWrapping="Wrap" LineHeight="19"
                                               Foreground="{StaticResource TextSecondaryBrush}"/>
                                    <TextBlock x:Name="InstallFailureSummaryText" Margin="0,14,0,0" FontSize="13"
                                               TextWrapping="Wrap" LineHeight="20"
                                               Foreground="{StaticResource DangerBrush}"
                                               Visibility="Collapsed"/>
                                    <Border x:Name="InstallFailureLogPreviewBorder" Margin="0,14,0,0"
                                            Padding="14,12" CornerRadius="11"
                                            Background="{StaticResource LogBgBrush}"
                                            Visibility="Collapsed">
                                        <StackPanel>
                                            <DockPanel LastChildFill="True">
                                                <Button x:Name="InstallFailureLogCopyButton" DockPanel.Dock="Right"
                                                        Style="{StaticResource LogSubButtonStyle}" Content="复制错误"/>
                                                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                                    <Ellipse Width="6" Height="6" Margin="0,0,8,0"
                                                             Fill="{StaticResource DangerBrush}"/>
                                                    <TextBlock Text="最近日志 · 末尾 8 行"
                                                               FontSize="11" FontWeight="Bold"
                                                               Foreground="#EBE8E0" VerticalAlignment="Center"/>
                                                </StackPanel>
                                            </DockPanel>
                                            <TextBox x:Name="InstallFailureLogPreviewText" Margin="0,10,0,0"
                                                     Background="Transparent" Foreground="#EBE8E0"
                                                     BorderThickness="0" IsReadOnly="True"
                                                     FontFamily="{StaticResource MonoFont}" FontSize="11.5"
                                                     TextWrapping="NoWrap"
                                                     VerticalScrollBarVisibility="Auto"
                                                     HorizontalScrollBarVisibility="Auto"
                                                     MaxHeight="120"/>
                                        </StackPanel>
                                    </Border>
                                </StackPanel>
                            </Border>

                            <Border x:Name="OpenClawPostInstallBorder" Margin="0,16,0,0"
                                    Padding="22,20" CornerRadius="16"
                                    Background="{StaticResource SurfacePrimaryBrush}"
                                    BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1"
                                    Visibility="Collapsed">
                                <StackPanel>
                                    <TextBlock FontSize="22" FontWeight="Bold"
                                               Foreground="{StaticResource TextPrimaryBrush}"
                                               Text="检测到旧版 OpenClaw 配置"/>
                                    <TextBlock x:Name="OpenClawPostInstallText" Margin="0,10,0,0" FontSize="13"
                                               TextWrapping="Wrap" LineHeight="19"
                                               Foreground="{StaticResource TextSecondaryBrush}"
                                               Text="Hermes 支持导入旧版 OpenClaw 配置。你可以现在迁移，也可以先跳过，之后再从“更多设置”里手动迁移。"/>
                                    <WrapPanel Margin="0,18,0,0">
                                        <Button x:Name="OpenClawImportButton" Margin="0,0,10,8"
                                                Style="{StaticResource PrimaryButtonStyle}" Content="立即迁移"/>
                                        <Button x:Name="OpenClawSkipButton" Margin="0,0,10,8"
                                                Style="{StaticResource SecondaryButtonStyle}" Content="暂不迁移"/>
                                    </WrapPanel>
                                </StackPanel>
                            </Border>
                        </StackPanel>

                        <!-- 右侧栏 3 大步骤指示器 -->
                        <Border x:Name="InstallStepIndicatorCard" Grid.Column="2" VerticalAlignment="Top"
                                Padding="22,20" CornerRadius="16"
                                Background="{StaticResource SurfaceSecondaryBrush}"
                                BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                            <StackPanel>
                                <TextBlock x:Name="InstallStepProgressTitle"
                                           FontSize="11" FontWeight="Bold"
                                           Foreground="{StaticResource TextTertiaryBrush}"
                                           Text="总进度 · 0 / 3"/>

                                <Border x:Name="InstallStep1Border" Margin="0,12,0,0"
                                        Padding="14,12" CornerRadius="11"
                                        Background="{StaticResource SurfacePrimaryBrush}"
                                        BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                                    <DockPanel LastChildFill="True">
                                        <Border DockPanel.Dock="Left" Width="26" Height="26" CornerRadius="13"
                                                Margin="0,0,12,0" VerticalAlignment="Center"
                                                x:Name="InstallStep1NumBg"
                                                Background="{StaticResource SurfaceTertiaryBrush}">
                                            <TextBlock x:Name="InstallStep1Num" Text="1" FontSize="12" FontWeight="Bold"
                                                       Foreground="{StaticResource TextTertiaryBrush}"
                                                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                        </Border>
                                        <StackPanel>
                                            <TextBlock x:Name="InstallStep1Title" Text="环境检测"
                                                       FontSize="13" FontWeight="SemiBold"
                                                       Foreground="{StaticResource TextPrimaryBrush}"/>
                                            <TextBlock x:Name="InstallStep1Desc" Margin="0,3,0,0" FontSize="11.5"
                                                       Foreground="{StaticResource TextTertiaryBrush}"
                                                       TextWrapping="Wrap"
                                                       Text="检查 Git、写入权限、网络通达性"/>
                                        </StackPanel>
                                    </DockPanel>
                                </Border>

                                <Border x:Name="InstallStep2Border" Margin="0,8,0,0"
                                        Padding="14,12" CornerRadius="11"
                                        Background="{StaticResource SurfacePrimaryBrush}"
                                        BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                                    <DockPanel LastChildFill="True">
                                        <Border DockPanel.Dock="Left" Width="26" Height="26" CornerRadius="13"
                                                Margin="0,0,12,0" VerticalAlignment="Center"
                                                x:Name="InstallStep2NumBg"
                                                Background="{StaticResource SurfaceTertiaryBrush}">
                                            <TextBlock x:Name="InstallStep2Num" Text="2" FontSize="12" FontWeight="Bold"
                                                       Foreground="{StaticResource TextTertiaryBrush}"
                                                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                        </Border>
                                        <StackPanel>
                                            <TextBlock x:Name="InstallStep2Title" Text="位置确认"
                                                       FontSize="13" FontWeight="SemiBold"
                                                       Foreground="{StaticResource TextPrimaryBrush}"/>
                                            <TextBlock x:Name="InstallStep2Desc" Margin="0,3,0,0" FontSize="11.5"
                                                       Foreground="{StaticResource TextTertiaryBrush}"
                                                       TextWrapping="Wrap"
                                                       Text="确认数据目录和安装目录"/>
                                        </StackPanel>
                                    </DockPanel>
                                </Border>

                                <Border x:Name="InstallStep3Border" Margin="0,8,0,0"
                                        Padding="14,12" CornerRadius="11"
                                        Background="{StaticResource SurfacePrimaryBrush}"
                                        BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                                    <DockPanel LastChildFill="True">
                                        <Border DockPanel.Dock="Left" Width="26" Height="26" CornerRadius="13"
                                                Margin="0,0,12,0" VerticalAlignment="Center"
                                                x:Name="InstallStep3NumBg"
                                                Background="{StaticResource SurfaceTertiaryBrush}">
                                            <TextBlock x:Name="InstallStep3Num" Text="3" FontSize="12" FontWeight="Bold"
                                                       Foreground="{StaticResource TextTertiaryBrush}"
                                                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                        </Border>
                                        <StackPanel>
                                            <TextBlock x:Name="InstallStep3Title" Text="开始安装"
                                                       FontSize="13" FontWeight="SemiBold"
                                                       Foreground="{StaticResource TextPrimaryBrush}"/>
                                            <TextBlock x:Name="InstallStep3Desc" Margin="0,3,0,0" FontSize="11.5"
                                                       Foreground="{StaticResource TextTertiaryBrush}"
                                                       TextWrapping="Wrap"
                                                       Text="下载并安装 Hermes Agent"/>
                                        </StackPanel>
                                    </DockPanel>
                                </Border>

                                <Border x:Name="InstallStepTipBorder" Margin="0,12,0,0"
                                        Padding="12,11" CornerRadius="10"
                                        Background="{StaticResource WarningSoftBrush}"
                                        Visibility="Collapsed">
                                    <TextBlock x:Name="InstallStepTipText"
                                               FontSize="11.5" TextWrapping="Wrap" LineHeight="17"
                                               Foreground="#6E5224"
                                               Text="另一个黑色窗口是官方安装终端，在那里下载和安装 Hermes。最小化它没问题，但请不要关闭。"/>
                                </Border>
                            </StackPanel>
                        </Border>
                    </Grid>
                </Border>

                <!-- ========== Home Mode ========== -->
                <Grid x:Name="HomeModePanel" Visibility="Collapsed">
                    <!-- 任务 014 QA Patch M1：HomeDepFailureBanner / HomeOpenClawBanner 移到
                         HomeModePanel 的直接子元素 StackPanel 里（而不是 HomeReadyContainer 内），
                         这样 Launching 阶段（HomeReadyContainer.Visibility=Collapsed）横幅仍可见，
                         避免陷阱 #4 复刻——用户在等待启动 WebUI 时也能看到失败提示。 -->
                    <StackPanel x:Name="HomeBannerStack" VerticalAlignment="Top" HorizontalAlignment="Center" Margin="0,0,0,0" Panel.ZIndex="10">
                        <!-- 任务 014 Bug A：渠道依赖安装失败横幅（默认隐藏，安装失败时显示） -->
                        <Border x:Name="HomeDepFailureBanner" Margin="0,0,0,8" Padding="16,12"
                                CornerRadius="12" MaxWidth="640"
                                Background="#FFF1EB" BorderBrush="#E59B4E" BorderThickness="1"
                                Visibility="Collapsed" Cursor="Hand">
                            <DockPanel LastChildFill="True">
                                <Button x:Name="HomeDepFailureViewButton" DockPanel.Dock="Right"
                                        Style="{StaticResource TextButtonStyle}" Content="查看详情"/>
                                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                    <TextBlock VerticalAlignment="Center" FontSize="20" Margin="0,0,10,0"
                                               Foreground="#B0502A" Text="!"/>
                                    <TextBlock x:Name="HomeDepFailureText" VerticalAlignment="Center"
                                               FontSize="13" TextWrapping="Wrap"
                                               Foreground="#6E3A1F"
                                               Text="渠道依赖未就绪。点这里查看详情"/>
                                </StackPanel>
                            </DockPanel>
                        </Border>
                        <!-- 任务 014 Bug B：旧版 OpenClaw 迁移横幅（不再强行进 Install Mode） -->
                        <Border x:Name="HomeOpenClawBanner" Margin="0,0,0,8" Padding="16,12"
                                CornerRadius="12" MaxWidth="640"
                                Background="{StaticResource SurfaceSecondaryBrush}"
                                BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1"
                                Visibility="Collapsed">
                            <DockPanel LastChildFill="True">
                                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                                    <Button x:Name="HomeOpenClawImportButton" Margin="0,0,8,0"
                                            Style="{StaticResource TextButtonStyle}" Content="立即迁移"/>
                                    <Button x:Name="HomeOpenClawSkipButton"
                                            Style="{StaticResource TextButtonStyle}" Content="稍后再说"/>
                                </StackPanel>
                                <TextBlock VerticalAlignment="Center" FontSize="13" TextWrapping="Wrap"
                                           Foreground="{StaticResource TextSecondaryBrush}"
                                           Text="检测到旧版 OpenClaw 配置，可按需迁移；不影响继续使用。"/>
                            </DockPanel>
                        </Border>
                    </StackPanel>
                    <Border x:Name="HomeReadyContainer">
                        <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,12,0,0">
                            <Border x:Name="HomeStatusBadgeBorder" Width="76" Height="76" CornerRadius="38"
                                    HorizontalAlignment="Center">
                                <Border.Background>
                                    <RadialGradientBrush GradientOrigin="0.38,0.35" Center="0.5,0.5" RadiusX="0.55" RadiusY="0.55">
                                        <GradientStop Color="#FFE7C4" Offset="0"/>
                                        <GradientStop Color="#F5C285" Offset="0.55"/>
                                        <GradientStop Color="#E59B4E" Offset="1"/>
                                    </RadialGradientBrush>
                                </Border.Background>
                                <Border.Effect>
                                    <DropShadowEffect Color="#A85420" Opacity="0.28" BlurRadius="22" ShadowDepth="6"/>
                                </Border.Effect>
                                <TextBlock Text="✓" FontFamily="{StaticResource UiFont}" FontSize="38" FontWeight="Bold"
                                           Foreground="{StaticResource TextOnAccentBrush}"
                                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <TextBlock x:Name="StatusHeadlineText" Margin="0,18,0,0"
                                       FontSize="34" FontWeight="Bold"
                                       Foreground="{StaticResource TextPrimaryBrush}"
                                       TextAlignment="Center" HorizontalAlignment="Center"
                                       Text="已就绪"/>
                            <TextBlock x:Name="StatusBodyText" Margin="0,12,0,0" MaxWidth="540"
                                       FontSize="14" LineHeight="22" TextWrapping="Wrap"
                                       Foreground="{StaticResource TextSecondaryBrush}"
                                       TextAlignment="Center" HorizontalAlignment="Center"/>
                            <WrapPanel Margin="0,22,0,0" HorizontalAlignment="Center">
                                <Button x:Name="PrimaryActionButton" Margin="0,0,12,10" MinWidth="160"
                                        Style="{StaticResource PrimaryButtonStyle}" Content="开始使用"/>
                                <Button x:Name="StageModelButton" Visibility="Collapsed" Width="0" Height="0" Padding="0" Margin="0" BorderThickness="0"/>
                                <Button x:Name="StageAdvancedButton" Margin="0,0,0,10"
                                        Style="{StaticResource SecondaryButtonStyle}" Content="更多设置"/>
                            </WrapPanel>
                            <TextBlock x:Name="RecommendationText" Margin="0,16,0,0" FontSize="12.5"
                                       Foreground="{StaticResource TextTertiaryBrush}"
                                       TextAlignment="Center" HorizontalAlignment="Center"/>
                            <TextBlock x:Name="RecommendationHintText" Visibility="Collapsed"/>
                            <Button x:Name="SecondaryActionButton" Visibility="Collapsed" Width="0" Height="0" Padding="0" Margin="0" BorderThickness="0"/>
                            <Button x:Name="RefreshButton" Visibility="Collapsed" Width="0" Height="0" Padding="0" Margin="0" BorderThickness="0"/>
                        </StackPanel>
                    </Border>

                    <Border x:Name="LaunchProgressCard" Margin="0,8,0,0"
                            Padding="28,24" CornerRadius="16"
                            Background="{StaticResource SurfacePrimaryBrush}"
                            BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1"
                            Visibility="Collapsed">
                        <Border.Effect>
                            <DropShadowEffect Color="#3C2814" Opacity="0.06" BlurRadius="18" ShadowDepth="3"/>
                        </Border.Effect>
                        <StackPanel>
                            <DockPanel LastChildFill="True">
                                <Border x:Name="LaunchSpinnerBorder" DockPanel.Dock="Left" Width="56" Height="56" CornerRadius="28"
                                        Margin="0,0,18,0">
                                    <Border.Background>
                                        <RadialGradientBrush GradientOrigin="0.38,0.35" Center="0.5,0.5" RadiusX="0.55" RadiusY="0.55">
                                            <GradientStop Color="#FFE7C4" Offset="0"/>
                                            <GradientStop Color="#F5C285" Offset="0.55"/>
                                            <GradientStop Color="#E59B4E" Offset="1"/>
                                        </RadialGradientBrush>
                                    </Border.Background>
                                    <Border.Effect>
                                        <DropShadowEffect Color="#A85420" Opacity="0.22" BlurRadius="16" ShadowDepth="4"/>
                                    </Border.Effect>
                                    <TextBlock x:Name="LaunchSpinnerGlyph" Text="⟳" FontFamily="{StaticResource UiFont}"
                                               FontSize="30" FontWeight="Bold"
                                               Foreground="{StaticResource TextOnAccentBrush}"
                                               HorizontalAlignment="Center" VerticalAlignment="Center"
                                               RenderTransformOrigin="0.5,0.5">
                                        <TextBlock.RenderTransform>
                                            <RotateTransform x:Name="LaunchSpinnerRotate" Angle="0"/>
                                        </TextBlock.RenderTransform>
                                    </TextBlock>
                                </Border>
                                <StackPanel VerticalAlignment="Center">
                                    <TextBlock x:Name="LaunchProgressEyebrow" Text="正在启动 WebUI"
                                               FontSize="11" FontWeight="Bold"
                                               Foreground="{StaticResource AccentDeepBrush}"/>
                                    <TextBlock x:Name="LaunchProgressHeadline" Margin="0,4,0,0"
                                               FontSize="22" FontWeight="Bold" TextWrapping="Wrap"
                                               Foreground="{StaticResource TextPrimaryBrush}"
                                               Text="第一次启动需要装一些组件"/>
                                    <TextBlock x:Name="LaunchProgressSubline" Margin="0,4,0,0"
                                               FontSize="12.5" TextWrapping="Wrap" LineHeight="18"
                                               Foreground="{StaticResource TextSecondaryBrush}"
                                               Text="完成后会自动在浏览器中打开 hermes-web-ui · 中途请勿关闭窗口"/>
                                </StackPanel>
                            </DockPanel>

                            <Border Margin="0,16,0,0"
                                    Padding="14,11" CornerRadius="11"
                                    Background="{StaticResource SurfaceSecondaryBrush}"
                                    BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                                <DockPanel LastChildFill="True">
                                    <TextBlock x:Name="LaunchCurrentStageDetail" DockPanel.Dock="Right"
                                               FontSize="11"
                                               Foreground="{StaticResource TextTertiaryBrush}"
                                               VerticalAlignment="Center"/>
                                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                        <Ellipse Width="7" Height="7" Margin="0,0,10,0"
                                                 Fill="{StaticResource AccentPrimaryBrush}"/>
                                        <TextBlock x:Name="LaunchCurrentStageText"
                                                   FontSize="13" FontWeight="SemiBold"
                                                   Foreground="{StaticResource TextPrimaryBrush}"
                                                   Text="正在检查环境"/>
                                    </StackPanel>
                                </DockPanel>
                            </Border>

                            <ProgressBar x:Name="LaunchProgressBar" Margin="0,12,0,0"
                                         Style="{StaticResource WarmProgressBarStyle}" Value="0"/>

                            <UniformGrid x:Name="LaunchProgressMiniSteps" Margin="0,12,0,0" Rows="1" Columns="7">
                                <Border x:Name="LaunchMiniStep1Border" Margin="0,0,3,0" CornerRadius="8"
                                        Background="{StaticResource SurfaceSecondaryBrush}"
                                        BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                                    <TextBlock x:Name="LaunchMiniStep1Text" Text="环境" Margin="3,7"
                                               TextAlignment="Center" FontSize="10.5" FontWeight="SemiBold"
                                               Foreground="{StaticResource TextTertiaryBrush}"/>
                                </Border>
                                <Border x:Name="LaunchMiniStep2Border" Margin="1.5,0,1.5,0" CornerRadius="8"
                                        Background="{StaticResource SurfaceSecondaryBrush}"
                                        BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                                    <TextBlock x:Name="LaunchMiniStep2Text" Text="下载 Node" Margin="3,7"
                                               TextAlignment="Center" FontSize="10.5" FontWeight="SemiBold"
                                               Foreground="{StaticResource TextTertiaryBrush}"/>
                                </Border>
                                <Border x:Name="LaunchMiniStep3Border" Margin="1.5,0,1.5,0" CornerRadius="8"
                                        Background="{StaticResource SurfaceSecondaryBrush}"
                                        BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                                    <TextBlock x:Name="LaunchMiniStep3Text" Text="解压" Margin="3,7"
                                               TextAlignment="Center" FontSize="10.5" FontWeight="SemiBold"
                                               Foreground="{StaticResource TextTertiaryBrush}"/>
                                </Border>
                                <Border x:Name="LaunchMiniStep4Border" Margin="1.5,0,1.5,0" CornerRadius="8"
                                        Background="{StaticResource SurfaceSecondaryBrush}"
                                        BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                                    <TextBlock x:Name="LaunchMiniStep4Text" Text="装 WebUI" Margin="3,7"
                                               TextAlignment="Center" FontSize="10.5" FontWeight="SemiBold"
                                               Foreground="{StaticResource TextTertiaryBrush}"/>
                                </Border>
                                <Border x:Name="LaunchMiniStep5Border" Margin="1.5,0,1.5,0" CornerRadius="8"
                                        Background="{StaticResource SurfaceSecondaryBrush}"
                                        BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                                    <TextBlock x:Name="LaunchMiniStep5Text" Text="启 Gateway" Margin="3,7"
                                               TextAlignment="Center" FontSize="10.5" FontWeight="SemiBold"
                                               Foreground="{StaticResource TextTertiaryBrush}"/>
                                </Border>
                                <Border x:Name="LaunchMiniStep6Border" Margin="1.5,0,1.5,0" CornerRadius="8"
                                        Background="{StaticResource SurfaceSecondaryBrush}"
                                        BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                                    <TextBlock x:Name="LaunchMiniStep6Text" Text="等待就绪" Margin="3,7"
                                               TextAlignment="Center" FontSize="10.5" FontWeight="SemiBold"
                                               Foreground="{StaticResource TextTertiaryBrush}"/>
                                </Border>
                                <Border x:Name="LaunchMiniStep7Border" Margin="3,0,0,0" CornerRadius="8"
                                        Background="{StaticResource SurfaceSecondaryBrush}"
                                        BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                                    <TextBlock x:Name="LaunchMiniStep7Text" Text="启 WebUI" Margin="3,7"
                                               TextAlignment="Center" FontSize="10.5" FontWeight="SemiBold"
                                               Foreground="{StaticResource TextTertiaryBrush}"/>
                                </Border>
                            </UniformGrid>

                            <DockPanel Margin="0,16,0,0" LastChildFill="True">
                                <TextBlock x:Name="LaunchProgressEstTime" DockPanel.Dock="Right"
                                           FontSize="11.5"
                                           Foreground="{StaticResource TextTertiaryBrush}"
                                           VerticalAlignment="Center"/>
                                <Button x:Name="LaunchProgressCancelButton"
                                        HorizontalAlignment="Left"
                                        Style="{StaticResource SecondaryButtonStyle}" Content="取消并返回"/>
                            </DockPanel>
                        </StackPanel>
                    </Border>
                </Grid>
            </Grid>
        </ScrollViewer>

        <!-- Log + Footer (Install Mode 显示) -->
        <StackPanel Grid.Row="2" Margin="34,14,34,16">
            <Border x:Name="LogSectionBorder"
                    Padding="14,12" CornerRadius="12"
                    Background="{StaticResource LogBgBrush}"
                    BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1"
                    MaxHeight="180">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <DockPanel Grid.Row="0" LastChildFill="False">
                        <TextBlock DockPanel.Dock="Left" FontSize="13" FontWeight="Bold"
                                   Foreground="#EBE8E0" Text="安装日志"/>
                        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                            <Button x:Name="CopyFeedbackButton" Margin="0,0,8,0"
                                    Style="{StaticResource LogSubButtonStyle}" Content="复制反馈信息"/>
                            <Button x:Name="ClearLogButton"
                                    Style="{StaticResource LogSubButtonStyle}" Content="清空"/>
                        </StackPanel>
                    </DockPanel>
                    <TextBox x:Name="LogTextBox" Grid.Row="1" Margin="0,8,0,0" MinHeight="60" MaxHeight="110"
                             Background="Transparent" Foreground="#EBE8E0" BorderThickness="0"
                             FontFamily="{StaticResource MonoFont}" FontSize="12"
                             AcceptsReturn="True" AcceptsTab="True"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                             IsReadOnly="True" TextWrapping="NoWrap"/>
                </Grid>
            </Border>

            <Border x:Name="FooterBorder" Margin="0,8,0,0"
                    Padding="14,8" CornerRadius="10"
                    Background="{StaticResource SurfaceSecondaryBrush}"
                    BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                <DockPanel LastChildFill="True">
                    <TextBlock x:Name="FooterVersionText" DockPanel.Dock="Right" FontSize="11"
                               Foreground="{StaticResource TextTertiaryBrush}" VerticalAlignment="Center"/>
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse Width="6" Height="6" Margin="0,0,8,0" Fill="{StaticResource AccentPrimaryBrush}"/>
                        <TextBlock x:Name="FooterText" FontSize="11.5"
                                   Foreground="{StaticResource TextSecondaryBrush}"
                                   Text="就绪"/>
                    </StackPanel>
                </DockPanel>
            </Border>
        </StackPanel>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$window.Title = "Hermes Agent 桌面控制台"

$controls = @{}
foreach ($name in @(
    # 模式容器 + Install Mode 主结构
    'InstallModePanel','HomeModePanel','InstallPathCardBorder','InstallTaskCardBorder','InstallProgressCardBorder','InstallProgressTitleText','OpenClawPostInstallBorder','OpenClawPostInstallText','OpenClawImportButton','OpenClawSkipButton','InstallPathSummaryText','InstallLocationNoticeText','InstallSettingsEditorBorder',
    'ChangeInstallLocationButton','ConfirmInstallLocationButton','SaveInstallSettingsButton','ResetInstallSettingsButton',
    'InstallTaskTitleText','InstallTaskBodyText','StartInstallPageButton','InstallRequirementsButton','InstallRefreshButton',
    'InstallProgressText','InstallFailureSummaryText','StatusHeadlineText','StatusBodyText','RecommendationText','RecommendationHintText',
    'RefreshButton','PrimaryActionButton','SecondaryActionButton','StageModelButton','StageAdvancedButton',
    'HermesHomeTextBox','InstallDirTextBox','BranchTextBox','NoVenvCheckBox','SkipSetupCheckBox',
    'LogSectionBorder','CopyFeedbackButton','ClearLogButton','LogTextBox','FooterBorder','FooterText','FooterVersionText',
    'AboutButton','TelemetryConsentBanner','TelemetryConsentDismissButton',
    # 任务 012 新增 - Header
    'BrandTitleText','BrandSubtitleText',
    # 任务 012 新增 - 安装任务卡（步骤 tag、当前阶段、子阶段、进度条）
    'InstallTaskStepTagBorder','InstallTaskStepTagNum','InstallTaskStepTagText',
    'InstallCurrentStageBorder','InstallCurrentStageText','InstallCurrentStageDetail',
    'InstallProgressBar','InstallSubStepsPanel',
    'InstallSubStep1Border','InstallSubStep1Text','InstallSubStep2Border','InstallSubStep2Text',
    'InstallSubStep3Border','InstallSubStep3Text','InstallSubStep4Border','InstallSubStep4Text',
    # 任务 012 新增 - 失败日志预览
    'InstallFailureLogPreviewBorder','InstallFailureLogPreviewText','InstallFailureLogCopyButton',
    # 任务 012 新增 - 右栏 3 大步骤指示器
    'InstallStepIndicatorCard','InstallStepProgressTitle',
    'InstallStep1Border','InstallStep1NumBg','InstallStep1Num','InstallStep1Title','InstallStep1Desc',
    'InstallStep2Border','InstallStep2NumBg','InstallStep2Num','InstallStep2Title','InstallStep2Desc',
    'InstallStep3Border','InstallStep3NumBg','InstallStep3Num','InstallStep3Title','InstallStep3Desc',
    'InstallStepTipBorder','InstallStepTipText',
    # 任务 012 新增 - Home Mode 已就绪 + 启动 WebUI 进度卡
    'HomeReadyContainer','HomeStatusBadgeBorder',
    # 任务 014 新增 - Home Mode 内 OpenClaw 迁移横幅（Bug B）+ 渠道依赖失败横幅（Bug A）
    # QA Patch M1：横幅移到 HomeModePanel 顶部 StackPanel（不在 HomeReadyContainer 内），
    # 这样 Launching 阶段（HomeReadyContainer 隐藏）横幅仍可见。
    'HomeBannerStack',
    'HomeDepFailureBanner','HomeDepFailureText','HomeDepFailureViewButton',
    'HomeOpenClawBanner','HomeOpenClawImportButton','HomeOpenClawSkipButton',
    'LaunchProgressCard','LaunchSpinnerBorder','LaunchSpinnerGlyph','LaunchSpinnerRotate',
    'LaunchProgressEyebrow','LaunchProgressHeadline','LaunchProgressSubline',
    'LaunchCurrentStageText','LaunchCurrentStageDetail','LaunchProgressBar','LaunchProgressMiniSteps',
    'LaunchMiniStep1Border','LaunchMiniStep1Text','LaunchMiniStep2Border','LaunchMiniStep2Text',
    'LaunchMiniStep3Border','LaunchMiniStep3Text','LaunchMiniStep4Border','LaunchMiniStep4Text',
    'LaunchMiniStep5Border','LaunchMiniStep5Text','LaunchMiniStep6Border','LaunchMiniStep6Text',
    'LaunchMiniStep7Border','LaunchMiniStep7Text',
    'LaunchProgressEstTime','LaunchProgressCancelButton'
)) {
    $controls[$name] = $window.FindName($name)
}

# 任务 012：FooterVersionText 在 XAML 里没默认值（避免 XAML 字符串内 $($script:LauncherVersion) 让 [xml] 解析变脆），上来在代码里设。
try { if ($controls.FooterVersionText) { $controls.FooterVersionText.Text = $script:LauncherVersion } } catch { }
try { if ($controls.BrandSubtitleText) { $controls.BrandSubtitleText.Text = "更聪明的个人 AI 助理 · $($script:LauncherVersion)" } } catch { }

$controls.HermesHomeTextBox.Text = $defaults.HermesHome
$controls.InstallDirTextBox.Text = $defaults.InstallDir
$controls.BranchTextBox.Text = 'main'
$controls.SkipSetupCheckBox.IsChecked = $true

$script:CrashLogPath = Join-Path $env:TEMP 'HermesGuiLauncher-crash.log'
$script:InstallLocationConfirmed = $false
$script:InstallPreflightConfirmed = $false
# 任务 014 Bug M (v2026.05.04.17):国内网络环境警告 ack 标志
# 用户在 NetworkEnv='china' 第一次点"开始安装"时弹一次警告,同一 launcher 会话不再重复弹
$script:ChinaNetworkAcknowledged = $false
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
        try {
            Send-Telemetry -EventName 'unexpected_error' -FailureReason ('dispatcher: ' + $eventArgs.Exception.GetType().FullName + ': ' + $eventArgs.Exception.Message) -Properties @{ source = 'dispatcher' }
        } catch { }
        $eventArgs.Handled = $true  # 防止未捕获异常导致进程崩溃（陷阱 #1）
    })
    [AppDomain]::CurrentDomain.add_UnhandledException({
        param($sender, $eventArgs)
        Write-CrashLog ("UnhandledException: " + $eventArgs.ExceptionObject.ToString())
        try {
            $exType = if ($eventArgs.ExceptionObject) { $eventArgs.ExceptionObject.GetType().FullName } else { 'unknown' }
            $exMsg = if ($eventArgs.ExceptionObject -and $eventArgs.ExceptionObject.Message) { [string]$eventArgs.ExceptionObject.Message } else { 'unknown' }
            Send-Telemetry -EventName 'unexpected_error' -FailureReason ('appdomain: ' + $exType + ': ' + $exMsg) -Properties @{ source = 'appdomain' }
        } catch { }
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

    # 任务 011：检测此次启动时模型是否已配置，未配置 → 用户即将进 webui 配置
    try {
        $hermesHomeForCheck = Join-Path $env:USERPROFILE '.hermes'
        $modelStatus = Test-HermesModelConfigured -HermesHome $hermesHomeForCheck
        if (-not $modelStatus.HasApiKey) {
            Send-TelemetryOnce -EventName 'model_config_started'
        } else {
            Send-TelemetryOnce -EventName 'model_config_validated'
        }
    } catch {
        try { Send-Telemetry -EventName 'model_config_failed' -FailureReason $_.Exception.Message } catch { }
    }

    # Check if webui already running — if so, just open browser (fast path, no blocking)
    $health = Test-HermesWebUiHealth
    if ($health.Healthy) {
        # Ensure config port is correct, gateway is alive, and deps installed.
        Repair-GatewayApiPort

        # Ensure $script:GatewayHermesExe is set so the .env watcher can restart
        # gateway later.  When gateway was started by a PREVIOUS launcher session,
        # this variable is null → Restart-HermesGateway silently skips → user
        # configures Telegram/WeChat in webui → .env changes → gateway never
        # reloads → "发消息均无回应".
        if (-not $script:GatewayHermesExe) {
            $hermesExe = Join-Path $InstallDir 'venv\Scripts\hermes.exe'
            if (Test-Path $hermesExe) {
                $script:GatewayHermesExe = $hermesExe
            }
        }

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

        $gatewayStartedOrRestarted = $false
        if (-not $gatewayAlive) {
            Add-LogLine "Gateway 未在运行，正在启动..."
            Start-HermesGateway -HermesInstallDir $InstallDir
            $gatewayStartedOrRestarted = $true
        } elseif ($depsInstalled) {
            Add-LogLine "检测到新安装的渠道依赖，正在重启 Gateway..."
            Restart-HermesGateway
            $gatewayStartedOrRestarted = $true
        } elseif (Test-GatewayConfigStale) {
            # 任务 014 Bug D (v2026.05.04.7):.env 比 gateway 启动还新 → gateway 用的是旧配置。
            # 场景:用户上次启动 launcher 后,在 webui 里配了新平台(如微信),launcher 退出后
            # .env watcher 也跟着没了,gateway 一直跑着旧配置。这次重新打开 launcher 必须 restart。
            # 见陷阱 #44。
            Add-LogLine ".env 比 Gateway 启动时间新，重启 Gateway 加载新渠道配置..."
            Restart-HermesGateway
            $gatewayStartedOrRestarted = $true
        }

        # Wait for gateway health before opening browser (陷阱 #23).
        # Without this, webui opens against an unready gateway → "未连接".
        if ($gatewayStartedOrRestarted) {
            $gwDeadline = (Get-Date).AddSeconds(15)
            while ((Get-Date) -lt $gwDeadline) {
                Start-Sleep -Milliseconds 1000
                try {
                    $null = Invoke-RestMethod -Uri 'http://127.0.0.1:8642/health' -TimeoutSec 2 -ErrorAction Stop
                    Add-LogLine 'Gateway 健康检查通过。'
                    break
                } catch { }
            }
        } else {
            # Gateway was already running — verify it's actually healthy
            try {
                $null = Invoke-RestMethod -Uri 'http://127.0.0.1:8642/health' -TimeoutSec 3 -ErrorAction Stop
            } catch {
                # Gateway process exists but API not responding — restart
                Add-LogLine "Gateway 进程存在但 API 未响应，正在重启..."
                Start-HermesGateway -HermesInstallDir $InstallDir
                $gwDeadline = (Get-Date).AddSeconds(15)
                while ((Get-Date) -lt $gwDeadline) {
                    Start-Sleep -Milliseconds 1000
                    try {
                        $null = Invoke-RestMethod -Uri 'http://127.0.0.1:8642/health' -TimeoutSec 2 -ErrorAction Stop
                        Add-LogLine 'Gateway 健康检查通过。'
                        break
                    } catch { }
                }
            }
        }

        # Start .env watcher so webui config changes trigger gateway restart
        Start-GatewayEnvWatcher

        Open-BrowserUrlSafe -Url $health.Url
        Add-ActionLog -Action '开始使用' -Result ("已打开 hermes-web-ui：{0}" -f $health.Url) -Next '在浏览器中完成模型配置和对话'
        try { Send-TelemetryOnce -EventName 'webui_started' -Properties @{ path = 'fast' } } catch { }
        $controls.PrimaryActionButton.IsEnabled = $true
        return
    }

    $script:LaunchState = @{
        Phase              = 'check-install'
        InstallDir         = $InstallDir
        HermesCommand      = $HermesCommand
        WebClient          = $null
        DownloadZipPath    = $null
        DownloadDone       = $false
        DownloadError      = $null
        NpmProcess         = $null
        HealthDeadline     = $null
        # 任务 012 P1-3：Expand-Archive 后台 Runspace 追踪字段
        ExtractRunspace    = $null
        ExtractPowerShell  = $null
        ExtractAsyncResult = $null
    }

    Add-ActionLog -Action '开始使用' -Result '正在检查环境...' -Next '请稍候'
    Set-Footer '正在检查环境...'

    # 任务 012：显示 LaunchProgressCard 修 Home Mode 启动 webui 时无反馈盲区
    Show-LaunchProgressCard

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
    # 任务 014 Bug C (v2026.05.04.6):success 态停留期间用户点关闭按钮 → 立刻 stop 倒计时 timer
    if ($script:LaunchSuccessHideTimer) {
        try { $script:LaunchSuccessHideTimer.Stop() } catch { }
        $script:LaunchSuccessHideTimer = $null
    }
    # 任务 012 P1-3：如果解压 Runspace 还在跑，安全释放（不等完成，不抛异常）
    if ($script:LaunchState) {
        try {
            if ($script:LaunchState.ExtractPowerShell) {
                $script:LaunchState.ExtractPowerShell.Stop()
                $script:LaunchState.ExtractPowerShell.Dispose()
            }
        } catch { }
        try {
            if ($script:LaunchState.ExtractRunspace) {
                $script:LaunchState.ExtractRunspace.Close()
                $script:LaunchState.ExtractRunspace.Dispose()
            }
        } catch { }
    }
    $script:LaunchState = $null
    $controls.PrimaryActionButton.IsEnabled = $true
    Set-Footer ''
    Hide-LaunchProgressCard
    if ($ErrorMessage) {
        Add-ActionLog -Action '开始使用' -Result ('失败：' + $ErrorMessage) -Next '可改用命令行对话'
        try { Send-Telemetry -EventName 'webui_failed' -FailureReason $ErrorMessage } catch { }
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

# ============== 任务 012：UI 状态同步 helpers ==============
# 这些函数集中处理"步骤指示器卡片状态切换"和"WebUI 启动进度卡同步"两块新视觉。
# 不动业务逻辑，只是视觉 mapping。

# 把 Brush 转成 SolidColorBrush（XAML token 引用）
function Get-PaletteBrush {
    param([string]$Key)
    try { return $window.FindResource($Key) } catch { return $null }
}

# 设置 InstallStep1/2/3 卡片的视觉态：'pending' / 'active' / 'done' / 'failed'
function Set-InstallStepCardState {
    param(
        [int]$StepIndex,    # 1/2/3
        [string]$State      # pending / active / done / failed
    )
    try {
        $border  = $controls["InstallStep$($StepIndex)Border"]
        $numBg   = $controls["InstallStep$($StepIndex)NumBg"]
        $numText = $controls["InstallStep$($StepIndex)Num"]
        $title   = $controls["InstallStep$($StepIndex)Title"]
        if (-not $border -or -not $numBg -or -not $numText -or -not $title) { return }

        $surfacePrimary  = Get-PaletteBrush 'SurfacePrimaryBrush'
        $lineSofter      = Get-PaletteBrush 'LineSofterBrush'
        $surfaceTertiary = Get-PaletteBrush 'SurfaceTertiaryBrush'
        $textPrimary     = Get-PaletteBrush 'TextPrimaryBrush'
        $textTertiary    = Get-PaletteBrush 'TextTertiaryBrush'
        $textOnAccent    = Get-PaletteBrush 'TextOnAccentBrush'
        $accentPrimary   = Get-PaletteBrush 'AccentPrimaryBrush'
        $accentDeep      = Get-PaletteBrush 'AccentDeepBrush'
        $accentBorder    = Get-PaletteBrush 'AccentBorderBrush'
        $success         = Get-PaletteBrush 'SuccessBrush'
        $danger          = Get-PaletteBrush 'DangerBrush'

        switch ($State) {
            'pending' {
                $border.Background = $surfacePrimary
                $border.BorderBrush = $lineSofter
                $numBg.Background = $surfaceTertiary
                $numText.Foreground = $textTertiary
                $numText.Text = "$StepIndex"
                $title.Foreground = $textPrimary
            }
            'active' {
                $border.Background = $surfacePrimary
                $border.BorderBrush = $accentBorder
                $numBg.Background = $accentPrimary
                $numText.Foreground = $textOnAccent
                $numText.Text = "$StepIndex"
                $title.Foreground = $accentDeep
            }
            'done' {
                $border.Background = $surfacePrimary
                $border.BorderBrush = $lineSofter
                $numBg.Background = $success
                $numText.Foreground = $textOnAccent
                $numText.Text = '✓'
                $title.Foreground = $success
            }
            'failed' {
                $border.Background = $surfacePrimary
                $border.BorderBrush = $danger
                $numBg.Background = $danger
                $numText.Foreground = $textOnAccent
                $numText.Text = '×'
                $title.Foreground = $danger
            }
        }
    } catch { }
}

# 设置一组 InstallSubStep1-4（4 段子阶段）的视觉态
function Set-InstallSubStepState {
    param(
        [int]$SubStepIndex, # 1/2/3/4
        [string]$State      # pending / active / done
    )
    try {
        $border = $controls["InstallSubStep$($SubStepIndex)Border"]
        $text   = $controls["InstallSubStep$($SubStepIndex)Text"]
        if (-not $border -or -not $text) { return }

        $surfaceSecondary = Get-PaletteBrush 'SurfaceSecondaryBrush'
        $lineSofter       = Get-PaletteBrush 'LineSofterBrush'
        $textTertiary     = Get-PaletteBrush 'TextTertiaryBrush'
        $accentPrimary    = Get-PaletteBrush 'AccentPrimaryBrush'
        $accentDeep       = Get-PaletteBrush 'AccentDeepBrush'
        $accentBorder     = Get-PaletteBrush 'AccentBorderBrush'
        $success          = Get-PaletteBrush 'SuccessBrush'
        $successSoft      = Get-PaletteBrush 'SuccessSoftBrush'

        switch ($State) {
            'pending' {
                $border.Background = $surfaceSecondary
                $border.BorderBrush = $lineSofter
                $text.Foreground = $textTertiary
            }
            'active' {
                $border.Background = ([System.Windows.Media.BrushConverter]::new().ConvertFromString('#33F4C98A'))
                $border.BorderBrush = $accentBorder
                $text.Foreground = $accentDeep
            }
            'done' {
                $border.Background = $successSoft
                $border.BorderBrush = ([System.Windows.Media.BrushConverter]::new().ConvertFromString('#4D4F8F7A'))
                $text.Foreground = $success
            }
        }
    } catch { }
}

# 设置一组 LaunchMiniStep1-7 的视觉态
function Set-LaunchMiniStepState {
    param(
        [int]$StepIndex, # 1..7
        [string]$State   # pending / active / done
    )
    try {
        $border = $controls["LaunchMiniStep$($StepIndex)Border"]
        $text   = $controls["LaunchMiniStep$($StepIndex)Text"]
        if (-not $border -or -not $text) { return }

        $surfaceSecondary = Get-PaletteBrush 'SurfaceSecondaryBrush'
        $lineSofter       = Get-PaletteBrush 'LineSofterBrush'
        $textTertiary     = Get-PaletteBrush 'TextTertiaryBrush'
        $accentDeep       = Get-PaletteBrush 'AccentDeepBrush'
        $accentBorder     = Get-PaletteBrush 'AccentBorderBrush'
        $success          = Get-PaletteBrush 'SuccessBrush'
        $successSoft      = Get-PaletteBrush 'SuccessSoftBrush'

        switch ($State) {
            'pending' {
                $border.Background = $surfaceSecondary
                $border.BorderBrush = $lineSofter
                $text.Foreground = $textTertiary
            }
            'active' {
                $border.Background = ([System.Windows.Media.BrushConverter]::new().ConvertFromString('#33F4C98A'))
                $border.BorderBrush = $accentBorder
                $text.Foreground = $accentDeep
            }
            'done' {
                $border.Background = $successSoft
                $border.BorderBrush = ([System.Windows.Media.BrushConverter]::new().ConvertFromString('#4D4F8F7A'))
                $text.Foreground = $success
            }
        }
    } catch { }
}

# Phase -> mini-step 索引（1-7）映射 + 文案
$script:LaunchPhaseMap = @{
    'check-install'        = @{ Step = 1; Text = '正在检查环境';     Detail = '';                        ProgressMin = 5;   ProgressMax = 12  }
    'download-node'        = @{ Step = 2; Text = '正在下载 Node.js'; Detail = '约 30 MB · 网络较差时偏慢'; ProgressMin = 12;  ProgressMax = 38  }
    'extract-node'         = @{ Step = 3; Text = '正在解压 Node.js'; Detail = '';                        ProgressMin = 38;  ProgressMax = 45  }
    'npm-install'          = @{ Step = 4; Text = '正在安装 hermes-web-ui'; Detail = '约 1-2 分钟';      ProgressMin = 45;  ProgressMax = 70  }
    'start-gateway'        = @{ Step = 5; Text = '正在启动 Hermes Gateway'; Detail = '';               ProgressMin = 70;  ProgressMax = 78  }
    'wait-gateway-healthy' = @{ Step = 6; Text = '等待 Gateway 就绪';  Detail = '';                     ProgressMin = 78;  ProgressMax = 88  }
    'start-webui'          = @{ Step = 7; Text = '正在启动 hermes-web-ui'; Detail = '';                ProgressMin = 88;  ProgressMax = 95  }
    'wait-healthy'         = @{ Step = 6; Text = '等待 hermes-web-ui 就绪'; Detail = '健康检查中';       ProgressMin = 90;  ProgressMax = 99  }
}
# 任务 014 Bug C (v2026.05.04.6):wait-healthy.Step 从 7 改成 6,跟 mini-step 6 "等待就绪" 对齐
# (mini-step 7 "启 WebUI" 应该在最终成功瞬间才标 done,由 Set-LaunchProgressCardSuccess 处理)

# 显示 LaunchProgressCard,隐藏 HomeReadyContainer
function Show-LaunchProgressCard {
    try {
        if ($controls.LaunchProgressCard) { $controls.LaunchProgressCard.Visibility = 'Visible' }
        if ($controls.HomeReadyContainer) { $controls.HomeReadyContainer.Visibility = 'Collapsed' }
        # reset all mini-steps
        for ($i = 1; $i -le 7; $i++) { Set-LaunchMiniStepState -StepIndex $i -State 'pending' }
        if ($controls.LaunchProgressBar) { $controls.LaunchProgressBar.Value = 0 }
        if ($controls.LaunchCurrentStageText) { $controls.LaunchCurrentStageText.Text = '正在检查环境' }
        if ($controls.LaunchCurrentStageDetail) { $controls.LaunchCurrentStageDetail.Text = '' }
        if ($controls.LaunchProgressEstTime) { $controls.LaunchProgressEstTime.Text = '' }

        # 任务 014 Bug C (v2026.05.04.6):上次 success 态残留可能让 spinner 还是墨绿/✓ — 复位为暖橙 ⟳
        try {
            if ($controls.LaunchSpinnerBorder) {
                $rgb = New-Object System.Windows.Media.RadialGradientBrush
                $rgb.GradientOrigin = New-Object System.Windows.Point 0.38, 0.35
                $rgb.Center = New-Object System.Windows.Point 0.5, 0.5
                $rgb.RadiusX = 0.55; $rgb.RadiusY = 0.55
                $rgb.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromRgb(0xFF, 0xE7, 0xC4)), 0))
                $rgb.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromRgb(0xF5, 0xC2, 0x85)), 0.55))
                $rgb.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromRgb(0xE5, 0x9B, 0x4E)), 1))
                $controls.LaunchSpinnerBorder.Background = $rgb
            }
            if ($controls.LaunchSpinnerGlyph) { $controls.LaunchSpinnerGlyph.Text = [char]0x27F3 }  # ⟳
            if ($controls.LaunchSpinnerRotate) { $controls.LaunchSpinnerRotate.Angle = 0 }
            if ($controls.LaunchProgressEyebrow) {
                $controls.LaunchProgressEyebrow.Text = '正在启动 WebUI'
                $accentDeep = Get-PaletteBrush 'AccentDeepBrush'
                if ($accentDeep) { $controls.LaunchProgressEyebrow.Foreground = $accentDeep }
            }
            if ($controls.LaunchProgressHeadline) { $controls.LaunchProgressHeadline.Text = '第一次启动需要装一些组件' }
            if ($controls.LaunchProgressSubline) { $controls.LaunchProgressSubline.Text = '完成后会自动在浏览器中打开 hermes-web-ui · 中途请勿关闭窗口' }
            if ($controls.LaunchProgressCancelButton) { $controls.LaunchProgressCancelButton.Content = '取消并返回' }
        } catch { }
    } catch { }
}

# 任务 014 Bug C (v2026.05.04.6):切换 LaunchProgressCard 到 success 态
# wait-healthy 检测到 webui 健康后调用此函数,展示"全 7 段绿 ✓ + URL bar + 倒计时收起"
# 见设计稿 mockups/011-windows-ui-extra/08-launching-success.html
function Set-LaunchProgressCardSuccess {
    param([string]$Url)
    try {
        # spinner Border 切墨绿径向渐变
        if ($controls.LaunchSpinnerBorder) {
            $rgb = New-Object System.Windows.Media.RadialGradientBrush
            $rgb.GradientOrigin = New-Object System.Windows.Point 0.38, 0.35
            $rgb.Center = New-Object System.Windows.Point 0.5, 0.5
            $rgb.RadiusX = 0.55; $rgb.RadiusY = 0.55
            $rgb.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromRgb(0xB8, 0xDD, 0xCC)), 0))
            $rgb.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromRgb(0x6F, 0xA9, 0x95)), 0.55))
            $rgb.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromRgb(0x3F, 0x7A, 0x65)), 1))
            $controls.LaunchSpinnerBorder.Background = $rgb
        }
        # glyph ⟳ → ✓ + 把 spinner 旋转角复位 0(否则 ✓ 会斜)
        if ($controls.LaunchSpinnerGlyph) { $controls.LaunchSpinnerGlyph.Text = [char]0x2713 }  # ✓
        if ($controls.LaunchSpinnerRotate) { $controls.LaunchSpinnerRotate.Angle = 0 }
        # eyebrow 文案 + 颜色墨绿
        if ($controls.LaunchProgressEyebrow) {
            $controls.LaunchProgressEyebrow.Text = 'WebUI 已启动'
            $success = Get-PaletteBrush 'SuccessBrush'
            if ($success) { $controls.LaunchProgressEyebrow.Foreground = $success }
        }
        # headline / subline 文案
        if ($controls.LaunchProgressHeadline) { $controls.LaunchProgressHeadline.Text = '已在浏览器中打开' }
        if ($controls.LaunchProgressSubline) { $controls.LaunchProgressSubline.Text = '2 秒后自动收起此窗口' }
        # current-stage 改成 URL 文本
        if ($controls.LaunchCurrentStageText) { $controls.LaunchCurrentStageText.Text = $Url }
        if ($controls.LaunchCurrentStageDetail) { $controls.LaunchCurrentStageDetail.Text = '' }
        # progress 100%
        if ($controls.LaunchProgressBar) { $controls.LaunchProgressBar.Value = 100 }
        # mini-steps 1-7 全 done
        for ($i = 1; $i -le 7; $i++) { Set-LaunchMiniStepState -StepIndex $i -State 'done' }
        # 取消按钮 → 关闭窗口
        if ($controls.LaunchProgressCancelButton) { $controls.LaunchProgressCancelButton.Content = '关闭窗口' }
        # 隐藏预计时间
        if ($controls.LaunchProgressEstTime) { $controls.LaunchProgressEstTime.Text = '' }
    } catch { }
}

# 任务 014 Bug C (v2026.05.04.6):success 态停留 ~2 秒后自动 Hide-LaunchProgressCard
# 期间 subline 倒计时 "2 秒 → 1 秒 → 即将" 让用户感知"自动收尾"
# 用户中途点关闭窗口按钮 → Stop-LaunchAsync(无 ErrorMessage)立即收起,timer 自然 Stop
$script:LaunchSuccessHideTimer = $null
function Start-LaunchSuccessAutoHide {
    try {
        # stop any existing timer
        if ($script:LaunchSuccessHideTimer) {
            try { $script:LaunchSuccessHideTimer.Stop() } catch { }
            $script:LaunchSuccessHideTimer = $null
        }
        $script:LaunchSuccessHideTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:LaunchSuccessHideTimer.Interval = [TimeSpan]::FromMilliseconds(700)
        $script:LaunchSuccessHideTickCount = 0
        $script:LaunchSuccessHideTimer.Add_Tick({
            try {
                $script:LaunchSuccessHideTickCount++
                switch ($script:LaunchSuccessHideTickCount) {
                    1 { if ($controls.LaunchProgressSubline) { $controls.LaunchProgressSubline.Text = '1 秒后自动收起此窗口' } }
                    2 { if ($controls.LaunchProgressSubline) { $controls.LaunchProgressSubline.Text = '即将收起...' } }
                    default {
                        $script:LaunchSuccessHideTimer.Stop()
                        $script:LaunchSuccessHideTimer = $null
                        Hide-LaunchProgressCard
                        try { Refresh-Status } catch { }
                    }
                }
            } catch { }
        })
        $script:LaunchSuccessHideTimer.Start()
    } catch { }
}

# 隐藏 LaunchProgressCard,恢复 HomeReadyContainer
function Hide-LaunchProgressCard {
    try {
        if ($controls.LaunchProgressCard) { $controls.LaunchProgressCard.Visibility = 'Collapsed' }
        if ($controls.HomeReadyContainer) { $controls.HomeReadyContainer.Visibility = 'Visible' }
    } catch { }
}

# 把 phase 同步到 LaunchProgressCard 的 mini-steps + 进度条 + 当前阶段文字
$script:LaunchPhaseLast = ''
function Update-LaunchProgressCardPhase {
    param([string]$Phase)
    try {
        if ($controls.LaunchProgressCard.Visibility -ne 'Visible') { return }
        $info = $script:LaunchPhaseMap[$Phase]
        if (-not $info) { return }

        $currStep = [int]$info.Step
        # 把所有 step 标 done/active/pending
        for ($i = 1; $i -le 7; $i++) {
            if ($i -lt $currStep) { Set-LaunchMiniStepState -StepIndex $i -State 'done' }
            elseif ($i -eq $currStep) { Set-LaunchMiniStepState -StepIndex $i -State 'active' }
            else { Set-LaunchMiniStepState -StepIndex $i -State 'pending' }
        }
        # 进度条 (在 ProgressMin..ProgressMax 之间)
        if ($controls.LaunchProgressBar) {
            $target = if ($script:LaunchPhaseLast -ne $Phase) { $info.ProgressMin } else { ($info.ProgressMin + $info.ProgressMax) / 2 }
            $controls.LaunchProgressBar.Value = $target
        }
        # 文案
        if ($controls.LaunchCurrentStageText) { $controls.LaunchCurrentStageText.Text = $info.Text }
        if ($controls.LaunchCurrentStageDetail) { $controls.LaunchCurrentStageDetail.Text = [string]$info.Detail }
        # spinner 旋转 30°
        try {
            if ($controls.LaunchSpinnerGlyph) {
                $rt = $controls.LaunchSpinnerGlyph.RenderTransform
                if ($rt -is [System.Windows.Media.RotateTransform]) {
                    $rt.Angle = ($rt.Angle + 30) % 360
                }
            }
        } catch { }

        $script:LaunchPhaseLast = $Phase
    } catch { }
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

    # 任务 012：把当前 phase 同步到 LaunchProgressCard 视觉
    Update-LaunchProgressCardPhase -Phase $s.Phase

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

                # 下载完成，进入独立解压阶段（与 LaunchPhaseMap 中的 extract-node 对应）
                Add-LogLine '正在解压 Node.js...'
                $s.Phase = 'extract-node'
            }

            # ── Phase 2b: Extract Node.js (background Runspace, non-blocking) ──
            # 任务 012 P1-3：Expand-Archive 同步解压在 UI 线程会阻塞数秒导致"未响应"
            # 改为后台 Runspace + 轮询完成标志，UI 线程全程不阻塞
            'extract-node' {
                if (-not $s.ExtractRunspace) {
                    Set-Footer '正在解压 Node.js...'
                    $webUi = Get-HermesWebUiDefaults

                    # 捕获需要传入 Runspace 的变量（Runspace 不共享调用者的变量作用域）
                    $zipPathCapture  = $s.DownloadZipPath
                    $nodeRootCapture = $webUi.NodeRoot

                    # 启动后台 Runspace（陷阱 #1：Runspace 内无 WPF Dispatcher，不需要 try-catch 包裹；
                    # 错误通过返回值传回 UI 线程）
                    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
                    $rs.Open()
                    $ps = [System.Management.Automation.PowerShell]::Create()
                    $ps.Runspace = $rs
                    [void]$ps.AddScript({
                        param($zipPath, $nodeRoot)
                        try {
                            Expand-Archive -Path $zipPath -DestinationPath $nodeRoot -Force
                            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                            return $null   # null = success
                        } catch {
                            return $_.Exception.Message   # non-null = error message
                        }
                    }).AddArgument($zipPathCapture).AddArgument($nodeRootCapture)
                    $s.ExtractRunspace    = $rs
                    $s.ExtractPowerShell  = $ps
                    $s.ExtractAsyncResult = $ps.BeginInvoke()
                    return
                }

                # 轮询：解压尚未完成则等下一个 tick
                if (-not $s.ExtractAsyncResult.IsCompleted) { return }

                # 解压完成 — 收集结果，释放资源（陷阱 #1：所有 Dispatcher 操作在 finally 后的 throw 之前）
                $webUi = Get-HermesWebUiDefaults
                $extractError = $null
                try {
                    $results = $s.ExtractPowerShell.EndInvoke($s.ExtractAsyncResult)
                    if ($results -and $results.Count -gt 0 -and $null -ne $results[0]) {
                        $extractError = [string]$results[0]
                    }
                    if ($s.ExtractPowerShell.HadErrors -and -not $extractError) {
                        $errRecord = $s.ExtractPowerShell.Streams.Error | Select-Object -First 1
                        if ($errRecord) { $extractError = $errRecord.ToString() }
                    }
                } catch {
                    $extractError = $_.Exception.Message
                } finally {
                    try { $s.ExtractPowerShell.Dispose() } catch { }
                    try { $s.ExtractRunspace.Close(); $s.ExtractRunspace.Dispose() } catch { }
                    $s.ExtractRunspace    = $null
                    $s.ExtractPowerShell  = $null
                    $s.ExtractAsyncResult = $null
                }

                if ($extractError) {
                    throw ("Node.js 解压失败：{0}" -f $extractError)
                }
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
                $s.GwHealthDeadline = (Get-Date).AddSeconds(15)
                $s.Phase = 'wait-gateway-healthy'
            }

            # ── Phase 4b: Wait for gateway health before starting webui ──
            'wait-gateway-healthy' {
                $gwHealthy = $false
                try {
                    # 任务 012 P1-3：TimeoutSec 1（本地 loopback，1s 足够；2s 会让 UI 线程阻塞超过 timer 间隔）
                    $null = Invoke-RestMethod -Uri 'http://127.0.0.1:8642/health' -TimeoutSec 1 -ErrorAction Stop
                    $gwHealthy = $true
                } catch { }
                if ($gwHealthy) {
                    Add-LogLine 'Gateway 健康检查通过，启动 WebUI...'
                    # Deferred upstream patching — gateway is healthy, safe to patch now
                    try { Repair-HermesUpstreamForWindows -HermesInstallDir $s.InstallDir } catch {
                        Add-LogLine ("上游补丁跳过：{0}" -f $_.Exception.Message)
                    }
                    $s.Phase = 'start-webui'
                } elseif ((Get-Date) -gt $s.GwHealthDeadline) {
                    Add-LogLine 'Gateway 健康检查超时（15秒），仍继续启动 WebUI'
                    $s.Phase = 'start-webui'
                } else {
                    Set-Footer '等待 Gateway 就绪...'
                    # 任务 012 P1-3：不在 UI 线程 Sleep — DispatcherTimer 本身已提供 800ms 间隔
                    # 移除 Start-Sleep -Milliseconds 1000 防止 UI 线程阻塞
                }
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
                # Fix webui terminal shell detection on Windows
                if (-not $env:SHELL) {
                    $env:SHELL = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
                    if (-not $env:SHELL) { $env:SHELL = 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe' }
                }

                Add-ActionLog -Action '开始使用' -Result '正在启动 hermes-web-ui...' -Next '等待服务就绪'
                Set-Footer '正在启动 hermes-web-ui...'
                Add-LogLine '正在启动 hermes-web-ui...'

                # 任务 014 Bug C：WebUiCmd 在罕见情况下（用户手动删了文件 / 路径权限）
                # 可能 Test-Path 通过但 Start-Process 仍抛 FileNotFoundException。
                # 显式 try-catch 把异常变成可处理的 throw，避免 dispatcher 未捕获。
                if (-not (Test-Path $webUi.WebUiCmd)) {
                    throw ("hermes-web-ui 命令文件不存在：{0}" -f $webUi.WebUiCmd)
                }
                try {
                    Start-Process -FilePath $webUi.WebUiCmd -ArgumentList @('start', $webUi.Port) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $env:TEMP 'hermes-webui-start.log') -RedirectStandardError (Join-Path $env:TEMP 'hermes-webui-start-err.log')
                } catch {
                    throw ("启动 hermes-web-ui 失败：{0}" -f $_.Exception.Message)
                }

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
                    try { Send-TelemetryOnce -EventName 'webui_started' -Properties @{ path = 'slow' } } catch { }
                    Set-Footer ''

                    $hermesHome = Join-Path $env:USERPROFILE '.hermes'
                    Save-LauncherState -HermesHome $hermesHome -LocalChatVerified $true
                    Start-GatewayEnvWatcher
                    $controls.PrimaryActionButton.IsEnabled = $true
                    $script:LaunchState = $null

                    # 任务 014 Bug C (v2026.05.04.6):切换到 success 态(全 7 段绿 ✓ + URL bar + 倒计时)
                    # 然后 ~2 秒后自动 Hide-LaunchProgressCard + Refresh-Status 回到主页
                    # 见设计稿 mockups/011-windows-ui-extra/08-launching-success.html
                    # 修陷阱 #43:任务 012 漏了成功路径的 Hide,被陷阱 #42 掩盖直到 v2026.05.04.5 才暴露
                    $browserUrl = "http://$($webUi.Host):$($webUi.Port)"
                    Set-LaunchProgressCardSuccess -Url $browserUrl
                    Start-LaunchSuccessAutoHide
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

# P1-2-LITE: 安装中 spinner(braille 文本切换,每 200ms 更新 InstallCurrentStageDetail)
function Stop-InstallSpinner {
    if ($script:InstallSpinnerTimer) {
        try { $script:InstallSpinnerTimer.Stop() } catch { }
        $script:InstallSpinnerTimer = $null
    }
}
function Start-InstallSpinner {
    Stop-InstallSpinner
    $script:InstallSpinnerFrames = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
    $script:InstallSpinnerIdx = 0
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(200)
    $t.Add_Tick({
        try {
            $f = $script:InstallSpinnerFrames[$script:InstallSpinnerIdx % $script:InstallSpinnerFrames.Length]
            $script:InstallSpinnerIdx++
            if ($controls.InstallCurrentStageDetail) { $controls.InstallCurrentStageDetail.Text = "$f 正在安装,看黑色终端窗口进度" }
        } catch { }
    })
    $script:InstallSpinnerTimer = $t
    $t.Start()
}

function Stop-ExternalInstallTimer {
    if ($script:ExternalInstallTimer) {
        $script:ExternalInstallTimer.Stop()
        $script:ExternalInstallTimer = $null
    }
    Stop-InstallSpinner
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

            # 任务 014 Bug L (v2026.05.04.16):上游 install.ps1 的 Install-Dependencies 用
            # `uv pip install -e ".[all]" 2>&1 | Out-Null` 吞掉所有错误,且 try/catch 接不到
            # native command 失败 → 即使 PyPI 装包失败,install.ps1 仍 exit 0 假装成功。
            # 终端关闭 + exit 0,但 hermes.exe 没生成 → launcher 不刷新到 home mode,
            # 用户看到卡在"3 正在安装"无解。
            # 修复:exit 0 后再 verify hermes.exe 真的生成,没生成则当失败处理。见陷阱 #50。
            $expectedHermesExe = Join-Path $defaults.InstallDir 'venv\Scripts\hermes.exe'
            $hermesExeReallyExists = Test-Path -LiteralPath $expectedHermesExe
            if ($exitCode -eq 0 -and $hermesExeReallyExists) {
                Add-ActionLog -Action '安装 / 更新 Hermes' -Result '安装终端已自动关闭，安装过程结束' -Next '启动器已自动刷新状态，请按推荐步骤继续'
                try { Send-Telemetry -EventName 'hermes_install_completed' -Properties @{ exit_code = 0 } } catch { }
            } elseif ($exitCode -eq 0 -and -not $hermesExeReallyExists) {
                # exit 0 但 hermes.exe 没生成 → install.ps1 silent fail
                Add-ActionLog -Action '安装 / 更新 Hermes' -Result '安装终端报告完成,但 hermes.exe 未生成' -Next '安装实际失败(很可能 PyPI 装包失败被上游脚本静默吞掉)。请重新安装或截图终端日志反馈给开发者'
                try { Send-Telemetry -EventName 'hermes_install_failed' -FailureReason 'silent_fail_no_hermes_exe' -Properties @{ stage = 'external_terminal_silent_fail'; exit_code = 0 } } catch { }
                $recentLog = @()
                if ($controls.LogTextBox.Text) {
                    $lines = $controls.LogTextBox.Text -split "`r?`n"
                    $recentLog = @($lines | Where-Object { $_ -ne '' } | Select-Object -Last 10)
                }
                $silentFailSummary = @(
                    "安装中断 · 退出码 0 但 hermes.exe 未生成 · 阶段:执行官方安装脚本"
                    ''
                    '可能的原因:'
                    '  • 国内 PyPI 镜像缺少某些 hermes-agent 依赖包'
                    '  • uv pip install 跑到一半失败,但官方脚本静默吞掉了错误(没暴露给启动器)'
                    '  • 磁盘空间不足'
                    ''
                    '建议:点"重新开始"重试一次。多次失败请截图终端日志反馈。'
                ) -join "`n"
                $controls.InstallFailureSummaryText.Text = $silentFailSummary
                $controls.InstallFailureSummaryText.Visibility = 'Visible'
                try {
                    $tail8 = @($recentLog | Select-Object -Last 8)
                    if ($controls.InstallFailureLogPreviewText) { $controls.InstallFailureLogPreviewText.Text = ($tail8 -join "`n") }
                    if ($controls.InstallFailureLogPreviewBorder) { $controls.InstallFailureLogPreviewBorder.Visibility = 'Visible' }
                } catch { }
                try { Set-InstallStepCardState -StepIndex 3 -State 'failed' } catch { }
            } else {
                Add-ActionLog -Action '安装 / 更新 Hermes' -Result ("安装终端已结束，退出码：{0}" -f $exitCode) -Next '安装失败时终端通常会保留；如已关闭，请重新打开安装并查看终端报错'
                try { Send-Telemetry -EventName 'hermes_install_failed' -FailureReason ('exit_code=' + $exitCode) -Properties @{ stage = 'external_terminal'; exit_code = [int]$exitCode } } catch { }
                $recentLog = @()
                if ($controls.LogTextBox.Text) {
                    $lines = $controls.LogTextBox.Text -split "`r?`n"
                    # 任务 012：单独抽出尾 8 行用于 LogPreview（mockup 06 的视觉），主 FailureSummaryText 仍用 10 行做兼容
                    $recentLog = @($lines | Where-Object { $_ -ne '' } | Select-Object -Last 10)
                }
                # 任务 012：失败摘要拆成两块 - 上面是原因 + 建议（FailureSummaryText），下面是 monospace 日志预览（LogPreview）
                $failSummary = @(
                    "安装中断 · 退出码 $exitCode · 阶段：执行官方安装脚本"
                    ''
                    '可能的原因：'
                    '  • 网络断开或 GitHub 加速通道失败'
                    '  • 磁盘空间不足（建议至少留 2 GB 可用）'
                    '  • 杀毒软件拦截了 git clone 进程'
                    ''
                    '大多数失败重新点一下下方"重新开始"就能过；还不行的话，复制日志反馈给开发者。'
                ) -join "`n"
                $controls.InstallFailureSummaryText.Text = $failSummary
                $controls.InstallFailureSummaryText.Visibility = 'Visible'
                # 任务 012：LogPreview 显示日志末尾 8 行（monospace 深色块）
                try {
                    $tail8 = @($recentLog | Select-Object -Last 8)
                    if ($controls.InstallFailureLogPreviewText) {
                        $controls.InstallFailureLogPreviewText.Text = ($tail8 -join "`n")
                    }
                    if ($controls.InstallFailureLogPreviewBorder) {
                        $controls.InstallFailureLogPreviewBorder.Visibility = 'Visible'
                    }
                } catch { }
                # 任务 012：右栏 step3 标 failed
                try { Set-InstallStepCardState -StepIndex 3 -State 'failed' } catch { }
            }
            Refresh-Status
            # 任务 012：失败时 Refresh-Status 会把 LogPreview 重新隐藏（默认行为），所以这里再设回来
            # 任务 014 Bug L (v2026.05.04.16):silent fail (exit 0 但 hermes.exe 没生成) 也走失败 UI
            if ($exitCode -ne 0 -or -not $hermesExeReallyExists) {
                try {
                    if ($controls.InstallFailureLogPreviewBorder) {
                        $controls.InstallFailureLogPreviewBorder.Visibility = 'Visible'
                    }
                    Set-InstallStepCardState -StepIndex 3 -State 'failed'
                    if ($controls.InstallTaskStepTagText) { $controls.InstallTaskStepTagText.Text = '安装中断' }
                    if ($controls.InstallTaskTitleText) { $controls.InstallTaskTitleText.Text = '安装没能完成，我们来看看怎么解决' }
                    if ($controls.InstallStepProgressTitle) { $controls.InstallStepProgressTitle.Text = '总进度 · 第 3 步出错' }
                    if ($controls.InstallStep3Desc) { $controls.InstallStep3Desc.Text = '中断于安装阶段' }
                } catch { }
            }
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
# 任务 014 Bug I (v2026.05.04.13):wrapper 启动时立即打印提示,让用户知道终端是活的。
# 之前空白终端让用户以为卡死,实际可能 install.ps1 在装 uv (国内 astral.sh 慢)阶段,
# 或在 git clone hermes-agent (国内 GitHub 不通)阶段卡几十秒没回显。
Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host '  Hermes 启动器 - 安装终端' -ForegroundColor Cyan
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '[启动器] 正在准备 Hermes 安装环境...' -ForegroundColor Yellow
Write-Host '[启动器] 接下来会调用官方安装脚本(预计 1-3 分钟,看网络)' -ForegroundColor Yellow
Write-Host '[启动器] 国内网络下,装 uv / git clone 阶段可能停顿几十秒,不要关闭' -ForegroundColor Yellow
Write-Host ''
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
                try { Send-Telemetry -EventName 'install_residue_cleaned' -Properties @{ method = 'auto' } } catch { }
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
        # 任务 014 Bug H (v2026.05.04.12):测全部镜像（之前 [1..2] 漏测后两个）
        $mirrorCfg = Get-MirrorConfig
        $mirrorReachable = $false
        $reachedMirror = $null
        # 测全部除了 [1] 官方源以外的镜像([0] 是自建,[2..] 是社区镜像)
        $mirrorsToProbe = @($mirrorCfg.GitHubRaw[0]) + @($mirrorCfg.GitHubRaw[2..($mirrorCfg.GitHubRaw.Count - 1)])
        foreach ($mirrorBase in $mirrorsToProbe) {
            try {
                if ($mirrorBase -match '/https?://') {
                    # 代理拼接型: 'https://xxx/https://raw.githubusercontent.com'
                    $mirrorUrl = $mirrorBase + ($defaults.OfficialInstallUrl -replace '^https://raw\.githubusercontent\.com', '')
                } else {
                    # 域名替换型: 'https://hermes.aisuper.win/mirror' / 'https://raw.gitmirror.com'
                    $mirrorUrl = $defaults.OfficialInstallUrl -replace '^https://raw\.githubusercontent\.com', $mirrorBase
                }
                $mResp = Invoke-WebRequest -UseBasicParsing -Uri $mirrorUrl -Method Head -TimeoutSec 6
                if ($mResp.StatusCode -ge 200 -and $mResp.StatusCode -lt 400) {
                    $mirrorReachable = $true
                    $reachedMirror = $mirrorBase
                    break
                }
            } catch { }
        }
        if ($mirrorReachable) {
            $mirrorTag = if ($reachedMirror -like '*hermes.aisuper.win*') { '自建' } else { '社区' }
            $passed.Add(("官方源不可访问，但 {0}镜像可用 ({1})。安装将自动切换。" -f $mirrorTag, $reachedMirror)) | Out-Null
            $networkOk = $true
            $networkEnvResult = 'china'
        } else {
            # 任务 014 Bug H (v2026.05.04.12):阻塞文案改友好,给具体下一步
            $blocking.Add('GitHub 官方源和全部国内镜像源都不可达。可能原因:1) 网络断开 2) 防火墙/杀毒软件拦截 3) 公司/校园网限制 GitHub。建议:换用手机热点重试,或加交流群求助(见「关于」按钮)。') | Out-Null
        }
    }

    $result = [pscustomobject]@{
        Passed   = @($passed.ToArray())
        Warnings = @($warnings.ToArray())
        Blocking = @($blocking.ToArray())
        HasGit   = [bool]$gitCommand
        HasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
        NetworkOk = $networkOk
        NetworkEnv = $networkEnvResult
        CanInstall = ($blocking.Count -eq 0)
    }

    # 任务 011 埋点：环境检测结果（脱敏，仅传聚合属性，不传完整路径）
    try {
        Send-Telemetry -EventName 'preflight_check' -Properties @{
            can_install   = [bool]$result.CanInstall
            has_git       = [bool]$result.HasGit
            has_winget    = [bool]$result.HasWinget
            network_ok    = [bool]$result.NetworkOk
            network_env   = [string]$result.NetworkEnv
            blocking_count = $result.Blocking.Count
            warning_count  = $result.Warnings.Count
            passed_count   = $result.Passed.Count
        }
    } catch { }

    return $result
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
        # 任务 012 P1-1：统一使用 LauncherPalette 主色暖橙，与 State 1/6 主按钮一致
        $controls.StartInstallPageButton.Background = '#D9772B'
        $controls.StartInstallPageButton.BorderBrush = '#D9772B'
        $controls.StartInstallPageButton.Foreground = '#FCFCF7'
    } else {
        # 禁用态：使用浅色系暗哑色（米色系）
        $controls.StartInstallPageButton.Background = '#D4CFC5'
        $controls.StartInstallPageButton.BorderBrush = '#C8C3B9'
        $controls.StartInstallPageButton.Foreground = '#897F75'
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

function Show-TelemetryConsentBanner {
    <#
    .SYNOPSIS
    首次启动时在主界面顶部显示一行提示，告知用户匿名遥测已启用。
    非弹窗、非阻塞，符合陷阱 #4（信息位置错误）的预防要求。
    #>
    try {
        if ($null -eq $controls.TelemetryConsentBanner) { return }
        $controls.TelemetryConsentBanner.Visibility = 'Visible'
    } catch { }
}

function Hide-TelemetryConsentBanner {
    try {
        if ($null -eq $controls.TelemetryConsentBanner) { return }
        $controls.TelemetryConsentBanner.Visibility = 'Collapsed'
        Mark-FirstRunConsentShown
    } catch { }
}

function Show-AboutDialog {
    <#
    .SYNOPSIS
    显示「关于」对话框：版本号 + 隐私说明 + 匿名遥测开关。
    #>
    try {
        $aboutXamlText = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="关于 Hermes 启动器"
        Width="580"
        Height="660"
        MinWidth="540"
        MinHeight="600"
        WindowStartupLocation="CenterOwner"
        Background="#F2F0E8"
        Foreground="#262621"
        ResizeMode="NoResize"
        TextOptions.TextFormattingMode="Display">
    <Window.Resources>
        <SolidColorBrush x:Key="BgAppBrush" Color="#F2F0E8"/>
        <SolidColorBrush x:Key="BgAppSecondaryBrush" Color="#EBE8E0"/>
        <SolidColorBrush x:Key="SurfacePrimaryBrush" Color="#FAF8F2"/>
        <SolidColorBrush x:Key="SurfaceSecondaryBrush" Color="#F4F0E8"/>
        <SolidColorBrush x:Key="SurfaceTertiaryBrush" Color="#F0E8DE"/>
        <SolidColorBrush x:Key="SurfaceHoverBrush" Color="#F2E6D6"/>
        <SolidColorBrush x:Key="TextPrimaryBrush" Color="#262621"/>
        <SolidColorBrush x:Key="TextSecondaryBrush" Color="#5E594F"/>
        <SolidColorBrush x:Key="TextTertiaryBrush" Color="#897F75"/>
        <SolidColorBrush x:Key="TextOnAccentBrush" Color="#FCFCF7"/>
        <SolidColorBrush x:Key="AccentPrimaryBrush" Color="#D9772B"/>
        <SolidColorBrush x:Key="AccentDeepBrush" Color="#A85420"/>
        <SolidColorBrush x:Key="AccentTintBrush" Color="#1AD9772B"/>
        <SolidColorBrush x:Key="SuccessBrush" Color="#4F8F7A"/>
        <SolidColorBrush x:Key="SuccessSoftBrush" Color="#DBEDE5"/>
        <SolidColorBrush x:Key="DangerBrush" Color="#C25E52"/>
        <SolidColorBrush x:Key="DangerSoftBrush" Color="#F7E0D8"/>
        <SolidColorBrush x:Key="LineSofterBrush" Color="#0A000000"/>

        <FontFamily x:Key="UiFont">$($script:UiFontFamily)</FontFamily>

        <Style TargetType="TextBlock">
            <Setter Property="FontFamily" Value="{StaticResource UiFont}"/>
            <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="TextOptions.TextFormattingMode" Value="Display"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="FontFamily" Value="{StaticResource UiFont}"/>
            <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="FontFamily" Value="{StaticResource UiFont}"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>

        <Style x:Key="AboutCloseButtonStyle" TargetType="Button">
            <Setter Property="FontFamily" Value="{StaticResource UiFont}"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="13.5"/>
            <Setter Property="Foreground" Value="{StaticResource AccentDeepBrush}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="{StaticResource AccentDeepBrush}"/>
            <Setter Property="BorderThickness" Value="1.5"/>
            <Setter Property="Padding" Value="22,8"/>
            <Setter Property="MinHeight" Value="38"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                CornerRadius="10" Padding="{TemplateBinding Padding}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Hero -->
        <StackPanel Grid.Row="0" Margin="32,30,32,18">
            <DockPanel LastChildFill="True">
                <Border DockPanel.Dock="Left" Width="56" Height="56" CornerRadius="14"
                        Margin="0,0,18,0">
                    <Border.Background>
                        <RadialGradientBrush GradientOrigin="0.3,0.3" Center="0.5,0.5" RadiusX="0.6" RadiusY="0.6">
                            <GradientStop Color="#F2B56B" Offset="0"/>
                            <GradientStop Color="#D9772B" Offset="0.6"/>
                            <GradientStop Color="#A85420" Offset="1"/>
                        </RadialGradientBrush>
                    </Border.Background>
                    <Border.Effect>
                        <DropShadowEffect Color="#A85420" Opacity="0.28" BlurRadius="14" ShadowDepth="3"/>
                    </Border.Effect>
                    <Border Margin="14" CornerRadius="3" BorderBrush="#A6FFFFFF" BorderThickness="2,2,0,0"/>
                </Border>
                <StackPanel VerticalAlignment="Center">
                    <TextBlock x:Name="AboutTitle" FontSize="22" FontWeight="Bold" Text="Hermes 启动器"
                               Foreground="{StaticResource TextPrimaryBrush}"/>
                    <TextBlock x:Name="AboutVersionText" Margin="0,4,0,0"
                               FontSize="12" Foreground="{StaticResource TextTertiaryBrush}"/>
                    <TextBlock Margin="0,6,0,0" FontSize="12.5" LineHeight="19" TextWrapping="Wrap"
                               Foreground="{StaticResource TextSecondaryBrush}"
                               Text="第三方 GUI 启动器，非官方项目。让更多中文用户用上 Hermes Agent。"/>
                </StackPanel>
            </DockPanel>
        </StackPanel>

        <!-- 匿名数据上报卡 -->
        <ScrollViewer Grid.Row="1" Margin="32,0,32,0" VerticalScrollBarVisibility="Auto">
            <StackPanel>
                <Border Padding="20,18" CornerRadius="14"
                        Background="{StaticResource SurfacePrimaryBrush}"
                        BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                    <Border.Effect>
                        <DropShadowEffect Color="#3C2814" Opacity="0.05" BlurRadius="14" ShadowDepth="2"/>
                    </Border.Effect>
                    <StackPanel>
                        <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
                            <Border Width="20" Height="20" CornerRadius="10"
                                    Background="{StaticResource AccentTintBrush}" Margin="0,0,8,0">
                                <TextBlock Text="i" FontFamily="Times New Roman" FontStyle="Italic"
                                           FontSize="12" FontWeight="Bold"
                                           Foreground="{StaticResource AccentDeepBrush}"
                                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <TextBlock FontSize="14.5" FontWeight="SemiBold" VerticalAlignment="Center"
                                       Foreground="{StaticResource TextPrimaryBrush}"
                                       Text="匿名数据上报"/>
                        </StackPanel>
                        <TextBlock Margin="0,8,0,0" FontSize="12.5" TextWrapping="Wrap" LineHeight="19"
                                   Foreground="{StaticResource TextSecondaryBrush}"
                                   Text="我们仅收集帮助修 bug 和改进体验的匿名数据，不收集任何与你个人相关的信息。"/>

                        <Grid Margin="0,12,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="10"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Padding="12,12" CornerRadius="9"
                                    Background="{StaticResource SurfaceSecondaryBrush}"
                                    BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                                <StackPanel>
                                    <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                                        <Border Width="14" Height="14" CornerRadius="7"
                                                Background="{StaticResource SuccessSoftBrush}" Margin="0,0,5,0">
                                            <TextBlock Text="✓" FontSize="9" FontWeight="Bold"
                                                       Foreground="{StaticResource SuccessBrush}"
                                                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                        </Border>
                                        <TextBlock Text="我们收集" FontSize="12.5" FontWeight="Bold"
                                                   Foreground="{StaticResource SuccessBrush}"
                                                   VerticalAlignment="Center"/>
                                    </StackPanel>
                                    <TextBlock FontSize="11.5" LineHeight="17" TextWrapping="Wrap"
                                               Foreground="{StaticResource TextSecondaryBrush}">
                                        <Run Text="• 启动 / 关闭事件"/><LineBreak/>
                                        <Run Text="• 安装阶段进展"/><LineBreak/>
                                        <Run Text="• 启动器 / Windows 版本号"/><LineBreak/>
                                        <Run Text="• 失败事件的脱敏后错误类型"/><LineBreak/>
                                        <Run Text="• 一次性匿名设备 ID"/>
                                    </TextBlock>
                                </StackPanel>
                            </Border>

                            <Border Grid.Column="2" Padding="12,12" CornerRadius="9"
                                    Background="{StaticResource SurfaceSecondaryBrush}"
                                    BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                                <StackPanel>
                                    <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                                        <Border Width="14" Height="14" CornerRadius="7"
                                                Background="{StaticResource DangerSoftBrush}" Margin="0,0,5,0">
                                            <TextBlock Text="×" FontSize="11" FontWeight="Bold"
                                                       Foreground="{StaticResource DangerBrush}"
                                                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                        </Border>
                                        <TextBlock Text="我们不收集" FontSize="12.5" FontWeight="Bold"
                                                   Foreground="{StaticResource DangerBrush}"
                                                   VerticalAlignment="Center"/>
                                    </StackPanel>
                                    <TextBlock FontSize="11.5" LineHeight="17" TextWrapping="Wrap"
                                               Foreground="{StaticResource TextSecondaryBrush}">
                                        <Run Text="• API key / token / 密码"/><LineBreak/>
                                        <Run Text="• 对话内容 / 聊天记录"/><LineBreak/>
                                        <Run Text="• 用户名 / 机器名 / 路径"/><LineBreak/>
                                        <Run Text="• IP 地址 / 邮箱"/>
                                    </TextBlock>
                                </StackPanel>
                            </Border>
                        </Grid>

                        <TextBlock Margin="0,10,0,0" FontSize="11" LineHeight="16"
                                   Foreground="{StaticResource TextTertiaryBrush}" TextWrapping="Wrap"
                                   Text="数据通过 HTTPS 发到我们自有的 Cloudflare Worker · 不经过第三方分析平台。"/>
                    </StackPanel>
                </Border>

                <!-- Toggle 卡 -->
                <Border Margin="0,12,0,0" Padding="14,12" CornerRadius="14"
                        Background="{StaticResource SurfacePrimaryBrush}"
                        BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="1">
                    <CheckBox x:Name="AboutTelemetryToggle"
                              FontFamily="{StaticResource UiFont}" FontSize="13.5" FontWeight="SemiBold"
                              Foreground="{StaticResource TextPrimaryBrush}"
                              Content="启用匿名数据上报（推荐保持开启，帮助我们改进产品）"/>
                </Border>

                <!-- 状态文字 -->
                <Border Margin="0,8,0,12" Padding="14,10" CornerRadius="10"
                        Background="{StaticResource SurfaceSecondaryBrush}">
                    <TextBlock x:Name="AboutTelemetryStatus" FontSize="12"
                               Foreground="{StaticResource TextSecondaryBrush}" TextWrapping="Wrap"/>
                </Border>
            </StackPanel>
        </ScrollViewer>

        <!-- 底部 close 按钮 -->
        <Border Grid.Row="2" Padding="32,16,32,22"
                Background="{StaticResource BgAppSecondaryBrush}"
                BorderBrush="{StaticResource LineSofterBrush}" BorderThickness="0,1,0,0">
            <DockPanel LastChildFill="False">
                <Button x:Name="AboutCloseButton" DockPanel.Dock="Right"
                        Style="{StaticResource AboutCloseButtonStyle}" Content="关闭"/>
            </DockPanel>
        </Border>
    </Grid>
</Window>
"@
        [xml]$aboutXaml = $aboutXamlText
        $aboutReader = New-Object System.Xml.XmlNodeReader $aboutXaml
        $aboutWindow = [Windows.Markup.XamlReader]::Load($aboutReader)
        $aboutWindow.Owner = $window

        $aboutControls = @{}
        foreach ($name in @('AboutVersionText','AboutTelemetryToggle','AboutTelemetryStatus','AboutCloseButton')) {
            $aboutControls[$name] = $aboutWindow.FindName($name)
        }
        $aboutControls.AboutVersionText.Text = ("Windows · {0}" -f $script:LauncherVersion)
        $aboutControls.AboutTelemetryToggle.IsChecked = (Get-TelemetryEnabled)
        # 状态文字初始值（暖色调适配，任务 012）
        $successBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4F8F7A')
        $dangerBrush  = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#C25E52')
        if ($aboutControls.AboutTelemetryToggle.IsChecked) {
            $aboutControls.AboutTelemetryStatus.Text = '✓ 已开启 · 感谢你帮助我们改进产品'
            $aboutControls.AboutTelemetryStatus.Foreground = $successBrush
        } else {
            $aboutControls.AboutTelemetryStatus.Text = '已关闭 · 我们不会再上报数据'
            $aboutControls.AboutTelemetryStatus.Foreground = $dangerBrush
        }
        # 闭包按 DECISIONS.md 经验避免嵌套 + 不用 GetNewClosure。
        # ScriptBlock 自然捕获 $aboutControls / $aboutWindow（与现有 AboutCloseButton 同一模式）。
        $aboutControls.AboutTelemetryToggle.Add_Checked({
            Set-TelemetryEnabled -Enabled $true
            Add-LogLine '匿名数据上报：已开启'
            try {
                $aboutControls.AboutTelemetryStatus.Text = '✓ 已开启 · 感谢你帮助我们改进产品'
                $aboutControls.AboutTelemetryStatus.Foreground = ([System.Windows.Media.BrushConverter]::new().ConvertFromString('#4F8F7A'))
            } catch { }
        })
        $aboutControls.AboutTelemetryToggle.Add_Unchecked({
            Set-TelemetryEnabled -Enabled $false
            Add-LogLine '匿名数据上报：已关闭'
            try {
                $aboutControls.AboutTelemetryStatus.Text = '已关闭 · 我们不会再上报数据'
                $aboutControls.AboutTelemetryStatus.Foreground = ([System.Windows.Media.BrushConverter]::new().ConvertFromString('#C25E52'))
            } catch { }
        })
        $aboutControls.AboutCloseButton.Add_Click({ $aboutWindow.Close() })
        [void]$aboutWindow.ShowDialog()
    } catch {
        Add-LogLine ("打开「关于」对话框失败：{0}" -f $_.Exception.Message)
    }
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
    # 任务 014 Bug B：已装机器即使 OpenClaw 残留也走 Home Mode（不再误判成 Install Mode）。
    # 迁移功能保留：Home Mode 顶部会显示一个 OpenClaw 横幅，按钮指向 openclaw-migrate / openclaw-skip。
    # Install Mode 只在「真未装」时进入。
    if (-not $isInstalled) {
        Set-LauncherWindowMode -Mode 'Install'
        $controls.InstallModePanel.Visibility = 'Visible'
        $controls.HomeModePanel.Visibility = 'Collapsed'
        $controls.LogSectionBorder.Visibility = 'Visible'
        $controls.FooterBorder.Visibility = 'Visible'

        # 任务 012：Install Mode 时把 Home Mode 的启动卡藏掉，避免残留
        try { if ($controls.LaunchProgressCard) { $controls.LaunchProgressCard.Visibility = 'Collapsed' } } catch { }
        try { if ($controls.HomeReadyContainer) { $controls.HomeReadyContainer.Visibility = 'Visible' } } catch { }

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

        # 任务 012：默认隐藏新视觉的辅助元素，下面分支按需打开
        try {
            $controls.InstallCurrentStageBorder.Visibility = 'Collapsed'
            $controls.InstallProgressBar.Visibility = 'Collapsed'
            $controls.InstallSubStepsPanel.Visibility = 'Collapsed'
            $controls.InstallStepTipBorder.Visibility = 'Collapsed'
            # 失败 LogPreview 默认收起；状态 9 下面会再打开
            $controls.InstallFailureLogPreviewBorder.Visibility = 'Collapsed'
        } catch { }

        if ($pendingOpenClaw) {
            $controls.InstallTaskCardBorder.Visibility = 'Collapsed'
            $controls.InstallProgressCardBorder.Visibility = 'Collapsed'
            $controls.InstallPathCardBorder.Visibility = 'Collapsed'
            $controls.OpenClawPostInstallBorder.Visibility = 'Visible'
            $controls.OpenClawPostInstallText.Text = '检测到旧版 OpenClaw 配置。Hermes 支持按官方方式迁移旧版模型、密钥和部分配置；如果暂时不迁移，也可以先开始使用。'
            $controls.OpenClawImportButton.IsEnabled = [bool]$script:CurrentStatus.HermesCommand
            $controls.OpenClawSkipButton.IsEnabled = $true
            # 任务 012：步骤指示器全部 done（hermes 已装，OpenClaw 是收尾迁移）
            Set-InstallStepCardState -StepIndex 1 -State 'done'
            Set-InstallStepCardState -StepIndex 2 -State 'done'
            Set-InstallStepCardState -StepIndex 3 -State 'done'
            $controls.InstallStepProgressTitle.Text = '总进度 · 3 / 3'
        } elseif ($installRunning) {
            # 任务 012：状态 8 - 安装中
            $controls.InstallTaskStepTagNum.Text = '3'
            $controls.InstallTaskStepTagText.Text = '正在安装'
            $controls.InstallProgressTitleText.Text = '执行进度'
            $controls.InstallTaskTitleText.Text = '正在安装 Hermes Agent'
            $controls.InstallTaskBodyText.Text = '官方安装终端已经打开，请不要关闭它。整个过程预计 1-3 分钟，具体看网络速度。'
            $controls.InstallProgressText.Text = ''
            $controls.InstallFailureSummaryText.Visibility = 'Collapsed'
            $controls.InstallFailureSummaryText.Text = ''
            # 显示进度条 + 子阶段 + 当前阶段
            $controls.InstallCurrentStageBorder.Visibility = 'Visible'
            $controls.InstallCurrentStageText.Text = '执行官方安装脚本'
            $controls.InstallCurrentStageDetail.Text = '终端已经打开，看终端进度即可'
            $controls.InstallProgressBar.Visibility = 'Visible'
            $controls.InstallProgressBar.Value = 65
            $controls.InstallSubStepsPanel.Visibility = 'Visible'
            Set-InstallSubStepState -SubStepIndex 1 -State 'done'
            Set-InstallSubStepState -SubStepIndex 2 -State 'active'
            Set-InstallSubStepState -SubStepIndex 3 -State 'pending'
            Set-InstallSubStepState -SubStepIndex 4 -State 'pending'
            # 步骤指示器 1=done, 2=done, 3=active
            Set-InstallStepCardState -StepIndex 1 -State 'done'
            Set-InstallStepCardState -StepIndex 2 -State 'done'
            Set-InstallStepCardState -StepIndex 3 -State 'active'
            $controls.InstallStepProgressTitle.Text = '总进度 · 2 / 3'
            $controls.InstallStep3Desc.Text = '官方安装脚本执行中，不要关闭终端'
            # 提示卡
            $controls.InstallStepTipBorder.Visibility = 'Visible'
            $controls.InstallStepTipText.Text = '另一个黑色窗口是官方安装终端，在那里下载和安装 Hermes。最小化它没问题，但请不要关闭。'
            # 任务 014 Bug I (v2026.05.04.13):删"查看官方文档"按钮(无效入口,链接是 placeholder)
            Set-InstallActionButtons -PrimaryActionId 'refresh' -PrimaryLabel '安装进行中' -PrimaryEnabled $false -SecondaryActionId '' -SecondaryLabel '' -SecondaryEnabled $false -TertiaryActionId 'refresh' -TertiaryLabel '刷新状态' -TertiaryEnabled $true
        } elseif (-not $script:InstallPreflightConfirmed -or -not $preflight.CanInstall) {
            # 任务 012：状态 1 - 环境检测
            $controls.InstallTaskStepTagNum.Text = '1'
            $controls.InstallTaskStepTagText.Text = '环境检测'
            $controls.InstallProgressTitleText.Text = '检测结果'
            if ($preflight.CanInstall) {
                $controls.InstallTaskTitleText.Text = '环境没问题，一起把 Hermes 装上吧'
            } else {
                $controls.InstallTaskTitleText.Text = '环境检测发现需要先解决的问题'
            }
            $controls.InstallTaskBodyText.Text = '我们已经检查了你的电脑环境。Python、uv、Node 之类缺失时官方脚本会自动补齐；Git、网络和目录权限异常会直接卡死安装。'
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
            # 步骤指示器: 1=active, 2=pending, 3=pending
            Set-InstallStepCardState -StepIndex 1 -State 'active'
            Set-InstallStepCardState -StepIndex 2 -State 'pending'
            Set-InstallStepCardState -StepIndex 3 -State 'pending'
            $controls.InstallStepProgressTitle.Text = '总进度 · 0 / 3'

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
                # 任务 014 Bug I (v2026.05.04.13):删"查看官方文档"和"查看解决说明"(URL 是 placeholder,无效入口)
                # 没 Git → 主"打开 Git 下载页" + 次"自动安装 Git"
                # 目录不可写 → 主"更改安装位置",次隐藏
                # 网络/其他阻塞 → 主"重新检测",次隐藏(因为没具体可操作步骤,Tertiary 也是重新检测)
                $primaryAction = if (-not $preflight.HasGit) { 'open-git-download' } elseif ($hasDirBlocking) { 'change-location' } else { 'refresh' }
                $primaryLabel = if (-not $preflight.HasGit) { '打开 Git 下载页' } elseif ($hasDirBlocking) { '更改安装位置' } else { '重新检测' }
                $secondaryAction = if (-not $preflight.HasGit) { 'install-git' } else { '' }
                $secondaryLabel = if (-not $preflight.HasGit) { '自动安装 Git' } else { '' }
                $secondaryEnabled = if (-not $preflight.HasGit) { $preflight.HasWinget } else { $false }
                Set-InstallActionButtons -PrimaryActionId $primaryAction -PrimaryLabel $primaryLabel -PrimaryEnabled $true -SecondaryActionId $secondaryAction -SecondaryLabel $secondaryLabel -SecondaryEnabled $secondaryEnabled -TertiaryActionId 'refresh' -TertiaryLabel '重新检测' -TertiaryEnabled $true
            }
        } elseif (-not $script:InstallLocationConfirmed) {
            # 任务 012：状态 6 - 位置确认
            $controls.InstallTaskCardBorder.Visibility = 'Collapsed'
            $controls.InstallPathCardBorder.Visibility = 'Visible'
            $controls.InstallProgressTitleText.Text = '流程进度'
            $controls.InstallProgressText.Text = ''
            $controls.InstallFailureSummaryText.Visibility = 'Collapsed'
            $controls.InstallFailureSummaryText.Text = ''
            $controls.InstallLocationNoticeText.Text = '安装完成后，这些路径会收纳到“更多设置”里查看。基础使用阶段不需要反复关注它们。'
            $controls.ChangeInstallLocationButton.IsEnabled = $true
            $controls.ConfirmInstallLocationButton.IsEnabled = $true
            $controls.ConfirmInstallLocationButton.Content = '位置已确认，继续'
            # 步骤指示器: 1=done, 2=active, 3=pending
            Set-InstallStepCardState -StepIndex 1 -State 'done'
            Set-InstallStepCardState -StepIndex 2 -State 'active'
            Set-InstallStepCardState -StepIndex 3 -State 'pending'
            $controls.InstallStepProgressTitle.Text = '总进度 · 1 / 3'
            $controls.InstallStep1Desc.Text = '已通过 · 准备开始安装'
            Set-InstallActionButtons -PrimaryActionId 'location-confirm' -PrimaryLabel '位置已确认，继续' -PrimaryEnabled $true -SecondaryActionId 'change-location' -SecondaryLabel '更改安装位置' -SecondaryEnabled $true -TertiaryActionId 'refresh' -TertiaryLabel '刷新状态' -TertiaryEnabled $true
        } else {
            # 任务 012：状态 7 - 准备安装
            $controls.InstallTaskCardBorder.Visibility = 'Visible'
            $controls.InstallTaskStepTagNum.Text = '3'
            $controls.InstallTaskStepTagText.Text = '开始安装'
            $controls.InstallProgressTitleText.Text = '安装前确认'
            $controls.InstallTaskTitleText.Text = '环境和位置都已确认，可以开始安装了'
            $controls.InstallTaskBodyText.Text = '点击开始后，启动器会在独立 PowerShell 终端里调用官方安装脚本；成功会自动关闭，失败会保留终端，方便直接把报错反馈回来。'
            $controls.InstallProgressText.Text = ''
            $controls.InstallFailureSummaryText.Visibility = if ($preflight.Warnings.Count -gt 0) { 'Visible' } else { 'Collapsed' }
            $controls.InstallFailureSummaryText.Text = if ($preflight.Warnings.Count -gt 0) { "提示：`n• " + ($preflight.Warnings -join "`n• ") } else { '' }
            # 步骤指示器: 1=done, 2=done, 3=active
            Set-InstallStepCardState -StepIndex 1 -State 'done'
            Set-InstallStepCardState -StepIndex 2 -State 'done'
            Set-InstallStepCardState -StepIndex 3 -State 'active'
            $controls.InstallStepProgressTitle.Text = '总进度 · 2 / 3'
            $controls.InstallStep1Desc.Text = '已通过'
            $controls.InstallStep2Desc.Text = '已确认'
            $controls.InstallStep3Desc.Text = '点开始安装即可启动官方脚本'
            Set-InstallActionButtons -PrimaryActionId 'install-external' -PrimaryLabel '开始安装' -PrimaryEnabled $true -SecondaryActionId 'change-location' -SecondaryLabel '更改安装位置' -SecondaryEnabled $true -TertiaryActionId 'refresh' -TertiaryLabel '刷新状态' -TertiaryEnabled $true
        }
    } else {
        Set-LauncherWindowMode -Mode 'Home'
        $controls.InstallModePanel.Visibility = 'Collapsed'
        $controls.HomeModePanel.Visibility = 'Visible'
        $controls.LogSectionBorder.Visibility = 'Collapsed'
        $controls.FooterBorder.Visibility = 'Collapsed'

        $controls.StatusHeadlineText.Text = '已就绪'
        $controls.StatusBodyText.Text = '点「开始使用」打开 hermes-web-ui，在浏览器中完成模型配置和对话。'

        Set-PrimaryAction -ActionId 'launch' -Label '开始使用' -Enabled ([bool]$script:CurrentStatus.HermesCommand)
        Set-SecondaryAction -ActionId '' -Label '' -Enabled $false -Visible $false
        $controls.RecommendationText.Text = ''
        $controls.RecommendationHintText.Text = ''

        # 任务 012：Home Mode 时如不在 launching，确保 LaunchProgressCard 隐藏，HomeReady 可见
        if (-not $script:LaunchState) {
            try { if ($controls.LaunchProgressCard) { $controls.LaunchProgressCard.Visibility = 'Collapsed' } } catch { }
            try { if ($controls.HomeReadyContainer) { $controls.HomeReadyContainer.Visibility = 'Visible' } } catch { }
        }

        # 任务 014 Bug B：Home Mode 内的 OpenClaw 迁移横幅显隐
        try {
            if ($controls.HomeOpenClawBanner) {
                if ($pendingOpenClaw) {
                    $controls.HomeOpenClawBanner.Visibility = 'Visible'
                    if ($controls.HomeOpenClawImportButton) { $controls.HomeOpenClawImportButton.IsEnabled = [bool]$script:CurrentStatus.HermesCommand }
                    if ($controls.HomeOpenClawSkipButton) { $controls.HomeOpenClawSkipButton.IsEnabled = $true }
                } else {
                    $controls.HomeOpenClawBanner.Visibility = 'Collapsed'
                }
            }
        } catch { }

        # 任务 014 Bug A：渠道依赖安装失败横幅显隐 + 主按钮屏蔽
        try {
            if ($controls.HomeDepFailureBanner) {
                if ($script:LastDepInstallFailure) {
                    $channel = [string]$script:LastDepInstallFailure.ChannelLabel
                    if ($controls.HomeDepFailureText) {
                        $controls.HomeDepFailureText.Text = "渠道依赖安装失败：$channel。点这里查看详情"
                    }
                    $controls.HomeDepFailureBanner.Visibility = 'Visible'
                    # 主按钮变灰，提示用户先解决依赖问题
                    Set-PrimaryAction -ActionId 'launch' -Label '渠道依赖未就绪' -Enabled $false
                } else {
                    $controls.HomeDepFailureBanner.Visibility = 'Collapsed'
                }
            }
        } catch { }
    }
    Set-Footer ("Hermes 命令路径：{0}" -f $(if ($script:CurrentStatus.HermesCommand) { $script:CurrentStatus.HermesCommand } else { '未找到' }))
}

function Invoke-AppAction {
    param([string]$ActionId)

    # 任务 014 Bug C：包裹整段 action 处理逻辑，任何文件不存在 / Start-Process 失败等
    # 异常都不再冒泡到 WPF Dispatcher 未捕获处理器，避免 dashboard 上 dispatcher:
    # FileNotFoundException 占失败事件 ~20%。
    try {
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
            # 任务 014 Bug M (v2026.05.04.18):国内网络警告
            # 用户点"环境没问题,继续"按钮的瞬间弹一次,让"环境检测"步骤承担所有风险告知职责。
            # 同一 launcher 会话只弹一次。
            # - 用户选"是"→ ack=true,InstallPreflightConfirmed=true,进入下一步(位置确认)
            # - 用户选"否"→ ack 不变(下次重新检测后还会弹),不前进,留在环境检测屏幕
            if ($preflight.NetworkEnv -eq 'china' -and -not $script:ChinaNetworkAcknowledged) {
                $chinaMsg = @(
                    '检测到你在国内网络环境。'
                    ''
                    'Hermes Agent 安装会从 GitHub、PyPI、npm 等多个海外资源下载组件。当前国内网络下安装可能因网络波动失败,我们正在持续改进。'
                    ''
                    '【是】继续尝试 - 失败时启动器会显示具体错误'
                    '【否】暂不安装 - 等后续版本改进'
                ) -join [Environment]::NewLine
                $chinaResult = [System.Windows.MessageBox]::Show(
                    $chinaMsg,
                    'Hermes 启动器',
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Information
                )
                $userChoice = if ($chinaResult -eq [System.Windows.MessageBoxResult]::Yes) { 'continue' } else { 'cancel' }
                try { Send-Telemetry -EventName 'china_network_warning_shown' -Properties @{ user_choice = $userChoice } } catch { }
                if ($chinaResult -ne [System.Windows.MessageBoxResult]::Yes) {
                    Add-ActionLog -Action '确认环境检测' -Result '用户暂不安装(国内网络警告未确认)' -Next '可重新点击"重新检测",再决定是否继续'
                    return
                }
                $script:ChinaNetworkAcknowledged = $true
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
            # 任务 014 Bug M (v2026.05.04.18):国内网络警告已从这里挪到 preflight-confirm action
            # (用户点"环境没问题,继续"按钮的瞬间弹),让"环境检测"步骤承担所有风险告知职责
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
                try { Refresh-Status } catch { }   # P1-2-LITE: 立即切到 State 8 占位屏
                Start-InstallSpinner               # P1-2-LITE: 启动 braille spinner
                Add-ActionLog -Action '安装 / 更新 Hermes' -Result '已打开独立 PowerShell 安装终端。成功时终端会在 5 秒后自动关闭，失败时会保留终端供查看报错。' -Next '安装结束后启动器会自动刷新状态'
                try { Send-Telemetry -EventName 'hermes_install_started' -Properties @{ network_env = [string]$networkEnv; branch = [string]$state.Branch } } catch { }
            } catch {
                Add-ActionLog -Action '改用外部终端安装' -Result ('启动安装脚本失败：' + $_.Exception.Message) -Next '检查网络连接或稍后重试；如持续失败请联系作者'
                try { Send-Telemetry -EventName 'hermes_install_failed' -FailureReason ('start_terminal: ' + $_.Exception.Message) -Properties @{ stage = 'start_terminal' } } catch { }
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
    } catch {
        # 任务 014 Bug C：把异常类型 + 消息记到日志和遥测，不让任何异常冒到 Dispatcher 未捕获处理器
        try {
            $exType = $_.Exception.GetType().FullName
            $exMsg  = $_.Exception.Message
            Add-LogLine ("操作 '{0}' 异常：{1}: {2}" -f $ActionId, $exType, $exMsg)
            Send-Telemetry -EventName 'unexpected_error' -FailureReason ('action: ' + $ActionId + ': ' + $exType + ': ' + $exMsg) -Properties @{ source = 'invoke_app_action'; action = $ActionId }
        } catch { }
    }
}

$controls.ClearLogButton.Add_Click({ $controls.LogTextBox.Clear() })
$controls.CopyFeedbackButton.Add_Click({
    [System.Windows.Clipboard]::SetText((Get-InstallFeedbackText))
    Add-ActionLog -Action '复制反馈信息' -Result '已复制当前状态、安装检测结果和最近日志' -Next '直接发给开发者即可'
})
# 任务 012：失败摘要 LogPreview 的"复制错误"按钮
if ($controls.InstallFailureLogCopyButton) {
    $controls.InstallFailureLogCopyButton.Add_Click({
        try {
            $logText = if ($controls.InstallFailureLogPreviewText -and $controls.InstallFailureLogPreviewText.Text) {
                $controls.InstallFailureLogPreviewText.Text
            } else {
                Get-InstallFeedbackText
            }
            [System.Windows.Clipboard]::SetText($logText)
            Add-ActionLog -Action '复制错误信息' -Result '已复制最近的安装日志' -Next '可粘到 GitHub Issue 或反馈群里'
        } catch { }
    })
}
# 任务 012：启动 WebUI 进度卡的"取消并返回"按钮
if ($controls.LaunchProgressCancelButton) {
    $controls.LaunchProgressCancelButton.Add_Click({
        try { Stop-LaunchAsync } catch { }
    })
}
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
# 任务 014 Bug B：Home Mode 内的 OpenClaw 迁移按钮（用户已装机器，不应进 Install Mode）
$controls.HomeOpenClawImportButton.Add_Click({ Invoke-AppAction 'openclaw-migrate' })
$controls.HomeOpenClawSkipButton.Add_Click({ Invoke-AppAction 'openclaw-skip' })
# 任务 014 Bug A：渠道依赖安装失败横幅 → 显示错误尾部 + 复制按钮
$controls.HomeDepFailureViewButton.Add_Click({ Show-DepInstallFailureDialog })
$controls.HomeDepFailureBanner.Add_MouseLeftButtonUp({ Show-DepInstallFailureDialog })

# 任务 011：「关于」按钮 + 首次同意提示「知道了」按钮
$controls.AboutButton.Add_Click({ Show-AboutDialog })
$controls.TelemetryConsentDismissButton.Add_Click({ Hide-TelemetryConsentBanner })

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

# 任务 011：上报会话开始 + 处理首次同意提示
try { Send-Telemetry -EventName 'launcher_opened' } catch { }
try {
    if (-not (Get-FirstRunConsentShown)) {
        Show-TelemetryConsentBanner
    }
} catch { }

try {
    Refresh-Status
} catch {
    Add-LogLine ("启动时状态刷新失败：{0}" -f $_.Exception.Message)
    try { Send-Telemetry -EventName 'unexpected_error' -FailureReason ("startup_refresh: " + $_.Exception.Message) } catch { }
}
try {
    $window.ShowDialog() | Out-Null
} finally {
    try {
        Send-Telemetry -EventName 'launcher_closed' -Properties @{ session_seconds = Get-LauncherUptimeSeconds }
        # 给上报一点时间发出去（最多 2 秒），避免进程退出时 task 被中断
        try { Start-Sleep -Milliseconds 600 } catch { }
    } catch { }
    try { Stop-HermesWebUiRuntime | Out-Null } catch { }
    if ($script:LauncherMutex) {
        $script:LauncherMutex.ReleaseMutex()
        $script:LauncherMutex.Dispose()
    }
}
