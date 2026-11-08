function Assert-ProfileTestNotCancelled {
    if ($Script:ProfileCancellationPath -and [IO.File]::Exists($Script:ProfileCancellationPath)) { throw [OperationCanceledException]::new('Profile check cancelled.') }
}

function Get-ProfileNetworkFingerprint {
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne [Net.NetworkInformation.OperationalStatus]::Up) { continue }
        try {
            $properties = $nic.GetIPProperties()
            $unicast = [string[]]@($properties.UnicastAddresses | ForEach-Object { $_.Address.ToString().ToLowerInvariant() })
            $gateways = [string[]]@($properties.GatewayAddresses | ForEach-Object { $_.Address.ToString().ToLowerInvariant() })
            $dns = [string[]]@($properties.DnsAddresses | ForEach-Object { $_.ToString().ToLowerInvariant() })
            [Array]::Sort($unicast, [StringComparer]::Ordinal); [Array]::Sort($gateways, [StringComparer]::Ordinal); [Array]::Sort($dns, [StringComparer]::Ordinal)
            $lines.Add($nic.Id.ToLowerInvariant() + ';' + ($unicast -join ',') + ';' + ($gateways -join ',') + ';' + ($dns -join ','))
        } catch { }
    }
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $lines.Add('hosts;' + [IO.File]::GetLastWriteTimeUtc($hosts).Ticks)
    $sorted = $lines.ToArray()
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return (Get-HostsDigest ([Text.Encoding]::UTF8.GetBytes(($sorted -join "`n")))).ToLowerInvariant()
}

function Receive-DiscordGatewayMessage($Socket, [Threading.CancellationToken]$Token) {
    $buffer = [byte[]]::new(4096)
    $stream = [IO.MemoryStream]::new()
    try {
        do {
            $fragment = $Socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), $Token).GetAwaiter().GetResult()
            if ($fragment.MessageType -ne [Net.WebSockets.WebSocketMessageType]::Text) { throw 'Gateway closed the connection or sent a non-text message.' }
            if ($stream.Length + $fragment.Count -gt 16384) { throw 'Gateway message exceeded the probe limit.' }
            $stream.Write($buffer, 0, $fragment.Count)
        } while (-not $fragment.EndOfMessage)
        return ([Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json)
    } finally { $stream.Dispose() }
}

function Invoke-DiscordWebSocketProbe {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $socket = [Net.WebSockets.ClientWebSocket]::new()
    $cancellation = [Threading.CancellationTokenSource]::new()
    $cancellation.CancelAfter(6500)
    $success = $false
    $detail = ''
    $pingMs = $null
    $pingSamples = [Collections.Generic.List[double]]::new()
    $pingError = ''
    try {
        $null = $socket.ConnectAsync([Uri]'wss://gateway.discord.gg/?v=10&encoding=json', $cancellation.Token).GetAwaiter().GetResult()
        $hello = Receive-DiscordGatewayMessage $socket $cancellation.Token
        $success = $socket.State -eq [Net.WebSockets.WebSocketState]::Open -and $hello.op -eq 10
        $detail = if ($success) { 'Anonymous Gateway Hello received.' } else { 'Gateway did not return Hello.' }
        if ($success) {
            try {
                $heartbeat = [ArraySegment[byte]]::new([Text.Encoding]::UTF8.GetBytes('{"op":1,"d":null}'))
                for ($sample = 0; $sample -lt 3; $sample++) {
                    Assert-ProfileTestNotCancelled
                    $roundTrip = [Diagnostics.Stopwatch]::StartNew()
                    $null = $socket.SendAsync($heartbeat, [Net.WebSockets.WebSocketMessageType]::Text, $true, $cancellation.Token).GetAwaiter().GetResult()
                    $acknowledgement = Receive-DiscordGatewayMessage $socket $cancellation.Token
                    $roundTrip.Stop()
                    if ($acknowledgement.op -ne 11) { throw 'Gateway heartbeat was not acknowledged.' }
                    $pingSamples.Add([Math]::Round($roundTrip.Elapsed.TotalMilliseconds, 2))
                    if ($sample -lt 2) { Start-Sleep -Milliseconds 100 }
                }
                $ordered = @($pingSamples | Sort-Object)
                $pingMs = [Math]::Round([double]$ordered[1], 1)
            } catch { $pingError = $_.Exception.Message }
        }
    } catch { $detail = $_.Exception.Message } finally { $socket.Abort(); $socket.Dispose(); $cancellation.Dispose() }
    [pscustomobject]@{ Url='wss://gateway.discord.gg/'; TLS='websocket'; Success=$success; ExitCode=if($success){0}else{1}; HttpCode=if($success){101}else{0}; DurationMs=$watch.ElapsedMilliseconds; Detail=$detail; PingMs=$pingMs; PingSamplesMs=@($pingSamples); PingError=$pingError }
}

