[CmdletBinding()]
param([switch]$SkipTools)
$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$project = Join-Path $PSScriptRoot 'src\Zapret4Discord.App\Zapret4Discord.App.csproj'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$stage = Join-Path $PSScriptRoot 'build\stage-1.1.4'
$dist = Join-Path $PSScriptRoot 'dist'
if (-not $SkipTools) { & (Join-Path $PSScriptRoot 'scripts\Prepare-Tools.ps1') | Out-Host }
$compiler = Join-Path $PSScriptRoot '.tools\InnoSetup\ISCC.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'Inno Setup compiler is missing.' }
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'runtime\winws2.exe'))) { & (Join-Path $PSScriptRoot 'Download-Upstream.ps1') | Out-Host }
& (Join-Path $PSScriptRoot 'scripts\New-AppIcon.ps1')
& dotnet build $project -c Release --verbosity minimal
if ($LASTEXITCODE -ne 0) { throw 'Application build failed.' }
New-Item -ItemType Directory -Path $stage,$dist,(Join-Path $stage 'payload'),(Join-Path $stage 'licenses') -Force | Out-Null
$appFiles = Join-Path $PSScriptRoot 'src\Zapret4Discord.App\bin\Release\net48'
foreach ($name in @('Zapret4Discord.exe','Zapret4Discord.exe.config')) { Copy-Item -LiteralPath (Join-Path $appFiles $name) -Destination $stage -Force }
foreach ($name in @('Manage-DiscordOnly.ps1','Profile-Catalog.ps1','Profile-Operations.ps1','Hosts-Management.ps1','profiles.json','discord-hosts.txt','discord-domains.txt','upstream-manifest.json','verified-files.json','runtime')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $stage 'payload') -Recurse -Force
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'THIRD-PARTY-NOTICES.txt') -Destination $stage -Force
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'docs\KULLANIM.txt') -Destination (Join-Path $stage 'KURULUM.txt') -Force
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'licenses') -File | Copy-Item -Destination (Join-Path $stage 'licenses') -Force
& $compiler ('/DStageDir=' + $stage) ('/DOutputPath=' + $dist) (Join-Path $PSScriptRoot 'installer\Zapret4Discord.iss')
if ($LASTEXITCODE -ne 0) { throw 'Installer build failed.' }
$setup = Join-Path $dist 'Zapret4Discord-Setup-1.1.4-x64.exe'
$hash = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $dist 'SHA256SUMS.txt'), ($hash + '  ' + (Split-Path -Leaf $setup) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
Get-Item -LiteralPath $setup | Select-Object FullName,Length
