$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$repositoryRoot = Split-Path -Parent $project
$destination = Join-Path $project 'dist\Zapret4Discord-Source-1.1.4.zip'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$files = [Collections.Generic.List[string]]::new()
foreach ($folder in @('src','scripts','installer','assets','licenses','tests')) {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $project $folder) -Recurse -File) {
        if ($file.FullName -match '[\\/](bin|obj)[\\/]') { continue }
        $files.Add($file.FullName)
    }
}
$files.Add((Join-Path $repositoryRoot 'docs\KULLANIM.txt'))
foreach ($folder in @('docs\images','docs\releases')) {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repositoryRoot $folder) -Recurse -File -ErrorAction SilentlyContinue) { $files.Add($file.FullName) }
}
foreach ($name in @('Build.ps1','Download-Upstream.ps1','Invoke-Management.ps1','Manage-DiscordOnly.ps1','Profile-Catalog.ps1','Profile-Operations.ps1','Hosts-Management.ps1','discord-domains.txt','discord-hosts.txt','profiles.json','upstream-manifest.json','verified-files.json','THIRD-PARTY-NOTICES.txt','KURULUM.txt','Verify-Filter.py','Verify-Discord.py','Start.cmd','Stop.cmd','Install.cmd','Uninstall.cmd','Status.cmd')) {
    $files.Add((Join-Path $project $name))
}
foreach ($name in @('.gitattributes','.gitignore','README.md')) { $files.Add((Join-Path $repositoryRoot $name)) }
$archive = [IO.Compression.ZipArchive]::new([IO.File]::Open($destination, [IO.FileMode]::Create), [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in ($files | Sort-Object)) {
        $relative = $file.Substring($repositoryRoot.Length + 1).Replace('\','/')
        $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]::new(2026,11,8,0,0,0,[TimeSpan]::Zero)
        $source = [IO.File]::OpenRead($file)
        $output = $entry.Open()
        try { $source.CopyTo($output) } finally { $output.Dispose(); $source.Dispose() }
    }
} finally { $archive.Dispose() }
$rows = foreach ($name in @('Zapret4Discord-Setup-1.1.4-x64.exe','Zapret4Discord-Source-1.1.4.zip')) {
    $path = Join-Path $project ('dist\' + $name)
    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $name
}
[IO.File]::WriteAllText((Join-Path $project 'dist\SHA256SUMS.txt'), (($rows -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
Get-Item -LiteralPath $destination | Select-Object FullName,Length
