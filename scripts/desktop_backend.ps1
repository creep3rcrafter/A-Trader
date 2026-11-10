param(
    [Parameter(Mandatory = $true)][int]$ParentProcessId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{48}$')][string]$ControlId,
    [switch]$Stop
)

$ErrorActionPreference = 'Stop'
$eventName = 'Local\ATraderBackend_' + $ParentProcessId + '_' + $ControlId
if ($Stop) {
    try {
        $signal = [Threading.EventWaitHandle]::OpenExisting($eventName)
        try { [void]$signal.Set() } finally { $signal.Dispose() }
        exit 0
    } catch {
        exit 1
    }
}
$child = $null
$owner = $null
$stopSignal = $null
try {
    $owner = [Diagnostics.Process]::GetProcessById($ParentProcessId)
    # Open and retain the handle so a recycled PID cannot become our owner.
    $null = $owner.Handle
    $created = $false
    $stopSignal = New-Object Threading.EventWaitHandle(
        $false, [Threading.EventResetMode]::ManualReset, $eventName, [ref]$created
    )
    if (!$created) { throw 'Duplicate backend control instance.' }
    . (Join-Path $PSScriptRoot 'private_config.ps1')
    Import-ATraderPrivateConfig
    $dartWrapper = Get-ATraderDartExecutable
    $dart = Join-Path (Split-Path -Parent $dartWrapper) 'cache\dart-sdk\bin\dart.exe'
    if (!(Test-Path -LiteralPath $dart -PathType Leaf)) {
        throw 'Dart SDK executable not found.'
    }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $dart
    # Invoke the VM directly, not dart run / a shell that could leave grandchildren.
    $info.Arguments = 'backend\bin\market_data_server.dart'
    $info.WorkingDirectory = Split-Path -Parent $PSScriptRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['A_TRADER_PORT'] = '8765'
    $info.EnvironmentVariables['A_TRADER_BIND_ADDRESS'] = '127.0.0.1'
    $info.EnvironmentVariables['A_TRADER_AUTH_ENABLED'] = 'false'
    $info.EnvironmentVariables.Remove('A_TRADER_WEB_ROOT')
    $info.EnvironmentVariables['A_TRADER_ALLOWED_ORIGIN'] = 'http://localhost:3000'
    $child = New-Object System.Diagnostics.Process
    $child.StartInfo = $info
    if (!$child.Start()) { throw 'Backend did not start.' }
    # Discard output; provider credentials and backend diagnostics never enter UI logs.
    $child.BeginOutputReadLine()
    $child.BeginErrorReadLine()
    [Console]::Out.WriteLine('STARTED')
    [Console]::Out.Flush()
    while (!$child.HasExited -and !$owner.HasExited -and !$stopSignal.WaitOne(200)) {}
} catch {
    [Console]::Out.WriteLine('FAILED')
} finally {
    if ($null -ne $child) {
        if (!$child.HasExited) {
            # The retained Process handle refers only to the child created above.
            $child.Kill()
            $child.WaitForExit()
        }
        $child.Dispose()
    }
    if ($null -ne $owner) { $owner.Dispose() }
    if ($null -ne $stopSignal) { $stopSignal.Dispose() }
}
