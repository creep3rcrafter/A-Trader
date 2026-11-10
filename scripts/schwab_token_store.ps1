param(
    [Parameter(Mandatory = $true)][ValidateSet('Read', 'Write')][string]$Operation,
    [string]$StoreDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'schwab_private.ps1')
if (!$StoreDirectory) { $StoreDirectory = $script:SchwabDirectory }
try {
    $path = Join-Path $StoreDirectory 'tokens.dpapi'
    if ($Operation -eq 'Read') {
        $value = Read-ATraderProtectedJson $path
        if ($null -eq $value) { [Console]::Out.Write('null') }
        else { [Console]::Out.Write(($value | ConvertTo-Json -Compress -Depth 8)) }
    } else {
        $json = [Console]::In.ReadToEnd()
        $null = ConvertFrom-Json $json
        Write-ATraderProtectedJson $path $json
    }
} catch {
    [Console]::Error.WriteLine('Private token storage failed.')
    exit 1
}
