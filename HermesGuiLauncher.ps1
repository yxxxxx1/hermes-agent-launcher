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

$script:LauncherVersion = 'Windows v2026.04.28.2'
$script:HermesWebUiSourceRepo = 'nesquena/hermes-webui'
$script:HermesWebUiVersionLabel = 'v0.50.63'
$script:HermesWebUiCommit = 'a512f2020e01ef8c98989eb00c84a8d8cfc81ee1'
$script:HermesWebUiArchiveUrl = "https://github.com/$($script:HermesWebUiSourceRepo)/archive/$($script:HermesWebUiCommit).zip"
$script:HermesWebUiHost = '127.0.0.1'
$script:HermesWebUiPortStart = 8787
$script:HermesWebUiPortEnd = 8799

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
    $webUiDir = Join-Path $installRoot 'hermes-webui'
    $venvScripts = Join-Path $installDir 'venv\Scripts'
    [pscustomobject]@{
        HermesHome         = $hermesHome
        InstallRoot        = $installRoot
        InstallDir         = $installDir
        WebUiDir           = $webUiDir
        WebUiStagingDir    = Join-Path $installRoot 'hermes-webui-staging'
        WebUiBackupDir     = Join-Path $installRoot 'hermes-webui-backup'
        WebUiStateDir      = Join-Path $hermesHome 'webui'
        WebUiLauncherState = Join-Path $hermesHome 'webui-launcher.json'
        WebUiWorkspaceDir  = Join-Path $env:USERPROFILE 'HermesWorkspace'
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
    param(
        [string]$HermesHome,
        [string]$InstallDir
    )

    $base = Get-HermesDefaults
    if (-not $HermesHome) { $HermesHome = $base.HermesHome }
    if (-not $InstallDir) { $InstallDir = $base.InstallDir }
    $installRoot = Split-Path -Parent $InstallDir
    if (-not $installRoot) { $installRoot = $base.InstallRoot }

    [pscustomobject]@{
        SourceRepo        = $script:HermesWebUiSourceRepo
        VersionLabel      = $script:HermesWebUiVersionLabel
        Commit            = $script:HermesWebUiCommit
        ArchiveUrl        = $script:HermesWebUiArchiveUrl
        Host              = $script:HermesWebUiHost
        PortStart         = $script:HermesWebUiPortStart
        PortEnd           = $script:HermesWebUiPortEnd
        InstallDir        = Join-Path $installRoot 'hermes-webui'
        StagingDir        = Join-Path $installRoot 'hermes-webui-staging'
        BackupDir         = Join-Path $installRoot 'hermes-webui-backup'
        StateDir          = Join-Path $HermesHome 'webui'
        LauncherStatePath = Join-Path $HermesHome 'webui-launcher.json'
        WorkspaceDir      = Join-Path $env:USERPROFILE 'HermesWorkspace'
        LogsDir           = Join-Path (Join-Path $HermesHome 'logs') 'webui'
        AgentDir          = $InstallDir
        PythonExe         = Join-Path $InstallDir 'venv\Scripts\python.exe'
        ConfigPath        = Join-Path $HermesHome 'config.yaml'
        HermesHome        = $HermesHome
    }
}

function Test-HermesWebUiInstalled {
    param([string]$WebUiDir)

    $serverPath = Join-Path $WebUiDir 'server.py'
    $requirementsPath = Join-Path $WebUiDir 'requirements.txt'
    $staticIndexPath = Join-Path (Join-Path $WebUiDir 'static') 'index.html'
    [pscustomobject]@{
        Installed          = [bool]((Test-Path $serverPath) -and (Test-Path $requirementsPath) -and (Test-Path $staticIndexPath))
        WebUiDir           = $WebUiDir
        ServerPath         = $serverPath
        RequirementsPath   = $requirementsPath
        StaticIndexPath    = $staticIndexPath
        ServerExists       = [bool](Test-Path $serverPath)
        RequirementsExists = [bool](Test-Path $requirementsPath)
        StaticIndexExists  = [bool](Test-Path $staticIndexPath)
        Commit             = $script:HermesWebUiCommit
        VersionLabel       = $script:HermesWebUiVersionLabel
    }
}

function Assert-SafeWebUiPath {
    param(
        [string]$Path,
        [string]$InstallRoot
    )

    if (-not $Path -or -not $InstallRoot) { throw 'WebUI 路径为空。' }
    $rootFull = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $pathFull = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not $pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝操作安装根目录之外的 WebUI 路径：$pathFull"
    }
}

