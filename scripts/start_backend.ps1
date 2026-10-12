$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'private_config.ps1')
Import-ATraderPrivateConfig
$dart = Get-ATraderDartExecutable
if (!$env:A_TRADER_PORT) { $env:A_TRADER_PORT = '8765' }
if (!$env:A_TRADER_BIND_ADDRESS) { $env:A_TRADER_BIND_ADDRESS = '127.0.0.1' }
if (!$env:A_TRADER_ALLOWED_ORIGIN) {
    $env:A_TRADER_ALLOWED_ORIGIN = 'http://localhost:3000'
}
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    & $dart run backend\bin\market_data_server.dart
    if ($LASTEXITCODE -ne 0) {
        throw "Backend exited with code $LASTEXITCODE."
    }
} finally {
    Pop-Location
}
