[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$grokHome = if ($env:GROK_HOME) { $env:GROK_HOME } else { Join-Path $env:USERPROFILE '.grok' }
. (Join-Path $PSScriptRoot 'scripts\monitor-task.ps1')
$task = Get-ScheduledTask -TaskName 'GrokHudMonitor' -ErrorAction SilentlyContinue
if ($task) {
    if ($task.Description -ne 'Grok HUD account quota monitor (managed by grok-hud installer)') { throw 'The task belongs to another application.' }
    $null = Disable-ScheduledTask -TaskName $task.TaskName
    Stop-ScheduledTask -TaskName $task.TaskName
    Stop-GrokHudLegacyMonitor -GrokHome $grokHome
    Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false
}
$configPath = Join-Path $grokHome 'config.toml'
if (Test-Path -LiteralPath $configPath) {
    $config = [IO.File]::ReadAllText($configPath)
    $pattern = '(?ms)^\[ui\.status_line\][^\n]*\n.*?(?=^\[|\z)'
    $match = [regex]::Match($config, $pattern)
    if ($match.Success -and $match.Value.Contains('grok-hud')) {
        $backupDir = Join-Path $grokHome ('grok-hud\backups\uninstall-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fffffff'))
        $null = New-Item -ItemType Directory -Path $backupDir -Force
        Copy-Item -LiteralPath $configPath -Destination $backupDir
        $updated = $config.Remove($match.Index, $match.Length)
        [IO.File]::WriteAllText($configPath, $updated, (New-Object System.Text.UTF8Encoding($false)))
    }
}
& grok plugin uninstall grok-hud --confirm --keep-data
if ($LASTEXITCODE -ne 0) { throw 'Grok plugin uninstall failed.' }
Write-Host 'Uninstalled. History, runtime files and backups are preserved. Restart Grok to reload its configuration.'
