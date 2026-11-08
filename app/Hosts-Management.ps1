# The caller supplies a protected state directory. The optional paths also permit
# fixture tests without touching the operating system's hosts file.
function Get-HostsDigest([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') } finally { $sha.Dispose() }
}

function Read-HostsDocument([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $skip = 0
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { $skip = 3 }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) { $encoding = [Text.Encoding]::Unicode; $skip = 2 }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255) { $encoding = [Text.Encoding]::BigEndianUnicode; $skip = 2 }
    try { $text = $encoding.GetString($bytes, $skip, $bytes.Length - $skip) } catch { $encoding = [Text.Encoding]::Default; $skip = 0; $text = $encoding.GetString($bytes) }
    $prefix = [byte[]]::new($skip)
    if ($skip) { [Array]::Copy($bytes, 0, $prefix, 0, $skip) }
    [pscustomobject]@{ Text=$text; Bytes=$bytes; Encoding=$encoding; Prefix=$prefix; Newline=if($text.Contains("`r`n")){"`r`n"}else{"`n"} }
}

function ConvertTo-HostsBytes($Document, [string]$Text) {
    $content = $Document.Encoding.GetBytes($Text)
    $bytes = [byte[]]::new($Document.Prefix.Length + $content.Length)
    if ($Document.Prefix.Length) { [Array]::Copy($Document.Prefix, 0, $bytes, 0, $Document.Prefix.Length) }
    [Array]::Copy($content, 0, $bytes, $Document.Prefix.Length, $content.Length)
    return ,$bytes
}

function Remove-DiscordHostsBlock([string]$Text) {
    $begin = '(?m)^# BEGIN Zapret4Discord hosts\r?$'
    $end = '(?m)^# END Zapret4Discord hosts\r?$'
    if ([regex]::Matches($Text, $begin).Count -ne [regex]::Matches($Text, $end).Count) { throw 'The managed hosts block is incomplete; refusing to change unrelated entries.' }
    return [regex]::Replace($Text, '(?ms)^# BEGIN Zapret4Discord hosts\r?\n.*?^# END Zapret4Discord hosts(?:\r?\n|$)', '')
}

