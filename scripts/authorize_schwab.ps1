param([switch]$Refresh)
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'schwab_private.ps1')
$lock = $null
$bootstrap = $null
try {
    Import-ATraderPrivateConfig
    if (!$env:SCHWAB_CLIENT_ID -or !$env:SCHWAB_CLIENT_SECRET) { throw 'Run setup first.' }
    New-Item -ItemType Directory -Path $script:SchwabDirectory -Force | Out-Null
    Protect-ATraderPrivatePath $script:SchwabDirectory
    $lock = [IO.File]::Open((Join-Path $script:SchwabDirectory 'oauth.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $tls = $null
    if (!$Refresh) {
        $tls = Read-ATraderProtectedJson (Join-Path $script:SchwabDirectory 'tls.dpapi')
        if ($null -eq $tls -or [DateTime]::Parse($tls.expiresUtc).ToUniversalTime() -le [DateTime]::UtcNow) {
            throw 'Run setup to renew the local certificate.'
        }
        Write-Output ('Local callback certificate thumbprint: ' + $tls.thumbprint)
        Write-Output 'Browser may warn ONLY at https://127.0.0.1:8766/oauth/schwab/callback'
        Write-Output 'No root trust is installed. Never bypass a TLS warning on Schwab or another site.'
        Write-Output 'Check the exact loopback address and this certificate before accepting its local exception.'
        Write-Output 'Review requested permissions; cancel if they exceed your approved Market Data app.'
        if ((Read-Host 'Open one Schwab authorization flow now? Type AUTHORIZE') -cne 'AUTHORIZE') {
            throw 'Authorization cancelled.'
        }
    }
    $bootstrap = @{
        clientId = $env:SCHWAB_CLIENT_ID
        clientSecret = $env:SCHWAB_CLIENT_SECRET
        tls = $tls
    } | ConvertTo-Json -Compress -Depth 6
    $dart = Get-ATraderDartExecutable
    $entry = Join-Path (Split-Path -Parent $PSScriptRoot) 'backend\bin\schwab_oauth.dart'
    $action = if ($Refresh) { 'refresh' } else { 'authorize' }
    $bootstrap | & $dart run $entry $action
    if ($LASTEXITCODE -ne 0) { throw 'OAuth command failed.' }
} catch {
    Write-Error 'Schwab auth did not complete. Check setup, exclusive local port 8766, certificate expiry, and consent. Reauthorize after revoked/expired refresh grants. No sensitive error details printed.'
    exit 1
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
    $bootstrap = $null
    $tls = $null
}
