# Round-2 QA adversarial cases: NEW cases the engineer has not seen.
# Verify the regex fixes are robust, not over-fit to QA's first set.
$ErrorActionPreference = 'Stop'

$src = Get-Content -Raw -Path (Join-Path $PSScriptRoot 'HermesGuiLauncher.ps1')
$ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
$fn = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Sanitize-TelemetryString' }, $true) | Select-Object -First 1
Invoke-Expression $fn.Extent.Text

$cases = @(
    # === New leak-risk cases not in original 16 ===
    @{ Name='GitHub PAT mid-sentence';    Input='Reason: ghp_AbCdEf01234567890abcdef caused 401'; MustNotContain='AbCdEf01234567890abcdef' },
    @{ Name='Google AIza in URL';         Input='https://gen-lang.googleapis.com/v1?key=AIzaSyAbCdEfGhIjKlMnOpQrStUvWx12345';  MustNotContain='AIzaSyAbCdEfGhIjKlMnOpQrStUvWx12345' },
    @{ Name='IPv6 with port bracket';     Input='Connect to [2001:db8::cafe:1]:8080 timed out';                                  MustNotContain='2001:db8::cafe:1' },
    @{ Name='IPv6 loopback ::1';          Input='Bind to ::1 failed';                                                            AcceptablePass='OK if too short to match' },
    @{ Name='URL-encoded lower-case';     Input='c%3a%5cusers%5c74431%5capp.log';                                                MustNotContain='74431' },
    @{ Name='JSON token (no quotes)';     Input='request: {token: my_t0ken_v4lue}';                                              MustNotContain='my_t0ken_v4lue' },
    @{ Name='JSON apikey hyphen var';     Input='{"api-key":"hf_abc123"}';                                                       MustNotContain='hf_abc123' },
    @{ Name='Hex hash NOT IPv6 false-pos';Input='SHA1: a1b2c3d4e5f6:abcdef:1234:5678';                                           MustContainSubstring='SHA1' },
    @{ Name='Version not as IPv6 false-pos';Input='dotnet 6.0.1.4 build';                                                        MustContainSubstring='6.0.1.4' },
    @{ Name='%XX in normal data';         Input='Encoded data %20 abc %FF def';                                                  MustContainSubstring='abc' },
    @{ Name='GitHub short suffix (<20)';  Input='Maybe ghp_short';                                                               AcceptablePass='OK if not redacted (too short)' },
    @{ Name='AIza too short (<30)';       Input='Maybe AIzaShort';                                                               AcceptablePass='OK if not redacted (too short)' },
    @{ Name='Anthropic sk-ant-api03';     Input='key=sk-ant-api03-AbCdEf12345678901234567890';                                   MustNotContain='AbCdEf12345678901234567890' },
    @{ Name='Forward-slash POSIX home';   Input='Stack at /home/zhangsan/app';                                                   MustNotContain='zhangsan' },
    @{ Name='URL-encoded then path';      Input='%2FUsers%2Fjohn%2Ffoo';                                                         MustNotContain='john' },
    @{ Name='Connection IPv6 in url';     Input='[::1]:8642/health';                                                             MustContainSubstring='8642' },
    @{ Name='Email upper-case domain';    Input='SEND TO Admin@Example.COM now';                                                 MustNotContain='Admin@Example.COM' },
    @{ Name='Chinese in path';            Input='C:\Users\张三\.hermes\config';                                                  MustNotContain='张三' },
    @{ Name='Multiple GitHub tokens';     Input='ghp_AAAA000011112222BBBB ghs_BBBB000011112222CCCC';                             MustNotContain='AAAA000011112222BBBB' },
    @{ Name='Bearer multiline';           Input="Authorization: Bearer abc.def.ghi`nNext line clean";                            MustNotContain='abc.def.ghi' }
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
    if ($c.ContainsKey('MustContainSubstring') -and -not ($out -match [regex]::Escape($c.MustContainSubstring))) {
        $ok = $false
        $reason = "missing '$($c.MustContainSubstring)' -> '$out'"
    }
    if ($ok) { $pass++; Write-Host ("PASS  " + $c.Name + "    -> " + $out) }
    else     { $fail++; Write-Host ("FAIL  " + $c.Name + " :: " + $reason) }
}

Write-Host ''
Write-Host ("QA-v2: Total $($pass+$fail)  Passed $pass  Failed $fail")
exit 0