function Install-HermesWebUi {
    param(
        $WebUiDefaults,
        [bool]$Force = $false
    )

    $existing = Test-HermesWebUiInstalled -WebUiDir $WebUiDefaults.InstallDir
    if ($existing.Installed -and -not $Force) {
        return [pscustomobject]@{
            Installed = $true
            Changed   = $false
            Message   = 'WebUI 已安装。'
            Status    = $existing
        }
    }

    $installRoot = Split-Path -Parent $WebUiDefaults.InstallDir
    Assert-SafeWebUiPath -Path $WebUiDefaults.InstallDir -InstallRoot $installRoot
    Assert-SafeWebUiPath -Path $WebUiDefaults.StagingDir -InstallRoot $installRoot
    Assert-SafeWebUiPath -Path $WebUiDefaults.BackupDir -InstallRoot $installRoot
    if (-not (Test-Path $installRoot)) {
        New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    }

    if (Test-Path $WebUiDefaults.StagingDir) {
        Remove-Item -LiteralPath $WebUiDefaults.StagingDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $WebUiDefaults.StagingDir -Force | Out-Null

    $archivePath = Join-Path $WebUiDefaults.StagingDir ('hermes-webui-' + $WebUiDefaults.Commit + '.zip')
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $WebUiDefaults.ArchiveUrl -OutFile $archivePath
        $extractDir = Join-Path $WebUiDefaults.StagingDir 'extract'
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDir -Force
        $inner = Get-ChildItem -LiteralPath $extractDir -Directory | Select-Object -First 1
        if (-not $inner) { throw 'WebUI 压缩包内没有源码目录。' }
        $candidate = $inner.FullName
        $candidateStatus = Test-HermesWebUiInstalled -WebUiDir $candidate
        if (-not $candidateStatus.Installed) {
            throw 'WebUI 压缩包缺少 server.py、requirements.txt 或 static/index.html。'
        }

        if (Test-Path $WebUiDefaults.BackupDir) {
            Remove-Item -LiteralPath $WebUiDefaults.BackupDir -Recurse -Force
        }
        if (Test-Path $WebUiDefaults.InstallDir) {
            Move-Item -LiteralPath $WebUiDefaults.InstallDir -Destination $WebUiDefaults.BackupDir -Force
        }

        try {
            Move-Item -LiteralPath $candidate -Destination $WebUiDefaults.InstallDir -Force
        } catch {
            if ((Test-Path $WebUiDefaults.BackupDir) -and -not (Test-Path $WebUiDefaults.InstallDir)) {
                Move-Item -LiteralPath $WebUiDefaults.BackupDir -Destination $WebUiDefaults.InstallDir -Force
            }
            throw
        }

        $finalStatus = Test-HermesWebUiInstalled -WebUiDir $WebUiDefaults.InstallDir
        if (-not $finalStatus.Installed) { throw 'WebUI 安装后校验失败。' }
        return [pscustomobject]@{
            Installed = $true
            Changed   = $true
            Message   = "WebUI 已安装到 $($WebUiDefaults.InstallDir)。"
            Status    = $finalStatus
        }
    } finally {
        if (Test-Path $WebUiDefaults.StagingDir) {
            Remove-Item -LiteralPath $WebUiDefaults.StagingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-HermesWebUiPythonReady {
    param([string]$PythonExe)

    if (-not $PythonExe -or -not (Test-Path $PythonExe)) {
        return [pscustomobject]@{
            Ready   = $false
            Message = '未找到 Hermes Python。'
        }
    }

    $output = & $PythonExe -c "import yaml; print('yaml-ok')" 2>&1
    [pscustomobject]@{
        Ready   = [bool]($LASTEXITCODE -eq 0)
        Message = if ($LASTEXITCODE -eq 0) { 'pyyaml 已可用。' } else { ($output -join [Environment]::NewLine) }
    }
}

function Ensure-HermesWebUiPythonDependency {
    param(
        [string]$PythonExe,
        [string]$UvExe
    )

    $ready = Test-HermesWebUiPythonReady -PythonExe $PythonExe
    if ($ready.Ready) {
        return [pscustomobject]@{ Ready = $true; Changed = $false; Message = $ready.Message }
    }

    if ($UvExe -and (Test-Path $UvExe)) {
        $uvOutput = & $UvExe pip install --python $PythonExe 'pyyaml>=6.0' 2>&1
        if ($LASTEXITCODE -eq 0) {
            return [pscustomobject]@{ Ready = $true; Changed = $true; Message = '已通过 uv 安装 pyyaml。' }
        }
    }

    $pipOutput = & $PythonExe -m pip install --quiet 'pyyaml>=6.0' 2>&1
    if ($LASTEXITCODE -eq 0) {
        return [pscustomobject]@{ Ready = $true; Changed = $true; Message = '已通过 pip 安装 pyyaml。' }
    }

    [pscustomobject]@{
        Ready   = $false
        Changed = $false
        Message = if ($pipOutput) { ($pipOutput -join [Environment]::NewLine) } else { 'pyyaml 安装失败。' }
    }
}

function Get-ObjectPropertyValue {
    param(
        $InputObject,
        [string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Load-HermesWebUiRuntimeState {
    param([string]$HermesHome)

    $webUiDefaults = Get-HermesWebUiDefaults -HermesHome $HermesHome
    $path = $webUiDefaults.LauncherStatePath
    if (-not $path -or -not (Test-Path $path)) {
        return [pscustomobject]@{
            Exists       = $false
            SourceRepo   = $script:HermesWebUiSourceRepo
            VersionLabel = $script:HermesWebUiVersionLabel
            Commit       = $script:HermesWebUiCommit
            Pid          = $null
            Port         = $null
            Url          = $null
            OutLog       = $null
            ErrLog       = $null
            InstalledAt  = $null
            StartedAt    = $null
            UpdatedAt    = $null
        }
    }

    try {
        $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $pidValue = Get-ObjectPropertyValue -InputObject $data -Name 'pid'
        $portValue = Get-ObjectPropertyValue -InputObject $data -Name 'port'
        return [pscustomobject]@{
            Exists       = $true
            SourceRepo   = [string](Get-ObjectPropertyValue -InputObject $data -Name 'source_repo')
            VersionLabel = [string](Get-ObjectPropertyValue -InputObject $data -Name 'version_label')
            Commit       = [string](Get-ObjectPropertyValue -InputObject $data -Name 'commit')
            WebUiDir     = [string](Get-ObjectPropertyValue -InputObject $data -Name 'webui_dir')
            StateDir     = [string](Get-ObjectPropertyValue -InputObject $data -Name 'state_dir')
            Workspace    = [string](Get-ObjectPropertyValue -InputObject $data -Name 'workspace')
            Pid          = if ($pidValue) { [int]$pidValue } else { $null }
            Port         = if ($portValue) { [int]$portValue } else { $null }
            Url          = [string](Get-ObjectPropertyValue -InputObject $data -Name 'url')
            OutLog       = [string](Get-ObjectPropertyValue -InputObject $data -Name 'out_log')
            ErrLog       = [string](Get-ObjectPropertyValue -InputObject $data -Name 'err_log')
            InstalledAt  = [string](Get-ObjectPropertyValue -InputObject $data -Name 'installed_at')
            StartedAt    = [string](Get-ObjectPropertyValue -InputObject $data -Name 'started_at')
            UpdatedAt    = [string](Get-ObjectPropertyValue -InputObject $data -Name 'updated_at')
        }
    } catch {
        return [pscustomobject]@{
            Exists       = $false
            SourceRepo   = $script:HermesWebUiSourceRepo
            VersionLabel = $script:HermesWebUiVersionLabel
            Commit       = $script:HermesWebUiCommit
            Pid          = $null
            Port         = $null
            Url          = $null
            OutLog       = $null
            ErrLog       = $null
            InstalledAt  = $null
            StartedAt    = $null
            UpdatedAt    = $null
        }
    }
}

function Test-HermesWebUiHealth {
    param(
        [int]$Port,
        [string]$HostName = $script:HermesWebUiHost,
        [int]$TimeoutSec = 2
    )

    $url = "http://$HostName`:$Port"
    try {
        $health = Invoke-RestMethod -Uri "$url/health" -TimeoutSec $TimeoutSec
        return [pscustomobject]@{
            Healthy = [bool]($health.status -eq 'ok')
            Url     = $url
            Port    = $Port
            Message = if ($health.status -eq 'ok') { 'WebUI health ok.' } else { 'WebUI health returned unexpected status.' }
            Raw     = $health
        }
    } catch {
        return [pscustomobject]@{
            Healthy = $false
            Url     = $url
            Port    = $Port
            Message = $_.Exception.Message
            Raw     = $null
        }
    }
}

function Get-HermesWebUiStatus {
    param(
        [string]$HermesHome,
        [string]$InstallDir
    )

    $webUiDefaults = Get-HermesWebUiDefaults -HermesHome $HermesHome -InstallDir $InstallDir
    $installStatus = Test-HermesWebUiInstalled -WebUiDir $webUiDefaults.InstallDir
    $runtime = Load-HermesWebUiRuntimeState -HermesHome $HermesHome
    $health = $null
    if ($runtime.Port) {
        $health = Test-HermesWebUiHealth -Port $runtime.Port
    }
    [pscustomobject]@{
        Defaults      = $webUiDefaults
        InstallStatus = $installStatus
        Runtime       = $runtime
        Healthy       = [bool]($health -and $health.Healthy)
        Health        = $health
        Url           = if ($health -and $health.Healthy) { $health.Url } elseif ($runtime.Url) { $runtime.Url } else { $null }
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

function Get-ModelProviderCatalog {
    $catalog = @(
        [pscustomobject]@{
            Id             = 'nous'
            Title          = 'Nous Portal'
            Category       = '账号登录'
            ConfigProvider = 'nous'
            DefaultModel   = 'xiaomi/mimo-v2-pro'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $false
            Description    = '使用 Nous Portal 订阅账号登录，Hermes 会自动维护 auth.json 和短期 agent key。'
            Help           = '点击后会生成浏览器登录链接和验证码。登录成功后，启动器会自动写入 provider 与凭证状态。'
            BaseUrlDefault = ''
            AuthType       = 'oauth_device_code'
        }
        [pscustomobject]@{
            Id             = 'openai-codex'
            Title          = 'OpenAI Codex'
            Category       = '账号登录'
            ConfigProvider = 'openai-codex'
            DefaultModel   = 'gpt-5.3-codex'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $false
            Description    = '使用 OpenAI 账号登录 Codex，不再手填 API Key。'
            Help           = '点击后会生成 OpenAI 登录码。完成浏览器授权后，启动器会自动保存到 ~/.hermes/auth.json。'
            BaseUrlDefault = ''
            AuthType       = 'oauth_device_code'
        }
        [pscustomobject]@{
            Id             = 'copilot'
            Title          = 'GitHub Copilot'
            Category       = '账号登录'
            ConfigProvider = 'copilot'
            ApiKeyEnv      = 'COPILOT_GITHUB_TOKEN'
            DefaultModel   = 'gpt-5.4'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $false
            Description    = '使用 GitHub 账号登录 Copilot，或复用 gh 登录态。'
            Help           = 'GUI 会生成 GitHub 设备码。授权成功后，令牌会保存到 COPILOT_GITHUB_TOKEN。'
            BaseUrlDefault = ''
            AuthType       = 'oauth_device_code'
        }
        [pscustomobject]@{
            Id             = 'anthropic-account'
            Title          = 'Anthropic / Claude Code 登录'
            Category       = '账号登录'
            ConfigProvider = 'anthropic'
            DefaultModel   = 'claude-sonnet-4-20250514'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $false
            Description    = '复用 Claude Code 的登录状态，或使用 Hermes 的 Claude OAuth 凭证文件。'
            Help           = '如果本机已经登录 Claude Code，可直接导入并启用，不需要再手填 API Key。'
            BaseUrlDefault = ''
            AuthType       = 'credential_import'
        }
        [pscustomobject]@{
            Id             = 'qwen-oauth'
            Title          = 'Qwen OAuth'
            Category       = '账号登录'
            ConfigProvider = 'qwen-oauth'
            DefaultModel   = 'qwen3-coder-plus'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $false
            Description    = '复用本机 Qwen CLI 的 OAuth 登录状态。'
            Help           = 'Hermes 会读取 ~/.qwen/oauth_creds.json。若尚未登录，需要先完成 Qwen CLI 登录。'
            BaseUrlDefault = ''
            AuthType       = 'external_cli'
        }
        [pscustomobject]@{
            Id             = 'copilot-acp'
            Title          = 'GitHub Copilot ACP'
            Category       = '账号登录'
            ConfigProvider = 'copilot-acp'
            DefaultModel   = 'copilot-acp'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $false
            Description    = '通过本地 Copilot CLI 的 ACP 进程接入 Hermes。'
            Help           = '需要本机已安装并可执行 copilot CLI。Hermes 会把本地模型选择当作 ACP 会话提示。'
            BaseUrlDefault = ''
            AuthType       = 'external_process'
        }
        [pscustomobject]@{
            Id             = 'deepseek'
            Title          = 'DeepSeek'
            Category       = '推荐'
            ConfigProvider = 'deepseek'
            ApiKeyEnv      = 'DEEPSEEK_API_KEY'
            DefaultModel   = 'deepseek-chat'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $true
            Description    = '适合中文用户。只需要模型名和 API Key。'
            Help           = '推荐先用 DeepSeek 快速验证 Hermes 是否能正常对话。'
            BaseUrlDefault = 'https://api.deepseek.com/v1'
        }
        [pscustomobject]@{
            Id             = 'openrouter'
            Title          = 'OpenRouter'
            Category       = '推荐'
            ConfigProvider = 'openrouter'
            ApiKeyEnv      = 'OPENROUTER_API_KEY'
            DefaultModel   = 'openai/gpt-4.1-mini'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $true
            Description    = '聚合多家模型平台。通常不需要自己填写 Base URL。'
            Help           = '模型名通常是带厂商前缀的完整名称，例如 openai/gpt-4.1-mini。'
            BaseUrlDefault = 'https://openrouter.ai/api/v1'
        }
        [pscustomobject]@{
            Id             = 'openai'
            Title          = 'OpenAI 官方接口'
            Category       = '推荐'
            ConfigProvider = 'custom'
            ApiKeyEnv      = 'OPENAI_API_KEY'
            DefaultModel   = 'gpt-4.1-mini'
            NeedsBaseUrl   = $true
            ApiKeyRequired = $true
            Description    = '直接连接 OpenAI 官方接口。GUI 会按官方 custom endpoint 方式写入 config.yaml。'
            Help           = '通常无需改 Base URL，保持 https://api.openai.com/v1 即可。'
            BaseUrlDefault = 'https://api.openai.com/v1'
        }
        [pscustomobject]@{
            Id             = 'anthropic'
            Title          = 'Anthropic API Key'
            Category       = 'API Key'
            ConfigProvider = 'anthropic'
            ApiKeyEnv      = 'ANTHROPIC_API_KEY'
            DefaultModel   = 'claude-sonnet-4-20250514'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $true
            Description    = '直接用 Anthropic API Key，不走 OAuth 登录。'
            Help           = '如果你使用的是 Claude API Key，这里是最简单的入口。'
            BaseUrlDefault = ''
        }
        [pscustomobject]@{
            Id             = 'gemini'
            Title          = 'Google / Gemini'
            Category       = 'API Key'
            ConfigProvider = 'gemini'
            ApiKeyEnv      = 'GOOGLE_API_KEY'
            DefaultModel   = 'gemini-2.5-flash'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $true
            Description    = '使用 Google / Gemini API Key。'
            Help           = '官方文档支持 GOOGLE_API_KEY 或 GEMINI_API_KEY，这里统一写 GOOGLE_API_KEY。'
            BaseUrlDefault = 'https://generativelanguage.googleapis.com/v1beta/openai'
        }
        [pscustomobject]@{
            Id             = 'zai'
            Title          = 'z.ai / GLM'
            Category       = 'API Key'
            ConfigProvider = 'zai'
            ApiKeyEnv      = 'GLM_API_KEY'
            DefaultModel   = 'glm-4.5'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $true
            Description    = '使用智谱 z.ai / GLM 平台。'
            Help           = '如需覆盖官方默认地址，可后续在 .env 中追加 GLM_BASE_URL。'
            BaseUrlDefault = 'https://open.bigmodel.cn/api/paas/v4'
        }
        [pscustomobject]@{
            Id             = 'kimi'
            Title          = 'Kimi / Moonshot'
            Category       = 'API Key'
            ConfigProvider = 'kimi-coding'
            ApiKeyEnv      = 'KIMI_API_KEY'
            DefaultModel   = 'kimi-k2-0711-preview'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $true
            Description    = '使用 Moonshot / Kimi 接口。'
            Help           = '如需覆盖默认地址，可后续在 .env 中追加 KIMI_BASE_URL。'
            BaseUrlDefault = 'https://api.moonshot.cn/v1'
        }
        [pscustomobject]@{
            Id             = 'minimax'
            Title          = 'MiniMax'
            Category       = 'API Key'
            ConfigProvider = 'minimax'
            ApiKeyEnv      = 'MINIMAX_API_KEY'
            DefaultModel   = 'MiniMax-M1-80k'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $true
            Description    = '使用 MiniMax 国际版接口。'
            Help           = '如需国内版，请选择下面的 MiniMax 中国区。'
            BaseUrlDefault = 'https://api.minimax.chat/v1'
        }
        [pscustomobject]@{
            Id             = 'minimax-cn'
            Title          = 'MiniMax 中国区'
            Category       = 'API Key'
            ConfigProvider = 'minimax-cn'
            ApiKeyEnv      = 'MINIMAX_CN_API_KEY'
            DefaultModel   = 'MiniMax-M1-80k'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $true
            Description    = '使用 MiniMax 中国区接口。'
            Help           = '如需覆盖默认地址，可后续在 .env 中追加 MINIMAX_CN_BASE_URL。'
            BaseUrlDefault = 'https://api.minimax.chat/v1'
        }
        [pscustomobject]@{
            Id             = 'alibaba'
            Title          = 'Qwen / 阿里百炼'
            Category       = 'API Key'
            ConfigProvider = 'alibaba'
            ApiKeyEnv      = 'DASHSCOPE_API_KEY'
            DefaultModel   = 'qwen-plus'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $true
            Description    = '使用阿里百炼 / DashScope / Qwen。'
            Help           = '官方 provider 是 alibaba；dashscope / qwen 只是别名。'
            BaseUrlDefault = 'https://dashscope.aliyuncs.com/compatible-mode/v1'
        }
        [pscustomobject]@{
            Id             = 'huggingface'
            Title          = 'Hugging Face'
            Category       = 'API Key'
            ConfigProvider = 'huggingface'
            ApiKeyEnv      = 'HF_TOKEN'
            DefaultModel   = 'Qwen/Qwen3-235B-A22B-Thinking-2507'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $true
            Description    = '通过 Hugging Face Inference Providers 访问开源模型。'
            Help           = '需要 HF_TOKEN，且令牌需开启 Inference Providers 权限。'
            BaseUrlDefault = ''
        }
        [pscustomobject]@{
            Id             = 'ai-gateway'
            Title          = 'AI Gateway'
            Category       = 'API Key'
            ConfigProvider = 'ai-gateway'
            ApiKeyEnv      = 'AI_GATEWAY_API_KEY'
            DefaultModel   = 'openai/gpt-4.1-mini'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $true
            Description    = '通过 AI Gateway 转发请求。'
            Help           = '如果你自己有统一网关或平台网关，可以用这一项。'
            BaseUrlDefault = ''
        }
        [pscustomobject]@{
            Id             = 'kilocode'
            Title          = 'Kilo Code'
            Category       = 'API Key'
            ConfigProvider = 'kilocode'
            ApiKeyEnv      = 'KILOCODE_API_KEY'
            DefaultModel   = 'kilocode-default'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $true
            Description    = '官方内置的一类 API Key 平台。'
            Help           = '如果你的服务商明确要求 KILOCODE_API_KEY，就选这里。'
            BaseUrlDefault = ''
        }
        [pscustomobject]@{
            Id             = 'xiaomi'
            Title          = 'Xiaomi / MiMo'
            Category       = 'API Key'
            ConfigProvider = 'xiaomi'
            ApiKeyEnv      = 'XIAOMI_API_KEY'
            DefaultModel   = 'mimo-v2-pro'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $true
            Description    = '小米 MiMo / Xiaomi 官方模型接口。'
            Help           = '官方 provider 是 xiaomi；mimo / xiaomi-mimo 是别名。'
            BaseUrlDefault = ''
        }
        [pscustomobject]@{
            Id             = 'opencode-zen'
            Title          = 'OpenCode Zen'
            Category       = 'API Key'
            ConfigProvider = 'opencode-zen'
            ApiKeyEnv      = 'OPENCODE_ZEN_API_KEY'
            DefaultModel   = 'opencode-zen'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $true
            Description    = 'OpenCode Zen 平台。'
            Help           = '如果服务商文档要求 OPENCODE_ZEN_API_KEY，就选这里。'
            BaseUrlDefault = ''
        }
        [pscustomobject]@{
            Id             = 'opencode-go'
            Title          = 'OpenCode Go'
            Category       = 'API Key'
            ConfigProvider = 'opencode-go'
            ApiKeyEnv      = 'OPENCODE_GO_API_KEY'
            DefaultModel   = 'opencode-go'
            NeedsBaseUrl   = $false
            ApiKeyRequired = $true
            Description    = 'OpenCode Go 平台。'
            Help           = '如果服务商文档要求 OPENCODE_GO_API_KEY，就选这里。'
            BaseUrlDefault = ''
        }
        [pscustomobject]@{
            Id             = 'local-ollama'
            Title          = '本地模型 / Ollama'
            Category       = '本地'
            ConfigProvider = 'custom'
            ApiKeyEnv      = 'OPENAI_API_KEY'
            DefaultModel   = 'qwen2.5-coder:32b'
            NeedsBaseUrl   = $true
            ApiKeyRequired = $false
            Description    = '本机最容易上手的本地模型方案。适合隐私敏感、离线使用或轻量验证。'
            Help           = '默认地址是 http://localhost:11434/v1。通常不需要 API Key，但建议把 Ollama 上下文长度调到至少 16k-32k。'
            BaseUrlDefault = 'http://localhost:11434/v1'
        }
        [pscustomobject]@{
            Id             = 'local-vllm'
            Title          = '本地模型 / vLLM'
            Category       = '本地'
            ConfigProvider = 'custom'
            ApiKeyEnv      = 'OPENAI_API_KEY'
            DefaultModel   = 'meta-llama/Llama-3.1-8B-Instruct'
            NeedsBaseUrl   = $true
            ApiKeyRequired = $false
            Description    = '适合独立 GPU 服务、吞吐更高的本地或局域网部署。'
            Help           = '常用地址是 http://localhost:8000/v1。若启用了 --api-key 可填写；未启用可留空。'
            BaseUrlDefault = 'http://localhost:8000/v1'
        }
        [pscustomobject]@{
            Id             = 'local-sglang'
            Title          = '本地模型 / SGLang'
            Category       = '本地'
            ConfigProvider = 'custom'
            ApiKeyEnv      = 'OPENAI_API_KEY'
            DefaultModel   = 'meta-llama/Llama-3.1-8B-Instruct'
            NeedsBaseUrl   = $true
            ApiKeyRequired = $false
            Description    = '适合高性能推理和更细粒度服务控制。'
            Help           = '常用地址是 http://localhost:30000/v1。若服务没要求 API Key，可留空。'
            BaseUrlDefault = 'http://localhost:30000/v1'
        }
        [pscustomobject]@{
            Id             = 'local-lmstudio'
            Title          = '本地模型 / LM Studio'
            Category       = '本地'
            ConfigProvider = 'custom'
            ApiKeyEnv      = 'OPENAI_API_KEY'
            DefaultModel   = 'qwen2.5-coder'
            NeedsBaseUrl   = $true
            ApiKeyRequired = $false
            Description    = '适合 mac / Windows 桌面用户，界面化管理本地模型更方便。'
            Help           = '默认地址是 http://localhost:1234/v1。LM Studio 常见问题是上下文长度默认过小，需要在它的模型设置里手动调大。'
            BaseUrlDefault = 'http://localhost:1234/v1'
        }
        [pscustomobject]@{
            Id             = 'local-model'
            Title          = '本地模型 / 通用兼容接口'
            Category       = '本地'
            ConfigProvider = 'custom'
            ApiKeyEnv      = 'OPENAI_API_KEY'
            DefaultModel   = 'llama3.1:8b'
            NeedsBaseUrl   = $true
            ApiKeyRequired = $false
            Description    = '适用于 Ollama、vLLM、SGLang、llama.cpp、Open WebUI、LiteLLM 等 OpenAI-compatible 接口。'
            Help           = '如果不是上面几个常见本地方案，或者你的服务跑在其他端口，就选这个通用入口。'
            BaseUrlDefault = 'http://localhost:11434/v1'
        }
        [pscustomobject]@{
            Id             = 'custom'
            Title          = 'OpenAI / 自定义兼容接口'
            Category       = '自定义'
            ConfigProvider = 'custom'
            ApiKeyEnv      = 'OPENAI_API_KEY'
            DefaultModel   = 'gpt-4.1-mini'
            NeedsBaseUrl   = $true
            ApiKeyRequired = $false
            Description    = '支持 OpenAI 官方、自建兼容接口、本地推理网关或第三方 OpenAI-compatible 服务。'
            Help           = 'Base URL 一般应包含 /v1。本地接口可留空 API Key。'
            BaseUrlDefault = 'https://api.openai.com/v1'
        }
    )

    foreach ($item in $catalog) {
        if (-not $item.PSObject.Properties['AuthType']) {
            $item | Add-Member -NotePropertyName AuthType -NotePropertyValue 'api_key'
        }
        if (-not $item.PSObject.Properties['ApiKeyEnv']) {
            $item | Add-Member -NotePropertyName ApiKeyEnv -NotePropertyValue ''
        }
    }

    return $catalog
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

function Set-EnvAssignmentValue {
    param(
        [string]$Text,
        [string]$Name,
        [string]$Value
    )

    $lines = New-Object System.Collections.Generic.List[string]
    if ($Text) {
        foreach ($line in ($Text -split "`r?`n")) {
            $lines.Add($line) | Out-Null
        }
    }

    $pattern = '^\s*' + [regex]::Escape($Name) + '\s*='
    $foundIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) {
            $foundIndex = $i
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($foundIndex -ge 0) {
            $lines.RemoveAt($foundIndex)
        }
    } else {
        $entry = "$Name=$Value"
        if ($foundIndex -ge 0) {
            $lines[$foundIndex] = $entry
        } else {
            if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ne '') {
                $lines.Add('') | Out-Null
            }
            $lines.Add($entry) | Out-Null
        }
    }

    return (($lines.ToArray()) -join [Environment]::NewLine).Trim() + [Environment]::NewLine
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

function Set-YamlTopLevelBlock {
    param(
        [string]$Text,
        [string]$BlockName,
        [string[]]$BlockLines
    )

    $existing = @()
    if ($Text) {
        $existing = @($Text -split "`r?`n")
    }

    $start = -1
    $end = -1
    for ($i = 0; $i -lt $existing.Count; $i++) {
        if ($existing[$i] -match ('^' + [regex]::Escape($BlockName) + '\s*:\s*$')) {
            $start = $i
            $end = $i + 1
            while ($end -lt $existing.Count) {
                $line = $existing[$end]
                if ($line -match '^\S' -and $line -notmatch '^\s') {
                    break
                }
                $end++
            }
            break
        }
    }

    $result = New-Object System.Collections.Generic.List[string]
    if ($start -ge 0) {
        for ($i = 0; $i -lt $start; $i++) { $result.Add($existing[$i]) | Out-Null }
        foreach ($line in $BlockLines) { $result.Add($line) | Out-Null }
        if ($end -lt $existing.Count -and $result.Count -gt 0 -and $result[$result.Count - 1] -ne '') {
            $result.Add('') | Out-Null
        }
        for ($i = $end; $i -lt $existing.Count; $i++) { $result.Add($existing[$i]) | Out-Null }
    } else {
        foreach ($line in $existing) { $result.Add($line) | Out-Null }
        if ($result.Count -gt 0 -and $result[$result.Count - 1] -ne '') {
            $result.Add('') | Out-Null
        }
        foreach ($line in $BlockLines) { $result.Add($line) | Out-Null }
    }

    return (($result.ToArray()) -join [Environment]::NewLine).Trim() + [Environment]::NewLine
}

function Get-HermesModelSnapshot {
    param([string]$HermesHome)

    $configPath = Join-Path $HermesHome 'config.yaml'
    $envPath = Join-Path $HermesHome '.env'
    $configText = if (Test-Path $configPath) { Get-Content -Path $configPath -Raw -Encoding UTF8 } else { '' }
    $envText = if (Test-Path $envPath) { Get-Content -Path $envPath -Raw -Encoding UTF8 } else { '' }

    $provider = $null
    $model = $null
    $baseUrl = $null
    $apiKey = $null
    $modelBlock = Get-YamlTopLevelBlockText -Text $configText -BlockName 'model'
    if ($modelBlock) {
        $provider = Get-YamlBlockFieldValue -BlockText $modelBlock -FieldName 'provider'
        $model = Get-YamlBlockFieldValue -BlockText $modelBlock -FieldName 'default'
        $baseUrl = Get-YamlBlockFieldValue -BlockText $modelBlock -FieldName 'base_url'
        $apiKey = Get-YamlBlockFieldValue -BlockText $modelBlock -FieldName 'api_key'
    }

    # Bug 3: fallback to .env OPENAI_API_KEY only for custom provider
    if (-not $apiKey -and $provider -eq 'custom') {
        $apiKey = Get-EnvAssignmentValue -Text $envText -Name 'OPENAI_API_KEY'
    }

    [pscustomobject]@{
        Provider   = $provider
        Model      = $model
        BaseUrl    = $baseUrl
        ApiKey     = $apiKey
        ConfigText = $configText
        EnvText    = $envText
    }
}

function Test-ModelDialogInput {
    param(
        $Provider,
        [string]$ModelName,
        [string]$ApiKey,
        [string]$BaseUrl
    )

    $errors = New-Object System.Collections.Generic.List[string]
    if (-not $Provider) {
        $errors.Add('请先选择模型平台。') | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        $errors.Add('模型名不能为空。') | Out-Null
    }
    if ($Provider -and $Provider.ApiKeyRequired -and [string]::IsNullOrWhiteSpace($ApiKey)) {
        $errors.Add('API Key 不能为空。') | Out-Null
    }
    if ($Provider -and $Provider.NeedsBaseUrl) {
        if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
            $errors.Add('Base URL 不能为空。') | Out-Null
        } elseif ($BaseUrl -notmatch '^https?://') {
            $errors.Add('Base URL 需要以 http:// 或 https:// 开头。') | Out-Null
        }
    }

    [pscustomobject]@{
        Valid   = ($errors.Count -eq 0)
        Message = if ($errors.Count -eq 0) { '字段检查通过，可以保存配置。' } else { ($errors -join ' ') }
    }
}

function Save-HermesModelDialogConfig {
    param(
        [string]$InstallDir,
        [string]$HermesHome,
        $Provider,
        [string]$ModelName,
        [string]$ApiKey,
        [string]$BaseUrl
    )

    Ensure-HermesConfigScaffold -InstallDir $InstallDir -HermesHome $HermesHome
    $snapshot = Get-HermesModelSnapshot -HermesHome $HermesHome

    $blockLines = New-Object System.Collections.Generic.List[string]
    $blockLines.Add('model:') | Out-Null
    $blockLines.Add(('  provider: {0}' -f $Provider.ConfigProvider)) | Out-Null
    $blockLines.Add(('  default: {0}' -f $ModelName.Trim())) | Out-Null
    if ($Provider.NeedsBaseUrl -and -not [string]::IsNullOrWhiteSpace($BaseUrl)) {
        $blockLines.Add(('  base_url: {0}' -f $BaseUrl.Trim())) | Out-Null
    }
    # Bug 1: custom provider with non-empty api_key -> write api_key into config.yaml
    if ($Provider.ConfigProvider -eq 'custom' -and -not [string]::IsNullOrWhiteSpace($ApiKey)) {
        $blockLines.Add(('  api_key: {0}' -f $ApiKey.Trim())) | Out-Null
    }

    $newConfigText = Set-YamlTopLevelBlock -Text $snapshot.ConfigText -BlockName 'model' -BlockLines $blockLines.ToArray()
    [System.IO.File]::WriteAllText((Join-Path $HermesHome 'config.yaml'), $newConfigText, [System.Text.Encoding]::UTF8)

    if ($Provider.ApiKeyEnv) {
        $newEnvText = Set-EnvAssignmentValue -Text $snapshot.EnvText -Name $Provider.ApiKeyEnv -Value ($ApiKey.Trim())
        [System.IO.File]::WriteAllText((Join-Path $HermesHome '.env'), $newEnvText, [System.Text.Encoding]::UTF8)
    }

    return [pscustomobject]@{
        Provider = $Provider.Title
        Model    = $ModelName.Trim()
    }
}

function Save-HermesProviderConfigOnly {
    param(
        [string]$InstallDir,
        [string]$HermesHome,
        $Provider,
        [string]$ModelName,
        [string]$BaseUrl
    )

    Ensure-HermesConfigScaffold -InstallDir $InstallDir -HermesHome $HermesHome
    $snapshot = Get-HermesModelSnapshot -HermesHome $HermesHome

    $blockLines = New-Object System.Collections.Generic.List[string]
    $blockLines.Add('model:') | Out-Null
    $blockLines.Add(('  provider: {0}' -f $Provider.ConfigProvider)) | Out-Null
    $blockLines.Add(('  default: {0}' -f $ModelName.Trim())) | Out-Null
    if ($Provider.NeedsBaseUrl -and -not [string]::IsNullOrWhiteSpace($BaseUrl)) {
        $blockLines.Add(('  base_url: {0}' -f $BaseUrl.Trim())) | Out-Null
    }
    # Preserve existing api_key when only switching provider (don't lose user's key)
    if ($Provider.ConfigProvider -eq 'custom' -and $snapshot.ApiKey) {
        $blockLines.Add(('  api_key: {0}' -f $snapshot.ApiKey)) | Out-Null
    }

    $newConfigText = Set-YamlTopLevelBlock -Text $snapshot.ConfigText -BlockName 'model' -BlockLines $blockLines.ToArray()
    [System.IO.File]::WriteAllText((Join-Path $HermesHome 'config.yaml'), $newConfigText, [System.Text.Encoding]::UTF8)

    return [pscustomobject]@{
        Provider = $Provider.Title
        Model    = $ModelName.Trim()
    }
}

function Test-ModelProviderConnectivity {
    param(
        $Provider,
        [string]$ModelName,
        [string]$ApiKey,
        [string]$BaseUrl
    )

    # Determine endpoint
    $endpoint = ''
    if ($Provider.NeedsBaseUrl -and -not [string]::IsNullOrWhiteSpace($BaseUrl)) {
        $endpoint = $BaseUrl.TrimEnd('/')
    } elseif ($Provider.BaseUrlDefault) {
        $endpoint = $Provider.BaseUrlDefault.TrimEnd('/')
    }
    if (-not $endpoint) {
        return [pscustomobject]@{ Success = $true; ErrorType = 'none'; Message = ''; Hint = ''; Detail = 'no endpoint to validate' }
    }

    $url = "$endpoint/chat/completions"
    $timeout = if ($endpoint -match 'localhost|127\.0\.0\.1|0\.0\.0\.0') { 3 } else { 5 }

    $headers = @{ 'Content-Type' = 'application/json' }
    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
        $headers['Authorization'] = "Bearer $($ApiKey.Trim())"
    }

    $body = @{
        model      = $ModelName.Trim()
        messages   = @(@{ role = 'user'; content = 'hi' })
        max_tokens = 1
    } | ConvertTo-Json -Depth 3

    try {
        $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $body -TimeoutSec $timeout
        if ($response.choices) {
            return [pscustomobject]@{ Success = $true; ErrorType = 'none'; Message = ''; Hint = ''; Detail = '' }
        }
        return [pscustomobject]@{ Success = $true; ErrorType = 'none'; Message = ''; Hint = ''; Detail = 'response ok but no choices' }
    } catch {
        $ex = $_.Exception
        $statusCode = 0
        $responseBody = ''
        if ($ex.PSObject.Properties['Response'] -and $ex.Response) {
            try { $statusCode = [int]$ex.Response.StatusCode } catch { }
            try {
                $stream = $ex.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $responseBody = $reader.ReadToEnd()
                $reader.Close()
            } catch { }
        }

        $shortEndpoint = if ($endpoint.Length -gt 50) { $endpoint.Substring(0, 50) + '...' } else { $endpoint }

        if ($statusCode -eq 401) {
            return [pscustomobject]@{ Success = $false; ErrorType = 'auth'; Message = 'API Key 无效或已过期。'; Hint = '请检查 API Key 是否正确，或到平台官网重新生成。'; Detail = $responseBody }
        }
        if ($statusCode -eq 403) {
            return [pscustomobject]@{ Success = $false; ErrorType = 'auth'; Message = 'API Key 没有权限访问该模型。'; Hint = '请确认账号权限或余额是否充足。'; Detail = $responseBody }
        }
        if ($statusCode -eq 404) {
            return [pscustomobject]@{ Success = $false; ErrorType = 'not_found'; Message = "模型名 `"$($ModelName.Trim())`" 不存在。"; Hint = '请确认模型名拼写正确，或点"检查填写"查看可用列表。'; Detail = $responseBody }
        }
        if ($statusCode -ge 400 -and $statusCode -lt 500) {
            $brief = if ($responseBody.Length -gt 120) { $responseBody.Substring(0, 120) + '...' } else { $responseBody }
            return [pscustomobject]@{ Success = $false; ErrorType = 'unknown'; Message = "校验失败（HTTP $statusCode）：$brief"; Hint = ''; Detail = $responseBody }
        }
        if ($statusCode -ge 500) {
            return [pscustomobject]@{ Success = $false; ErrorType = 'unknown'; Message = "服务端错误（HTTP $statusCode）。"; Hint = '平台服务可能暂时不可用，请稍后重试。'; Detail = $responseBody }
        }

        $msg = [string]$ex.Message
        # Use WebExceptionStatus for reliable detection (error messages are localized on non-English systems)
        $webStatus = if ($ex -is [System.Net.WebException]) { [string]$ex.Status } else { '' }
        if ($webStatus -eq 'Timeout') {
            $timeoutHint = if ($endpoint -match 'localhost|127\.0\.0\.1|0\.0\.0\.0') { '请确认本地模型服务已启动。' } else { '请检查网络连接是否正常。' }
            return [pscustomobject]@{ Success = $false; ErrorType = 'timeout'; Message = "连接 $shortEndpoint 超时。"; Hint = $timeoutHint; Detail = $msg }
        }
        if ($webStatus -eq 'ConnectFailure') {
            return [pscustomobject]@{ Success = $false; ErrorType = 'connection'; Message = "无法连接到 $shortEndpoint。"; Hint = '请检查 Base URL 是否正确，或确认网络可以访问该地址。'; Detail = $msg }
        }
        if ($webStatus -eq 'NameResolutionFailure') {
            return [pscustomobject]@{ Success = $false; ErrorType = 'connection'; Message = "无法连接到 $shortEndpoint。"; Hint = '请检查 Base URL 中的域名是否正确。'; Detail = $msg }
        }

        $brief = if ($msg.Length -gt 120) { $msg.Substring(0, 120) + '...' } else { $msg }
        return [pscustomobject]@{ Success = $false; ErrorType = 'unknown'; Message = "校验失败：$brief"; Hint = ''; Detail = $msg }
    }
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

function Get-HermesProviderModelCatalog {
    param(
        [string]$InstallDir,
        [string]$HermesHome,
        [string]$ProviderId,
        [string]$CopilotToken = '',
        [string]$BaseUrl = ''
    )

    try {
        return Invoke-HermesPythonJson -InstallDir $InstallDir -HermesHome $HermesHome -Payload @{
            ProviderId = $ProviderId
            CopilotToken = $CopilotToken
            BaseUrl = $BaseUrl
        } -PythonBody @"
from hermes_cli.models import provider_model_ids, fetch_github_model_catalog, fetch_api_models

provider_id = str(payload.get('ProviderId') or '').strip()
copilot_token = str(payload.get('CopilotToken') or '').strip()
base_url = str(payload.get('BaseUrl') or '').strip()
models = []
source = 'fallback'
resolved_base_url = base_url
detected_provider = provider_id

if provider_id == 'copilot':
    catalog = None
    if copilot_token:
        catalog = fetch_github_model_catalog(api_key=copilot_token)
    if not catalog:
        try:
            from hermes_cli.copilot_auth import resolve_copilot_token
            resolved_token, _ = resolve_copilot_token()
            if resolved_token:
                catalog = fetch_github_model_catalog(api_key=resolved_token)
        except Exception:
            catalog = None
    if catalog:
        models = [str(item.get('id') or '').strip() for item in catalog if str(item.get('id') or '').strip()]
        source = 'live'
    else:
        models = provider_model_ids('copilot')
elif provider_id == 'openai-codex':
    from hermes_cli.auth import resolve_codex_runtime_credentials
    from hermes_cli.codex_models import get_codex_model_ids
    creds = resolve_codex_runtime_credentials(refresh_if_expiring=True)
    access_token = str(creds.get('api_key') or '').strip()
    models = get_codex_model_ids(access_token or None)
    source = 'live' if access_token else 'fallback'
elif provider_id == 'nous':
    models = provider_model_ids('nous')
    source = 'live' if models else 'fallback'
elif provider_id in ('local-ollama', 'local-vllm', 'local-sglang', 'local-lmstudio', 'local-model', 'custom'):
    candidates = []
    if base_url:
        candidates.append((provider_id, base_url))
    elif provider_id == 'local-ollama':
        candidates.append(('local-ollama', 'http://localhost:11434/v1'))
    elif provider_id == 'local-vllm':
        candidates.append(('local-vllm', 'http://localhost:8000/v1'))
    elif provider_id == 'local-sglang':
        candidates.append(('local-sglang', 'http://localhost:30000/v1'))
    elif provider_id == 'local-lmstudio':
        candidates.append(('local-lmstudio', 'http://localhost:1234/v1'))
    else:
        candidates.extend([
            ('local-ollama', 'http://localhost:11434/v1'),
            ('local-vllm', 'http://localhost:8000/v1'),
            ('local-sglang', 'http://localhost:30000/v1'),
            ('local-lmstudio', 'http://localhost:1234/v1'),
        ])

    for candidate_provider, candidate_url in candidates:
        live = fetch_api_models(None, candidate_url, timeout=3.0)
        if live:
            models = live
            source = 'local_live'
            resolved_base_url = candidate_url
            detected_provider = candidate_provider
            break

    if not models and provider_id not in ('custom', 'local-model'):
        models = provider_model_ids('custom')
else:
    models = provider_model_ids(provider_id)

ordered = []
seen = set()
for item in models or []:
    mid = str(item or '').strip()
    if not mid or mid in seen:
        continue
    seen.add(mid)
    ordered.append(mid)

print(json.dumps({
    'provider': provider_id,
    'detected_provider': detected_provider,
    'source': source,
    'resolved_base_url': resolved_base_url,
    'models': ordered,
}, ensure_ascii=False))
"@
    } catch {
        return [pscustomobject]@{
            provider = $ProviderId
            source = 'error'
            error = $_.Exception.Message
            models = @()
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

function Normalize-FriendlyMessagingDefaults {
    param([string]$HermesHome)

    $envPath = Join-Path $HermesHome '.env'
    if (-not (Test-Path $envPath)) {
        return [pscustomobject]@{ Changed = $false; Message = '未找到 .env' }
    }

    try {
        $envText = Get-Content -Path $envPath -Raw -Encoding UTF8
        $weixinAccountId = Get-EnvAssignmentValue -Text $envText -Name 'WEIXIN_ACCOUNT_ID'
        $weixinDmPolicy = (Get-EnvAssignmentValue -Text $envText -Name 'WEIXIN_DM_POLICY')
        $weixinAllowAll = (Get-EnvAssignmentValue -Text $envText -Name 'WEIXIN_ALLOW_ALL_USERS')
        $weixinAllowedUsers = (Get-EnvAssignmentValue -Text $envText -Name 'WEIXIN_ALLOWED_USERS')

        if ($weixinAccountId -and [string]::IsNullOrWhiteSpace($weixinAllowedUsers) -and ($weixinAllowAll -ne 'true')) {
            $envText = Set-EnvAssignmentValue -Text $envText -Name 'WEIXIN_DM_POLICY' -Value 'open'
            $envText = Set-EnvAssignmentValue -Text $envText -Name 'WEIXIN_ALLOW_ALL_USERS' -Value 'true'
            $envText = Set-EnvAssignmentValue -Text $envText -Name 'WEIXIN_ALLOWED_USERS' -Value ''
            [System.IO.File]::WriteAllText($envPath, $envText, [System.Text.Encoding]::UTF8)
            return [pscustomobject]@{
                Changed = $true
                Message = ("已将微信消息渠道授权方式调整为普通直聊模式（原策略：{0}）。" -f $(if ($weixinDmPolicy) { $weixinDmPolicy } else { '未设置' }))
            }
        }
    } catch {
        return [pscustomobject]@{
            Changed = $false
            Message = $_.Exception.Message
        }
    }

    [pscustomobject]@{
        Changed = $false
        Message = '当前消息渠道配置无需调整。'
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
    $weixinDmPolicy = ''
    $weixinAllowAll = $false
    $weixinHasAllowlist = $false
    $connectedPlatforms = @()
    $missingDependencyPlatforms = @()
    $inspectedViaPython = $false
    $hasFallbackChannelHints = $false

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
        if ($envText -match '(?m)^\s*WEIXIN_DM_POLICY\s*=\s*([A-Za-z0-9_-]+)\s*$') {
            $weixinDmPolicy = $matches[1].Trim().ToLowerInvariant()
        }
        $weixinAllowAll = ($envText -match '(?m)^\s*WEIXIN_ALLOW_ALL_USERS\s*=\s*true\s*$')
        $weixinHasAllowlist = ($envText -match '(?m)^\s*WEIXIN_ALLOWED_USERS\s*=\s*[^#\s]+')
        $hasAllowAll = ($envText -match '(?m)^\s*GATEWAY_ALLOW_ALL_USERS\s*=\s*true\s*$') -or $weixinAllowAll

        if (-not $inspectedViaPython) {
            $fallbackPlatforms = New-Object System.Collections.Generic.List[string]
            $platformPatterns = [ordered]@{
                telegram      = '(?m)^\s*TELEGRAM_BOT_TOKEN\s*=\s*[^#\s]+'
                discord       = '(?m)^\s*DISCORD_BOT_TOKEN\s*=\s*[^#\s]+'
                slack         = '(?m)^\s*SLACK_BOT_TOKEN\s*=\s*[^#\s]+'
                whatsapp      = '(?mi)^\s*WHATSAPP_ENABLED\s*=\s*(true|1|yes|on)\s*$'
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
            $hasFallbackChannelHints = ($connectedPlatforms.Count -gt 0)
        }
    }

    $needsDependencyInstall = ($missingDependencyPlatforms.Count -gt 0)
    $hasConfiguredChannel = (($inspectedViaPython -and ($connectedPlatforms.Count -gt 0)) -or $hasFallbackChannelHints)

    [pscustomobject]@{
        HasTelegramToken       = [bool]$hasTelegramToken
        HasTelegramDependency  = [bool]$hasTelegramDependency
        HasAllowlist           = [bool]$hasAllowlist
        HasAllowAll            = [bool]$hasAllowAll
        HasGatewayAccessPolicy = [bool]($hasAllowlist -or $hasAllowAll)
        HasConfiguredChannel   = [bool]$hasConfiguredChannel
        HasSuspectedChannelConfig = [bool]$hasFallbackChannelHints
        NeedsDependencyInstall = [bool]$needsDependencyInstall
        WeixinDmPolicy         = $weixinDmPolicy
        WeixinAllowAll         = [bool]$weixinAllowAll
        WeixinHasAllowlist     = [bool]$weixinHasAllowlist
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
                Message = '已检测到 Hermes 渠道服务正在运行。'
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
            Message = if ($script:GatewayRuntimeMessage) { $script:GatewayRuntimeMessage } else { '消息渠道刚刚开始上线，正在等待状态文件。' }
        }
    }

    if ($script:GatewayRuntimeState -eq 'Failed') {
        return [pscustomobject]@{
            State   = 'Failed'
            Pid     = $script:GatewayTerminalPid
            Alive   = $false
            Message = if ($script:GatewayRuntimeMessage) { $script:GatewayRuntimeMessage } else { '上一次消息渠道上线失败。' }
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

    [System.IO.File]::WriteAllText($tempPath, $scriptText, (New-Object System.Text.UTF8Encoding $true))
    return $tempPath
}

if ($SelfTest) {
    $defaults = Get-HermesDefaults
    $status = Test-HermesInstalled -InstallDir $defaults.InstallDir -HermesHome $defaults.HermesHome
    $resolvedHermes = Resolve-HermesCommand -InstallDir $defaults.InstallDir
    $resolvedUv = Resolve-UvCommand
    $webUiStatus = Get-HermesWebUiStatus -HermesHome $defaults.HermesHome -InstallDir $defaults.InstallDir
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
            SourceRepo     = $script:HermesWebUiSourceRepo
            VersionLabel   = $script:HermesWebUiVersionLabel
            Commit         = $script:HermesWebUiCommit
            ArchiveUrl     = $script:HermesWebUiArchiveUrl
            Installed      = [bool]$webUiStatus.InstallStatus.Installed
            WebUiDir       = $webUiStatus.Defaults.InstallDir
            StateDir       = $webUiStatus.Defaults.StateDir
            WorkspaceDir   = $webUiStatus.Defaults.WorkspaceDir
            LauncherState  = $webUiStatus.Defaults.LauncherStatePath
            RuntimeKnown   = [bool]$webUiStatus.Runtime.Exists
            RuntimeHealthy = [bool]$webUiStatus.Healthy
            Port           = $webUiStatus.Runtime.Port
            Url            = $webUiStatus.Url
            OutLog         = $webUiStatus.Runtime.OutLog
            ErrLog         = $webUiStatus.Runtime.ErrLog
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
                                <TextBlock x:Name="StatusHeadlineText" FontSize="30" FontWeight="SemiBold" Text="开始对话" TextAlignment="Center" HorizontalAlignment="Center"/>
                                <TextBlock x:Name="StatusBodyText" Margin="0,12,0,0" Foreground="#AFC3E3" TextWrapping="Wrap" TextAlignment="Center" HorizontalAlignment="Center"/>
                                <WrapPanel Margin="0,24,0,0" HorizontalAlignment="Center">
                                    <Button x:Name="PrimaryActionButton" Margin="0,0,12,12" Padding="20,12" MinWidth="140" FontWeight="SemiBold" Background="#22C55E" Foreground="#04110A" BorderBrush="#22C55E" Content="开始对话"/>
                                    <Button x:Name="StageModelButton" Margin="0,0,12,12" Padding="16,12" Background="#0F172A" Foreground="#E2E8F0" BorderBrush="#334155" Content="模型配置"/>
                                    <Button x:Name="StageGatewayButton" Margin="0,0,12,12" Padding="16,12" Background="#0F172A" Foreground="#E2E8F0" BorderBrush="#334155" Content="消息渠道"/>
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
    'RefreshButton','PrimaryActionButton','SecondaryActionButton','StageModelButton','StageGatewayButton','StageAdvancedButton',
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
    })
    [AppDomain]::CurrentDomain.add_UnhandledException({
        param($sender, $eventArgs)
        Write-CrashLog ("UnhandledException: " + $eventArgs.ExceptionObject.ToString())
    })
})

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

function Save-HermesWebUiRuntimeState {
    param(
        $WebUiDefaults,
        [Nullable[int]]$ProcessId = $null,
        [Nullable[int]]$Port = $null,
        [string]$Url = $null,
        [string]$OutLog = $null,
        [string]$ErrLog = $null
    )

    $path = $WebUiDefaults.LauncherStatePath
    $parent = Split-Path -Parent $path
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $current = Load-HermesWebUiRuntimeState -HermesHome $WebUiDefaults.HermesHome
    $payload = @{
        source_repo   = $WebUiDefaults.SourceRepo
        version_label = $WebUiDefaults.VersionLabel
        commit        = $WebUiDefaults.Commit
        webui_dir     = $WebUiDefaults.InstallDir
        state_dir     = $WebUiDefaults.StateDir
        workspace     = $WebUiDefaults.WorkspaceDir
        pid           = if ($PSBoundParameters.ContainsKey('ProcessId')) { if ($null -ne $ProcessId) { [int]$ProcessId } else { $null } } else { $current.Pid }
        port          = if ($null -ne $Port) { [int]$Port } else { $current.Port }
        url           = if ($Url) { $Url } else { $current.Url }
        out_log       = if ($OutLog) { $OutLog } else { $current.OutLog }
        err_log       = if ($ErrLog) { $ErrLog } else { $current.ErrLog }
        installed_at  = if ($current.InstalledAt) { $current.InstalledAt } else { (Get-Date).ToString('s') }
        started_at    = if ($PSBoundParameters.ContainsKey('ProcessId') -or ($Url -and -not $current.StartedAt)) { (Get-Date).ToString('s') } else { $current.StartedAt }
        updated_at    = (Get-Date).ToString('s')
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($path, $payload, (New-Object System.Text.UTF8Encoding $false))
}

function Wait-HermesWebUiHealth {
    param(
        [int]$Port,
        [int]$TimeoutSec = 25
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $health = Test-HermesWebUiHealth -Port $Port -TimeoutSec 2
        if ($health.Healthy) { return $health }
        Start-Sleep -Milliseconds 600
    } while ((Get-Date) -lt $deadline)

    return $health
}

function Resolve-HermesWebUiPort {
    param($WebUiDefaults)

    $state = Load-HermesWebUiRuntimeState -HermesHome $WebUiDefaults.HermesHome
    if ($state.Port) {
        $existingHealth = Test-HermesWebUiHealth -Port $state.Port
        if ($existingHealth.Healthy) {
            return [pscustomobject]@{ Port = [int]$state.Port; Reuse = $true; Health = $existingHealth }
        }
    }

    for ($port = $WebUiDefaults.PortStart; $port -le $WebUiDefaults.PortEnd; $port++) {
        $health = Test-HermesWebUiHealth -Port $port
        if ($health.Healthy) {
            return [pscustomobject]@{ Port = $port; Reuse = $true; Health = $health }
        }
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $async = $client.BeginConnect($WebUiDefaults.Host, $port, $null, $null)
            $connected = $async.AsyncWaitHandle.WaitOne(250, $false)
            $client.Close()
            if ($connected) { continue }
        } catch { }
        return [pscustomobject]@{ Port = $port; Reuse = $false; Health = $health }
    }

    throw "没有可用的 WebUI 本地端口（$($WebUiDefaults.PortStart)-$($WebUiDefaults.PortEnd)）。"
}

function Start-HermesWebUiRuntime {
    param(
        $WebUiDefaults,
        [int]$Port
    )

    if (-not (Test-Path $WebUiDefaults.PythonExe)) {
        throw "未找到 Hermes Python：$($WebUiDefaults.PythonExe)"
    }
    $serverPath = Join-Path $WebUiDefaults.InstallDir 'server.py'
    if (-not (Test-Path $serverPath)) {
        throw "未找到 WebUI server.py：$serverPath"
    }
    foreach ($dir in @($WebUiDefaults.StateDir, $WebUiDefaults.WorkspaceDir, $WebUiDefaults.LogsDir)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outLog = Join-Path $WebUiDefaults.LogsDir "$timestamp-webui.out.log"
    $errLog = Join-Path $WebUiDefaults.LogsDir "$timestamp-webui.err.log"

    $envBlock = @{
        HERMES_HOME                    = $WebUiDefaults.HermesHome
        HERMES_CONFIG_PATH             = $WebUiDefaults.ConfigPath
        HERMES_WEBUI_AGENT_DIR         = $WebUiDefaults.AgentDir
        HERMES_WEBUI_STATE_DIR         = $WebUiDefaults.StateDir
        HERMES_WEBUI_DEFAULT_WORKSPACE = $WebUiDefaults.WorkspaceDir
        HERMES_WEBUI_HOST              = $WebUiDefaults.Host
        HERMES_WEBUI_PORT              = [string]$Port
        HERMES_WEBUI_BOT_NAME          = 'Hermes'
        PYTHONIOENCODING               = 'utf-8'
        PYTHONUTF8                     = '1'
    }

    $oldEnv = @{}
    foreach ($key in $envBlock.Keys) {
        $oldEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $envBlock[$key], 'Process')
    }
    try {
        $process = Start-Process -FilePath $WebUiDefaults.PythonExe -ArgumentList @($serverPath) -WorkingDirectory $WebUiDefaults.InstallDir -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru -WindowStyle Hidden
    } finally {
        foreach ($key in $oldEnv.Keys) {
            [Environment]::SetEnvironmentVariable($key, $oldEnv[$key], 'Process')
        }
    }

    Save-HermesWebUiRuntimeState -WebUiDefaults $WebUiDefaults -ProcessId $process.Id -Port $Port -Url "http://$($WebUiDefaults.Host)`:$Port" -OutLog $outLog -ErrLog $errLog
    return [pscustomobject]@{
        Process = $process
        Pid     = $process.Id
        Port    = $Port
        Url     = "http://$($WebUiDefaults.Host)`:$Port"
        OutLog  = $outLog
        ErrLog  = $errLog
    }
}

function Set-HermesWebUiDefaults {
    param(
        [string]$Url,
        $WebUiDefaults
    )

    $body = @{
        language          = 'zh'
        default_workspace = $WebUiDefaults.WorkspaceDir
        theme             = 'dark'
        send_key          = 'enter'
        check_for_updates = $false
        show_cli_sessions = $false
        show_token_usage  = $false
        bot_name          = 'Hermes'
    } | ConvertTo-Json -Compress

    Invoke-RestMethod -Uri "$Url/api/settings" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 10 | Out-Null
}

function Stop-HermesWebUiRuntime {
    param([string]$HermesHome)

    $state = Load-HermesWebUiRuntimeState -HermesHome $HermesHome
    if ($state.Pid) {
        $process = Get-Process -Id $state.Pid -ErrorAction SilentlyContinue
        if ($process) {
            Stop-Process -Id $state.Pid -Force
            return $true
        }
    }
    return $false
}

function Ensure-HermesWebUiReady {
    param(
        [string]$HermesHome,
        [string]$InstallDir,
        [bool]$ForceInstall = $false,
        [bool]$Restart = $false
    )

    $webUiDefaults = Get-HermesWebUiDefaults -HermesHome $HermesHome -InstallDir $InstallDir
    if ($Restart) { Stop-HermesWebUiRuntime -HermesHome $HermesHome | Out-Null }

    $installResult = Install-HermesWebUi -WebUiDefaults $webUiDefaults -Force:$ForceInstall
    if (-not $installResult.Installed) {
        throw $installResult.Message
    }

    $dependency = Ensure-HermesWebUiPythonDependency -PythonExe $webUiDefaults.PythonExe -UvExe (Resolve-UvCommand)
    if (-not $dependency.Ready) {
        throw "WebUI Python 依赖未就绪：$($dependency.Message)"
    }

    $portChoice = Resolve-HermesWebUiPort -WebUiDefaults $webUiDefaults
    if ($portChoice.Reuse) {
        Set-HermesWebUiDefaults -Url $portChoice.Health.Url -WebUiDefaults $webUiDefaults
        Save-HermesWebUiRuntimeState -WebUiDefaults $webUiDefaults -ProcessId $null -Port $portChoice.Port -Url $portChoice.Health.Url
        return [pscustomobject]@{
            Ready   = $true
            Reused  = $true
            Url     = $portChoice.Health.Url
            Message = '已复用正在运行的 WebUI。'
            Details = $portChoice.Health
        }
    }

    $runtime = Start-HermesWebUiRuntime -WebUiDefaults $webUiDefaults -Port $portChoice.Port
    $health = Wait-HermesWebUiHealth -Port $runtime.Port -TimeoutSec 25
    if (-not $health.Healthy) {
        throw "WebUI 启动后没有通过健康检查：$($health.Message)。日志：$($runtime.OutLog) / $($runtime.ErrLog)"
    }
    Set-HermesWebUiDefaults -Url $health.Url -WebUiDefaults $webUiDefaults

    [pscustomobject]@{
        Ready   = $true
        Reused  = $false
        Url     = $health.Url
        Message = 'WebUI 已启动。'
        Details = $runtime
    }
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

function Show-ModelConfigDialog {
    param(
        [string]$InstallDir,
        [string]$HermesHome,
        [bool]$CanLaunchAfterSave
    )

    $providers = @(Get-ModelProviderCatalog)
    $snapshot = Get-HermesModelSnapshot -HermesHome $HermesHome

    function Get-InitialModelProvider {
        param(
            $Providers,
            $Snapshot
        )

        if (-not $Snapshot -or (-not $Snapshot.Provider -and -not $Snapshot.BaseUrl)) {
            return ($Providers | Where-Object { $_.Id -eq 'deepseek' } | Select-Object -First 1)
        }

        if ($Snapshot.Provider -eq 'custom') {
            $baseUrl = [string]$Snapshot.BaseUrl
            if ($baseUrl -match '^https?://api\.openai\.com(/v1)?/?$') {
                return ($Providers | Where-Object { $_.Id -eq 'openai' } | Select-Object -First 1)
            }
            if ($baseUrl -match '^https?://(localhost|127\.0\.0\.1|0\.0\.0\.0):11434(/v1)?/?$') {
                return ($Providers | Where-Object { $_.Id -eq 'local-ollama' } | Select-Object -First 1)
            }
            if ($baseUrl -match '^https?://(localhost|127\.0\.0\.1|0\.0\.0\.0):8000(/v1)?/?$') {
                return ($Providers | Where-Object { $_.Id -eq 'local-vllm' } | Select-Object -First 1)
            }
            if ($baseUrl -match '^https?://(localhost|127\.0\.0\.1|0\.0\.0\.0):30000(/v1)?/?$') {
                return ($Providers | Where-Object { $_.Id -eq 'local-sglang' } | Select-Object -First 1)
            }
            if ($baseUrl -match '^https?://(localhost|127\.0\.0\.1|0\.0\.0\.0):1234(/v1)?/?$') {
                return ($Providers | Where-Object { $_.Id -eq 'local-lmstudio' } | Select-Object -First 1)
            }
            if ($baseUrl -match '^https?://(localhost|127\.0\.0\.1|0\.0\.0\.0)') {
                return ($Providers | Where-Object { $_.Id -eq 'local-model' } | Select-Object -First 1)
            }
            return ($Providers | Where-Object { $_.Id -eq 'custom' } | Select-Object -First 1)
        }

        if ($Snapshot.Provider -eq 'anthropic') {
            $anthropicKey = Get-EnvAssignmentValue -Text $Snapshot.EnvText -Name 'ANTHROPIC_API_KEY'
            if ([string]::IsNullOrWhiteSpace($anthropicKey)) {
                return ($Providers | Where-Object { $_.Id -eq 'anthropic-account' } | Select-Object -First 1)
            }
        }

        return ($Providers | Where-Object { $_.ConfigProvider -eq $Snapshot.Provider } | Select-Object -First 1)
    }

    [xml]$dialogXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="模型配置"
        Height="720"
        Width="1100"
        MinHeight="660"
        MinWidth="980"
        WindowStartupLocation="CenterOwner"
        Background="#0B1220"
        Foreground="#E2E8F0">
    <Window.Resources>
        <Style TargetType="ComboBox">
            <Setter Property="Foreground" Value="#111111"/>
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="BorderBrush" Value="#334155"/>
        </Style>
        <Style TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="#111111"/>
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Padding" Value="8,6"/>
            <Style.Triggers>
                <Trigger Property="IsHighlighted" Value="True">
                    <Setter Property="Background" Value="#F3F4F6"/>
                    <Setter Property="Foreground" Value="#111111"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#E5E7EB"/>
                    <Setter Property="Foreground" Value="#111111"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="CaretBrush" Value="#FFFFFF"/>
        </Style>
    </Window.Resources>
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Border Grid.Row="0" Padding="18" CornerRadius="16" Background="#111827" BorderBrush="#22314D" BorderThickness="1">
            <StackPanel>
                <TextBlock FontSize="28" FontWeight="Bold" Text="模型配置"/>
                <TextBlock Margin="0,8,0,0" Foreground="#CBD5E1" TextWrapping="Wrap"
                           Text="通过图形界面完成 provider、模型名、Base URL 和 API Key 配置。已覆盖主流 API Key 平台，以及 Ollama、vLLM、SGLang、LM Studio 等本地模型入口。"/>
            </StackPanel>
        </Border>
        <Grid Grid.Row="1" Margin="0,16,0,16">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="250"/>
                <ColumnDefinition Width="16"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="16"/>
                <ColumnDefinition Width="280"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Padding="14" CornerRadius="16" Background="#111827" BorderBrush="#22314D" BorderThickness="1">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" FontSize="18" FontWeight="SemiBold" Text="模型平台"/>
                    <TextBlock Grid.Row="1" Margin="0,8,0,12" Foreground="#94A3B8" TextWrapping="Wrap"
                               Text="先选择你当前使用的模型平台。"/>
                    <ListBox x:Name="ProviderListBox"
                             Grid.Row="2"
                             Background="#0F172A"
                             Foreground="#E2E8F0"
                             BorderBrush="#334155"
                             ScrollViewer.VerticalScrollBarVisibility="Auto"
                             ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                             ScrollViewer.CanContentScroll="False" />
                </Grid>
            </Border>

            <Border Grid.Column="2" Padding="18" CornerRadius="16" Background="#111827" BorderBrush="#22314D" BorderThickness="1">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <TextBlock x:Name="FormTitleText" FontSize="24" FontWeight="SemiBold" Text="选择模型平台"/>
                    <TextBlock x:Name="FormSubtitleText" Grid.Row="1" Margin="0,10,0,18" Foreground="#CBD5E1" TextWrapping="Wrap"/>

                    <Grid Grid.Row="2">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="112"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock VerticalAlignment="Center" Foreground="#CBD5E1" Text="模型名"/>
                        <ComboBox x:Name="ModelNameTextBox"
                                  Grid.Column="1"
                                  Padding="6"
                                  IsEditable="True"
                                  IsTextSearchEnabled="True"
                                  Background="#FFFFFF"
                                  Foreground="#111111"
                                  BorderBrush="#334155">
                            <ComboBox.Resources>
                                <SolidColorBrush x:Key="{x:Static SystemColors.WindowBrushKey}" Color="#FFFFFF"/>
                                <SolidColorBrush x:Key="{x:Static SystemColors.WindowTextBrushKey}" Color="#111111"/>
                                <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#E5E7EB"/>
                                <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#111111"/>
                                <Style TargetType="TextBox">
                                    <Setter Property="Foreground" Value="#111111"/>
                                    <Setter Property="Background" Value="#FFFFFF"/>
                                    <Setter Property="CaretBrush" Value="#111111"/>
                                    <Setter Property="SelectionBrush" Value="#E5E7EB"/>
                                    <Setter Property="SelectionOpacity" Value="1"/>
                                </Style>
                            </ComboBox.Resources>
                        </ComboBox>
                    </Grid>

                    <Grid x:Name="ApiKeyRow" Grid.Row="3" Margin="0,12,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="112"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock VerticalAlignment="Center" Foreground="#CBD5E1" Text="API Key"/>
                        <PasswordBox x:Name="ApiKeyPasswordBox" Grid.Column="1" Padding="8" Background="#0F172A" Foreground="#F8FAFC" BorderBrush="#334155"/>
                    </Grid>

                    <Grid x:Name="BaseUrlRow" Grid.Row="4" Margin="0,12,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="112"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock VerticalAlignment="Center" Foreground="#CBD5E1" Text="Base URL"/>
                        <TextBox x:Name="BaseUrlTextBox" Grid.Column="1" Padding="8" Background="#0F172A" Foreground="#F8FAFC" BorderBrush="#334155"/>
                    </Grid>

                    <StackPanel Grid.Row="5" Margin="0,20,0,0">
                        <TextBlock Foreground="#7DD3FC" Text="填写说明"/>
                        <TextBlock x:Name="FieldHintText" Margin="0,8,0,0" Foreground="#CBD5E1" TextWrapping="Wrap"/>
                        <Border x:Name="AccountPanel" Margin="0,16,0,0" Padding="14" CornerRadius="14" Background="#0F172A" BorderBrush="#334155" BorderThickness="1" Visibility="Collapsed">
                            <StackPanel>
                                <TextBlock Foreground="#7DD3FC" Text="账号登录"/>
                                <TextBlock x:Name="AccountGuideText" Margin="0,8,0,0" Foreground="#CBD5E1" TextWrapping="Wrap"/>
                                <TextBlock x:Name="AccountSessionText" Margin="0,12,0,0" Foreground="#94A3B8" TextWrapping="Wrap" Text="尚未生成登录码。"/>
                                <WrapPanel Margin="0,14,0,0">
                                    <Button x:Name="AccountPrimaryButton" Margin="0,0,10,10" Padding="14,8" Background="#1E40AF" Foreground="#F8FAFC" BorderBrush="#2563EB" Content="开始登录"/>
                                    <Button x:Name="AccountSecondaryButton" Margin="0,0,10,10" Padding="14,8" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="检查状态"/>
                                    <Button x:Name="AccountOpenBrowserButton" Margin="0,0,10,10" Padding="14,8" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="打开浏览器"/>
                                    <Button x:Name="AccountCopyCodeButton" Margin="0,0,10,10" Padding="14,8" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="复制验证码"/>
                                </WrapPanel>
                            </StackPanel>
                        </Border>
                    </StackPanel>
                </Grid>
            </Border>

            <Border Grid.Column="4" Padding="16" CornerRadius="16" Background="#111827" BorderBrush="#22314D" BorderThickness="1">
                <StackPanel>
                    <TextBlock FontSize="18" FontWeight="SemiBold" Text="状态与引导"/>
                    <TextBlock Margin="0,12,0,0" Foreground="#7DD3FC" Text="已保存配置"/>
                    <TextBlock x:Name="CurrentSnapshotText" Margin="0,6,0,0" Foreground="#CBD5E1" TextWrapping="Wrap"/>
                    <TextBlock Margin="0,16,0,0" Foreground="#7DD3FC" Text="当前表单状态"/>
                    <TextBlock x:Name="ValidationStatusText" Margin="0,6,0,0" Foreground="#CBD5E1" TextWrapping="Wrap" Text="尚未检查填写。"/>
                    <TextBlock Margin="0,16,0,0" Foreground="#7DD3FC" Text="保存位置"/>
                    <TextBlock Margin="0,6,0,0" Foreground="#CBD5E1" TextWrapping="Wrap" Text="config.yaml 保存 provider / model / base_url；.env 保存 API Key。"/>
                    <TextBlock Margin="0,16,0,0" Foreground="#7DD3FC" Text="当前覆盖范围"/>
                    <TextBlock Margin="0,6,0,0" Foreground="#94A3B8" TextWrapping="Wrap" Text="API Key、本地兼容接口、Nous Portal、OpenAI Codex、GitHub Copilot、Claude Code 凭证导入已纳入 GUI。Qwen OAuth 与 Copilot ACP 先做图形检测与启用。"/>
                </StackPanel>
            </Border>
        </Grid>

        <DockPanel Grid.Row="2" LastChildFill="False">
            <TextBlock x:Name="DialogFooterText" DockPanel.Dock="Left" Foreground="#94A3B8" VerticalAlignment="Center" Text="请先选择平台并检查填写。"/>
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                <Button x:Name="DialogValidateButton" Margin="0,0,10,0" Padding="14,8" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="检查填写"/>
                <Button x:Name="DialogSaveButton" Margin="0,0,10,0" Padding="14,8" Background="#1E293B" Foreground="#F8FAFC" BorderBrush="#475569" Content="保存配置"/>
                <Button x:Name="DialogSaveLaunchButton" Margin="0,0,10,0" Padding="14,8" Background="#22C55E" Foreground="#04110A" BorderBrush="#22C55E" Content="保存并开始本地对话"/>
                <Button x:Name="DialogCancelButton" Padding="14,8" Background="#0F172A" Foreground="#CBD5E1" BorderBrush="#334155" Content="取消"/>
            </StackPanel>
        </DockPanel>
    </Grid>
</Window>
"@

    $dialogReader = New-Object System.Xml.XmlNodeReader $dialogXaml
    $dialog = [Windows.Markup.XamlReader]::Load($dialogReader)
    $dialog.Owner = $window

    $dialogControls = @{}
    foreach ($name in @('ProviderListBox','FormTitleText','FormSubtitleText','ModelNameTextBox','ApiKeyRow','ApiKeyPasswordBox','BaseUrlRow','BaseUrlTextBox','FieldHintText','AccountPanel','AccountGuideText','AccountSessionText','AccountPrimaryButton','AccountSecondaryButton','AccountOpenBrowserButton','AccountCopyCodeButton','CurrentSnapshotText','ValidationStatusText','DialogFooterText','DialogValidateButton','DialogSaveButton','DialogSaveLaunchButton','DialogCancelButton')) {
        $dialogControls[$name] = $dialog.FindName($name)
    }

    $dialogControls.DialogSaveLaunchButton.Visibility = if ($CanLaunchAfterSave) { 'Visible' } else { 'Collapsed' }

    $providerDisplay = @($providers | ForEach-Object {
        [pscustomobject]@{
            Title    = ('[{0}] {1}' -f $_.Category, $_.Title)
            Provider = $_
        }
    })
    $dialogControls.ProviderListBox.ItemsSource = $providerDisplay
    $dialogControls.ProviderListBox.DisplayMemberPath = 'Title'
    $dialogControls.ProviderListBox.Add_Loaded({
        $listScrollViewer = Find-VisualDescendantByType -Root $dialogControls.ProviderListBox -TargetType ([System.Windows.Controls.ScrollViewer])
        if ($listScrollViewer) {
            Attach-MouseWheelScrolling -Control $dialogControls.ProviderListBox -ScrollViewer $listScrollViewer
        }
    }.GetNewClosure())
    $dialogControls.ModelNameTextBox.Add_Loaded({
        Update-EditableComboBoxAppearance -ComboBox $dialogControls.ModelNameTextBox
        Clear-EditableComboBoxSelection -ComboBox $dialogControls.ModelNameTextBox
    }.GetNewClosure())
    $dialogControls.ModelNameTextBox.Add_GotKeyboardFocus({
        Update-EditableComboBoxAppearance -ComboBox $dialogControls.ModelNameTextBox
        Clear-EditableComboBoxSelection -ComboBox $dialogControls.ModelNameTextBox
    }.GetNewClosure())
    $dialogControls.ModelNameTextBox.Add_DropDownClosed({
        Update-EditableComboBoxAppearance -ComboBox $dialogControls.ModelNameTextBox
        Clear-EditableComboBoxSelection -ComboBox $dialogControls.ModelNameTextBox
    }.GetNewClosure())
    $dialogControls.ModelNameTextBox.Add_SelectionChanged({
        Update-EditableComboBoxAppearance -ComboBox $dialogControls.ModelNameTextBox
        Clear-EditableComboBoxSelection -ComboBox $dialogControls.ModelNameTextBox
    }.GetNewClosure())

    $dialogState = [ordered]@{
        Saved           = $false
        LaunchAfterSave = $false
        Selected        = $null
        PreviousSelected = $null
        AccountSession  = $null
        AccountStatus   = $null
        AccountAuthenticated = $false
        AccountCredential = ''
        ModelOptionsByProvider = @{}
        LastValidation       = $null
        LastValidationTime   = $null
        LastValidationKey    = ''
        ValidationFailed     = $false
    }

    $findInitial = Get-InitialModelProvider -Providers $providers -Snapshot $snapshot
    if (-not $findInitial) {
        $findInitial = $providers | Where-Object { $_.Id -eq 'deepseek' } | Select-Object -First 1
    }

    $dialogControls.CurrentSnapshotText.Text = if ($snapshot.Provider -or $snapshot.Model) {
        $detectedTitle = if ($findInitial) { $findInitial.Title } else { $snapshot.Provider }
        "已保存：$detectedTitle`nprovider：$($snapshot.Provider)`n模型：$($snapshot.Model)`nBase URL：$($snapshot.BaseUrl)"
    } else {
        '还没有保存过模型配置。'
    }

    $setDialogResult = {
        param(
            [bool]$Saved,
            [bool]$LaunchAfterSave,
            [string]$Message
        )
        $dialogState.Saved = $Saved
        $dialogState.LaunchAfterSave = $LaunchAfterSave
        $dialog.Tag = [pscustomobject]@{
            Saved           = $Saved
            LaunchAfterSave = $LaunchAfterSave
            Message         = $Message
        }
        $dialog.DialogResult = $Saved
        $dialog.Close()
    }.GetNewClosure()

    $applyModelCatalog = {
        param(
            $Provider,
            [string[]]$Models,
            [string]$Source,
            [string]$PreferredModel
        )

        if (-not $Provider) { return }

        $orderedModels = New-Object System.Collections.Generic.List[string]
        foreach ($modelId in @($Models)) {
            $trimmed = [string]$modelId
            if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
            $trimmed = $trimmed.Trim()
            if (-not $orderedModels.Contains($trimmed)) {
                $orderedModels.Add($trimmed) | Out-Null
            }
        }

        $dialogState.ModelOptionsByProvider[$Provider.Id] = [pscustomobject]@{
            Models = $orderedModels.ToArray()
            Source = $Source
        }
        $dialogControls.ModelNameTextBox.ItemsSource = $orderedModels.ToArray()
        $dialogControls.ModelNameTextBox.IsEditable = $false

        $targetModel = ''
        if (-not [string]::IsNullOrWhiteSpace($PreferredModel) -and $orderedModels.Contains($PreferredModel.Trim())) {
            $targetModel = $PreferredModel.Trim()
        } elseif ($orderedModels.Count -gt 0) {
            if ($orderedModels.Contains($Provider.DefaultModel)) {
                $targetModel = $Provider.DefaultModel
            } else {
                $targetModel = $orderedModels[0]
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($targetModel)) {
            $dialogControls.ModelNameTextBox.SelectedItem = $targetModel
            $dialogControls.ModelNameTextBox.Text = $targetModel
        }
        Update-EditableComboBoxAppearance -ComboBox $dialogControls.ModelNameTextBox
        Clear-EditableComboBoxSelection -ComboBox $dialogControls.ModelNameTextBox
    }.GetNewClosure()

    $loadModelCatalog = {
        param(
            $Provider,
            [string]$CopilotToken = '',
            [bool]$ForceRefresh = $false
        )

        if (-not $Provider) { return $false }

        $cached = $dialogState.ModelOptionsByProvider[$Provider.Id]
        if (-not $ForceRefresh -and $cached) {
            & $applyModelCatalog -Provider $Provider -Models @($cached.Models) -Source ([string]$cached.Source) -PreferredModel $dialogControls.ModelNameTextBox.Text
            return $true
        }

        $effectiveBaseUrl = ''
        if ($Provider.NeedsBaseUrl) {
            $effectiveBaseUrl = [string]$dialogControls.BaseUrlTextBox.Text
            if ([string]::IsNullOrWhiteSpace($effectiveBaseUrl)) {
                $effectiveBaseUrl = [string]$Provider.BaseUrlDefault
            }
        }

        $catalog = Get-HermesProviderModelCatalog -InstallDir $InstallDir -HermesHome $HermesHome -ProviderId $Provider.Id -CopilotToken $CopilotToken -BaseUrl $effectiveBaseUrl
        $models = @($catalog.models)
        $resolvedBaseUrl = [string](Get-ObjectPropertyValue -InputObject $catalog -Name 'resolved_base_url' -Default '')
        $detectedProvider = [string](Get-ObjectPropertyValue -InputObject $catalog -Name 'detected_provider' -Default '')
        if ($models.Count -gt 0) {
            if ($Provider.Id -in @('local-ollama','local-vllm','local-sglang','local-lmstudio','local-model','custom') -and $resolvedBaseUrl) {
                $dialogControls.BaseUrlTextBox.Text = $resolvedBaseUrl
            }
            & $applyModelCatalog -Provider $Provider -Models $models -Source ([string](Get-ObjectPropertyValue -InputObject $catalog -Name 'source' -Default 'fallback')) -PreferredModel $dialogControls.ModelNameTextBox.Text
            if ($detectedProvider -and $detectedProvider -ne $Provider.Id) {
                $dialogControls.ValidationStatusText.Text = "已自动识别本地服务：$detectedProvider，并加载了 $($models.Count) 个模型。"
            }
            return $true
        }

        $catalogError = [string](Get-ObjectPropertyValue -InputObject $catalog -Name 'error' -Default '')
        if ($catalogError) {
            $dialogControls.ValidationStatusText.Text = "模型列表获取失败：$catalogError"
        } else {
            $dialogControls.ValidationStatusText.Text = '暂时没有拿到可用模型列表，可先手动填写模型名。'
        }
        $dialogControls.ModelNameTextBox.IsEditable = $true
        return $false
    }.GetNewClosure()

    $isManualLocalCatalogProvider = {
        param($Provider)
        if (-not $Provider) { return $false }
        return ($Provider.Id -in @('local-ollama','local-vllm','local-sglang','local-lmstudio','local-model','custom'))
    }.GetNewClosure()

    $updateAccountPanel = {
        $provider = $dialogState.Selected
        if (-not $provider) { return }

        $isAccount = $provider.AuthType -ne 'api_key'
        $dialogControls.AccountPanel.Visibility = if ($isAccount) { 'Visible' } else { 'Collapsed' }
        $dialogControls.ApiKeyRow.Visibility = if ($provider.AuthType -eq 'api_key' -and $provider.ApiKeyEnv) { 'Visible' } else { 'Collapsed' }
        $dialogControls.BaseUrlRow.Visibility = if ($provider.AuthType -eq 'api_key' -and $provider.NeedsBaseUrl) { 'Visible' } else { 'Collapsed' }
        $dialogControls.DialogValidateButton.Visibility = if ($provider.AuthType -eq 'api_key') { 'Visible' } else { 'Collapsed' }
        $dialogControls.DialogSaveButton.Visibility = if ($provider.AuthType -eq 'api_key') { 'Visible' } else { 'Collapsed' }
        $dialogControls.DialogSaveLaunchButton.Visibility = if ($provider.AuthType -eq 'api_key' -and $CanLaunchAfterSave) { 'Visible' } else { 'Collapsed' }

        if (-not $isAccount) {
            if (& $isManualLocalCatalogProvider -Provider $provider) {
                $dialogControls.DialogValidateButton.Content = '检测本地模型'
                $dialogControls.DialogFooterText.Text = '本地模型不会自动扫描。先启动本地服务，再点“检测本地模型”读取 /models。'
            } else {
                $dialogControls.DialogValidateButton.Content = '检查填写'
            }
            return
        }

        $status = Get-HermesAuthStatusSnapshot -InstallDir $InstallDir -HermesHome $HermesHome -ProviderId $provider.Id
        $dialogState.AccountStatus = $status
        $statusLoggedIn = [bool](Get-ObjectPropertyValue -InputObject $status -Name 'logged_in' -Default $false)
        $loggedIn = $statusLoggedIn -or [bool]$dialogState.AccountAuthenticated
        $dialogState.AccountAuthenticated = $loggedIn
        $statusSource = [string](Get-ObjectPropertyValue -InputObject $status -Name 'source' -Default '')
        $statusAuthFile = [string](Get-ObjectPropertyValue -InputObject $status -Name 'auth_file' -Default '')
        $statusResolvedCommand = [string](Get-ObjectPropertyValue -InputObject $status -Name 'resolved_command' -Default '')
        $statusError = [string](Get-ObjectPropertyValue -InputObject $status -Name 'error' -Default '')

        $loadedLiveModels = $false
        if ($loggedIn -and $provider.Id -in @('nous','openai-codex','copilot')) {
            $loadedLiveModels = [bool](& $loadModelCatalog -Provider $provider -CopilotToken $dialogState.AccountCredential)
        }

        switch ($provider.Id) {
            'nous' {
                $dialogControls.AccountGuideText.Text = '先生成 Nous Portal 登录码，浏览器完成授权后，再回到这里点“检查登录结果”。'
                if ($dialogState.AccountSession) {
                    $dialogControls.AccountSessionText.Text = "登录地址：$($dialogState.AccountSession.verification_url)`n验证码：$($dialogState.AccountSession.user_code)"
                    $dialogControls.AccountPrimaryButton.Content = '我已完成登录，检查结果'
                    $dialogControls.AccountSecondaryButton.Content = '重新生成登录码'
                    $dialogControls.AccountSecondaryButton.Visibility = 'Visible'
                    $dialogControls.AccountOpenBrowserButton.Visibility = 'Visible'
                    $dialogControls.AccountCopyCodeButton.Visibility = 'Visible'
                } else {
                    $dialogControls.AccountSessionText.Text = if ($loggedIn) { '已检测到 Nous Portal 登录状态。会优先读取实时模型列表；确认模型后再保存。' } else { '尚未生成 Nous 登录码。' }
                    $dialogControls.AccountPrimaryButton.Content = if ($loggedIn) { '保存并启用' } else { '生成登录码' }
                    $dialogControls.AccountSecondaryButton.Visibility = 'Collapsed'
                    $dialogControls.AccountOpenBrowserButton.Visibility = 'Collapsed'
                    $dialogControls.AccountCopyCodeButton.Visibility = 'Collapsed'
                }
            }
            'openai-codex' {
                $dialogControls.AccountGuideText.Text = '先生成 OpenAI Codex 登录码，浏览器完成授权后，再回来点“检查登录结果”。'
                if ($dialogState.AccountSession) {
                    $dialogControls.AccountSessionText.Text = "登录地址：$($dialogState.AccountSession.verification_url)`n验证码：$($dialogState.AccountSession.user_code)"
                    $dialogControls.AccountPrimaryButton.Content = '我已完成登录，检查结果'
                    $dialogControls.AccountSecondaryButton.Content = '重新生成登录码'
                    $dialogControls.AccountSecondaryButton.Visibility = 'Visible'
                    $dialogControls.AccountOpenBrowserButton.Visibility = 'Visible'
                    $dialogControls.AccountCopyCodeButton.Visibility = 'Visible'
                } else {
                    $dialogControls.AccountSessionText.Text = if ($loggedIn) { '已检测到 Codex 登录状态。会优先读取可用模型列表；确认模型后再保存。' } else { '尚未生成 Codex 登录码。' }
                    $dialogControls.AccountPrimaryButton.Content = if ($loggedIn) { '保存并启用' } else { '生成登录码' }
                    $dialogControls.AccountSecondaryButton.Visibility = 'Collapsed'
                    $dialogControls.AccountOpenBrowserButton.Visibility = 'Collapsed'
                    $dialogControls.AccountCopyCodeButton.Visibility = 'Collapsed'
                }
            }
            'copilot' {
                $dialogControls.AccountGuideText.Text = '可以用 GitHub 设备码登录，也可以复用 gh 的登录态。授权完成后再回来检查。'
                if ($dialogState.AccountSession) {
                    $dialogControls.AccountSessionText.Text = "登录地址：$($dialogState.AccountSession.verification_url)`n验证码：$($dialogState.AccountSession.user_code)"
                    $dialogControls.AccountPrimaryButton.Content = '我已完成登录，检查结果'
                    $dialogControls.AccountSecondaryButton.Content = '重新生成登录码'
                    $dialogControls.AccountSecondaryButton.Visibility = 'Visible'
                    $dialogControls.AccountOpenBrowserButton.Visibility = 'Visible'
                    $dialogControls.AccountCopyCodeButton.Visibility = 'Visible'
                } else {
                    $source = if ($statusSource) { "来源：$statusSource" } else { '尚未检测到 Copilot 可用令牌。' }
                    $dialogControls.AccountSessionText.Text = if ($loggedIn) { "已检测到 GitHub Copilot 登录状态。会优先读取实时模型列表。`n$source" } else { $source }
                    $dialogControls.AccountPrimaryButton.Content = if ($loggedIn) { '保存并启用' } else { '生成登录码' }
                    $dialogControls.AccountSecondaryButton.Visibility = 'Collapsed'
                    $dialogControls.AccountOpenBrowserButton.Visibility = 'Collapsed'
                    $dialogControls.AccountCopyCodeButton.Visibility = 'Collapsed'
                }
            }
            'anthropic-account' {
                $dialogControls.AccountGuideText.Text = '本入口用于复用 Claude Code 的登录状态。若本机已登录 Claude Code，可直接导入启用。'
                $dialogControls.AccountSessionText.Text = if ($loggedIn) { "已检测到 Claude 登录凭证。`n$statusAuthFile" } else { '未检测到 Claude Code 登录文件。请先登录 Claude Code，或改用 Anthropic API Key 入口。' }
                $dialogControls.AccountPrimaryButton.Content = '检测并启用'
                $dialogControls.AccountSecondaryButton.Content = '打开 Claude 凭证目录'
                $dialogControls.AccountSecondaryButton.Visibility = 'Visible'
                $dialogControls.AccountOpenBrowserButton.Visibility = 'Collapsed'
                $dialogControls.AccountCopyCodeButton.Visibility = 'Collapsed'
            }
            'qwen-oauth' {
                $dialogControls.AccountGuideText.Text = '本入口复用 Qwen CLI 的 OAuth 登录。若已登录 Qwen CLI，可直接启用。'
                $dialogControls.AccountSessionText.Text = if ($loggedIn) { "已检测到 Qwen OAuth 登录。`n$statusAuthFile" } else { '未检测到 ~/.qwen/oauth_creds.json。需要先完成 Qwen CLI 登录。' }
                $dialogControls.AccountPrimaryButton.Content = '检测并启用'
                $dialogControls.AccountSecondaryButton.Content = '打开 Qwen 文档'
                $dialogControls.AccountSecondaryButton.Visibility = 'Visible'
                $dialogControls.AccountOpenBrowserButton.Visibility = 'Collapsed'
                $dialogControls.AccountCopyCodeButton.Visibility = 'Collapsed'
            }
            'copilot-acp' {
                $dialogControls.AccountGuideText.Text = '本入口用于启用本机 Copilot CLI 的 ACP 模式。'
                $dialogControls.AccountSessionText.Text = if ($loggedIn) { "已检测到 Copilot ACP 可用。`n命令：$statusResolvedCommand" } elseif ($statusError) { $statusError } else { '未检测到可用的 Copilot CLI。' }
                $dialogControls.AccountPrimaryButton.Content = '检测并启用'
                $dialogControls.AccountSecondaryButton.Content = '打开 Copilot CLI 文档'
                $dialogControls.AccountSecondaryButton.Visibility = 'Visible'
                $dialogControls.AccountOpenBrowserButton.Visibility = 'Collapsed'
                $dialogControls.AccountCopyCodeButton.Visibility = 'Collapsed'
            }
            default {
                $dialogControls.AccountGuideText.Text = $provider.Help
                $dialogControls.AccountSessionText.Text = '当前 provider 属于账号登录型。'
                $dialogControls.AccountPrimaryButton.Content = '检测并启用'
                $dialogControls.AccountSecondaryButton.Visibility = 'Collapsed'
                $dialogControls.AccountOpenBrowserButton.Visibility = 'Collapsed'
                $dialogControls.AccountCopyCodeButton.Visibility = 'Collapsed'
            }
        }

        if ($loggedIn -and $loadedLiveModels) {
            $loadedModels = @($dialogControls.ModelNameTextBox.ItemsSource)
            $dialogControls.ValidationStatusText.Text = "已检测到可用登录状态，并加载了 $($loadedModels.Count) 个模型。"
        } elseif ($loggedIn) {
            $dialogControls.ValidationStatusText.Text = '已检测到可用登录状态。'
        } else {
            $dialogControls.ValidationStatusText.Text = '当前还没有可用登录状态。'
        }
        $dialogControls.DialogFooterText.Text = '账号登录型 provider 通过右侧登录卡片完成。'
    }.GetNewClosure()

    $refreshDialog = {
        $selectedItem = $dialogControls.ProviderListBox.SelectedItem
        if (-not $selectedItem) { return }
        $provider = $selectedItem.Provider
        $previousProvider = $dialogState.PreviousSelected
        $dialogState.Selected = $provider
        $dialogState.AccountSession = $null
        $dialogState.AccountCredential = ''
        $dialogState.AccountAuthenticated = $false
        $dialogControls.FormTitleText.Text = $provider.Title
        $dialogControls.FormSubtitleText.Text = $provider.Description
        $dialogControls.FieldHintText.Text = $provider.Help
        $dialogControls.FieldHintText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#CBD5E1')
        $cachedModels = $dialogState.ModelOptionsByProvider[$provider.Id]
        if ($cachedModels) {
            $dialogControls.ModelNameTextBox.ItemsSource = @($cachedModels.Models)
            $dialogControls.ModelNameTextBox.IsEditable = $false
        } else {
            $dialogControls.ModelNameTextBox.ItemsSource = @()
            $dialogControls.ModelNameTextBox.IsEditable = $true
        }

        $providerChanged = $null -eq $previousProvider -or $previousProvider.Id -ne $provider.Id

        if ($providerChanged -or [string]::IsNullOrWhiteSpace($dialogControls.ModelNameTextBox.Text)) {
            if ($snapshot.Provider -eq $provider.ConfigProvider -and $snapshot.Model) {
                $dialogControls.ModelNameTextBox.Text = $snapshot.Model
            } else {
                $dialogControls.ModelNameTextBox.Text = $provider.DefaultModel
            }
        }
        if ($provider.AuthType -eq 'api_key' -and $provider.NeedsBaseUrl) {
            if ($providerChanged -or [string]::IsNullOrWhiteSpace($dialogControls.BaseUrlTextBox.Text)) {
                if ($snapshot.Provider -eq $provider.ConfigProvider -and $snapshot.BaseUrl) {
                    $dialogControls.BaseUrlTextBox.Text = $snapshot.BaseUrl
                } else {
                    $dialogControls.BaseUrlTextBox.Text = $provider.BaseUrlDefault
                }
            }
        } else {
            $dialogControls.BaseUrlTextBox.Text = ''
        }
        if ($provider.AuthType -eq 'api_key' -and $provider.ApiKeyEnv) {
            if ($providerChanged -or [string]::IsNullOrWhiteSpace($dialogControls.ApiKeyPasswordBox.Password)) {
                $existingKey = $null
                # Bug 3: for custom providers, prefer snapshot.ApiKey (reads config.yaml first, falls back to .env)
                if ($provider.ConfigProvider -eq 'custom' -and $snapshot.ApiKey) {
                    $existingKey = $snapshot.ApiKey
                }
                if (-not $existingKey) {
                    $existingKey = Get-EnvAssignmentValue -Text $snapshot.EnvText -Name $provider.ApiKeyEnv
                }
                if ($existingKey) {
                    $dialogControls.ApiKeyPasswordBox.Password = $existingKey
                } else {
                    $dialogControls.ApiKeyPasswordBox.Password = ''
                }
            }
        } else {
            $dialogControls.ApiKeyPasswordBox.Password = ''
        }
        # Reset validation state and visual feedback
        $dialogState.ValidationFailed = $false
        $dialogState.LastValidationKey = ''
        $dialogControls.DialogSaveButton.Content = '保存配置'
        $dialogControls.DialogSaveButton.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#1E293B')
        $dialogControls.DialogSaveButton.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F8FAFC')
        $dialogControls.DialogSaveButton.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#475569')
        $dialogControls.ApiKeyPasswordBox.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#334155')
        $dialogControls.ModelNameTextBox.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#334155')
        $dialogControls.BaseUrlTextBox.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#334155')
        if ($CanLaunchAfterSave -and $provider.AuthType -eq 'api_key') {
            $dialogControls.DialogSaveLaunchButton.Visibility = 'Visible'
        }

        $dialogControls.ValidationStatusText.Text = '尚未检查填写。'
        if (& $isManualLocalCatalogProvider -Provider $provider) {
            $dialogControls.DialogValidateButton.Content = '检测本地模型'
            $dialogControls.DialogFooterText.Text = '先启动对应本地模型服务，再点”检测本地模型”读取模型列表。'
        } elseif ($provider.Id -eq 'anthropic') {
            $dialogControls.DialogValidateButton.Content = '检查填写'
            $dialogControls.DialogFooterText.Text = '当前 provider 暂不支持自动校验，请确保 API Key 正确。'
        } else {
            $dialogControls.DialogValidateButton.Content = '检查填写'
            $dialogControls.DialogFooterText.Text = if ($provider.AuthType -eq 'api_key') { '保存时会进行一次小额 API 调用校验（通常不到 0.01 元），确保配置可用。' } else { '账号登录型 provider 通过右侧登录卡片完成。' }
        }
        $dialogState.PreviousSelected = $provider
        & $updateAccountPanel
    }.GetNewClosure()

    $dialogControls.ProviderListBox.Add_SelectionChanged({ & $refreshDialog }.GetNewClosure())

    $runValidation = {
        if (& $isManualLocalCatalogProvider -Provider $dialogState.Selected) {
            $loaded = [bool](& $loadModelCatalog -Provider $dialogState.Selected -ForceRefresh $true)
            if ($loaded) {
                $loadedModels = @($dialogControls.ModelNameTextBox.ItemsSource)
                $dialogControls.ValidationStatusText.Text = "已读取本地模型列表，共 $($loadedModels.Count) 个模型。"
                $dialogControls.DialogFooterText.Text = '确认模型名与 Base URL 后即可直接保存。'
                return [pscustomobject]@{ Valid = $true; Message = '本地模型列表读取成功。' }
            }
            $dialogControls.DialogFooterText.Text = '未读取到模型列表。请确认本地服务已启动、端口正确，再重试。'
            return [pscustomobject]@{ Valid = $false; Message = '本地模型列表读取失败。' }
        }

        $validation = Test-ModelDialogInput -Provider $dialogState.Selected -ModelName $dialogControls.ModelNameTextBox.Text -ApiKey $dialogControls.ApiKeyPasswordBox.Password -BaseUrl $dialogControls.BaseUrlTextBox.Text
        $dialogControls.ValidationStatusText.Text = $validation.Message
        $dialogControls.DialogFooterText.Text = if ($validation.Valid) { '字段检查通过，可以直接保存。' } else { '请先修正表单中的缺项。' }
        return $validation
    }.GetNewClosure()

    $dialogControls.DialogValidateButton.Add_Click({
        [void](& $runValidation)
    }.GetNewClosure())

    $saveHandler = {
        param([bool]$LaunchAfterSave)

        $provider = $dialogState.Selected
        $modelName = $dialogControls.ModelNameTextBox.Text
        $apiKey = $dialogControls.ApiKeyPasswordBox.Password
        $baseUrl = $dialogControls.BaseUrlTextBox.Text

        # If validation previously failed and user clicks "保留错误设置保存" without changing fields → skip validation, save directly
        if ($dialogState.ValidationFailed) {
            $saved = Save-HermesModelDialogConfig -InstallDir $InstallDir -HermesHome $HermesHome -Provider $provider -ModelName $modelName -ApiKey $apiKey -BaseUrl $baseUrl
            & $setDialogResult $true $LaunchAfterSave "已通过图形界面保存模型配置（跳过校验）：$($saved.Provider) / $($saved.Model)"
            return
        }

        # Field validation
        $validation = & $runValidation
        if (-not $validation.Valid) { return }

        # Connectivity check — wrapped in try-catch because $ErrorActionPreference='Stop' and
        # any unhandled error in a WPF click handler kills the process (DispatcherUnhandledException without Handled=$true)
        $skipConnectivity = $provider.AuthType -ne 'api_key' -or $provider.Id -eq 'anthropic'
        if (-not $skipConnectivity) {
            try {
                # Check cache: 10s window, same config fingerprint
                $fingerprint = "$($provider.Id)|$modelName|$apiKey|$baseUrl"
                $now = Get-Date
                $cached = $dialogState.LastValidation
                if ($cached -and $dialogState.LastValidationKey -eq $fingerprint -and $dialogState.LastValidationTime -and ($now - $dialogState.LastValidationTime).TotalSeconds -lt 10) {
                    if (-not $cached.Success) {
                        # Cached failure — already showing error state, enter "skip" mode
                        $dialogState.ValidationFailed = $true
                        return
                    }
                    # Cached success — proceed to save
                } else {
                    # Run connectivity check (Invoke-RestMethod blocks the UI thread for up to 5s)
                    $dialogControls.ValidationStatusText.Text = '正在验证配置…'

                    $connResult = Test-ModelProviderConnectivity -Provider $provider -ModelName $modelName -ApiKey $apiKey -BaseUrl $baseUrl
                    $dialogState.LastValidation = $connResult
                    $dialogState.LastValidationTime = $now
                    $dialogState.LastValidationKey = $fingerprint

                    if (-not $connResult.Success) {
                        # Show specific error near the input fields (FieldHintText is right below them)
                        $dialogControls.FieldHintText.Text = $connResult.Message
                        $dialogControls.FieldHintText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#EF4444')
                        # Right panel status — keep in sync
                        $dialogControls.ValidationStatusText.Text = $connResult.Message
                        # Footer: specific reason + warning (no separate generic hint)
                        $dialogControls.DialogFooterText.Text = "$($connResult.Message) 保存后可能无法正常使用。"

                        # Red border on relevant input
                        $redBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#EF4444')
                        if ($connResult.ErrorType -eq 'auth') {
                            $dialogControls.ApiKeyPasswordBox.BorderBrush = $redBrush
                        } elseif ($connResult.ErrorType -eq 'not_found') {
                            $dialogControls.ModelNameTextBox.BorderBrush = $redBrush
                        } elseif ($connResult.ErrorType -in @('timeout', 'connection')) {
                            $dialogControls.BaseUrlTextBox.BorderBrush = $redBrush
                        }

                        # Change save button to warning style
                        $dialogControls.DialogSaveButton.Content = '保留错误设置保存'
                        $dialogControls.DialogSaveButton.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#92400E')
                        $dialogControls.DialogSaveButton.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FEF3C7')
                        $dialogControls.DialogSaveButton.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#B45309')

                        # Hide "save and launch" — no point launching with broken config
                        $dialogControls.DialogSaveLaunchButton.Visibility = 'Collapsed'

                        $dialogState.ValidationFailed = $true
                        return
                    }
                }
            } catch {
                # Connectivity check failed unexpectedly — degrade gracefully, skip validation and proceed to save
                Write-CrashLog ("ConnectivityCheck error (non-fatal): " + $_.Exception.ToString())
                $dialogControls.ValidationStatusText.Text = '连通性校验出现异常，已跳过。'
            }
        }

        $saved = Save-HermesModelDialogConfig -InstallDir $InstallDir -HermesHome $HermesHome -Provider $provider -ModelName $modelName -ApiKey $apiKey -BaseUrl $baseUrl
        & $setDialogResult $true $LaunchAfterSave "已通过图形界面保存模型配置：$($saved.Provider) / $($saved.Model)"
    }.GetNewClosure()

    $dialogControls.DialogSaveButton.Add_Click({ & $saveHandler $false }.GetNewClosure())
    $dialogControls.DialogSaveLaunchButton.Add_Click({ & $saveHandler $true }.GetNewClosure())

    # Reset validation-failed state when user edits any field
    # Inline logic with try-catch — avoids closure-in-closure (.GetNewClosure() nesting)
    # which causes "& expression produced invalid object" in PowerShell 5.1
    $onFieldEdited = {
        try {
            if (-not $dialogState.ValidationFailed) { return }
            $dialogState.ValidationFailed = $false
            $dialogState.LastValidationKey = ''
            $defaultBorder = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#334155')
            $dialogControls.ApiKeyPasswordBox.BorderBrush = $defaultBorder
            $dialogControls.ModelNameTextBox.BorderBrush = $defaultBorder
            $dialogControls.BaseUrlTextBox.BorderBrush = $defaultBorder
            $dialogControls.DialogSaveButton.Content = '保存配置'
            $dialogControls.DialogSaveButton.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#1E293B')
            $dialogControls.DialogSaveButton.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F8FAFC')
            $dialogControls.DialogSaveButton.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#475569')
            $p = $dialogState.Selected
            if ($CanLaunchAfterSave -and $p -and $p.AuthType -eq 'api_key') {
                $dialogControls.DialogSaveLaunchButton.Visibility = 'Visible'
            }
            $dialogControls.ValidationStatusText.Text = '尚未检查填写。'
            # Restore FieldHintText to provider help (was showing error in red)
            $dialogControls.FieldHintText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#CBD5E1')
            if ($p) { $dialogControls.FieldHintText.Text = $p.Help }
            if ($p -and $p.Id -eq 'anthropic') {
                $dialogControls.DialogFooterText.Text = '当前 provider 暂不支持自动校验，请确保 API Key 正确。'
            } else {
                $dialogControls.DialogFooterText.Text = '保存时会进行一次小额 API 调用校验（通常不到 0.01 元），确保配置可用。'
            }
        } catch { }
    }.GetNewClosure()

    $dialogControls.ModelNameTextBox.Add_DropDownClosed($onFieldEdited)
    $dialogControls.ApiKeyPasswordBox.Add_PasswordChanged($onFieldEdited)
    $dialogControls.BaseUrlTextBox.Add_TextChanged($onFieldEdited)

    $dialogControls.AccountOpenBrowserButton.Add_Click({
        if ($dialogState.AccountSession -and $dialogState.AccountSession.verification_url) {
            Open-BrowserUrlSafe -Url $dialogState.AccountSession.verification_url
        }
    }.GetNewClosure())
    $dialogControls.AccountCopyCodeButton.Add_Click({
        if ($dialogState.AccountSession -and $dialogState.AccountSession.user_code) {
            Set-ClipboardTextSafe -Text $dialogState.AccountSession.user_code
            $dialogControls.ValidationStatusText.Text = '验证码已复制到剪贴板。'
        }
    }.GetNewClosure())
    $dialogControls.AccountSecondaryButton.Add_Click({
        $provider = $dialogState.Selected
        if (-not $provider) { return }
        switch ($provider.Id) {
            'nous' {
                $dialogState.AccountSession = New-NousLoginSession -InstallDir $InstallDir -HermesHome $HermesHome
                Open-BrowserUrlSafe -Url $dialogState.AccountSession.verification_url
                $dialogControls.ValidationStatusText.Text = 'Nous 登录码已生成，请在浏览器完成授权。'
                & $updateAccountPanel
            }
            'openai-codex' {
                $dialogState.AccountSession = New-CodexLoginSession -InstallDir $InstallDir -HermesHome $HermesHome
                Open-BrowserUrlSafe -Url $dialogState.AccountSession.verification_url
                $dialogControls.ValidationStatusText.Text = 'Codex 登录码已生成，请在浏览器完成授权。'
                & $updateAccountPanel
            }
            'copilot' {
                $dialogState.AccountSession = New-CopilotLoginSession -InstallDir $InstallDir -HermesHome $HermesHome
                Open-BrowserUrlSafe -Url $dialogState.AccountSession.verification_url
                $dialogControls.ValidationStatusText.Text = 'GitHub 登录码已生成，请在浏览器完成授权。'
                & $updateAccountPanel
            }
            'anthropic-account' {
                Open-BrowserUrlSafe -Url 'https://docs.anthropic.com/en/docs/claude-code/setup'
            }
            'qwen-oauth' {
                Open-BrowserUrlSafe -Url 'https://hermes-agent.nousresearch.com/docs/reference/cli-commands/'
            }
            'copilot-acp' {
                Open-BrowserUrlSafe -Url 'https://hermes-agent.nousresearch.com/docs/reference/cli-commands/'
            }
        }
    }.GetNewClosure())
    $dialogControls.AccountPrimaryButton.Add_Click({
        $provider = $dialogState.Selected
        if (-not $provider) { return }

        switch ($provider.Id) {
            'nous' {
                if ($dialogState.AccountAuthenticated -and -not $dialogState.AccountSession) {
                    $modelName = $dialogControls.ModelNameTextBox.Text.Trim()
                    if ([string]::IsNullOrWhiteSpace($modelName)) {
                        $dialogControls.ValidationStatusText.Text = '请先从模型列表中选择一个模型，或手动填写模型名。'
                        return
                    }
                    $saved = Save-HermesProviderConfigOnly -InstallDir $InstallDir -HermesHome $HermesHome -Provider $provider -ModelName $modelName -BaseUrl ''
                    & $setDialogResult $true $false "已启用 Nous Portal，并保存模型：$($saved.Model)"
                    return
                }
                if (-not $dialogState.AccountSession) {
                    $dialogState.AccountSession = New-NousLoginSession -InstallDir $InstallDir -HermesHome $HermesHome
                    Open-BrowserUrlSafe -Url $dialogState.AccountSession.verification_url
                    $dialogControls.ValidationStatusText.Text = 'Nous 登录码已生成，请在浏览器完成授权。'
                    & $updateAccountPanel
                    return
                }
                $result = Complete-NousLoginSession -InstallDir $InstallDir -HermesHome $HermesHome -Session $dialogState.AccountSession -ModelName ''
                if ($result.status -eq 'success') {
                    $dialogState.AccountAuthenticated = $true
                    $dialogState.AccountSession = $null
                    [void](& $loadModelCatalog -Provider $provider -ForceRefresh $true)
                    & $updateAccountPanel
                    $dialogControls.ValidationStatusText.Text = 'Nous Portal 授权成功。已刷新模型列表，请选择模型后再保存。'
                    return
                }
                $dialogControls.ValidationStatusText.Text = $result.message
            }
            'openai-codex' {
                if ($dialogState.AccountAuthenticated -and -not $dialogState.AccountSession) {
                    $modelName = $dialogControls.ModelNameTextBox.Text.Trim()
                    if ([string]::IsNullOrWhiteSpace($modelName)) {
                        $dialogControls.ValidationStatusText.Text = '请先从模型列表中选择一个模型，或手动填写模型名。'
                        return
                    }
                    $saved = Save-HermesProviderConfigOnly -InstallDir $InstallDir -HermesHome $HermesHome -Provider $provider -ModelName $modelName -BaseUrl ''
                    & $setDialogResult $true $false "已启用 OpenAI Codex，并保存模型：$($saved.Model)"
                    return
                }
                if (-not $dialogState.AccountSession) {
                    $dialogState.AccountSession = New-CodexLoginSession -InstallDir $InstallDir -HermesHome $HermesHome
                    Open-BrowserUrlSafe -Url $dialogState.AccountSession.verification_url
                    $dialogControls.ValidationStatusText.Text = 'Codex 登录码已生成，请在浏览器完成授权。'
                    & $updateAccountPanel
                    return
                }
                $result = Complete-CodexLoginSession -InstallDir $InstallDir -HermesHome $HermesHome -Session $dialogState.AccountSession -ModelName ''
                if ($result.status -eq 'success') {
                    $dialogState.AccountAuthenticated = $true
                    $dialogState.AccountSession = $null
                    [void](& $loadModelCatalog -Provider $provider -ForceRefresh $true)
                    & $updateAccountPanel
                    $dialogControls.ValidationStatusText.Text = 'OpenAI Codex 授权成功。已刷新模型列表，请选择模型后再保存。'
                    return
                }
                $dialogControls.ValidationStatusText.Text = $result.message
            }
            'copilot' {
                if ($dialogState.AccountAuthenticated -and -not $dialogState.AccountSession) {
                    $modelName = $dialogControls.ModelNameTextBox.Text.Trim()
                    if ([string]::IsNullOrWhiteSpace($modelName)) {
                        $dialogControls.ValidationStatusText.Text = '请先从模型列表中选择一个模型，或手动填写模型名。'
                        return
                    }
                    if (-not [string]::IsNullOrWhiteSpace($dialogState.AccountCredential)) {
                        $saved = Save-HermesModelDialogConfig -InstallDir $InstallDir -HermesHome $HermesHome -Provider $provider -ModelName $modelName -ApiKey $dialogState.AccountCredential -BaseUrl ''
                    } else {
                        $saved = Save-HermesProviderConfigOnly -InstallDir $InstallDir -HermesHome $HermesHome -Provider $provider -ModelName $modelName -BaseUrl ''
                    }
                    & $setDialogResult $true $false "已启用 GitHub Copilot，并保存模型：$($saved.Model)"
                    return
                }
                if (-not $dialogState.AccountSession) {
                    $dialogState.AccountSession = New-CopilotLoginSession -InstallDir $InstallDir -HermesHome $HermesHome
                    Open-BrowserUrlSafe -Url $dialogState.AccountSession.verification_url
                    $dialogControls.ValidationStatusText.Text = 'GitHub 登录码已生成，请在浏览器完成授权。'
                    & $updateAccountPanel
                    return
                }
                $result = Complete-CopilotLoginSession -InstallDir $InstallDir -HermesHome $HermesHome -Session $dialogState.AccountSession
                if ($result.status -eq 'success') {
                    $dialogState.AccountAuthenticated = $true
                    $dialogState.AccountCredential = [string](Get-ObjectPropertyValue -InputObject $result -Name 'token' -Default '')
                    $dialogState.AccountSession = $null
                    [void](& $loadModelCatalog -Provider $provider -CopilotToken $dialogState.AccountCredential -ForceRefresh $true)
                    & $updateAccountPanel
                    $dialogControls.ValidationStatusText.Text = 'GitHub Copilot 授权成功。已刷新模型列表，请选择模型后再保存。'
                    return
                }
                $dialogControls.ValidationStatusText.Text = $result.message
            }
            'anthropic-account' {
                $modelName = $dialogControls.ModelNameTextBox.Text.Trim()
                if ([string]::IsNullOrWhiteSpace($modelName)) {
                    $dialogControls.ValidationStatusText.Text = '模型名不能为空。'
                    return
                }
                $status = Get-HermesAuthStatusSnapshot -InstallDir $InstallDir -HermesHome $HermesHome -ProviderId $provider.Id
                if (-not $status.logged_in) {
                    $dialogControls.ValidationStatusText.Text = '未检测到 Claude Code 登录凭证，请先登录 Claude Code。'
                    return
                }
                $saved = Save-HermesProviderConfigOnly -InstallDir $InstallDir -HermesHome $HermesHome -Provider $provider -ModelName $modelName -BaseUrl ''
                & $setDialogResult $true $false "已启用 Claude Code 登录态：$($saved.Model)"
            }
            'qwen-oauth' {
                $modelName = $dialogControls.ModelNameTextBox.Text.Trim()
                if ([string]::IsNullOrWhiteSpace($modelName)) {
                    $dialogControls.ValidationStatusText.Text = '模型名不能为空。'
                    return
                }
                $status = Get-HermesAuthStatusSnapshot -InstallDir $InstallDir -HermesHome $HermesHome -ProviderId $provider.Id
                if (-not $status.logged_in) {
                    $dialogControls.ValidationStatusText.Text = '未检测到 Qwen OAuth 登录，请先完成 Qwen CLI 登录。'
                    return
                }
                $saved = Save-HermesProviderConfigOnly -InstallDir $InstallDir -HermesHome $HermesHome -Provider $provider -ModelName $modelName -BaseUrl ''
                & $setDialogResult $true $false "已启用 Qwen OAuth：$($saved.Model)"
            }
            'copilot-acp' {
                $modelName = $dialogControls.ModelNameTextBox.Text.Trim()
                if ([string]::IsNullOrWhiteSpace($modelName)) {
                    $dialogControls.ValidationStatusText.Text = '模型名不能为空。'
                    return
                }
                $status = Get-HermesAuthStatusSnapshot -InstallDir $InstallDir -HermesHome $HermesHome -ProviderId $provider.Id
                if (-not $status.logged_in) {
                    $dialogControls.ValidationStatusText.Text = '未检测到可用的 Copilot CLI / ACP。'
                    return
                }
                $saved = Save-HermesProviderConfigOnly -InstallDir $InstallDir -HermesHome $HermesHome -Provider $provider -ModelName $modelName -BaseUrl ''
                & $setDialogResult $true $false "已启用 GitHub Copilot ACP：$($saved.Model)"
            }
        }
    }.GetNewClosure())
    $dialogControls.DialogCancelButton.Add_Click({
        $dialog.Tag = [pscustomobject]@{
            Saved           = $false
            LaunchAfterSave = $false
            Message         = '已取消模型配置。'
        }
        $dialog.DialogResult = $false
        $dialog.Close()
    }.GetNewClosure())

    foreach ($item in $providerDisplay) {
        if ($item.Provider.Id -eq $findInitial.Id) {
            $dialogControls.ProviderListBox.SelectedItem = $item
            break
        }
    }
    if (-not $dialogControls.ProviderListBox.SelectedItem -and $providerDisplay.Count -gt 0) {
        $dialogControls.ProviderListBox.SelectedIndex = 0
    }

    [void]$dialog.ShowDialog()
    if ($dialog.Tag) { return $dialog.Tag }
    return [pscustomobject]@{
        Saved           = $false
        LaunchAfterSave = $false
        Message         = '已关闭模型配置窗口。'
    }
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

function New-HiddenGatewayWrapper {
    param(
        [string]$WorkingDirectory,
        [string]$HermesHome,
        [string]$HermesCommand
    )

    $tempPath = Join-Path $env:TEMP ('hermes-gateway-hidden-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $stdoutLog = Join-Path $HermesHome 'logs\gateway-stdout.log'
    $stderrLog = Join-Path $HermesHome 'logs\gateway-stderr.log'
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
`$logsDir = Join-Path '$HermesHome' 'logs'
New-Item -ItemType Directory -Force -Path `$logsDir | Out-Null
`$stdoutLog = '$stdoutLog'
`$stderrLog = '$stderrLog'
Set-Content -Path `$stdoutLog -Value '' -Encoding UTF8
Set-Content -Path `$stderrLog -Value '' -Encoding UTF8
& '$HermesCommand' gateway 1>> `$stdoutLog 2>> `$stderrLog
exit `$LASTEXITCODE
"@
    [System.IO.File]::WriteAllText($tempPath, $wrapper, (New-Object System.Text.UTF8Encoding $true))
    return $tempPath
}

function Start-ExternalModelMonitor {
    param([System.Diagnostics.Process]$Process)

    Stop-ExternalModelTimer
    $script:ExternalModelProcess = $Process

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(2)
    $timer.Add_Tick({
        try {
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
                Add-ActionLog -Action '配置模型提供商' -Result '已检测到 provider/model 与可用凭证，模型配置完成' -Next '继续执行本地对话测试'
            } elseif ($state.ModelStatus.HasModelConfig) {
                Add-ActionLog -Action '配置模型提供商' -Result '已检测到模型配置，但还没有确认可用凭证或登录态' -Next '重新打开模型配置，补全密钥或完成账号登录'
            } elseif ($exitCode -eq 0) {
                Add-ActionLog -Action '配置模型提供商' -Result '配置终端已关闭，但还没有检测到有效模型配置' -Next '请重新运行模型配置，并确保最后保存生效'
            } else {
                Add-ActionLog -Action '配置模型提供商' -Result ("配置终端退出，退出码：{0}" -f $exitCode) -Next '查看终端报错后重试'
            }
            Refresh-Status
        } catch {
            Add-LogLine ("模型配置监视器异常：{0}" -f $_.Exception.Message)
            Stop-ExternalModelTimer
        }
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
    $script:GatewayRuntimeMessage = '已在后台启动消息渠道，启动器将在 3 秒后自动复检。'
    $wrapperScript = New-HiddenGatewayWrapper -WorkingDirectory $InstallDir -HermesHome $HermesHome -HermesCommand $HermesCommand
    $proc = Start-Process powershell.exe -WindowStyle Hidden -PassThru -WorkingDirectory $InstallDir -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapperScript)
    if ($proc) {
        $script:GatewayTerminalPid = $proc.Id
    }
    Add-ActionLog -Action '让消息渠道上线' -Result '已在后台启动消息渠道，启动器将在 3 秒后自动复检' -Next '如仍无法回复，请打开日志目录查看 gateway-stdout.log / gateway-stderr.log'
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
        try {
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
            if ($alive) {
                Refresh-Status
                return
            }

            $exitCode = 1
            try { $exitCode = $script:ExternalGatewaySetupProcess.ExitCode } catch { }

            $script:ExternalGatewaySetupProcess = $null
            Stop-ExternalGatewaySetupTimer

            $state = Get-UiState
            $platformText = if ($state.GatewayStatus.ConnectedPlatforms.Count -gt 0) { $state.GatewayStatus.ConnectedPlatforms -join '、' } else { '未识别到已配置渠道' }
            $normalized = Normalize-FriendlyMessagingDefaults -HermesHome $HermesHome
            if ($normalized.Changed) {
                Add-LogLine $normalized.Message
                $state = Get-UiState
                $platformText = if ($state.GatewayStatus.ConnectedPlatforms.Count -gt 0) { $state.GatewayStatus.ConnectedPlatforms -join '、' } else { '未识别到已配置渠道' }
            }
            if ($state.GatewayStatus.HasConfiguredChannel) {
                $nextHint = if ($state.GatewayStatus.HasGatewayAccessPolicy) {
                    '下一步可直接点击“消息渠道”，再点“让消息渠道上线”；如仍无回复，请检查终端和日志。'
                } else {
                    '已识别到渠道配置，但未检测到允许用户配置；若消息无回复，请在消息渠道里改成直接允许或补充允许用户。'
                }
                Add-ActionLog -Action '配置消息渠道' -Result ("已检测到消息渠道配置：{0}" -f $platformText) -Next $nextHint
            } elseif ($state.GatewayStatus.HasSuspectedChannelConfig) {
                Add-ActionLog -Action '配置消息渠道' -Result ("在 .env 中发现消息渠道字段：{0}" -f $platformText) -Next '启动器已按已配置处理；如仍异常，可手动刷新或重新配置一次'
            } elseif ($exitCode -eq 0) {
                Add-ActionLog -Action '配置消息渠道' -Result '配置终端已关闭，但还没有检测到有效消息渠道配置' -Next '请重新运行消息渠道配置，并确保最后保存生效'
            } else {
                Add-ActionLog -Action '配置消息渠道' -Result (“配置终端退出，退出码：{0}” -f $exitCode) -Next '查看终端报错后重试'
            }
            Refresh-Status
        } catch {
            Add-LogLine (“渠道配置监视器异常：{0}” -f $_.Exception.Message)
            Stop-ExternalGatewaySetupTimer
        }
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
        try {
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
            if ($alive) {
                Refresh-Status
                return
            }

            $exitCode = 1
            try { $exitCode = $script:ExternalMessagingProcess.ExitCode } catch { }

            $script:ExternalMessagingProcess = $null
            Stop-ExternalMessagingTimer

            $state = Get-UiState
            if ($exitCode -eq 0 -and -not $state.GatewayStatus.NeedsDependencyInstall) {
                Add-ActionLog -Action '安装消息渠道依赖' -Result '消息渠道依赖安装完成' -Next '如果你是通过”启用消息渠道”进入，启动器会继续自动启用渠道'
                $shouldAutoStart = $script:PendingGatewayStartAfterMessagingInstall -and $state.GatewayStatus.HasConfiguredChannel -and [bool]$HermesCommand
                $script:PendingGatewayStartAfterMessagingInstall = $false
                Refresh-Status
                if ($shouldAutoStart) {
                    Add-LogLine '依赖已就绪，继续启用消息渠道。'
                    Start-GatewayRuntimeLaunch -InstallDir $InstallDir -HermesHome $HermesHome -HermesCommand $HermesCommand
                    return
                }
            } elseif ($exitCode -eq 0) {
                $script:PendingGatewayStartAfterMessagingInstall = $false
                Add-ActionLog -Action '安装消息渠道依赖' -Result '安装终端已关闭，但启动器仍检测到缺少依赖' -Next '请查看安装终端是否有报错，必要时重试'
                Refresh-Status
            } else {
                $script:PendingGatewayStartAfterMessagingInstall = $false
                Add-ActionLog -Action '安装消息渠道依赖' -Result (“依赖安装终端退出，退出码：{0}” -f $exitCode) -Next '查看终端报错并修复后重试'
                Refresh-Status
            }
        } catch {
            Add-LogLine (“依赖安装监视器异常：{0}” -f $_.Exception.Message)
            Stop-ExternalMessagingTimer
        }
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

function Show-GatewayPanel {
    $script:CurrentStatus = Get-UiState
    $state = $script:CurrentStatus
    if (-not $state) { return }

    $dialogRef = New-SubPanelWindow -Title '消息渠道' -Width 760 -Height 470

    if ($script:ExternalGatewaySetupProcess) {
        Add-SubPanelSection -DialogWindow $dialogRef.Window -Container $dialogRef.ContentPanel -Title '当前状态' -Body '消息渠道配置终端已经打开。关闭终端后，首页状态会自动刷新。' -Actions @(
            [pscustomobject]@{ Label = '刷新状态'; ActionId = 'refresh'; Enabled = $true },
            [pscustomobject]@{ Label = '重新打开消息渠道配置'; ActionId = 'gateway-setup'; Enabled = [bool]$state.HermesCommand; Primary = $true }
        )
    } elseif ($script:ExternalMessagingProcess) {
        Add-SubPanelSection -DialogWindow $dialogRef.Window -Container $dialogRef.ContentPanel -Title '当前状态' -Body '正在安装消息渠道依赖。完成后会自动继续让消息渠道上线。' -Actions @(
            [pscustomobject]@{ Label = '刷新状态'; ActionId = 'refresh'; Enabled = $true }
        )
    } elseif ($state.GatewayRuntime.State -eq 'Running') {
        $runningBody = '消息渠道已经在后台运行，当前可以持续接收和回复。'
        if (-not $state.GatewayStatus.HasGatewayAccessPolicy) {
            $runningBody += ' 当前未检测到允许用户配置，外部消息可能会被拒绝。'
        }
        Add-SubPanelSection -DialogWindow $dialogRef.Window -Container $dialogRef.ContentPanel -Title '当前状态' -Body $runningBody -Actions @(
            [pscustomobject]@{ Label = '刷新状态'; ActionId = 'refresh'; Enabled = $true },
            [pscustomobject]@{ Label = '重新配置消息渠道'; ActionId = 'gateway-setup'; Enabled = [bool]$state.HermesCommand; Primary = $true },
            [pscustomobject]@{ Label = '打开日志目录'; ActionId = 'open-logs'; Enabled = (Test-Path (Join-Path $state.HermesHome 'logs')) }
        )
    } elseif ($state.GatewayStatus.HasConfiguredChannel) {
        $platformText = $state.GatewayStatus.ConnectedPlatforms -join '、'
        $body = "已检测到消息渠道配置：{0}。" -f $platformText
        if (-not $state.GatewayStatus.HasGatewayAccessPolicy) {
            $body += ' 但当前未检测到允许用户配置，若消息发出后没有回复，通常是这里还没放行。'
        }
        Add-SubPanelSection -DialogWindow $dialogRef.Window -Container $dialogRef.ContentPanel -Title '当前状态' -Body $body -Actions @(
            [pscustomobject]@{ Label = '刷新状态'; ActionId = 'refresh'; Enabled = $true },
            [pscustomobject]@{ Label = '让消息渠道上线'; ActionId = 'gateway'; Enabled = [bool]$state.HermesCommand; Primary = $true },
            [pscustomobject]@{ Label = '重新配置消息渠道'; ActionId = 'gateway-setup'; Enabled = [bool]$state.HermesCommand },
            [pscustomobject]@{ Label = '手动安装渠道依赖'; ActionId = 'install-messaging'; Enabled = [bool]$state.HermesCommand }
        )
    } elseif ($state.GatewayStatus.HasSuspectedChannelConfig) {
        $platformText = $state.GatewayStatus.ConnectedPlatforms -join '、'
        Add-SubPanelSection -DialogWindow $dialogRef.Window -Container $dialogRef.ContentPanel -Title '当前状态' -Body ("在 .env 中发现疑似消息渠道字段：{0}，但当前还没有确认 Hermes 已成功加载这些渠道。" -f $platformText) -Actions @(
            [pscustomobject]@{ Label = '刷新状态'; ActionId = 'refresh'; Enabled = $true },
            [pscustomobject]@{ Label = '重新配置消息渠道'; ActionId = 'gateway-setup'; Enabled = [bool]$state.HermesCommand; Primary = $true }
        )
    } else {
        Add-SubPanelSection -DialogWindow $dialogRef.Window -Container $dialogRef.ContentPanel -Title '当前状态' -Body '还没有检测到有效的消息渠道配置。完成配置后，可按需启用消息渠道。' -Actions @(
            [pscustomobject]@{ Label = '刷新状态'; ActionId = 'refresh'; Enabled = $true },
            [pscustomobject]@{ Label = '配置消息渠道'; ActionId = 'gateway-setup'; Enabled = [bool]$state.HermesCommand; Primary = $true }
        )
    }

    [void]$dialogRef.Window.ShowDialog()
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
    $webUiBody = if ($state.WebUiStatus.Healthy) {
        "WebUI 正在运行：$($state.WebUiStatus.Url)"
    } elseif ($state.WebUiStatus.InstallStatus.Installed) {
        "WebUI 已安装，版本：$($script:HermesWebUiVersionLabel) / $($script:HermesWebUiCommit.Substring(0, 12))。"
    } else {
        'WebUI 尚未安装。点击【打开 WebUI】或首页【开始对话】会自动安装启动器内置稳定版。'
    }
    Add-SubPanelSection -DialogWindow $dialogRef.Window -Container $dialogRef.ContentPanel -Title 'WebUI' -Body $webUiBody -Actions @(
        [pscustomobject]@{ Label = '打开 WebUI'; ActionId = 'launch-webui'; Enabled = [bool]$state.HermesCommand; Primary = $true },
        [pscustomobject]@{ Label = '重启 WebUI'; ActionId = 'restart-webui'; Enabled = [bool]$state.HermesCommand },
        [pscustomobject]@{ Label = '更新 WebUI'; ActionId = 'update-webui'; Enabled = [bool]$state.HermesCommand },
        [pscustomobject]@{ Label = '打开 WebUI 日志'; ActionId = 'open-webui-logs'; Enabled = (Test-Path $state.WebUiStatus.Defaults.LogsDir) },
        [pscustomobject]@{ Label = '打开 WebUI 目录'; ActionId = 'open-webui-dir'; Enabled = (Test-Path $state.WebUiStatus.Defaults.InstallDir) },
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
        "MessagingConfigured: $($state.GatewayStatus.HasConfiguredChannel)"
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
    $gatewayStatus = Test-HermesGatewayReadiness -InstallDir $installDir -HermesHome $hermesHome
    $gatewayRuntime = Get-GatewayRuntimeStatus -HermesHome $hermesHome
    $launcherState = Load-LauncherState -HermesHome $hermesHome
    $webUiStatus = Get-HermesWebUiStatus -HermesHome $hermesHome -InstallDir $installDir

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
        WebUiStatus     = $webUiStatus
    }
}

function Get-Recommendation {
    param($state)

    if ($script:ExternalModelProcess) {
        return [pscustomobject]@{
            Headline = '正在等待模型配置完成'
            Body     = '模型配置窗口已打开。请在图形弹窗里完成模型平台、模型名以及 API Key / 登录授权配置；关闭后启动器会自动检查结果。'
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
            Headline = '正在准备消息渠道依赖'
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
            Hint     = '安装成功后刷新状态，再继续配置模型，或按需迁移旧版 OpenClaw 配置。'
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
            Hint     = '如果你不是从旧版迁移，可以跳过，直接继续模型配置。'
            ActionId = 'openclaw-migrate'
            Label    = '迁移旧版配置'
            Stage    = 'Migration'
            Enabled  = [bool]$state.HermesCommand
        }
    }

    if (-not $state.ModelStatus.ReadyLikely) {
        $modelGap = $state.ModelStatus.Summary
        return [pscustomobject]@{
            Headline = '配置模型与登录方式'
            Body     = $modelGap
            Hint     = '点击后会打开图形化模型配置弹窗，不再要求你进入命令行。'
            ActionId = 'model'
            Label    = '打开模型配置'
            Stage    = 'Model'
            Enabled  = [bool]$state.HermesCommand
        }
    }

    if ($state.GatewayRuntime.State -eq 'Running') {
        return [pscustomobject]@{
            Headline = '消息渠道正在运行'
            Body     = '已检测到 Hermes 渠道服务进程。关闭对应终端后，消息渠道会离线。'
            Hint     = '如果只是继续使用，保持网关终端窗口打开即可。需要排错时再打开日志目录。'
            ActionId = 'refresh'
            Label    = '刷新状态'
            Stage    = 'Gateway'
            Enabled  = $true
        }
    }

    if ($state.GatewayRuntime.State -eq 'Starting') {
        return [pscustomobject]@{
            Headline = '正在让消息渠道上线'
            Body     = if ($state.GatewayRuntime.Message) { $state.GatewayRuntime.Message } else { '消息渠道刚刚启动，正在等待状态回传。' }
            Hint     = '等待几秒，启动器会自动复检是否已成功进入运行状态。'
            ActionId = 'refresh'
            Label    = '等待消息渠道上线'
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
            '点击后会自动检查依赖；若缺失则先安装，随后继续让消息渠道上线。'
        } else {
            '点击后会自动检查依赖并让消息渠道上线。当前未检测到允许用户配置，消息可能发得出去但不会收到回复。'
        }
        return [pscustomobject]@{
            Headline = '可以让消息渠道上线'
            Body     = "已检测到消息渠道配置：$platformText。"
            Hint     = $hint
            ActionId = 'gateway'
            Label    = '让消息渠道上线'
            Stage    = 'Gateway'
            Enabled  = [bool]$state.HermesCommand
        }
    }

    if ($state.GatewayStatus.HasSuspectedChannelConfig) {
        $platformText = $state.GatewayStatus.ConnectedPlatforms -join '、'
        return [pscustomobject]@{
            Headline = '重新确认消息渠道配置'
            Body     = "在 .env 中发现疑似消息渠道字段：$platformText，但当前还没有确认 Hermes 已成功加载这些渠道。"
            Hint     = '建议重新运行消息渠道配置；关闭终端后，启动器会再次检查是否真正生效。'
            ActionId = 'gateway-setup'
            Label    = '重新配置消息渠道'
            Stage    = 'Gateway'
            Enabled  = [bool]$state.HermesCommand
        }
    }

    $localChatVerified = $script:LocalChatVerified -or [bool]$state.LauncherState.LocalChatVerified
    if (-not $localChatVerified) {
        return [pscustomobject]@{
            Headline = '先验证本地对话'
            Body     = '模型与凭证看起来已经就绪，建议先在本机终端里验证 Hermes 能否正常回答。'
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
    if ($state.ModelStatus.HasApiKey) { $ok.Add('已检测到可用凭证或登录态。') } else { $warn.Add('尚未检测到可用凭证或登录态。') }
    if ($state.OpenClawSources.Count -gt 0) { $items.Add("已检测到旧版配置目录：$($state.OpenClawSources -join '; ')。可按需迁移。") }
    if ($state.GatewayRuntime.State -eq 'Running') {
        $ok.Add('消息渠道正在运行。')
    } elseif ($state.GatewayStatus.HasConfiguredChannel) {
        $items.Add("已检测到消息渠道配置：$($state.GatewayStatus.ConnectedPlatforms -join '、')。")
    } elseif ($state.GatewayStatus.HasSuspectedChannelConfig) {
        $warn.Add("在 .env 中检测到疑似消息渠道字段：$($state.GatewayStatus.ConnectedPlatforms -join '、')，但还没有确认 Hermes 已成功加载这些渠道。")
    } else {
        $items.Add('未检测到有效消息渠道配置，不影响本地聊天。')
    }

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
            Hint    = '用户安装完毕后，可以通过本地对话或已上线的消息渠道继续和 Hermes 交互。'
            Primary = $localAction
            Secondary = [pscustomobject]@{
                ActionId = 'refresh'
                Label    = '消息渠道已在线'
                Enabled  = $false
            }
        }
    }

    if ($state.GatewayStatus.HasConfiguredChannel) {
        return [pscustomobject]@{
            Active  = $true
            Title   = '开始对话'
            Hint    = '本地对话可立即使用；如果希望脱离电脑继续通过手机或消息平台对话，可先让消息渠道上线。'
            Primary = $localAction
            Secondary = [pscustomobject]@{
                ActionId = 'gateway'
                Label    = '让消息渠道上线'
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
                Add-ActionLog -Action '消息渠道复检' -Result '未检测到渠道服务稳定运行' -Next '查看终端报错，修复后重新启用消息渠道'
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
    $script:LocalChatVerified = [bool]$script:CurrentStatus.LauncherState.LocalChatVerified -or $script:LocalChatVerified
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

        if (-not $script:CurrentStatus.ModelStatus.ReadyLikely) {
            $controls.StatusHeadlineText.Text = '先完成模型配置'
            $controls.StatusBodyText.Text = '模型：未配置 · 消息渠道：未就绪 · Hermes：正常'
        } elseif ($script:CurrentStatus.GatewayRuntime.State -eq 'Running') {
            $controls.StatusHeadlineText.Text = '消息渠道已在线'
            $controls.StatusBodyText.Text = '模型：已配置 · 消息渠道：运行中 · Hermes：正常'
        } elseif ($script:CurrentStatus.GatewayStatus.HasConfiguredChannel) {
            $controls.StatusHeadlineText.Text = '本地对话已就绪'
            $controls.StatusBodyText.Text = '模型：已配置 · 消息渠道：已配置未启动 · Hermes：正常'
        } else {
            $controls.StatusHeadlineText.Text = '本地对话已就绪'
            $controls.StatusBodyText.Text = '模型：已配置 · 消息渠道：未配置 · Hermes：正常'
        }

        Set-PrimaryAction -ActionId 'launch' -Label '开始对话' -Enabled ([bool]$script:CurrentStatus.HermesCommand)
        Set-SecondaryAction -ActionId '' -Label '' -Enabled $false -Visible $false

        if (-not $script:CurrentStatus.ModelStatus.ReadyLikely) {
            $controls.RecommendationText.Text = '下一步：点击上方“模型配置”，保存模型和密钥后，再点“开始对话”。'
        } elseif ($script:CurrentStatus.GatewayRuntime.State -eq 'Running') {
            $controls.RecommendationText.Text = '你现在可以直接点“开始对话”。外部消息渠道已在后台在线；如需查看状态或停用，请点击上方“消息渠道”。'
        } elseif ($script:CurrentStatus.GatewayStatus.HasConfiguredChannel) {
            if (-not $script:CurrentStatus.GatewayStatus.HasGatewayAccessPolicy) {
                $controls.RecommendationText.Text = '下一步：点击上方“消息渠道”，先检查并补充允许用户配置，再让消息渠道上线；否则外部消息不会收到回复。'
            } else {
                $controls.RecommendationText.Text = '下一步：点击上方“消息渠道”，然后点“让消息渠道上线”。上线后会在后台持续运行，外部消息渠道才会在线。'
            }
        } else {
            $controls.RecommendationText.Text = '你现在可以直接点“开始对话”。如果还想接入微信、Telegram、Discord 等外部渠道，请点击上方“消息渠道”继续配置。'
        }
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
                $args = Build-InstallArguments -ScriptPath $tempScript -InstallDir $installDir -HermesHome $hermesHome -Branch $state.Branch -NoVenv ([bool]$controls.NoVenvCheckBox.IsChecked) -SkipSetup ([bool]$controls.SkipSetupCheckBox.IsChecked)
                $wrapperScript = New-ExternalInstallWrapperScript -InstallScriptPath $tempScript -Arguments $args
                $proc = Start-Process powershell.exe -PassThru -WorkingDirectory $env:TEMP -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapperScript)
                Start-ExternalInstallMonitor -Process $proc
                Add-ActionLog -Action '安装 / 更新 Hermes' -Result '已打开独立 PowerShell 安装终端。安装成功会自动关闭，失败会保留终端供查看报错。' -Next '安装结束后启动器会自动刷新状态'
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
        'model' {
            if (-not $hermesCommand) {
                [System.Windows.MessageBox]::Show('未找到 Hermes 命令，请先安装 Hermes。', 'Hermes 启动器')
                return
            }
            try {
                $result = Show-ModelConfigDialog -InstallDir $installDir -HermesHome $hermesHome -CanLaunchAfterSave ([bool]$state.HermesCommand)
                if ($result.Saved) {
                    Add-ActionLog -Action '配置模型提供商' -Result $result.Message -Next '主界面已刷新状态；建议立即验证一次本地对话'
                    Refresh-Status
                    if ($result.LaunchAfterSave) {
                        Invoke-AppAction 'launch'
                        return
                    }
                } else {
                    Add-LogLine '已关闭模型配置弹窗，未写入新配置。'
                }
            } catch {
                Add-ActionLog -Action '配置模型提供商' -Result ('打开模型配置弹窗失败：' + $_.Exception.Message) -Next '检查环境后重试'
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
            if (-not (Confirm-TerminalAction -ActionTitle '运行官方诊断' -UserSteps @('等待 doctor 输出检查结果。', '根据终端提示查看缺失依赖或配置问题。', '看完后回到启动器再刷新状态。') -SuccessHint '诊断窗口可以手动关闭。')) {
                Add-ActionLog -Action '运行 doctor' -Result '已取消打开终端' -Next '如需诊断，可再次点击“运行 doctor”'
                return
            }
            Start-InTerminal -WorkingDirectory $installDir -HermesHome $hermesHome -CommandLine ("& '$hermesCommand' doctor") | Out-Null
            Add-ActionLog -Action '运行 doctor' -Result '已打开官方诊断终端' -Next '根据终端输出修复问题后再刷新状态'
        }
        'launch' {
            Invoke-AppAction 'launch-webui'
        }
        'launch-webui' {
            if (-not $hermesCommand) {
                [System.Windows.MessageBox]::Show('未找到 Hermes 命令，请先安装 Hermes。', 'Hermes 启动器')
                return
            }
            if (-not $state.ModelStatus.ReadyLikely) {
                Add-ActionLog -Action '开始对话' -Result '当前还没有完成模型配置，已转到模型配置入口' -Next '先保存模型配置，再重新点击“开始对话”'
                Invoke-AppAction 'model'
                return
            }
            try {
                Add-ActionLog -Action '打开 WebUI' -Result '正在准备 Hermes WebUI' -Next '首次使用会下载启动器内置稳定版，请稍等'
                $result = Ensure-HermesWebUiReady -HermesHome $hermesHome -InstallDir $installDir
                Open-BrowserUrlSafe -Url $result.Url
                $script:LocalChatVerificationPending = $false
                $script:LocalChatVerified = $true
                Save-LauncherState -HermesHome $hermesHome -LocalChatVerified $true
                Add-ActionLog -Action '开始对话' -Result ("已打开 Hermes WebUI：{0}" -f $result.Url) -Next '浏览器中可以直接开始中文 WebUI 对话；命令行入口保留在“更多设置”'
                Refresh-Status
            } catch {
                $message = @(
                    'WebUI 启动失败。'
                    ''
                    $_.Exception.Message
                    ''
                    '可以先改用命令行对话，或打开 WebUI 日志排查。'
                    ''
                    '是否现在打开命令行对话？'
                ) -join [Environment]::NewLine
                Add-ActionLog -Action '打开 WebUI' -Result ('失败：' + $_.Exception.Message) -Next '可打开 WebUI 日志，或使用命令行对话作为备用入口'
                $choice = [System.Windows.MessageBox]::Show($message, 'Hermes WebUI', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
                if ($choice -eq [System.Windows.MessageBoxResult]::Yes) {
                    Invoke-AppAction 'launch-cli'
                }
            }
        }
        'launch-cli' {
            if (-not $hermesCommand) {
                [System.Windows.MessageBox]::Show('未找到 Hermes 命令，请先安装 Hermes。', 'Hermes 启动器')
                return
            }
            if (-not $state.ModelStatus.ReadyLikely) {
                Add-ActionLog -Action '开始命令行对话' -Result '当前还没有完成模型配置，已转到模型配置入口' -Next '先保存模型配置，再重新点击“打开命令行对话”'
                Invoke-AppAction 'model'
                return
            }
            $script:LocalChatVerificationPending = $true
            if (-not (Confirm-TerminalAction -ActionTitle '开始本地对话' -UserSteps @('终端打开后，直接在里面和 Hermes 对话。', '结束对话时可输入 exit，或按 Ctrl+C。', '首次验证本地对话时，确认能正常聊天即可。') -SuccessHint '关闭终端后回到启动器，可继续配置消息渠道。')) {
                $script:LocalChatVerificationPending = $false
                Add-ActionLog -Action '开始命令行对话' -Result '已取消打开终端' -Next '准备好后可再次点击“打开命令行对话”'
                return
            }
            Start-InTerminal -WorkingDirectory $installDir -HermesHome $hermesHome -CommandLine ("& '$hermesCommand'") | Out-Null
            Add-ActionLog -Action '开始命令行对话' -Result '已打开 Hermes 本地对话终端' -Next '如需通过 WebUI 对话，可再次点击首页“开始对话”'
            Refresh-Status
        }
        'restart-webui' {
            try {
                $result = Ensure-HermesWebUiReady -HermesHome $hermesHome -InstallDir $installDir -Restart $true
                Open-BrowserUrlSafe -Url $result.Url
                Add-ActionLog -Action '重启 WebUI' -Result ("WebUI 已重启：{0}" -f $result.Url) -Next '浏览器已打开 WebUI'
                Refresh-Status
            } catch {
                Add-ActionLog -Action '重启 WebUI' -Result ('失败：' + $_.Exception.Message) -Next '可打开 WebUI 日志或改用命令行对话'
                [System.Windows.MessageBox]::Show(('重启 WebUI 失败：' + $_.Exception.Message), 'Hermes WebUI')
            }
        }
        'update-webui' {
            try {
                $result = Ensure-HermesWebUiReady -HermesHome $hermesHome -InstallDir $installDir -ForceInstall $true -Restart $true
                Open-BrowserUrlSafe -Url $result.Url
                Add-ActionLog -Action '更新 WebUI' -Result ("已更新到启动器内置稳定版 {0}，并打开：{1}" -f $script:HermesWebUiVersionLabel, $result.Url) -Next '如遇异常，可打开 WebUI 日志排查'
                Refresh-Status
            } catch {
                Add-ActionLog -Action '更新 WebUI' -Result ('失败：' + $_.Exception.Message) -Next '保留现有 WebUI 或改用命令行对话'
                [System.Windows.MessageBox]::Show(('更新 WebUI 失败：' + $_.Exception.Message), 'Hermes WebUI')
            }
        }
        'open-webui-logs' {
            $webUiDefaults = Get-HermesWebUiDefaults -HermesHome $hermesHome -InstallDir $installDir
            Open-InExplorer -Path $webUiDefaults.LogsDir
            Add-ActionLog -Action '打开 WebUI 日志' -Result '已请求打开 WebUI 日志目录' -Next '可查看 stdout/stderr 日志'
        }
        'open-webui-dir' {
            $webUiDefaults = Get-HermesWebUiDefaults -HermesHome $hermesHome -InstallDir $installDir
            Open-InExplorer -Path $webUiDefaults.InstallDir
            Add-ActionLog -Action '打开 WebUI 目录' -Result '已请求打开 WebUI 安装目录' -Next '可查看 upstream WebUI 源码'
        }
        'confirm-local-chat' {
            if (-not $hermesCommand) {
                [System.Windows.MessageBox]::Show('未找到 Hermes 命令，请先安装 Hermes。', 'Hermes 启动器')
                return
            }
            $script:LocalChatVerificationPending = $false
            $script:LocalChatVerified = $true
            Save-LauncherState -HermesHome $hermesHome -LocalChatVerified $true
            try {
                if (-not (Confirm-TerminalAction -ActionTitle '配置消息渠道' -UserSteps @('按终端里的菜单选择要接入的消息平台。', '对普通用户建议选择直接允许私聊，不用配对审批。', '配置完成后关闭终端，启动器会自动重新检测。') -SuccessHint '识别到已配置渠道后，首页会显示消息渠道状态。')) {
                    Add-ActionLog -Action '确认本地对话已验证' -Result '已取消打开消息渠道配置终端' -Next '需要时可再次点击“继续配置消息渠道”'
                    return
                }
                $wrapperScript = New-ExternalTerminalCommandWrapper -WorkingDirectory $installDir -HermesHome $hermesHome -CommandLine ("& '$hermesCommand' gateway setup") -FailurePrompt '消息渠道配置失败，' -DisablePythonUtf8Mode $true
                $proc = Start-Process powershell.exe -PassThru -WorkingDirectory $installDir -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapperScript)
                Start-ExternalGatewaySetupMonitor -Process $proc
                Add-ActionLog -Action '确认本地对话已验证' -Result '已直接打开消息渠道配置终端。关闭终端后，启动器会自动检测配置结果。' -Next '若识别到已配置渠道，首页会直接显示消息渠道状态'
                Refresh-Status
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
                if (-not (Confirm-TerminalAction -ActionTitle '配置消息渠道' -UserSteps @('按终端里的菜单选择要接入的消息平台。', '对普通用户建议选择直接允许私聊，不用配对审批。', '配置完成后关闭终端，启动器会自动重新检测。') -SuccessHint '配置成功后，首页会直接显示消息渠道状态。')) {
                    Add-ActionLog -Action '配置消息渠道' -Result '已取消打开终端' -Next '需要时可再次点击“配置消息渠道”'
                    return
                }
                $wrapperScript = New-ExternalTerminalCommandWrapper -WorkingDirectory $installDir -HermesHome $hermesHome -CommandLine ("& '$hermesCommand' gateway setup") -FailurePrompt '消息渠道配置失败，' -DisablePythonUtf8Mode $true
                $proc = Start-Process powershell.exe -PassThru -WorkingDirectory $installDir -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapperScript)
                Start-ExternalGatewaySetupMonitor -Process $proc
                Add-ActionLog -Action '配置消息渠道' -Result '已打开 `hermes gateway setup` 配置终端。关闭终端后，启动器会自动检测配置结果。' -Next '如配置成功，首页会直接显示消息渠道状态'
                Refresh-Status
            } catch {
                Add-ActionLog -Action '配置消息渠道' -Result ('启动消息渠道配置终端失败：' + $_.Exception.Message) -Next '检查环境后重试'
            }
        }
        'install-messaging' {
            if (-not (Confirm-TerminalAction -ActionTitle '安装消息渠道依赖' -UserSteps @('等待依赖安装完成。', '安装过程中可能会下载 Python 或平台依赖，请耐心等待。', '安装完成后关闭终端，回到启动器继续。') -SuccessHint '依赖装好后，再启用消息渠道。' -FailureHint '如果终端报错，请保留终端，把最后几行错误发出来。')) {
                Add-ActionLog -Action '安装消息渠道依赖' -Result '已取消打开终端' -Next '需要时可再次点击“安装消息渠道依赖”'
                return
            }
            $proc = Start-MessagingDependencyInstall -InstallDir $installDir -HermesHome $hermesHome
            if ($proc) {
                $script:PendingGatewayStartAfterMessagingInstall = $false
                Start-ExternalMessagingMonitor -Process $proc -InstallDir $installDir -HermesHome $hermesHome -HermesCommand $hermesCommand
                Add-ActionLog -Action '安装消息渠道依赖' -Result '已打开依赖安装终端。关闭终端后，启动器会自动检测安装结果。' -Next '依赖装好后再让消息渠道上线'
                Refresh-Status
            }
        }
        'gateway' {
            if (-not $hermesCommand) {
                [System.Windows.MessageBox]::Show('未找到 Hermes 命令，请先安装 Hermes。', 'Hermes 启动器')
                return
            }
            $normalized = Normalize-FriendlyMessagingDefaults -HermesHome $hermesHome
            if ($normalized.Changed) {
                Add-ActionLog -Action '消息渠道授权修正' -Result $normalized.Message -Next '已按普通用户模式放开微信私聊，继续让消息渠道上线'
                Refresh-Status
                $state = Get-UiState
                $script:CurrentStatus = $state
            }
            if (-not $state.GatewayStatus.HasConfiguredChannel) {
                [System.Windows.MessageBox]::Show('还没有检测到已配置的消息渠道，请先运行“配置消息渠道”。', 'Hermes 启动器')
                return
            }
            if ($state.GatewayStatus.NeedsDependencyInstall) {
                if (-not (Confirm-TerminalAction -ActionTitle '先安装消息渠道依赖' -UserSteps @('因为当前渠道缺少依赖，系统会先打开安装终端。', '等待依赖安装完成后，启动器会继续尝试让消息渠道上线。', '如果出现报错，请先保留终端。') -SuccessHint '依赖安装结束后，启动器会继续推进消息渠道上线。')) {
                    Add-ActionLog -Action '让消息渠道上线' -Result '已取消打开依赖安装终端' -Next '准备好后可再次点击“让消息渠道上线”'
                    return
                }
                $proc = Start-MessagingDependencyInstall -InstallDir $installDir -HermesHome $hermesHome
                if ($proc) {
                    $script:PendingGatewayStartAfterMessagingInstall = $true
                    Start-ExternalMessagingMonitor -Process $proc -InstallDir $installDir -HermesHome $hermesHome -HermesCommand $hermesCommand
                    Add-ActionLog -Action '让消息渠道上线' -Result '已检测到缺少消息渠道依赖，正在先安装依赖。安装完成后，启动器会自动继续让渠道上线。' -Next '请等待依赖安装终端完成'
                    Refresh-Status
                }
                return
            }
            if (-not (Confirm-TerminalAction -ActionTitle '让消息渠道上线' -UserSteps @('终端打开后，保持它运行，不要立刻关闭。', '只要这个终端在运行，消息渠道就会保持在线。', '需要停止消息渠道时，再回到该终端按 Ctrl+C。') -SuccessHint '消息渠道在线期间，首页会显示“消息渠道已在线”。')) {
                Add-ActionLog -Action '让消息渠道上线' -Result '已取消打开终端' -Next '准备好后可再次点击“让消息渠道上线”'
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
$controls.StageModelButton.Add_Click({ Invoke-AppAction 'model' })
$controls.StageGatewayButton.Add_Click({ Show-GatewayPanel })
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
    if ($script:LauncherMutex) {
        $script:LauncherMutex.ReleaseMutex()
        $script:LauncherMutex.Dispose()
    }
}