function Read-ProfileChecksReport {
    $path = Join-Path $Root 'profile-checks.json'
    if (Test-Path -LiteralPath $path) {
        try { $report = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json; if ($report.SchemaVersion -eq 1) { return $report } } catch { }
    }
    [pscustomobject][ordered]@{ SchemaVersion=1; CatalogRevision=$Script:ProfileCatalog.Revision; OperationId=''; ScanState='idle'; CurrentProfileId=''; TotalCount=0; CompletedCount=0; WorkerId=0; WorkerStartTicks=0; UpdatedUtc=''; Restored=$true; Error=''; Results=@() }
}

function Save-ProfileChecksReport($Report) {
    $Report.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    Write-Json (Join-Path $Root 'profile-checks.json') $Report
}

function Add-ProfileCheckResult($Report, $Result) {
    $Report.Results = @(@($Report.Results) | Where-Object { $_ -and $_.ProfileId -cne $Result.ProfileId }) + @($Result)
    Save-ProfileChecksReport $Report
}

function Invoke-OneDiscordProfileCheck([string]$Id) {
    $result = [pscustomobject][ordered]@{ ProfileId=$Id; State='failed'; Passed=$false; CheckedUtc=''; NetworkFingerprint=''; CatalogRevision=$Script:ProfileCatalog.Revision; DurationMs=0; PingMs=$null; PingSamplesMs=@(); PingError=''; Error=''; Probes=@() }
    $process = $null
    $result.NetworkFingerprint = Get-ProfileNetworkFingerprint
    try {
        Assert-ProfileTestNotCancelled
        $configuration = Get-Configuration $Id
        Invoke-EngineCheck $configuration
        Invoke-EngineCheck $configuration -InitializeLua
        # Upstream blockcheck2 uses the same timer API to prevent orphaned engines.
        $guard = '--lua-init="timer_set(''profile_guard'',function()os.exit(3000)end,75000,true)"'
        $trial = $guard + [Environment]::NewLine + $configuration
        $path = Join-Path $Root 'profile-trial.conf'
        Write-Text $path $trial
        $process = Start-Process -FilePath (Join-Path $Root 'runtime\winws2.exe') -ArgumentList ('@' + $path) -WorkingDirectory (Join-Path $Root 'runtime') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $Root 'logs\profile-trial.stdout.log') -RedirectStandardError (Join-Path $Root 'logs\profile-trial.stderr.log')
        Write-Json (Join-Path $Root 'candidate-process.json') ([ordered]@{ Active=$true; ProcessId=$process.Id; StartTicks=$process.StartTime.ToUniversalTime().Ticks; ParentId=$PID })
        Start-Sleep -Milliseconds 450
        if ($process.HasExited) { throw 'Candidate engine could not start; see profile-trial logs.' }
        $network = Get-ProfileNetworkFingerprint
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $probes = @(Invoke-DiscordProbes)
        $result.DurationMs = $watch.ElapsedMilliseconds
        Assert-ProfileTestNotCancelled
        $result.Probes = $probes
        $gateway = $probes | Where-Object { $_.TLS -eq 'websocket' } | Select-Object -First 1
        if ($gateway.Success) {
            $result.PingMs = $gateway.PingMs
            $result.PingSamplesMs = @($gateway.PingSamplesMs)
            $result.PingError = $gateway.PingError
        }
        $result.NetworkFingerprint = $network
        if ($network -ne (Get-ProfileNetworkFingerprint)) { $result.State = 'network-changed'; $result.Error = 'Network changed during the check.' }
        else {
            $result.Passed = @($probes | Where-Object { -not $_.Success }).Count -eq 0 -and -not $process.HasExited
            $result.State = if ($result.Passed) { 'passed' } else { 'failed' }
            if (-not $result.Passed) { $result.Error = (@($probes | Where-Object { -not $_.Success } | ForEach-Object { $_.Url + ': ' + $_.Detail }) -join ' | ') }
        }
    } catch [OperationCanceledException] { $result.State = 'cancelled'; $result.Error = 'Cancelled.' }
    catch { $result.Error = $_.Exception.Message }
    finally {
        if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force; $process.WaitForExit(3000) | Out-Null }
        Write-Json (Join-Path $Root 'candidate-process.json') ([ordered]@{ Active=$false; ProcessId=0; StartTicks=0; ParentId=0 })
        $result.CheckedUtc = [DateTime]::UtcNow.ToString('o')
    }
    return $result
}

