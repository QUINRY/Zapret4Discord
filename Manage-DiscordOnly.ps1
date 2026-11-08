[CmdletBinding()]
param(
    [ValidateSet('Install','Start','Stop','Refresh','Status','Uninstall','Probe','Prepare','Tune','Setup','TestProfiles','SelectProfile','Catalog')]
    [string]$Action = 'Status',
    [ValidatePattern('^[a-z0-9-]*$')][string]$ProfileId = '',
    [ValidatePattern('^[a-f0-9]{32}$')][string]$OperationId = ([Guid]::NewGuid().ToString('N')),
    [string]$CancelFile = ''
)

$ErrorActionPreference = 'Stop'
$ServiceName = 'ZapretDiscordOnly'
$TaskName = 'ZapretDiscordOnly-Refresh'
$InstallRoot = Join-Path $env:ProgramData 'ZapretDiscordOnly'
$Root = if ($Action -eq 'Prepare') { $PSScriptRoot } else { $InstallRoot }
$Utf8 = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'Profile-Catalog.ps1')
. (Join-Path $PSScriptRoot 'Hosts-Management.ps1')
Import-DiscordProfiles (Join-Path $PSScriptRoot 'profiles.json')

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Text([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $Utf8)
}

function Write-Json([string]$Path, $Value) {
    $temporary = $Path + '.' + $PID + '.new'
    Write-Text $temporary ($Value | ConvertTo-Json -Depth 10)
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        try {
            if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) } else { [IO.File]::Move($temporary, $Path) }
            return
        } catch { if ($attempt -eq 3) { throw }; Start-Sleep -Milliseconds 25 }
    }
}

function Write-Event([string]$Message) {
    $line = '{0} {1}' -f (Get-Date).ToString('o'), $Message
    Write-Host $line
    $log = Join-Path $Root 'logs\management.log'
    if (Test-Path -LiteralPath (Split-Path -Parent $log)) {
        if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 1048576) {
            Move-Item -LiteralPath $log -Destination ($log + '.previous') -Force
        }
        [IO.File]::AppendAllText($log, $line + [Environment]::NewLine, $Utf8)
    }
}

function Test-PublicAddress([string]$Address) {
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $false }
    if ([Net.IPAddress]::IsLoopback($parsed)) { return $false }
    $b = $parsed.GetAddressBytes()
    if ($b.Length -eq 4) {
        return -not ($b[0] -in @(0,10,127) -or $b[0] -ge 224 -or
            ($b[0] -eq 169 -and $b[1] -eq 254) -or
            ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
            ($b[0] -eq 192 -and $b[1] -eq 168) -or
            ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) -or
            ($b[0] -eq 198 -and $b[1] -in @(18,19)))
    }
    return ($b[0] -ge 0x20 -and $b[0] -le 0x3f)
}

function Resolve-Addresses([string[]]$Names) {
    foreach ($dnsName in $Names) {
        $parsed = $null
        if ([Net.IPAddress]::TryParse($dnsName, [ref]$parsed)) { $parsed.IPAddressToString; continue }
        try { [Net.Dns]::GetHostAddresses($dnsName) | ForEach-Object { $_.IPAddressToString } } catch { }
    }
}

function Get-VpnAddresses {
    $servers = @()
    foreach ($registryPath in @(
        'HKLM:\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels',
        'HKCU:\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels',
        'HKLM:\SOFTWARE\WOW6432Node\Fortinet\FortiClient\Sslvpn\Tunnels'
    )) {
        if (Test-Path -LiteralPath $registryPath) {
            foreach ($tunnel in Get-ChildItem -LiteralPath $registryPath) {
                $properties = Get-ItemProperty -LiteralPath $tunnel.PSPath
                $serverProperty = $properties.PSObject.Properties['Server']
                $value = if ($serverProperty) { [string]$serverProperty.Value } else { '' }
                foreach ($server in ($value -split '[;,\s]+')) {
                    if ($server) {
                        try { $servers += ([Uri]('https://' + ($server -replace '^https?://',''))).DnsSafeHost } catch { }
                    }
                }
            }
        }
    }
    $extra = Join-Path $Root 'vpn-exclusions.txt'
    if (Test-Path -LiteralPath $extra) {
        $servers += @(Get-Content -LiteralPath $extra | Where-Object { $_ -and -not $_.StartsWith('#') })
    }
    $fortiIds = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^Forti' } | Select-Object -ExpandProperty Id)
    if ($fortiIds.Count) {
        $servers += @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
            Where-Object { $_.OwningProcess -in $fortiIds } | Select-Object -ExpandProperty RemoteAddress)
    }
    @(Resolve-Addresses ($servers | Sort-Object -Unique) | Sort-Object -Unique)
}

