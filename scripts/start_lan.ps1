param(
    [string]$BindAddress = '0.0.0.0',
    [switch]$AcknowledgePrivateNetworkOnly
)

$ErrorActionPreference = 'Stop'
if (!$AcknowledgePrivateNetworkOnly) {
    throw 'LAN launch requires -AcknowledgePrivateNetworkOnly. HTTP is unencrypted and this server must never be exposed to the public Internet.'
}
$parsedAddress = $null
if (![Net.IPAddress]::TryParse($BindAddress, [ref]$parsedAddress) -or
    [Net.IPAddress]::IsLoopback($parsedAddress)) {
    throw 'Choose a non-loopback LAN IP address or 0.0.0.0.'
}

$configScript = Join-Path $PSScriptRoot 'private_config.ps1'
. $configScript
$flutter = Get-ATraderFlutterExecutable
$dart = Get-ATraderDartExecutable
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    & $flutter build web --release --dart-define=A_TRADER_SAME_ORIGIN=true
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter Web build failed with code $LASTEXITCODE."
    }

    Import-ATraderPrivateConfig
    if (!$env:A_TRADER_AUTH_PASSWORD -or $env:A_TRADER_AUTH_PASSWORD.Length -lt 12) {
        throw 'LAN hosting requires a password of at least 12 characters. Run scripts\setup_local.ps1 first.'
    }
    $env:A_TRADER_PORT = '3000'
    $env:A_TRADER_BIND_ADDRESS = $parsedAddress.ToString()
    $env:A_TRADER_AUTH_ENABLED = 'true'
    $env:A_TRADER_WEB_ROOT = Join-Path $projectRoot 'build\web'

    Write-Warning 'LAN HTTP is unencrypted. Use only on a trusted private network; never expose or forward port 3000 to the public Internet.'
    Write-Warning 'Passwords and session cookies are not transport-encrypted. Never configure public router forwarding. If needed, manually allow port 3000 only on the Windows Firewall Private profile.'
    Write-Output 'LAN Host/Origin checks allow local interface IPs and localhost on port 3000 by default. A_TRADER_LAN_ORIGINS may restrict this to comma-separated exact HTTP origins.'
    Write-Warning 'No firewall rule is created. The signed-in session expires after 24 hours; restart or stop this process when finished.'
    & $dart run backend\bin\market_data_server.dart
    if ($LASTEXITCODE -ne 0) {
        throw "Authenticated LAN server exited with code $LASTEXITCODE."
    }
} finally {
    Pop-Location
}
