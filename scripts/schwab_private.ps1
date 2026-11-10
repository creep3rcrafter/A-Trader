$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'private_config.ps1')
$script:SchwabDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) '.local\schwab'

function Read-ATraderProtectedJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $secure = $null
    try {
        $secure = ConvertTo-SecureString ([IO.File]::ReadAllText($Path))
        return (ConvertFrom-Json (ConvertFrom-ATraderSecureString $secure))
    } finally {
        if ($null -ne $secure) { $secure.Dispose() }
    }
}

function Write-ATraderProtectedJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Json
    )
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Protect-ATraderPrivatePath $directory
    $pending = Join-Path $directory ([Guid]::NewGuid().ToString('N') + '.pending')
    $secure = $null
    try {
        $secure = ConvertTo-SecureString $Json -AsPlainText -Force
        $encrypted = ConvertFrom-SecureString $secure
        [IO.File]::WriteAllText($pending, $encrypted, [Text.UTF8Encoding]::new($false))
        Protect-ATraderPrivatePath $pending
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($pending, $Path, [NullString]::Value)
        } else {
            [IO.File]::Move($pending, $Path)
        }
    } finally {
        if ($null -ne $secure) { $secure.Dispose() }
        if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending -Force }
    }
}

function New-ATraderSchwabTlsBundle {
    $certificate = $null
    try {
        $certificate = New-SelfSignedCertificate -Subject 'CN=A-Trader local Schwab callback' `
            -FriendlyName ('A-Trader callback ' + [Guid]::NewGuid().ToString('N')) `
            -CertStoreLocation 'Cert:\CurrentUser\My' -KeyAlgorithm RSA -KeyLength 2048 `
            -KeyExportPolicy Exportable -HashAlgorithm SHA256 `
            -NotAfter (Get-Date).AddDays(90) `
            -TextExtension @('2.5.29.17={text}IPAddress=127.0.0.1', '2.5.29.37={text}1.3.6.1.5.5.7.3.1')
        $password = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
        $pfx = $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $password)
        return @{
            pfx = [Convert]::ToBase64String($pfx)
            password = $password
            thumbprint = $certificate.Thumbprint
            expiresUtc = $certificate.NotAfter.ToUniversalTime().ToString('o')
        }
    } finally {
        if ($null -ne $certificate) {
            Remove-Item -LiteralPath ('Cert:\CurrentUser\My\' + $certificate.Thumbprint) -DeleteKey -Force
        }
    }
}
