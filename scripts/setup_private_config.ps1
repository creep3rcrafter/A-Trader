$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'private_config.ps1')

if ($env:OS -ne 'Windows_NT') {
    throw 'The private configuration setup requires Windows DPAPI.'
}
if (Test-Path -LiteralPath $script:ATraderPrivateConfigPath -PathType Leaf) {
    $replace = Read-Host 'Private config already exists. Type REPLACE to replace it'
    if ($replace -cne 'REPLACE') {
        throw 'Private configuration was not changed.'
    }
}

$privateValues = [ordered]@{}
$privateNames = @(
    'ALPACA_API_KEY_ID',
    'ALPACA_API_SECRET_KEY',
    'TWELVE_DATA_API_KEY',
    'OPENAI_API_KEY',
    'LM_STUDIO_API_TOKEN'
)
foreach ($name in $privateNames) {
    $secureValue = Read-Host "Enter $name (leave blank to keep it unset)" -AsSecureString
    $plainValue = ConvertFrom-ATraderSecureString -SecureValue $secureValue
    if ($plainValue.Length -gt 0) {
        $privateValues[$name] = $plainValue
    }
    $plainValue = $null
    $secureValue.Dispose()
}

$password = Read-Host 'Set the LAN access password (at least 12 characters, any characters; leave blank to keep LAN hosting disabled)' -AsSecureString
$passwordText = ConvertFrom-ATraderSecureString -SecureValue $password
if ($passwordText.Length -gt 0) {
    if ($passwordText.Length -lt 12) {
        throw 'LAN access password must contain at least 12 characters. No character mix is required.'
    }
    $passwordConfirmation = Read-Host 'Confirm the LAN access password' -AsSecureString
    $confirmationText = ConvertFrom-ATraderSecureString -SecureValue $passwordConfirmation
    if ($passwordText -cne $confirmationText) {
        throw 'The LAN passwords did not match.'
    }
    $privateValues['A_TRADER_AUTH_PASSWORD'] = $passwordText
    $confirmationText = $null
    $passwordConfirmation.Dispose()
}
$passwordText = $null
$password.Dispose()

$provider = Read-Host 'Default market-data provider (alpaca or twelveData; default alpaca)'
if (!$provider) { $provider = 'alpaca' }
if ($provider -notin @('alpaca', 'twelveData')) {
    throw 'Market-data provider must be alpaca or twelveData.'
}
$privateValues['A_TRADER_MARKET_DATA_PROVIDER'] = $provider
$privateValues['ALPACA_MARKET_DATA_TERMS_CONFIRMED'] =
    if ((Read-Host 'Have you reviewed and confirmed Alpaca market-data terms? Type YES') -ceq 'YES') {
        'true'
    } else {
        'false'
    }
$privateValues['ALPACA_DATA_CACHING_PERMITTED'] =
    if ((Read-Host 'Does your Alpaca agreement expressly permit local data caching? Type YES') -ceq 'YES') {
        'true'
    } else {
        'false'
    }
$privateValues['TWELVE_DATA_RESEARCH_TERMS_CONFIRMED'] =
    if ((Read-Host 'Have you reviewed and confirmed Twelve Data personal-research terms? Type YES') -ceq 'YES') {
        'true'
    } else {
        'false'
    }
$privateValues['A_TRADER_ASSISTANT_ENABLED'] =
    if ((Read-Host 'Explicitly enable model explanations? Type YES') -ceq 'YES') {
        'true'
    } else {
        'false'
    }
$privateValues['ALPACA_LAN_DISPLAY_TERMS_CONFIRMED'] =
    if ((Read-Host 'Does your Alpaca agreement expressly permit display to the intended LAN users? Type YES') -ceq 'YES') {
        'true'
    } else {
        'false'
    }
$privateValues['TWELVE_DATA_LAN_RIGHTS_CONFIRMED'] =
    if ((Read-Host 'Have Twelve Data LAN display/sharing rights been expressly resolved for the intended users (personal research alone is insufficient)? Type YES') -ceq 'YES') {
        'true'
    } else {
        'false'
    }
$privateValues['A_TRADER_MODEL_FORWARDING_TERMS_CONFIRMED'] =
    if ((Read-Host 'Do applicable provider/model terms permit processing this market quote and your prompt? Type YES') -ceq 'YES') {
        'true'
    } else {
        'false'
    }

$privateValues['A_TRADER_SEC_TERMS_CONFIRMED'] =
    if ((Read-Host 'Have you reviewed SEC fair-access and metadata/model-processing permissions? Type YES (otherwise SEC stays disabled)') -ceq 'YES') {
        'true'
    } else {
        'false'
    }
if ($privateValues['A_TRADER_SEC_TERMS_CONFIRMED'] -eq 'true') {
    $secUserAgent = Read-Host 'Identifying SEC User-Agent: application name and real contact email'
    if ($secUserAgent -notmatch '^[^\r\n]+ [^\s@]+@[^\s@]+\.[^\s@]+$') {
        throw 'SEC User-Agent requires an application name and contact email.'
    }
    $privateValues['SEC_USER_AGENT'] = $secUserAgent
}

