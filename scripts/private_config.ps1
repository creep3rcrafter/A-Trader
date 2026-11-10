$script:ATraderPrivateConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) '.local\private_config.dpapi'
$script:ATraderAllowedConfigNames = @(
    'SCHWAB_CLIENT_ID',
    'SCHWAB_CLIENT_SECRET',
    'SCHWAB_MARKET_DATA_TERMS_CONFIRMED',
    'SCHWAB_LAN_DISPLAY_TERMS_CONFIRMED',
    'ALPACA_API_KEY_ID',
    'ALPACA_API_SECRET_KEY',
    'ALPACA_MARKET_DATA_TERMS_CONFIRMED',
    'ALPACA_LAN_DISPLAY_TERMS_CONFIRMED',
    'ALPACA_DATA_CACHING_PERMITTED',
    'TWELVE_DATA_API_KEY',
    'TWELVE_DATA_RESEARCH_TERMS_CONFIRMED',
    'TWELVE_DATA_LAN_RIGHTS_CONFIRMED',
    'A_TRADER_MARKET_DATA_PROVIDER',
    'OPENAI_API_KEY',
    'OPENAI_MODEL',
    'LM_STUDIO_MODEL',
    'LM_STUDIO_API_TOKEN',
    'LM_STUDIO_BASE_URL',
    'LM_STUDIO_LOCAL_ONLY_CONFIRMED',
    'A_TRADER_ASSISTANT_ENABLED',
    'A_TRADER_MODEL_FORWARDING_TERMS_CONFIRMED',
    'A_TRADER_SEC_TERMS_CONFIRMED',
    'SEC_USER_AGENT',
    'A_TRADER_ASSISTANT_MAX_CALLS',
    'A_TRADER_ASSISTANT_MAX_CONCURRENT',
    'A_TRADER_ASSISTANT_MAX_INPUT_CHARS',
    'A_TRADER_ASSISTANT_MAX_OUTPUT_TOKENS',
    'A_TRADER_ASSISTANT_TIMEOUT_SECONDS',
    'A_TRADER_AUTH_PASSWORD'
)

function ConvertFrom-ATraderSecureString {
    param([Parameter(Mandatory = $true)][Security.SecureString]$SecureValue)
    $pointer = [IntPtr]::Zero
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
    }
}

function Import-ATraderPrivateConfig {
    param(
        [string]$Path = $script:ATraderPrivateConfigPath
    )
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    try {
        $encrypted = [IO.File]::ReadAllText($Path)
        $secureValue = ConvertTo-SecureString -String $encrypted
        $plainText = ConvertFrom-ATraderSecureString -SecureValue $secureValue
        $config = ConvertFrom-Json -InputObject $plainText
        foreach ($name in $script:ATraderAllowedConfigNames) {
            $property = $config.PSObject.Properties[$name]
            $current = [Environment]::GetEnvironmentVariable($name, 'Process')
            if ($null -ne $property -and ($null -eq $current -or $current.Length -eq 0)) {
                [Environment]::SetEnvironmentVariable(
                    $name,
                    [string]$property.Value,
                    'Process'
                )
            }
        }
    } catch {
        throw 'Unable to decrypt the private A-Trader configuration for this Windows user. Run scripts\setup_local.ps1 again.'
    } finally {
        $plainText = $null
        $secureValue = $null
        $encrypted = $null
        $config = $null
    }
}

function Protect-ATraderPrivatePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $isDirectory = (Get-Item -LiteralPath $Path).PSIsContainer
    # Build a DACL, not a copied audit descriptor requiring SeSecurityPrivilege.
    # A fresh descriptor also removes any pre-existing explicit grants.
    $acl = if ($isDirectory) {
        New-Object Security.AccessControl.DirectorySecurity
    } else {
        New-Object Security.AccessControl.FileSecurity
    }
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($identity)
    $rights = [Security.AccessControl.FileSystemRights]::FullControl
    if ($isDirectory) {
        $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [Security.AccessControl.InheritanceFlags]::ObjectInherit
        $propagation = [Security.AccessControl.PropagationFlags]::None
    } else {
        $inheritance = [Security.AccessControl.InheritanceFlags]::None
        $propagation = [Security.AccessControl.PropagationFlags]::None
    }
    $rule = New-Object Security.AccessControl.FileSystemAccessRule(
        $identity,
        $rights,
        $inheritance,
        $propagation,
        [Security.AccessControl.AccessControlType]::Allow
    )
    $acl.SetAccessRule($rule)
    if ($isDirectory) {
        [IO.Directory]::SetAccessControl($Path, $acl)
    } else {
        [IO.File]::SetAccessControl($Path, $acl)
    }
}

function Get-ATraderFlutterExecutable {
    $root = $env:A_TRADER_FLUTTER_ROOT
    if (!$root) { $root = $env:FLUTTER_ROOT }
    if (!$root) { $root = 'C:\Users\brend\FlutterSDK\flutter' }
    $candidate = Join-Path $root 'bin\flutter.bat'
    if (!(Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Flutter executable not found. Set A_TRADER_FLUTTER_ROOT to its installation directory."
    }
    return $candidate
}

function Get-ATraderDartExecutable {
    $root = $env:A_TRADER_FLUTTER_ROOT
    if (!$root) { $root = $env:FLUTTER_ROOT }
    if (!$root) { $root = 'C:\Users\brend\FlutterSDK\flutter' }
    $candidate = Join-Path $root 'bin\dart.bat'
    if (!(Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Dart executable not found. Set A_TRADER_FLUTTER_ROOT to its installation directory."
    }
    return $candidate
}
