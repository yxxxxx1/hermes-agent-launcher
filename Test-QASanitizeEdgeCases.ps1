# QA-designed edge cases for Sanitize-TelemetryString
# Targets cases the engineer's own tests might miss.
$ErrorActionPreference = 'Stop'

$src = Get-Content -Raw -Path (Join-Path $PSScriptRoot 'HermesGuiLauncher.ps1')
$ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
$fn = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Sanitize-TelemetryString' }, $true) | Select-Object -First 1
Invoke-Expression $fn.Extent.Text

$cases = @(
    # ==== leak-risk cases ====
    @{ Name='Bare GitHub PAT (ghp_)';       Input='Auth failed with ghp_AbCdEf0123456789ABCDEF';  MustNotContain='ghp_AbCdEf0123456789ABCDEF' },
    @{ Name='Bare HuggingFace token (hf_)'; Input='Token: hf_xxxYYYzzzABC123';                    MustNotContain='hf_xxxYYYzzzABC123' },
    @{ Name='Bare OpenAI sk-proj-';         Input='Using key sk-proj-AbCd1234EfGh5678';           MustNotContain='AbCd1234EfGh5678' },
    @{ Name='Bare Google API AIza...';      Input='Using AIzaSyAbCdEfGhIjKlMnOpQrStUvWxYz1234567'; MustNotContain='AIzaSyAbCdEfGhIjKlMnOpQrStUvWxYz1234567' },
    @{ Name='Bare JWT eyJ...';              Input='Token=eyJhbGciOiJIUzI1NiJ9.body.sig';          MustNotContain='eyJhbGciOiJIUzI1NiJ9' },
    @{ Name='IPv6 address';                 Input='Connection from 2001:db8::1 refused';          MustNotContain='2001:db8::1' },
    @{ Name='Anthropic sk-ant- key';        Input='key=sk-ant-api03-AbCdEf01234567';              MustNotContain='sk-ant-api03-AbCdEf01234567' },
    @{ Name='Url-encoded path with user';   Input='C%3A%5CUsers%5C74431%5Capp.log';               MustNotContain='74431' },
    @{ Name='Forward slash Windows path';   Input='C:/Users/74431/.hermes/config.yaml';           MustNotContain='74431' },
    @{ Name='Mixed case token=';            Input='ToKeN=abc123def456';                           MustNotContain='abc123def456' },
    @{ Name='Spaces around equals';         Input='token = abc123def456';                         MustNotContain='abc123def456' },
    @{ Name='JSON style password';          Input='{"password": "Sup3rS3cret!"}';                 MustNotContain='Sup3rS3cret!' },
    @{ Name='Connection string';            Input='Server=db;User Id=admin;Password=p@ss123';     MustNotContain='p@ss123' },
    @{ Name='Authorization header colon';   Input='Authorization: AbCdEf123';                     MustNotContain='AbCdEf123' },
    @{ Name='Path no Users prefix';         Input='C:\workspace\projects\foo';                    AcceptableLeak='workspace' },
    @{ Name='Multiple secrets one line';    Input='token=A1 password=B2 api_key=C3';              MustNotContain='A1' }
)

$pass = 0; $fail = 0
foreach ($c in $cases) {
    $out = Sanitize-TelemetryString -Text $c.Input
    $ok = $true
    $reason = ''
    if ($c.ContainsKey('MustNotContain') -and $out -match [regex]::Escape($c.MustNotContain)) {
        $ok = $false
        $reason = "still contains '$($c.MustNotContain)' -> '$out'"
    }
    if ($ok) { $pass++; Write-Host ("PASS  " + $c.Name + "    -> " + $out) }
    else     { $fail++; Write-Host ("FAIL  " + $c.Name + " :: " + $reason) }
}

Write-Host ''
Write-Host ("QA Edge: Total $($pass+$fail)  Passed $pass  Failed $fail")
exit 0
