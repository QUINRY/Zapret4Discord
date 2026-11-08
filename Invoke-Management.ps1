param([ValidateSet('Install','Start','Stop','Refresh','Status','Uninstall','Probe')][string]$Action = 'Status')
$ErrorActionPreference = 'Stop'
$manager = if ($Action -eq 'Install') { Join-Path $PSScriptRoot 'Manage-DiscordOnly.ps1' } else { Join-Path $env:ProgramData 'ZapretDiscordOnly\Manage-DiscordOnly.ps1' }
if (-not (Test-Path -LiteralPath $manager)) { throw 'Discord-only installation is missing. Run Install.cmd first.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($admin -or $Action -in @('Status','Probe')) { & $manager -Action $Action; exit }
$arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $manager + '" -Action ' + $Action
$process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -Wait
if ($process.ExitCode -ne 0) {
    $result = Join-Path $PSScriptRoot 'logs\install-result.json'
    if ($Action -eq 'Install' -and (Test-Path -LiteralPath $result)) { Get-Content -LiteralPath $result }
    throw "Management action failed: $Action (exit $($process.ExitCode)). See C:\ProgramData\ZapretDiscordOnly\logs."
}
Write-Output ("Completed: " + $Action)
