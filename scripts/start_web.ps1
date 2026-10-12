$ErrorActionPreference = 'Stop'
$configScript = Join-Path $PSScriptRoot 'private_config.ps1'
. $configScript
$flutter = Get-ATraderFlutterExecutable
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    & $flutter run -d chrome --web-hostname=localhost --web-port=3000
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter Web exited with code $LASTEXITCODE."
    }
} finally {
    Pop-Location
}
