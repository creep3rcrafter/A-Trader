param(
    [Parameter(Mandatory = $true)][string]$PublicIp,
    [switch]$AcknowledgeUnencryptedPublicTesting
)

$ErrorActionPreference = 'Stop'
if (!$AcknowledgeUnencryptedPublicTesting) {
    throw 'Temporary public HTTP requires -AcknowledgeUnencryptedPublicTesting. Passwords, cookies and displayed data can be intercepted. This is not HTTPS or production hosting.'
}
$address = $null
if (![Net.IPAddress]::TryParse($PublicIp, [ref]$address) -or
    $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
    [Net.IPAddress]::IsLoopback($address) -or
    $address.ToString() -eq '0.0.0.0' -or
    $address.ToString() -eq '255.255.255.255') {
    throw 'PublicIp must be a specific IPv4 address, not localhost or a wildcard.'
}

. (Join-Path $PSScriptRoot 'private_config.ps1')
Import-ATraderPrivateConfig
if (!$env:A_TRADER_AUTH_PASSWORD -or $env:A_TRADER_AUTH_PASSWORD.Length -lt 12) {
    throw 'Public testing requires the existing password of at least 12 characters. Run scripts\setup_local.ps1 first.'
}

$flutter = Get-ATraderFlutterExecutable
$dart = Get-ATraderDartExecutable
$projectRoot = Split-Path -Parent $PSScriptRoot
$overrides = @{
    A_TRADER_PORT = '3000'
    A_TRADER_BIND_ADDRESS = '0.0.0.0'
    A_TRADER_AUTH_ENABLED = 'true'
    A_TRADER_WEB_ROOT = Join-Path $projectRoot 'build\web'
    A_TRADER_LAN_ORIGINS = "http://$($address.ToString()):3000,http://localhost:3000,http://127.0.0.1:3000"
}
$previous = @{}
Push-Location $projectRoot
try {
    & $flutter build web --release --dart-define=A_TRADER_SAME_ORIGIN=true
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter Web build failed with code $LASTEXITCODE."
    }
    foreach ($name in $overrides.Keys) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $overrides[$name], 'Process')
    }
    Write-Warning 'TEMPORARY PUBLIC HTTP: the password and session cookie are unencrypted and can be intercepted. Use a unique test password and rotate it after testing. Do not use sensitive data or paid AI.'
    Write-Warning 'No router/firewall changes are made. External reachability and control of the supplied IP are not verified. Provider sharing/display permission gates remain enforced.'
    Write-Output "Test URL: http://$($address.ToString()):3000/"
    Write-Output 'Only that exact public origin and local loopback origins are allowed. Authentication is required; sessions expire 24 hours after login or immediately on server restart.'
    Write-Warning 'Stop with Ctrl+C and remove any port forwarding/firewall exception after testing. Session expiry does not shut down the server or close your router ports.'
    & $dart run backend\bin\market_data_server.dart
    if ($LASTEXITCODE -ne 0) {
        throw "Authenticated public test server exited with code $LASTEXITCODE."
    }
} finally {
    foreach ($name in $previous.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
    }
    Pop-Location
}
