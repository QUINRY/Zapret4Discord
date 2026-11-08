$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. (Join-Path $workspace 'Hosts-Management.ps1')
$mappingFile = Join-Path $workspace 'discord-hosts.txt'
$fixtureRoot = Join-Path $workspace ('build\hosts-fixtures-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
function Assert-Contract([bool]$Condition, [string]$Name) { if (-not $Condition) { throw ('FAIL ' + $Name) }; Write-Output ('PASS ' + $Name) }
function New-Fixture([string]$Name, [string]$Content, [Text.Encoding]$Encoding=([Text.UTF8Encoding]::new($false))) {
    $directory = Join-Path $fixtureRoot $Name
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $path = Join-Path $directory 'hosts'
    [IO.File]::WriteAllText($path, $Content, $Encoding)
    [pscustomobject]@{ Directory=$directory; Path=$path; Original=[IO.File]::ReadAllBytes($path) }
}
$original = "# user configuration`r`n127.0.0.1 localhost`r`n203.0.113.10 discord.com vpn.example # keep this alias`r`n104.17.117.93 discord.co`r`n"
$fixture = New-Fixture 'restore' $original
$result = Ensure-DiscordHosts -HostsPath $fixture.Path -StateDirectory $fixture.Directory -MappingsPath $mappingFile
$text = [IO.File]::ReadAllText($fixture.Path)
Assert-Contract ($result.CorrectCount -eq 11 -and $result.ManagedCount -eq 10) 'all requested mappings present; existing correct entry remains user-owned'
Assert-Contract ($text -match '203\.0\.113\.10\s+vpn\.example # keep this alias') 'unrelated alias and comment survive a conflicting Discord entry'
$firstHash = Get-HostsDigest ([IO.File]::ReadAllBytes($fixture.Path))
$null = Ensure-DiscordHosts -HostsPath $fixture.Path -StateDirectory $fixture.Directory -MappingsPath $mappingFile
Assert-Contract ($firstHash -eq (Get-HostsDigest ([IO.File]::ReadAllBytes($fixture.Path)))) 'second ensure is byte-for-byte idempotent'
Restore-DiscordHosts -HostsPath $fixture.Path -StateDirectory $fixture.Directory
Assert-Contract ((Get-HostsDigest $fixture.Original) -eq (Get-HostsDigest ([IO.File]::ReadAllBytes($fixture.Path)))) 'uninstall restores exact original bytes when no concurrent edits exist'
$fixture = New-Fixture 'concurrent' $original
$null = Ensure-DiscordHosts -HostsPath $fixture.Path -StateDirectory $fixture.Directory -MappingsPath $mappingFile
[IO.File]::AppendAllText($fixture.Path, "10.0.0.99 corp-added.internal`r`n# later user edit`r`n")
Restore-DiscordHosts -HostsPath $fixture.Path -StateDirectory $fixture.Directory
$text = [IO.File]::ReadAllText($fixture.Path)
Assert-Contract ($text.Contains('corp-added.internal') -and $text.Contains('# later user edit')) 'uninstall preserves edits added after installation'
Assert-Contract ($text -match '(?m)^203\.0\.113\.10 discord\.com\r?$') 'displaced Discord entry restored without replacing later edits'
Assert-Contract (-not $text.Contains('# BEGIN Zapret4Discord hosts')) 'owned block removed on uninstall'
$fixture = New-Fixture 'already-present' ((Get-Content -LiteralPath $mappingFile -Raw) + "`n10.20.30.40 corporate.internal`n")
$result = Ensure-DiscordHosts -HostsPath $fixture.Path -StateDirectory $fixture.Directory -MappingsPath $mappingFile
Assert-Contract (-not $result.Changed -and $result.ManagedCount -eq 0) 'all 11 existing user entries require no file change'
Restore-DiscordHosts -HostsPath $fixture.Path -StateDirectory $fixture.Directory
Assert-Contract ((Get-HostsDigest $fixture.Original) -eq (Get-HostsDigest ([IO.File]::ReadAllBytes($fixture.Path)))) 'uninstall leaves pre-existing requested entries intact'
$fixture = New-Fixture 'utf8-bom' "# Türkçe açıklama`r`n127.0.0.1 localhost`r`n" ([Text.UTF8Encoding]::new($true))
$null = Ensure-DiscordHosts -HostsPath $fixture.Path -StateDirectory $fixture.Directory -MappingsPath $mappingFile
Restore-DiscordHosts -HostsPath $fixture.Path -StateDirectory $fixture.Directory
Assert-Contract ((Get-HostsDigest $fixture.Original) -eq (Get-HostsDigest ([IO.File]::ReadAllBytes($fixture.Path)))) 'Unicode comments and BOM survive the full lifecycle'
Write-Output 'ALL HOSTS LIFECYCLE CONTRACTS PASSED'
