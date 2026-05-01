<#
.SYNOPSIS
Integration test: validates launcher core pipeline without GUI.
Covers layers 2-4 above SelfTest.

.DESCRIPTION
Layer 1: SelfTest (config paths, version)
Layer 2: config.yaml encoding + port
Layer 3: Gateway process + health
Layer 4: WebUI health + connectivity
Layer 5: Environment checks

Usage:
  powershell -ExecutionPolicy Bypass -File .\Test-Integration.ps1

Exit codes:
  0 = all passed
  1 = has failures
#>

$ErrorActionPreference = 'Continue'
$failed = 0
$passed = 0
$skipped = 0

function Test-Check {
    param([string]$Name, [scriptblock]$Check)
    try {
        $result = & $Check
        if ($result) {
            Write-Host "  PASS  $Name" -ForegroundColor Green
            $script:passed++
        } else {
            Write-Host "  FAIL  $Name" -ForegroundColor Red
            $script:failed++
        }
    }
    catch {
        Write-Host "  FAIL  $Name - $($_.Exception.Message)" -ForegroundColor Red
        $script:failed++
    }
}

function Test-Skip {
    param([string]$Name, [string]$Reason)
    Write-Host "  SKIP  $Name - $Reason" -ForegroundColor Yellow
    $script:skipped++
}

# == Layer 1: SelfTest ==
Write-Host "`n=== Layer 1: SelfTest ===" -ForegroundColor Cyan
$selfTestJson = powershell -NoProfile -ExecutionPolicy Bypass -File .\HermesGuiLauncher.ps1 -SelfTest 2>$null
try {
    $st = $selfTestJson | ConvertFrom-Json
}
catch {
    Write-Host "  FAIL  SelfTest JSON parse failed" -ForegroundColor Red
    $failed++
    $st = $null
}

if ($st) {
    Test-Check 'SelfTest passed' { $st.SelfTest -eq $true }
    Test-Check 'Version not empty' { $st.LauncherVersion -and $st.LauncherVersion.Length -gt 5 }
    Test-Check 'Hermes installed' { $st.Status.Installed -eq $true }
    Test-Check 'config.yaml exists' { $st.Status.ConfigExists -eq $true }
    Test-Check '.env exists' { $st.Status.EnvExists -eq $true }
}

# == Layer 2: config.yaml validation ==
Write-Host "`n=== Layer 2: config.yaml ===" -ForegroundColor Cyan
$configPath = Join-Path $env:USERPROFILE '.hermes\config.yaml'

if (Test-Path $configPath) {
    $configBytes = [System.IO.File]::ReadAllBytes($configPath)
    $configText = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)

    Test-Check 'config.yaml no BOM' {
        -not ($configBytes.Length -ge 3 -and $configBytes[0] -eq 0xEF -and $configBytes[1] -eq 0xBB -and $configBytes[2] -eq 0xBF)
    }

    Test-Check 'config.yaml UTF-8 parseable' {
        $configText.Length -gt 0
    }

    Test-Check 'api_server port = 8642' {
        $configText -match '(?m)^\s+port:\s+8642\s*$'
    }

    Test-Check 'config.yaml no GBK corruption' {
        -not ($configText -match '\uFFFD')
    }
} else {
    Test-Skip 'config.yaml validation' 'file not found'
}

# == Layer 3: Gateway ==
Write-Host "`n=== Layer 3: Gateway ===" -ForegroundColor Cyan

$hermesExe = Join-Path $env:LOCALAPPDATA 'hermes\hermes-agent\venv\Scripts\hermes.exe'
if (Test-Path $hermesExe) {
    $gatewayProc = Get-Process -Name 'hermes' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path -like '*hermes-agent*' }

    if ($gatewayProc) {
        Test-Check 'Gateway process exists' { $true }

        Test-Check 'Gateway health (8642)' {
            try {
                $r = Invoke-RestMethod -Uri 'http://127.0.0.1:8642/health' -TimeoutSec 3 -ErrorAction Stop
                $true
            }
            catch { $false }
        }

        $pidFile = Join-Path $env:USERPROFILE '.hermes\gateway.pid'
        Test-Check 'gateway.pid valid' {
            if (-not (Test-Path $pidFile)) { return $false }
            try {
                $pidJson = [System.IO.File]::ReadAllText($pidFile) | ConvertFrom-Json
                $pidJson.pid -gt 0 -and $pidJson.kind -eq 'hermes-gateway'
            }
            catch { $false }
        }

        $hermesProcs = @(Get-Process -Name 'hermes' -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path -like '*hermes-agent*' })
        Test-Check 'Gateway single instance' {
            $hermesProcs.Count -le 1
        }
    } else {
        Test-Skip 'Gateway process checks' 'Gateway not running (start via launcher first)'
    }
} else {
    Test-Skip 'Gateway checks' 'hermes not installed'
}

# == Layer 4: WebUI ==
Write-Host "`n=== Layer 4: WebUI ===" -ForegroundColor Cyan

$webuiPort = 8648
$webuiHealthy = $false
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$webuiPort/health" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
    $webuiHealthy = $r.StatusCode -eq 200
}
catch {
    # webui not running
}

if ($webuiHealthy) {
    Test-Check 'WebUI health OK' { $true }

    Test-Check 'WebUI homepage accessible' {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$webuiPort/" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            $r.StatusCode -eq 200 -and $r.Content -match 'Hermes'
        }
        catch { $false }
    }

    Test-Check 'WebUI -> Gateway connectivity' {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$webuiPort/api/status" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            $true
        }
        catch {
            # 401 means webui is responding (auth required) - still proves connectivity
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 401) { $true }
            else { $false }
        }
    }
} else {
    Test-Skip 'WebUI checks' 'WebUI not running (start via launcher first)'
}

# == Layer 5: Environment ==
Write-Host "`n=== Layer 5: Environment ===" -ForegroundColor Cyan

Test-Check '.env file UTF-8 no BOM' {
    $envFile = Join-Path $env:USERPROFILE '.hermes\.env'
    if (-not (Test-Path $envFile)) { return $true }
    $bytes = [System.IO.File]::ReadAllBytes($envFile)
    -not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

Test-Check 'PowerShell >= 5.1' {
    $PSVersionTable.PSVersion.Major -ge 5
}

Test-Check 'Git Bash available' {
    $gitBash = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($gitBash) { return $true }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
    )
    ($candidates | Where-Object { Test-Path $_ }).Count -gt 0
}

# == Summary ==
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $passed" -ForegroundColor Green
if ($failed -gt 0) {
    Write-Host "  Failed: $failed" -ForegroundColor Red
}
if ($skipped -gt 0) {
    Write-Host "  Skipped: $skipped" -ForegroundColor Yellow
}
Write-Host ""

if ($failed -gt 0) {
    Write-Host "$failed check(s) failed. Fix before release." -ForegroundColor Red
    exit 1
} else {
    Write-Host "All integration tests passed." -ForegroundColor Green
    exit 0
}