$openAiModel = Read-Host 'OpenAI model name (default gpt-5-mini)'
if (!$openAiModel) { $openAiModel = 'gpt-5-mini' }
$privateValues['OPENAI_MODEL'] = $openAiModel
Write-Output 'Start the LM Studio local server on loopback port 1234. Use only locally installed models; no downloads, hosted providers, or remote LM Link routes are enabled by these scripts.'
$privateValues['LM_STUDIO_LOCAL_ONLY_CONFIRMED'] =
    if ((Read-Host 'Have you disabled LM Link/remote routing and confirmed this LM Studio server uses only models on this computer? Type YES') -ceq 'YES') {
        'true'
    } else {
        'false'
    }
$lmStudioModel = Read-Host 'Exact local LM Studio model ID from /v1/models (default google/gemma-4-e4b; visibility does not verify loaded/inference-ready)'
if (!$lmStudioModel) { $lmStudioModel = 'google/gemma-4-e4b' }
if ($lmStudioModel) {
    if ($lmStudioModel -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._:/-]{0,199}$' -or
        $lmStudioModel -match '://') {
        throw 'A valid local LM Studio model ID is required.'
    }
    $privateValues['LM_STUDIO_MODEL'] = $lmStudioModel
}
$lmStudioEndpoint = Read-Host 'Local LM Studio OpenAI-compatible base URL (default http://127.0.0.1:1234/v1)'
if (!$lmStudioEndpoint) { $lmStudioEndpoint = 'http://127.0.0.1:1234/v1' }
$privateValues['LM_STUDIO_BASE_URL'] = $lmStudioEndpoint

$limitQuestions = @(
    @{ Name = 'A_TRADER_ASSISTANT_MAX_CALLS'; Prompt = 'Assistant maximum calls per server process (1-1000; default 10)'; Default = '10' },
    @{ Name = 'A_TRADER_ASSISTANT_MAX_CONCURRENT'; Prompt = 'Assistant maximum concurrent calls (1-20; default 2)'; Default = '2' },
    @{ Name = 'A_TRADER_ASSISTANT_MAX_INPUT_CHARS'; Prompt = 'Assistant maximum prompt characters (128-12000; default 4000)'; Default = '4000' },
    @{ Name = 'A_TRADER_ASSISTANT_MAX_OUTPUT_TOKENS'; Prompt = 'Assistant maximum output tokens (32-2048; default 512)'; Default = '512' },
    @{ Name = 'A_TRADER_ASSISTANT_TIMEOUT_SECONDS'; Prompt = 'Assistant timeout seconds (5-180; default 45)'; Default = '45' }
)
foreach ($limit in $limitQuestions) {
    $value = Read-Host $limit.Prompt
    if (!$value) { $value = $limit.Default }
    if ($value -notmatch '^\d+$') {
        throw "Invalid numeric value for $($limit.Name)."
    }
    $number = [int]$value
    switch ($limit.Name) {
        'A_TRADER_ASSISTANT_MAX_CALLS' {
            if ($number -lt 1 -or $number -gt 1000) { throw 'Assistant call cap must be between 1 and 1000.' }
        }
        'A_TRADER_ASSISTANT_MAX_CONCURRENT' {
            if ($number -lt 1 -or $number -gt 20) { throw 'Assistant concurrency cap must be between 1 and 20.' }
        }
        'A_TRADER_ASSISTANT_MAX_INPUT_CHARS' {
            if ($number -lt 128 -or $number -gt 12000) { throw 'Assistant input cap must be between 128 and 12000 characters.' }
        }
        'A_TRADER_ASSISTANT_MAX_OUTPUT_TOKENS' {
            if ($number -lt 32 -or $number -gt 2048) { throw 'Assistant output cap must be between 32 and 2048 tokens.' }
        }
        'A_TRADER_ASSISTANT_TIMEOUT_SECONDS' {
            if ($number -lt 5 -or $number -gt 180) { throw 'Assistant timeout must be between 5 and 180 seconds.' }
        }
    }
    $privateValues[$limit.Name] = $value
}

$configDirectory = Split-Path -Parent $script:ATraderPrivateConfigPath
New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
Protect-ATraderPrivatePath -Path $configDirectory
$json = $privateValues | ConvertTo-Json -Compress
$secureConfig = ConvertTo-SecureString -String $json -AsPlainText -Force
$encryptedConfig = ConvertFrom-SecureString -SecureString $secureConfig
[IO.File]::WriteAllText(
    $script:ATraderPrivateConfigPath,
    $encryptedConfig,
    [Text.UTF8Encoding]::new($false)
)
Protect-ATraderPrivatePath -Path $script:ATraderPrivateConfigPath
$privateValues.Clear()
$json = $null
$secureConfig.Dispose()
$encryptedConfig = $null
Write-Output 'Private configuration saved with Windows DPAPI for the current user.'
