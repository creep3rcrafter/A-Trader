$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path $root ('.desktop_backend_test_' + [Guid]::NewGuid().ToString('N'))
$supervisor = $null
$external = $null
$ownedId = $null
function Assert-DesktopTest {
    param([bool]$Condition, [string]$Message)
    if (!$Condition) { throw $Message }
}
function Start-FixtureProcess {
    param([string]$Executable, [string]$Arguments, [string]$WorkingDirectory)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = $Arguments
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['A_TRADER_BIND_ADDRESS'] = '0.0.0.0'
    $info.EnvironmentVariables['A_TRADER_PORT'] = '9999'
    $info.EnvironmentVariables['A_TRADER_AUTH_ENABLED'] = 'true'
    $info.EnvironmentVariables['A_TRADER_WEB_ROOT'] = 'unsafe'
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    [void]$process.Start()
    return $process
}
try {
    # No private config is read: a standalone Dart fixture replaces the backend.
    New-Item -ItemType Directory -Path (Join-Path $scratch 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $scratch 'backend\bin') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $scratch '.dart_tool') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $scratch 'external') -Force | Out-Null
    '{"configVersion":2,"packages":[]}' | Set-Content -LiteralPath (Join-Path $scratch '.dart_tool\package_config.json')
    '' | Set-Content -LiteralPath (Join-Path $scratch 'fixture.only')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'desktop_backend.ps1') -Destination (Join-Path $scratch 'scripts')
    $sdk = $env:A_TRADER_FLUTTER_ROOT
    if (!$sdk) { $sdk = $env:FLUTTER_ROOT }
    if (!$sdk) { $sdk = 'C:\Users\brend\FlutterSDK\flutter' }
    $wrapper = Join-Path $sdk 'bin\dart.bat'
    $dart = Join-Path $sdk 'bin\cache\dart-sdk\bin\dart.exe'
    Assert-DesktopTest (Test-Path -LiteralPath $dart) 'Dart SDK required for fixture test.'
    $escapedWrapper = $wrapper.Replace("'", "''")
    @"
function Import-ATraderPrivateConfig {}
function Get-ATraderDartExecutable { return '$escapedWrapper' }
"@ | Set-Content -LiteralPath (Join-Path $scratch 'scripts\private_config.ps1') -Encoding UTF8
    @'
import 'dart:async';
import 'dart:convert';
import 'dart:io';
void main() {
  File('child.json').writeAsStringSync(jsonEncode({
    'pid': pid,
    'bind': Platform.environment['A_TRADER_BIND_ADDRESS'],
    'port': Platform.environment['A_TRADER_PORT'],
    'auth': Platform.environment['A_TRADER_AUTH_ENABLED'],
    'webRoot': Platform.environment['A_TRADER_WEB_ROOT'],
  }));
  Timer.periodic(const Duration(seconds: 1), (_) {});
}
'@ | Set-Content -LiteralPath (Join-Path $scratch 'backend\bin\market_data_server.dart') -Encoding UTF8
    $fixture = Join-Path $scratch 'backend\bin\market_data_server.dart'
    $external = Start-FixtureProcess $dart ('"' + $fixture + '"') (Join-Path $scratch 'external')
    $hostScript = Join-Path $PSScriptRoot 'desktop_backend_test_host.dart'
    for ($iteration = 0; $iteration -lt 2; $iteration++) {
        $supervisor = Start-FixtureProcess $dart ('"' + $hostScript + '" "' + $scratch + '"') $scratch
        $lineTask = $supervisor.StandardOutput.ReadLineAsync()
        Assert-DesktopTest ($lineTask.Wait(15000)) 'Supervisor handshake timed out.'
        Assert-DesktopTest ($lineTask.Result -eq 'STARTED') 'Supervisor did not start fixture.'
        $record = Join-Path $scratch 'child.json'
        for ($retry = 0; $retry -lt 100 -and !(Test-Path -LiteralPath $record); $retry++) {
            Start-Sleep -Milliseconds 100
        }
        Assert-DesktopTest (Test-Path -LiteralPath $record) 'Dart fixture did not run.'
        $state = Get-Content -Raw -LiteralPath $record | ConvertFrom-Json
        $ownedId = [int]$state.pid
        Assert-DesktopTest ($state.bind -eq '127.0.0.1') 'Inherited LAN bind was not overridden.'
        Assert-DesktopTest ($state.port -eq '8765') 'Inherited port was not overridden.'
        Assert-DesktopTest ($state.auth -eq 'false') 'Inherited authentication was not overridden.'
        Assert-DesktopTest ($null -eq $state.webRoot) 'Inherited web root must be absent, not an empty build path.'
        Assert-DesktopTest ($null -ne (Get-Process -Id $ownedId -ErrorAction SilentlyContinue)) 'Owned child is not running.'
        if ($iteration -eq 0) {
            # Exercise the actual Dart controller's explicit Stop.
            $supervisor.StandardInput.WriteLine('stop')
            $supervisor.StandardInput.Flush()
        } else {
            # Terminate only our fixture host to simulate abrupt desktop app exit.
            $supervisor.Kill()
        }
        if (!$supervisor.WaitForExit(10000)) {
            $diagnostic = $supervisor.StandardOutput.ReadLineAsync()
            $progress = if ($diagnostic.Wait(1000)) { $diagnostic.Result } else { 'no stop received' }
            throw "Fixture host did not exit (iteration $iteration, progress: $progress)."
        }
        for ($retry = 0; $retry -lt 100 -and $null -ne (Get-Process -Id $ownedId -ErrorAction SilentlyContinue); $retry++) {
            Start-Sleep -Milliseconds 100
        }
        Assert-DesktopTest ($null -eq (Get-Process -Id $ownedId -ErrorAction SilentlyContinue)) 'Owned child survived Stop.'
        $external.Refresh()
        Assert-DesktopTest (!$external.HasExited) 'Unrelated process was terminated.'
        $ownedId = $null
        $supervisor.Dispose()
        $supervisor = $null
        Remove-Item -LiteralPath $record
    }
    Write-Output 'PASS: actual Dart controller start/stop, abrupt host exit cleanup, inherited environment isolation, unrelated process preserved.'
} finally {
    if ($null -ne $supervisor) {
        $supervisor.StandardInput.Close()
        if (!$supervisor.WaitForExit(10000)) { $supervisor.Kill() }
        $supervisor.Dispose()
    }
    if ($null -ne $ownedId) {
        Stop-Process -Id $ownedId -ErrorAction SilentlyContinue
    }
    if ($null -ne $external) {
        if (!$external.HasExited) { $external.Kill(); $external.WaitForExit() }
        $external.Dispose()
    }
    for ($retry = 0; $retry -lt 100 -and (Test-Path -LiteralPath $scratch); $retry++) {
        try {
            Remove-Item -LiteralPath $scratch -Recurse -Force
        } catch {
            if ($retry -eq 99) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
}