function Get-TrafficScope {
    $adapters = @(Get-NetAdapter -Physical | Where-Object {
        $_.InterfaceDescription -notmatch 'Forti|Virtual|Tailscale|WireSock|VMware|Hyper-V|TAP|Tunnel'
    } | Sort-Object ifIndex)
    if (-not $adapters.Count) { throw 'No physical network adapter found; refusing to widen interception.' }
    $domains = @(Get-Content -LiteralPath (Join-Path $Root 'discord-domains.txt') |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($domains.Count -eq 0) { throw 'Discord hostlist is empty; refusing to run.' }
    $seeds = @('discord.com','discord.gg','discordapp.com','discordapp.net','discord.media','discordcdn.com',
        'dis.gd','discord.gift','gateway.discord.gg','cdn.discordapp.com','media.discordapp.net',
        'images-ext-1.discordapp.net','images-ext-2.discordapp.net','updates.discord.com',
        'stable.dl2.discordapp.net','canary.discord.com','ptb.discord.com','status.discord.com')
    if (Test-Path -LiteralPath (Join-Path $Root 'discord-hosts.txt')) { $seeds += @((Get-DiscordHostMappings (Join-Path $Root 'discord-hosts.txt')).Keys) }
    $cachedAddresses = @()
    foreach ($record in @(Get-DnsClientCache -ErrorAction SilentlyContinue)) {
        $entryName = [string]$record.Entry
        foreach ($domain in $domains) {
            if ($entryName -eq $domain -or $entryName.EndsWith('.' + $domain, [StringComparison]::OrdinalIgnoreCase)) {
                $seeds += $entryName
                if (Test-PublicAddress ([string]$record.Data)) { $cachedAddresses += [string]$record.Data }
                break
            }
        }
    }
    $vpn = @(Get-VpnAddresses)
    $addresses = @((@(Resolve-Addresses ($seeds | Sort-Object -Unique)) + $cachedAddresses) |
        Where-Object { (Test-PublicAddress $_) -and $_ -notin $vpn } | Sort-Object -Unique)
    if ($addresses.Count -eq 0) { throw 'Discord DNS resolution failed; refusing to capture all HTTPS traffic.' }
    [pscustomobject]@{ InterfaceIndexes = @($adapters.ifIndex); VpnExcluded = $vpn; DiscordAddresses = $addresses }
}

function Get-IpMatch([string[]]$Addresses, [ValidateSet('SrcAddr','DstAddr')][string]$Field) {
    $parts = foreach ($address in $Addresses) {
        $protocol = if ($address.Contains(':')) { 'ipv6' } else { 'ip' }
        "($protocol and $protocol.$Field == $address)"
    }
    if (-not @($parts).Count) { return 'false' }
    return '(' + ($parts -join ' or ') + ')'
}

function Get-IpExclusion([string[]]$Addresses, [ValidateSet('SrcAddr','DstAddr')][string]$Field) {
    $parts = foreach ($address in $Addresses) {
        $protocol = if ($address.Contains(':')) { 'ipv6' } else { 'ip' }
        "(not $protocol or $protocol.$Field != $address)"
    }
    if (-not @($parts).Count) { return 'true' }
    return '(' + ($parts -join ' and ') + ')'
}

function Get-RawFilter($Scope) {
    $interfaces = '(' + (($Scope.InterfaceIndexes | ForEach-Object { 'ifIdx == ' + $_ }) -join ' or ') + ')'
    $discordOut = Get-IpMatch $Scope.DiscordAddresses 'DstAddr'
    $discordIn = Get-IpMatch $Scope.DiscordAddresses 'SrcAddr'
    $vpnOut = Get-IpExclusion $Scope.VpnExcluded 'DstAddr'
    $vpnIn = Get-IpExclusion $Scope.VpnExcluded 'SrcAddr'
    $nonPrivate = foreach ($range in @(@('10.0.0.0','10.255.255.255'),@('100.64.0.0','100.127.255.255'),
        @('127.0.0.0','127.255.255.255'),@('169.254.0.0','169.254.255.255'),@('172.16.0.0','172.31.255.255'),
        @('192.168.0.0','192.168.255.255'),@('198.18.0.0','198.19.255.255'))) {
        '(ip.DstAddr < {0} or ip.DstAddr > {1})' -f $range[0],$range[1]
    }
    $publicOut = '((ip and ip.DstAddr >= 1.0.0.0 and ip.DstAddr < 224.0.0.0 and ' + ($nonPrivate -join ' and ') + ') or (ipv6 and ipv6.DstAddr >= 2000:: and ipv6.DstAddr < 4000::))'
    # Discord IP discovery v2: exact 74-byte request, type 1, length 70, empty address/port.
    # No generic STUN, QUIC, WireGuard, UDP/443, DTLS, game or VPN rule is included.
    $voice = '(udp and ((udp.DstPort >= 50000 and udp.DstPort <= 50099) or (udp.DstPort >= 19294 and udp.DstPort <= 19344)) and udp.PayloadLength == 74 and udp.Payload32[0] == 0x00010046'
    foreach ($word in 2..17) { $voice += " and udp.Payload32[$word] == 0" }
    $voice += ' and udp.Payload16[36] == 0)'
    $filter = "not loopback and not impostor and $interfaces and ((outbound and $vpnOut and $publicOut and ((tcp and tcp.DstPort == 443 and $discordOut and (tcp.PayloadLength > 0 or tcp.Syn or tcp.Fin or tcp.Rst)) or $voice)) or (inbound and $vpnIn and tcp and tcp.SrcPort == 443 and $discordIn and (tcp.Syn or tcp.Fin or tcp.Rst)))"
    if ($filter.Length -gt 15000) { throw 'Traffic filter exceeds safe length; refusing to widen it.' }
    return $filter
}

function Get-Configuration([string]$Strategy, [string]$DebugLog = '') {
    if (-not $Script:Strategies.Contains($Strategy)) { throw "Unknown strategy: $Strategy" }
    $base = $Root.Replace('\','/')
    $debug = if ($DebugLog) { '--debug=@' + $DebugLog.Replace('\','/') } else { '--debug=0' }
    $options = @($debug, '--comment=discord-only-v1', "--chdir=$base/runtime", "--wf-raw=@$base/discord.filter.txt",
        "--lua-init=@$base/runtime/lua/zapret-lib.lua", "--lua-init=@$base/runtime/lua/zapret-antidpi.lua")
    $profile = $Script:Profiles | Where-Object { $_.Id -ceq $Strategy } | Select-Object -First 1
    foreach ($initialization in @($profile.Init)) { $options += '--lua-init="' + $initialization + '"' }
    $options += @('--filter-tcp=443','--filter-l7=tls',"--hostlist=$base/discord-domains.txt",'--out-range=-d10','--payload=tls_client_hello')
    $options += $Script:Strategies[$Strategy]
    $options += @('--new','--filter-udp=19294-19344,50000-50099','--filter-l7=discord','--payload=discord_ip_discovery',
        '--lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=6')
    return ($options -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-ServiceBinaryPath([string]$Configuration) {
    return '"' + (Join-Path $Root 'runtime\winws2.exe') + '" ' + (($Configuration -split '[\r\n]+' | Where-Object { $_ }) -join ' ')
}

function Invoke-EngineCheck([string]$Configuration, [switch]$InitializeLua) {
    $checkFile = Join-Path $Root 'check.conf'
    $extra = if ($InitializeLua) { '--intercept=0' } else { '--dry-run' }
    # Even --dry-run claims the per-filter singleton. Use an inert filter for validation,
    # so a health check cannot conflict with the already-running service.
    $checkConfiguration = [regex]::Replace($Configuration, '(?m)^--wf-raw=[^\r\n]*', '--wf-raw=false')
    Write-Text $checkFile ($extra + [Environment]::NewLine + $checkConfiguration)
    $process = Start-Process -FilePath (Join-Path $Root 'runtime\winws2.exe') -ArgumentList ('@' + $checkFile) -WorkingDirectory (Join-Path $Root 'runtime') -WindowStyle Hidden -PassThru -Wait -RedirectStandardOutput (Join-Path $Root 'logs\check.stdout.log') -RedirectStandardError (Join-Path $Root 'logs\check.stderr.log')
    if ($process.ExitCode -ne 0) {
        throw ('Engine configuration rejected (exit {0}): {1} {2}' -f $process.ExitCode, (Get-Content -LiteralPath (Join-Path $Root 'logs\check.stdout.log') -Raw), (Get-Content -LiteralPath (Join-Path $Root 'logs\check.stderr.log') -Raw))
    }
}

function Invoke-WebProbe([string]$Url, [string]$TlsVersion = '') {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = "$env:SystemRoot\System32\curl.exe"
    $process.StartInfo.Arguments = '--noproxy "*" --connect-timeout 4 --max-time 6 --silent --show-error --output NUL --write-out "%{http_code}|%{remote_ip}|%{ssl_verify_result}" "' + $Url + '"'
    if ($TlsVersion -eq '1.2') { $process.StartInfo.Arguments = '--tls-max 1.2 ' + $process.StartInfo.Arguments }
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $null = $process.Start()
    if (-not $process.WaitForExit(9000)) { $process.Kill(); $process.WaitForExit() }
    $exitCode = $process.ExitCode
    $text = ($process.StandardError.ReadToEnd() + ' ' + $process.StandardOutput.ReadToEnd()).Trim()
    $process.Dispose()
    $match = [regex]::Match($text, '(\d{3})\|([^| ]*)\|(\d+)')
    $code = if ($match.Success) { [int]$match.Groups[1].Value } else { 0 }
    $expected = if ($Url -match '^https://(discord\.com/api/|updates\.discord\.com/)') { $code -eq 200 } else { $code -in @(200,400,403,404) }
    [pscustomobject]@{ Url=$Url; TLS=if($TlsVersion){$TlsVersion}else{'default'}; Success=($exitCode -eq 0 -and $expected); ExitCode=$exitCode; HttpCode=$code; DurationMs=$watch.ElapsedMilliseconds; Detail=$text }
}

function Invoke-DiscordProbes {
    foreach ($target in @('https://discord.com/api/v10/gateway','https://gateway.discord.gg/','https://cdn.discordapp.com/')) {
        Assert-ProfileTestNotCancelled
        Invoke-WebProbe $target
    }
    Assert-ProfileTestNotCancelled
    Invoke-WebProbe 'https://updates.discord.com/distributions/app/manifests/latest?channel=stable&platform=win&arch=x64' '1.2'
    Assert-ProfileTestNotCancelled
    Invoke-WebProbe 'https://discord.com/api/v10/gateway' '1.2'
    Assert-ProfileTestNotCancelled
    Invoke-DiscordWebSocketProbe
}

function Read-Settings {
    Get-Content -LiteralPath (Join-Path $Root 'settings.json') -Raw | ConvertFrom-Json
}

function Update-ScopeFiles {
    $scope = Get-TrafficScope
    $newFilter = Get-RawFilter $scope
    $filterPath = Join-Path $Root 'discord.filter.txt'
    $previous = if (Test-Path -LiteralPath $filterPath) { Get-Content -LiteralPath $filterPath -Raw } else { '' }
    Write-Json (Join-Path $Root 'scope.json') $scope
    if ($previous -ne $newFilter) { Write-Text $filterPath $newFilter; return $true }
    return $false
}

function Install-ProtectedFiles {
    param([switch]$AllowExisting)
    $existingService = Get-CimInstance Win32_Service -Filter "Name = '$ServiceName'" -ErrorAction SilentlyContinue
    if ($existingService) {
        if (-not $AllowExisting) { throw 'Already installed. Use Start, Stop or Uninstall before reinstalling.' }
        $pathMatch = [regex]::Match($existingService.PathName, '^\s*(?:"([^"]+)"|(\S+))')
        $existingExe = if ($pathMatch.Groups[1].Success) { $pathMatch.Groups[1].Value } else { $pathMatch.Groups[2].Value }
        $expectedExe = Join-Path $InstallRoot 'runtime\winws2.exe'
        if (-not $pathMatch.Success -or [IO.Path]::GetFullPath($existingExe) -ne [IO.Path]::GetFullPath($expectedExe)) { throw 'The service name belongs to another installation; refusing to replace it.' }
    }
    $verifiedSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'verified-files.json') -Raw | ConvertFrom-Json
    foreach ($file in $verifiedSource) {
        if ($file.Path.StartsWith('runtime/')) {
            $sourcePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $file.Path))
            if (-not $sourcePath.StartsWith([IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid runtime source path.' }
            if ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -ne $file.SHA256) { throw "Source file hash mismatch: $($file.Path)" }
        }
    }
    if (Test-Path -LiteralPath $InstallRoot) {
        if ((Get-Item -LiteralPath $InstallRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Install directory is a reparse point.' }
    }
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach ($entry in @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'),@('S-1-5-32-545','ReadAndExecute'))) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($entry[0]), [Security.AccessControl.FileSystemRights]$entry[1], [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit', [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $InstallRoot -AclObject $acl
    foreach ($item in @('discord-domains.txt','discord-hosts.txt','profiles.json','Profile-Catalog.ps1','Profile-Operations.ps1','Hosts-Management.ps1','Manage-DiscordOnly.ps1','upstream-manifest.json','verified-files.json')) {
        $sourceItem = Join-Path $PSScriptRoot $item
        if ([IO.Path]::GetFullPath($sourceItem) -ne [IO.Path]::GetFullPath((Join-Path $InstallRoot $item))) {
            Copy-Item -LiteralPath $sourceItem -Destination $InstallRoot -Force
        }
    }
    New-Item -ItemType Directory -Path (Join-Path $InstallRoot 'logs') -Force | Out-Null
    foreach ($file in (Get-Content -LiteralPath (Join-Path $InstallRoot 'verified-files.json') -Raw | ConvertFrom-Json)) {
        if ($file.Path.StartsWith('runtime/')) {
            $destination = Join-Path $InstallRoot $file.Path
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            $same = (Test-Path -LiteralPath $destination) -and ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -eq $file.SHA256)
            if (-not $same) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file.Path) -Destination $destination -Force }
            if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $file.SHA256) { throw "Installed file hash mismatch: $($file.Path)" }
        }
    }
    $driver = Get-AuthenticodeSignature -LiteralPath (Join-Path $InstallRoot 'runtime\WinDivert64.sys')
    if ($driver.Status -ne 'Valid') { throw 'Installed WinDivert signature is not valid.' }
    # Persist discovered exclusions so the SYSTEM refresh task also knows the current user's VPN gateways.
    $vpn = @(Get-VpnAddresses)
    Write-Text (Join-Path $InstallRoot 'vpn-exclusions.txt') (($vpn -join [Environment]::NewLine) + [Environment]::NewLine)
}

function Install-ForSetup {
    Install-ProtectedFiles -AllowExisting
    $Script:Root = $InstallRoot
    $settingsPath = Join-Path $Root 'settings.json'
    $existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existingService -and (Test-Path -LiteralPath $settingsPath)) {
        $settings = Read-Settings
        if ($settings.Strategy -in @('splitwire-vodafone','splitwire-telekom-mobile','kzm-tt-fiber','kzm-superonline','kzm-vodafone-seq','kzm-vodafone-tt','multisplit','multidisorder','hostfakesplit')) { $settings.Strategy = 'turkey-disorder' }
        if (-not $Script:Strategies.Contains([string]$settings.Strategy)) { throw 'Installed profile is not recognized. Existing service was left unchanged.' }
    } else {
        $settings = [pscustomobject][ordered]@{ Enabled=$true; Strategy='turkey-disorder'; InstalledAt=(Get-Date).ToString('o'); EngineVersion='zapret2 v1.0.7' }
    }
    $settings | Add-Member -NotePropertyName ManagerVersion -NotePropertyValue '1.1.4' -Force
    Write-Json $settingsPath $settings
    $null = Ensure-DiscordHosts
    $prepared = $true
    try { $null = Update-ScopeFiles } catch {
        $prepared = $false
        Write-Event ('Scope preparation deferred until the network is ready: ' + $_.Exception.Message)
        if (-not (Test-Path -LiteralPath (Join-Path $Root 'discord.filter.txt'))) {
            Write-Text (Join-Path $Root 'discord.filter.txt') 'false'
            Write-Json (Join-Path $Root 'scope.json') ([ordered]@{ InterfaceIndexes=@(); VpnExcluded=@(Get-VpnAddresses); DiscordAddresses=@() })
        }
    }
    $configuration = Get-Configuration $settings.Strategy
    Invoke-EngineCheck $configuration
    Invoke-EngineCheck $configuration -InitializeLua
    Write-Text (Join-Path $Root 'discord.conf') $configuration
    if (-not $existingService) {
        New-Service -Name $ServiceName -BinaryPathName (Get-ServiceBinaryPath $configuration) -DisplayName 'Zapret - Discord Only' -Description 'Discord SNI and exact Discord voice discovery only. FortiClient gateways and virtual interfaces excluded.' -StartupType Manual | Out-Null
    }
    Register-RefreshTask
    if ($prepared -and $settings.Enabled) {
        Start-ConfiguredService
        (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(10))
    }
    if (Test-Path -LiteralPath (Join-Path $Root 'profile-checks.json')) {
        $checks = Read-ProfileChecksReport
        $checks.Results = @($checks.Results | Where-Object { $Script:Strategies.Contains([string]$_.ProfileId) })
        $checks.CatalogRevision = $Script:ProfileCatalog.Revision
        $checks.TotalCount = $Script:Profiles.Count
        $checks.CompletedCount = $checks.Results.Count
        $checks.ScanState = 'idle'
        $checks.CurrentProfileId = ''
        $checks.OperationId = ''
        $checks.Restored = $true
        Save-ProfileChecksReport $checks
    }
    Write-Json (Join-Path $Root 'logs\setup-result.json') ([ordered]@{ Status='Configured'; ManagerVersion='1.1.4'; ExistingInstallation=([bool]$existingService); NetworkReady=$prepared; Enabled=$settings.Enabled; Strategy=$settings.Strategy; Time=(Get-Date).ToString('o') })
    Write-Event 'Desktop application setup completed. Existing profile and enabled state were preserved.'
}

function Register-RefreshTask {
    $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $InstallRoot 'Manage-DiscordOnly.ps1') + '" -Action Refresh'
    $taskAction = New-ScheduledTaskAction -Execute $exe -Argument $arguments -WorkingDirectory $InstallRoot
    $startup = New-ScheduledTaskTrigger -AtStartup
    $startup.Delay = 'PT30S'
    $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger @($startup,$repeat) -Principal $principal -Settings $settings -Description 'Refresh Discord-only destination IPs, physical adapter indexes and FortiClient exclusions. Does not change DNS or routes.' -Force | Out-Null
}

function Start-ConfiguredService {
    $settings = Read-Settings
    if (-not $settings.Enabled) { return }
    $null = Ensure-DiscordHosts
    $changed = Update-ScopeFiles
    $configuration = Get-Configuration $settings.Strategy
    Invoke-EngineCheck $configuration
    Write-Text (Join-Path $Root 'discord.conf') $configuration
    $serviceRecord = Get-CimInstance Win32_Service -Filter "Name = '$ServiceName'"
    $binaryPath = Get-ServiceBinaryPath $configuration
    if ($serviceRecord.PathName -ne $binaryPath) {
        $change = Invoke-CimMethod -InputObject $serviceRecord -MethodName Change -Arguments @{ PathName = $binaryPath }
        if ($change.ReturnValue -ne 0) { throw "Could not update service arguments (code $($change.ReturnValue))." }
        $changed = $true
    }
    $service = Get-Service -Name $ServiceName
    if ($changed -and $service.Status -eq 'Running') {
        Restart-Service -Name $ServiceName
        Write-Event 'Refreshed Discord traffic scope and restarted its service.'
    } elseif ($service.Status -ne 'Running') {
        Start-Service -Name $ServiceName
        Write-Event 'Started Discord-only service.'
    }
}

function Find-DiscordStrategy {
    Write-Event 'Starting restricted Discord-only strategy selection.'
    $null = Update-ScopeFiles
    $baseline = @(Invoke-DiscordProbes)
    Write-Json (Join-Path $Root 'logs\selection-baseline.json') $baseline
    $trials = @()
    $selected = $null
    foreach ($strategy in $Script:Strategies.Keys) {
        Write-Event ("Testing strategy: " + $strategy)
        $configuration = Get-Configuration $strategy (Join-Path $Root ('logs\trial-' + $strategy + '.debug.log'))
        Invoke-EngineCheck $configuration
        Invoke-EngineCheck $configuration -InitializeLua
        $trialPath = Join-Path $Root 'trial.conf'
        Write-Text $trialPath $configuration
        $process = $null
        try {
            $process = Start-Process -FilePath (Join-Path $Root 'runtime\winws2.exe') -ArgumentList ('@' + $trialPath) -WorkingDirectory (Join-Path $Root 'runtime') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $Root ('logs\trial-' + $strategy + '.stdout.log')) -RedirectStandardError (Join-Path $Root ('logs\trial-' + $strategy + '.stderr.log'))
            Start-Sleep -Milliseconds 600
            if ($process.HasExited) { $process.WaitForExit(); throw "Engine stopped before probes. See logs/trial-$strategy.debug.log and stdout/stderr logs." }
            $probes = @(Invoke-DiscordProbes)
            $passed = @($probes | Where-Object { -not $_.Success }).Count -eq 0
            $trials += [pscustomobject]@{ Strategy=$strategy; Passed=$passed; Probes=$probes }
            Write-Json (Join-Path $Root 'logs\strategy-results.json') $trials
            if ($passed) { $selected = $strategy; break }
        } finally {
            if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force; $process.WaitForExit(3000) | Out-Null }
        }
    }
    if (-not $selected) { throw 'No restricted strategy passed both Discord TLS 1.2 and modern TLS checks.' }
    return $selected
}

function Install-DiscordOnly {
    Install-ProtectedFiles
    $Script:Root = $InstallRoot
    $null = Ensure-DiscordHosts
    $selected = Find-DiscordStrategy
    Write-Json (Join-Path $Root 'settings.json') ([ordered]@{ Enabled=$true; Strategy=$selected; InstalledAt=(Get-Date).ToString('o'); EngineVersion='zapret2 v1.0.7' })
    $configuration = Get-Configuration $selected
    Invoke-EngineCheck $configuration
    Write-Text (Join-Path $Root 'discord.conf') $configuration
    $binaryPath = Get-ServiceBinaryPath $configuration
    New-Service -Name $ServiceName -BinaryPathName $binaryPath -DisplayName 'Zapret - Discord Only' -Description 'Discord SNI and exact Discord voice discovery only. FortiClient gateways and virtual interfaces excluded.' -StartupType Manual | Out-Null
    try {
        Register-RefreshTask
        Start-ConfiguredService
        (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(10))
        Start-Sleep -Milliseconds 1000
        $finalProbes = @(Invoke-DiscordProbes)
        Write-Json (Join-Path $Root 'logs\installed-probes.json') $finalProbes
        if (@($finalProbes | Where-Object { -not $_.Success }).Count) { throw 'Installed-service Discord probes failed.' }
    } catch {
        Stop-Service -Name $ServiceName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        & "$env:SystemRoot\System32\sc.exe" delete $ServiceName | Out-Null
        throw
    }
    Write-Event ("Installed and verified. Strategy: " + $selected)
    return [ordered]@{ Status='Installed'; Service=$ServiceName; Strategy=$selected; Root=$Root; Probes=$finalProbes; VpnConnectedTested=$false }
}

. (Join-Path $PSScriptRoot 'Profile-Operations.ps1')
if ($Action -eq 'Catalog') { $Script:ProfileCatalog | ConvertTo-Json -Depth 8; exit 0 }
if ($Action -eq 'Status') {
    $service = Get-CimInstance Win32_Service -Filter "Name = '$ServiceName'" -ErrorAction SilentlyContinue
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $settings = if (Test-Path -LiteralPath (Join-Path $Root 'settings.json')) { Read-Settings } else { $null }
    [pscustomobject]@{ Service=$service | Select-Object Name,State,StartMode,PathName; AutoStartTask=$task | Select-Object TaskName,State; Settings=$settings; InstallRoot=$InstallRoot } | ConvertTo-Json -Depth 6
    exit 0
}
if ($Action -eq 'Probe') { Invoke-DiscordProbes | ConvertTo-Json -Depth 5; exit 0 }
if ($Action -eq 'Prepare') {
    New-Item -ItemType Directory -Path (Join-Path $Root 'logs') -Force | Out-Null
    $null = Update-ScopeFiles
    foreach ($strategy in $Script:Strategies.Keys) { Write-Text (Join-Path $Root ($strategy + '.conf')) (Get-Configuration $strategy) }
    Get-Content -LiteralPath (Join-Path $Root 'scope.json')
    exit 0
}
if (-not (Test-Administrator)) { throw 'Administrator privileges are required for this action (WinDivert driver and service).' }

$mutex = [Threading.Mutex]::new($false, 'Global\ZapretDiscordOnly-Management')
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { if ($Action -eq 'Refresh') { exit 0 }; throw 'Another Discord-only management action is running.' }
    switch ($Action) {
        'Setup' { Install-ForSetup }
        'TestProfiles' { Invoke-ProfileChecks -OnlyProfile $ProfileId -JobId $OperationId -CancellationPath $CancelFile }
        'SelectProfile' { Set-SelectedDiscordProfile $ProfileId }
        'Install' {
            $result = Install-DiscordOnly
            Write-Json (Join-Path $PSScriptRoot 'logs\install-result.json') $result
            $result | ConvertTo-Json -Depth 8
        }
        'Start' {
            $settings = Read-Settings
            $settings.Enabled = $true
            Write-Json (Join-Path $Root 'settings.json') $settings
            Start-ConfiguredService
        }
        'Tune' {
            $originalSettings = Read-Settings
            Stop-Service -Name $ServiceName
            try {
                $selected = Find-DiscordStrategy
                $settings = Read-Settings
                $settings.Strategy = $selected
                $settings.Enabled = $true
                Write-Json (Join-Path $Root 'settings.json') $settings
                Start-ConfiguredService
                Start-Sleep -Seconds 1
                $probes = @(Invoke-DiscordProbes)
                Write-Json (Join-Path $Root 'logs\installed-probes.json') $probes
                if (@($probes | Where-Object { -not $_.Success }).Count) { throw 'Service failed TLS verification after tuning.' }
                Write-Event ('Retuned and verified TLS 1.2 and TLS 1.3: ' + $selected)
            } catch {
                Write-Json (Join-Path $Root 'settings.json') $originalSettings
                Start-ConfiguredService
                throw
            }
        }
        'Stop' {
            $settings = Read-Settings
            $settings.Enabled = $false
            Write-Json (Join-Path $Root 'settings.json') $settings
            Stop-Service -Name $ServiceName -ErrorAction SilentlyContinue
            Write-Event 'Stopped Discord-only service; automatic restarts disabled until Start.'
        }
        'Refresh' { Reset-OrphanedProfileCheck; Start-ConfiguredService }
        'Uninstall' {
            $settingsPath = Join-Path $Root 'settings.json'
            if (Test-Path -LiteralPath $settingsPath) {
                $settings = Read-Settings
                $settings.Enabled = $false
                Write-Json $settingsPath $settings
            }
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            Stop-Service -Name $ServiceName -ErrorAction SilentlyContinue
            Restore-DiscordHosts
            if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
                & "$env:SystemRoot\System32\sc.exe" delete $ServiceName | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'Could not remove Discord-only service.' }
            }
            Write-Event 'Uninstalled Discord-only service and autostart task. Files retained for inspection.'
        }
    }
} catch {
    if ($Action -eq 'Install') {
        Write-Json (Join-Path $PSScriptRoot 'logs\install-result.json') ([ordered]@{ Status='Failed'; Error=$_.Exception.Message; Time=(Get-Date).ToString('o') })
    }
    Write-Event ('ERROR: ' + $_.Exception.Message)
    throw
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