function Set-HostsDocumentBytes([string]$Path, [byte[]]$Bytes) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing to replace a redirected hosts file.' }
    $temporary = $Path + '.Zapret4Discord.' + $PID + '.tmp'
    [IO.File]::WriteAllBytes($temporary, $Bytes)
    try { [IO.File]::Replace($temporary, $Path, [NullString]::Value) } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Write-HostsState([string]$Path, $State) {
    [IO.File]::WriteAllText($Path, ($State | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

function Get-DiscordHostMappings([string]$MappingsPath) {
    $allowed = @('www.discord.com','status.discord.com','discord.com','updates.discord.com','discord.gg','gateway.discord.gg','cdn.discordapp.com','discordapp.com','latency.discord.media','discord.media','discord.co')
    $mappings = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $MappingsPath) {
        if (-not $line.Trim() -or $line.TrimStart().StartsWith('#')) { continue }
        $tokens = $line.Trim() -split '\s+'
        $address = $null
        if ($tokens.Count -ne 2 -or $tokens[1] -notin $allowed -or -not [Net.IPAddress]::TryParse($tokens[0], [ref]$address)) { throw 'Invalid Discord hosts mapping.' }
        if ($mappings.Contains($tokens[1])) { throw 'Duplicate Discord hosts mapping.' }
        $mappings.Add($tokens[1], $address.IPAddressToString)
    }
    if ($mappings.Count -ne 11) { throw 'Exactly 11 requested Discord hosts mappings are required.' }
    return $mappings
}

function Ensure-DiscordHosts {
    param(
        [string]$HostsPath = (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'),
        [string]$StateDirectory = $Root,
        [string]$MappingsPath = (Join-Path $Root 'discord-hosts.txt')
    )
    $expected = Get-DiscordHostMappings $MappingsPath
    $document = Read-HostsDocument $HostsPath
    $outside = Remove-DiscordHostsBlock $document.Text
    $statePath = Join-Path $StateDirectory 'hosts-state.json'
    $backupPath = Join-Path $StateDirectory 'hosts.original'
    $state = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } else {
        [pscustomobject][ordered]@{ SchemaVersion=1; BackupSHA256=''; OriginalOutsideHash=''; HasConcurrentEdits=$false; DisplacedMappings=@(); ManagedAnyChanges=$false; CorrectCount=0; ManagedNames=@(); LastOutsideHash=''; VerifiedUtc='' }
    }
    $outsideHash = Get-HostsDigest (ConvertTo-HostsBytes $document $outside)
    if ($state.LastOutsideHash -and $state.LastOutsideHash -ne $outsideHash) { $state.HasConcurrentEdits = $true }
    $correct = @{}
    $conflicts = @()
    $builder = [Text.StringBuilder]::new()
    foreach ($match in [regex]::Matches($outside, '[^\r\n]+(?:\r\n|\n|\r|$)|(?:\r\n|\n|\r)')) {
        $rawLine = $match.Value
        $content = $rawLine.TrimEnd([char[]]"`r`n")
        $ending = $rawLine.Substring($content.Length)
        $entry = [regex]::Match($content, '^(\s*)(\S+)([ \t]+)([^#]*)(.*)$')
        $ip = $null
        if (-not $entry.Success -or -not [Net.IPAddress]::TryParse($entry.Groups[2].Value, [ref]$ip)) { $null = $builder.Append($rawLine); continue }
        $hostPart = $entry.Groups[4].Value
        foreach ($name in @($hostPart.Trim() -split '\s+')) {
            $domain = $name.ToLowerInvariant()
            if (-not $expected.Contains($domain)) { continue }
            if ($ip.IPAddressToString -eq $expected[$domain]) { $correct[$domain] = $true; continue }
            $conflicts += [pscustomobject]@{ Domain=$domain; Address=$ip.IPAddressToString }
            $hostPart = [regex]::Replace($hostPart, '(?i)(?<!\S)' + [regex]::Escape($name) + '(?=\s|$)', '')
        }
        if ($hostPart -eq $entry.Groups[4].Value) { $null = $builder.Append($rawLine) }
        elseif ($hostPart.Trim()) { $null = $builder.Append($entry.Groups[1].Value + $entry.Groups[2].Value + $entry.Groups[3].Value + $hostPart + $entry.Groups[5].Value + $ending) }
        else { $null = $builder.Append($entry.Groups[5].Value + $ending) }
    }
    $sanitized = $builder.ToString()
    $missing = @($expected.Keys | Where-Object { -not $correct.ContainsKey($_) })
    $newText = $sanitized
    if ($missing.Count) {
        if ($newText.Length -and -not $newText.EndsWith("`n") -and -not $newText.EndsWith("`r")) { $newText += $document.Newline }
        $newText += '# BEGIN Zapret4Discord hosts' + $document.Newline
        foreach ($name in $missing) { $newText += $expected[$name] + ' ' + $name + $document.Newline }
        $newText += '# END Zapret4Discord hosts' + $document.Newline
    }
    $newBytes = ConvertTo-HostsBytes $document $newText
    $changed = (Get-HostsDigest $newBytes) -ne (Get-HostsDigest $document.Bytes)
    if ($changed -and -not $state.BackupSHA256) {
        New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
        $original = ConvertTo-HostsBytes $document $outside
        [IO.File]::WriteAllBytes($backupPath, $original)
        $state.BackupSHA256 = Get-HostsDigest $original
        $state.HasConcurrentEdits = $false
    }
    if ($conflicts.Count) {
        $domains = @($conflicts.Domain)
        $state.DisplacedMappings = @(@($state.DisplacedMappings) | Where-Object { $_.Domain -notin $domains }) + $conflicts
    }
    $newOutside = Remove-DiscordHostsBlock $newText
    $state.LastOutsideHash = Get-HostsDigest (ConvertTo-HostsBytes $document $newOutside)
    if ($changed -and -not $state.OriginalOutsideHash) { $state.OriginalOutsideHash = $state.LastOutsideHash }
    $state.ManagedAnyChanges = $state.ManagedAnyChanges -or $changed
    $state.ManagedNames = @($missing)
    $state.CorrectCount = 11
    $state.VerifiedUtc = [DateTime]::UtcNow.ToString('o')
    Write-HostsState $statePath $state
    if ($changed) { Set-HostsDocumentBytes $HostsPath $newBytes }
    [pscustomobject]@{ CorrectCount=11; Changed=$changed; ManagedCount=$missing.Count }
}

function Restore-DiscordHosts {
    param([string]$HostsPath=(Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'), [string]$StateDirectory=$Root)
    $document = Read-HostsDocument $HostsPath
    $outside = Remove-DiscordHostsBlock $document.Text
    $statePath = Join-Path $StateDirectory 'hosts-state.json'
    $state = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    $backupPath = Join-Path $StateDirectory 'hosts.original'
    $outsideHash = Get-HostsDigest (ConvertTo-HostsBytes $document $outside)
    if ($state -and $state.ManagedAnyChanges -and -not $state.HasConcurrentEdits -and $outsideHash -eq $state.OriginalOutsideHash -and (Test-Path -LiteralPath $backupPath)) {
        $original = [IO.File]::ReadAllBytes($backupPath)
        if ((Get-HostsDigest $original) -ne $state.BackupSHA256) { throw 'Hosts backup failed verification; refusing to restore it.' }
        Set-HostsDocumentBytes $HostsPath $original
        return
    }
    if ($state) {
        foreach ($mapping in @($state.DisplacedMappings)) {
            $pattern = '(?im)^\s*[^#\s]+\s+[^#\r\n]*(?<!\S)' + [regex]::Escape($mapping.Domain) + '(?=\s|#|$)'
            if (-not [regex]::IsMatch($outside, $pattern)) {
                if ($outside.Length -and -not $outside.EndsWith("`n")) { $outside += $document.Newline }
                $outside += $mapping.Address + ' ' + $mapping.Domain + $document.Newline
            }
        }
    }
    if ($outside -ne $document.Text) { Set-HostsDocumentBytes $HostsPath (ConvertTo-HostsBytes $document $outside) }
}
