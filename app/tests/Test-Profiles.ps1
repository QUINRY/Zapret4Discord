$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'Profile-Catalog.ps1')
. (Join-Path $project 'Hosts-Management.ps1')
. (Join-Path $project 'Profile-Operations.ps1')
Import-DiscordProfiles (Join-Path $project 'profiles.json')
if ($Script:Profiles.Count -ne 6) { throw 'Expected 6 unique profiles.' }
if (@($Script:Profiles.Id | Select-Object -Unique).Count -ne $Script:Profiles.Count) { throw 'Profile IDs must be unique.' }
$application = Join-Path $PSScriptRoot 'Zapret4Discord.Contracts\bin\Release\net48\Zapret4Discord.Contracts.exe'
$guiFingerprint = (& $application --fingerprint | Out-String).Trim()
if ((Get-ProfileNetworkFingerprint) -cne $guiFingerprint) { throw 'GUI and worker disagree on network identity; status colors would be invalid.' }
Write-Output 'PASS GUI and Windows PowerShell worker use identical network identity'
$fixture = Join-Path $project ('build\invalid-profile-' + [Guid]::NewGuid().ToString('N') + '.json')
$catalog = Get-Content -LiteralPath (Join-Path $project 'profiles.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$catalog.Profiles[0].Arguments = @('--wf-raw=true')
$catalog | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixture -Encoding UTF8
$rejected = $false
try { Import-DiscordProfiles $fixture } catch { $rejected = $true }
if (-not $rejected) { throw 'Catalog allowed a profile to widen the packet filter.' }
Write-Output 'PASS catalog refuses profiles that attempt to widen the packet filter'
Write-Output 'ALL PROFILE CONTRACTS PASSED'