function Invoke-ProfileChecks {
    param([string]$OnlyProfile='', [string]$JobId=([Guid]::NewGuid().ToString('N')), [string]$CancellationPath='')
    if ($OnlyProfile -and -not $Script:Strategies.Contains($OnlyProfile)) { throw 'Unknown profile.' }
    $targets = if ($OnlyProfile) { @($OnlyProfile) } else { @($Script:Profiles.Id) }
    $null = Ensure-DiscordHosts
    $null = Update-ScopeFiles
    $service = Get-Service -Name $ServiceName
    $wasRunning = $service.Status -eq 'Running'
    $report = Read-ProfileChecksReport
    $report.CatalogRevision = $Script:ProfileCatalog.Revision
    $report.OperationId = $JobId
    $report.ScanState = 'testing'
    $report.CurrentProfileId = ''
    $report.TotalCount = $targets.Count
    $report.CompletedCount = 0
    $report.Restored = $false
    $report.Error = ''
    $report.WorkerId = $PID
    $report.WorkerStartTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
    $Script:ProfileCancellationPath = $CancellationPath
    Save-ProfileChecksReport $report
    try {
        if ($wasRunning) { Stop-Service -Name $ServiceName; (Get-Service -Name $ServiceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(12)) }
        foreach ($id in $targets) {
            Assert-ProfileTestNotCancelled
            $report.CurrentProfileId = $id
            Save-ProfileChecksReport $report
            Write-Event ('Checking isolated Discord profile: ' + $id)
            $result = Invoke-OneDiscordProfileCheck $id
            Add-ProfileCheckResult $report $result
            $report.CompletedCount++
            Save-ProfileChecksReport $report
            if ($result.State -eq 'cancelled') { throw [OperationCanceledException]::new('Cancelled.') }
        }
        $report.ScanState = 'completed'
    } catch [OperationCanceledException] { $report.ScanState = 'cancelled' }
    catch { $report.ScanState = 'failed'; $report.Error = $_.Exception.Message; throw }
    finally {
        $Script:ProfileCancellationPath = ''
        try {
            if ($wasRunning) { Start-Service -Name $ServiceName; (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(12)) }
            else { Stop-Service -Name $ServiceName -ErrorAction SilentlyContinue }
            $report.Restored = $true
        } catch { $report.Error = 'Could not restore the original service: ' + $_.Exception.Message; $report.ScanState = 'failed'; throw }
        finally { $report.CurrentProfileId = ''; Save-ProfileChecksReport $report }
    }
}

function Reset-OrphanedProfileCheck {
    $report = Read-ProfileChecksReport
    if ($report.ScanState -ne 'testing') { return }
    $owner = Get-Process -Id $report.WorkerId -ErrorAction SilentlyContinue
    if ($owner -and $owner.StartTime.ToUniversalTime().Ticks -eq $report.WorkerStartTicks) { return }
    $candidatePath = Join-Path $Root 'candidate-process.json'
    if (Test-Path -LiteralPath $candidatePath) {
        $candidate = Get-Content -LiteralPath $candidatePath -Raw | ConvertFrom-Json
        if ($candidate.Active) {
            $process = Get-Process -Id $candidate.ProcessId -ErrorAction SilentlyContinue
            $service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
            if ($process -and $process.Id -ne $service.ProcessId -and $process.StartTime.ToUniversalTime().Ticks -eq $candidate.StartTicks) {
                $record = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)"
                if ($record.ExecutablePath -eq (Join-Path $Root 'runtime\winws2.exe')) { Stop-Process -Id $process.Id -Force }
            }
        }
    }
    $report.ScanState = 'interrupted'
    $report.CurrentProfileId = ''
    $report.Error = 'Previous check was interrupted; normal service recovery resumed.'
    Save-ProfileChecksReport $report
}

function Set-SelectedDiscordProfile([string]$Id) {
    if (-not $Id -or -not $Script:Strategies.Contains($Id)) { throw 'Unknown profile.' }
    $configuration = Get-Configuration $Id
    Invoke-EngineCheck $configuration
    Invoke-EngineCheck $configuration -InitializeLua
    $previous = Read-Settings
    $wasRunning = (Get-Service -Name $ServiceName).Status -eq 'Running'
    $settings = Read-Settings
    $settings.Strategy = $Id
    $settings.Enabled = $true
    try {
        Write-Json (Join-Path $Root 'settings.json') $settings
        Start-ConfiguredService
        (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(12))
        Write-Event ('Selected Discord profile: ' + $Id)
    } catch {
        Write-Json (Join-Path $Root 'settings.json') $previous
        if ($wasRunning) { Start-ConfiguredService } else { Stop-Service -Name $ServiceName -ErrorAction SilentlyContinue }
        throw
    }
}
