# Prepare the official compiler in portable mode inside this workspace.
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$toolRoot = Join-Path $workspace '.tools'
New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
$compiler = Join-Path $toolRoot 'InnoSetup\ISCC.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    $installer = Join-Path $toolRoot 'innosetup-7.1.1-x64.exe'
    Invoke-WebRequest -Uri 'https://github.com/jrsoftware/issrc/releases/download/is-7_1_1/innosetup-7.1.1-x64.exe' -OutFile $installer -TimeoutSec 120
    $expected = '8A5A6711C3766A6E5FB74F280BA0E3551E719CE94538D901FDBD1F8F9920B3F0'
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ne $expected) { throw 'Inno Setup download hash mismatch.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if ($signature.Status -ne 'Valid') { throw 'Inno Setup signature is not valid.' }
    $destination = Join-Path $toolRoot 'InnoSetup'
    $arguments = '/PORTABLE=1 /CURRENTUSER /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /NOICONS /DIR="' + $destination + '" /LOG="' + (Join-Path $toolRoot 'inno-install.log') + '"'
    $process = Start-Process -FilePath $installer -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait
    if ($process.ExitCode -ne 0) { throw "Could not prepare portable Inno Setup (exit $($process.ExitCode))." }
}
if (-not (Test-Path -LiteralPath $compiler)) { throw 'Inno Setup compiler was not found.' }
Write-Output $compiler
