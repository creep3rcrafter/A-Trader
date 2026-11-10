$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'schwab_private.ps1')
$lock = $null
$values = $null
try {
    Write-Output 'Read-only quotes/daily history only. No accounts, orders, streaming, paid add-ons or automatic provider fallback.'
    Write-Output 'OAuth authorization is not confirmation of data usage, personal/free access, LAN display or model-processing rights.'
    Write-Output 'Review your Schwab app/account agreements and entitlements. Do not confirm unless this use is permitted without paid add-ons.'
    if ((Read-Host 'Confirm permitted personal/free read-only market-data use. Type PERMITTED') -cne 'PERMITTED') {
        throw 'Market-data rights not confirmed.'
    }
    $lan = (Read-Host 'Separately confirm LAN/shared display rights ONLY if your agreements permit it. Type LAN-PERMITTED or press Enter to leave disabled') -ceq 'LAN-PERMITTED'
    if ((Read-Host 'Explicitly select Schwab (no fallback). Type SELECT-SCHWAB') -cne 'SELECT-SCHWAB') {
        throw 'Provider selection cancelled.'
    }
    if (!(Test-Path -LiteralPath (Join-Path $script:SchwabDirectory 'tokens.dpapi'))) {
        throw 'Run authorize_schwab.ps1 first.'
    }
    $lock = [IO.File]::Open((Join-Path $script:SchwabDirectory 'oauth.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $existing = Read-ATraderProtectedJson $script:ATraderPrivateConfigPath
    $values = @{}
    if ($null -ne $existing) {
        foreach ($property in $existing.PSObject.Properties) { $values[$property.Name] = $property.Value }
    }
    if (!$values['SCHWAB_CLIENT_ID'] -or !$values['SCHWAB_CLIENT_SECRET']) { throw 'Private credentials missing.' }
    $values['SCHWAB_MARKET_DATA_TERMS_CONFIRMED'] = 'true'
    $values['SCHWAB_LAN_DISPLAY_TERMS_CONFIRMED'] = $lan.ToString().ToLowerInvariant()
    $values['A_TRADER_MARKET_DATA_PROVIDER'] = 'schwab'
    Write-ATraderProtectedJson $script:ATraderPrivateConfigPath ($values | ConvertTo-Json -Compress)
    Write-Output 'Saved explicit selection and permissions privately. Existing tokens/other settings preserved.'
    Write-Output 'Model forwarding permission was NOT changed. Daily indicators remain unavailable (adjustment unknown).'
    Write-Output 'Next: .\scripts\test_schwab_market_data.ps1 (one quote and one bounded daily-history request).'
    Write-Output 'No running backend was changed or restarted. Process environment overrides private settings.'
} catch {
    Write-Error 'Schwab market-data setup not completed. Confirm rights privately, authorize first, and avoid concurrent setup/authorization.'
    exit 1
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
    $values = $null
    $existing = $null
}
