$ErrorActionPreference = 'Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    # Explicit setup only. Normal application requests never download packages.
    python -m venv .local\ddg-search
    if ($LASTEXITCODE -ne 0) { throw 'Python 3.10+ is required.' }
    & .local\ddg-search\Scripts\python.exe -m pip install -r scripts\ddg_requirements.txt
    if ($LASTEXITCODE -ne 0) { throw 'Pinned DuckDuckGo package installation failed.' }
    & .local\ddg-search\Scripts\python.exe -m pip check
    if ($LASTEXITCODE -ne 0) { throw 'DuckDuckGo dependency validation failed.' }
    Write-Host 'Installed search-only runtime. No search was made and no permission was accepted.'
    Write-Host 'Review docs\LOCAL_PROVIDER_SETUP.md before enabling the three explicit search flags.'
} finally {
    Pop-Location
}
