param()
$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'upstream-manifest.json') -Raw | ConvertFrom-Json
$downloaded = foreach ($entry in $manifest.files) {
    $destination = Join-Path $PSScriptRoot $entry.destination
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    $url = 'https://raw.githubusercontent.com/{0}/{1}/{2}' -f $manifest.repository, $manifest.commit, $entry.source
    Invoke-WebRequest -Uri $url -OutFile $destination -TimeoutSec 60
    $bytes = [IO.File]::ReadAllBytes($destination)
    if ($bytes.Length -ne $entry.size) { throw "Wrong size: $($entry.destination)" }
    $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $gitBytes = [byte[]]::new($header.Length + $bytes.Length)
    [Array]::Copy($header, 0, $gitBytes, 0, $header.Length)
    [Array]::Copy($bytes, 0, $gitBytes, $header.Length, $bytes.Length)
    $sha = [Security.Cryptography.SHA1]::Create()
    try { $gitHash = ([BitConverter]::ToString($sha.ComputeHash($gitBytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    if ($gitHash -ne $entry.gitBlobSha1) { throw "Git blob hash mismatch: $($entry.destination)" }
    [pscustomobject]@{ Path = $entry.destination; SHA256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash; GitBlobVerified = $true }
}
$downloaded | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'verified-files.json') -Encoding UTF8
$driver = Get-AuthenticodeSignature -LiteralPath (Join-Path $PSScriptRoot 'runtime/WinDivert64.sys')
if ($driver.Status -ne 'Valid') { throw "WinDivert driver signature is not valid: $($driver.Status)" }
$downloaded | ConvertTo-Json
$driver | Select-Object Status, @{Name='Signer';Expression={$_.SignerCertificate.Subject}} | ConvertTo-Json
