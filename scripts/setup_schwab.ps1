$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'schwab_private.ps1')
$lock = $null
try {
    Write-Output 'Auth only: this does not enable Schwab quotes, accounts or orders.'
    Write-Output 'Registered callback must be exactly https://127.0.0.1:8766/oauth/schwab/callback'
    Write-Output 'A unique self-signed loopback TLS certificate will be generated. No root trust or firewall changes.'
    if ((Read-Host 'Confirm this callback and local certificate creation. Type YES') -cne 'YES') {
        throw 'Setup cancelled.'
    }
    New-Item -ItemType Directory -Path $script:SchwabDirectory -Force | Out-Null
    Protect-ATraderPrivatePath $script:SchwabDirectory
    $lock = [IO.File]::Open((Join-Path $script:SchwabDirectory 'oauth.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $values = @{}
    $existing = Read-ATraderProtectedJson $script:ATraderPrivateConfigPath
    if ($null -ne $existing) {
        foreach ($property in $existing.PSObject.Properties) { $values[$property.Name] = $property.Value }
    }
    foreach ($name in @('SCHWAB_CLIENT_ID', 'SCHWAB_CLIENT_SECRET')) {
        $secure = Read-Host "Enter $name privately (required)" -AsSecureString
        try { $value = ConvertFrom-ATraderSecureString $secure } finally { $secure.Dispose() }
        if ([string]::IsNullOrWhiteSpace($value) -or $value -match '[\r\n]') { throw 'Credential required.' }
        $values[$name] = $value
        $value = $null
    }
    # Generate TLS before modifying credentials; no provider requests or browser launch.
    $tls = New-ATraderSchwabTlsBundle
    Write-ATraderProtectedJson (Join-Path $script:SchwabDirectory 'tls.dpapi') ($tls | ConvertTo-Json -Compress)
    Write-ATraderProtectedJson $script:ATraderPrivateConfigPath ($values | ConvertTo-Json -Compress)
    # A previous refresh token belongs to the old credential setup.
    $tokenPath = Join-Path $script:SchwabDirectory 'tokens.dpapi'
    if (Test-Path -LiteralPath $tokenPath) { Remove-Item -LiteralPath $tokenPath -Force }
    Write-Output ('Saved current-user DPAPI credentials and TLS. Local certificate thumbprint: ' + $tls.thumbprint)
    Write-Output 'Next: .\scripts\authorize_schwab.ps1 (explicit browser consent required).'
} catch {
    Write-Error 'Schwab setup did not complete. Check local Windows certificate/DPAPI access and rerun. No error details printed.'
    exit 1
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
    $values = $null
    $existing = $null
    $tls = $null
}
