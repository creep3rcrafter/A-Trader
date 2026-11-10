param([string]$Symbol = 'AAPL')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'private_config.ps1')
try {
    Import-ATraderPrivateConfig
    if ($env:A_TRADER_MARKET_DATA_PROVIDER -ne 'schwab' -or
        $env:SCHWAB_MARKET_DATA_TERMS_CONFIRMED -cne 'true') {
        throw 'Explicit selection and terms confirmation required.'
    }
    $dart = Get-ATraderDartExecutable
    $entry = Join-Path (Split-Path -Parent $PSScriptRoot) 'backend\bin\schwab_market_data_smoke.dart'
    & $dart run $entry $Symbol
    if ($LASTEXITCODE -ne 0) { throw 'Smoke failed.' }
} catch {
    Write-Error 'Schwab smoke not completed. Run setup_schwab_market_data.ps1 privately, check consent/rights and cooldown. No retries or provider fallback.'
    exit 1
}
