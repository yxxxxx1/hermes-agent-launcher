# Unit test for Sanitize-TelemetryString.
# Extracts the function from HermesGuiLauncher.ps1 via AST and runs cases.
$ErrorActionPreference = 'Stop'

$src = Get-Content -Raw -Path (Join-Path $PSScriptRoot 'HermesGuiLauncher.ps1')
$ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
$fn = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Sanitize-TelemetryString' }, $true) | Select-Object -First 1
if (-not $fn) { Write-Host 'Sanitize-TelemetryString not found'; exit 1 }
Invoke-Expression $fn.Extent.Text

$cases = @(
    @{ Name='API Key sk-';      Input='Failed: sk-abc123XYZ_secretkey'; MustNotContain='abc123XYZ' },
    @{ Name='API key=val';      Input='api_key=hf_xxxYYYzzz123 in config'; MustNotContain='hf_xxxYYYzzz123' },
    @{ Name='token=';           Input='token=ghp_AbCdEf123456'; MustNotContain='ghp_AbCdEf123456' },
    @{ Name='Bearer';           Input='Authorization: Bearer eyJhbGciOiJIUzI1NiJ9'; MustNotContain='eyJhbGciOiJIUzI1NiJ9' },
    @{ Name='Win user path';    Input='C:\Users\someuser\.hermes\config.yaml'; MustNotContain='someuser' },
    @{ Name='POSIX home';       Input='Stack at /home/myname/foo'; MustNotContain='myname' },
    @{ Name='POSIX Users';      Input='Stack at /Users/myname/foo'; MustNotContain='myname' },
    @{ Name='Email';            Input='Contact: foo.bar+test@example.com for help'; MustNotContain='foo.bar+test@example.com' },
    @{ Name='IPv4';             Input='Connection refused 192.168.1.55:8080'; MustNotContain='192.168.1.55' },
    @{ Name='Username from env'; Input=('Hello ' + $env:USERNAME + ' welcome'); MustNotContain=$env:USERNAME },
    @{ Name='password=';        Input='password=Sup3rS3cret!'; MustNotContain='Sup3rS3cret!' },
    @{ Name='secret=';          Input='secret=topsecret'; MustNotContain='topsecret' },
    @{ Name='Truncation';       Input=('a' * 700); MustContainSubstring='...' },
    @{ Name='Empty string';     Input=''; MustEqual='' },
    @{ Name='Null';             Input=$null; MustEqual='' },
    @{ Name='Numeric input';    Input=42; MustEqual='42' },
    # ---- 任务 011 返工 F1：吸收 QA 对抗测试的 5 个漏脱场景，防止下次回归 ----
    @{ Name='GitHub PAT (ghp_)';      Input='Auth failed with ghp_AbCdEf0123456789ABCDEF';  MustNotContain='ghp_AbCdEf0123456789ABCDEF' },
    @{ Name='Google API key (AIza)';  Input='Using AIzaSyAbCdEfGhIjKlMnOpQrStUvWxYz1234567'; MustNotContain='AIzaSyAbCdEfGhIjKlMnOpQrStUvWxYz1234567' },
    @{ Name='IPv6 address';           Input='Connection from 2001:db8::1 refused';          MustNotContain='2001:db8::1' },
    @{ Name='URL-encoded user path';  Input='C%3A%5CUsers%5Cmysecretuser%5Capp.log';        MustNotContain='mysecretuser' },
    @{ Name='JSON-style password';    Input='{"password": "Sup3rS3cret!"}';                 MustNotContain='Sup3rS3cret!' }
)

$pass = 0; $fail = 0
foreach ($c in $cases) {
    $out = Sanitize-TelemetryString -Text $c.Input
    $ok = $true
    $reason = ''
    if ($c.ContainsKey('MustNotContain') -and $out -match [regex]::Escape($c.MustNotContain)) {
        $ok = $false; $reason = "still contains '$($c.MustNotContain)' -> '$out'"
    }
    if ($c.ContainsKey('MustContainSubstring') -and -not ($out -match [regex]::Escape($c.MustContainSubstring))) {
        $ok = $false; $reason = "missing '$($c.MustContainSubstring)'"
    }
    if ($c.ContainsKey('MustEqual') -and $out -ne $c.MustEqual) {
        $ok = $false; $reason = "expected '$($c.MustEqual)' got '$out'"
    }
    if ($ok) { $pass++; Write-Host ("PASS  " + $c.Name + "    -> " + $out) }
    else     { $fail++; Write-Host ("FAIL  " + $c.Name + " :: " + $reason) }
}

Write-Host ''
Write-Host ("Total: $($pass+$fail)  Passed: $pass  Failed: $fail")
if ($fail -gt 0) { exit 1 } else { exit 0 }
