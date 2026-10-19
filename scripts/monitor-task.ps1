# Shared by the installer and task-definition / recovery tests.
function Stop-GrokHudLegacyMonitor {
    param([Parameter(Mandatory)][string]$GrokHome)
    # Releases through 0.5.0 used the grok-budget runtime. Also stop a monitor
    # left by an interrupted earlier grok-hud install.
    $roots = @(
        [IO.Path]::GetFullPath((Join-Path $GrokHome 'grok-budget\runtime')).TrimEnd('\') + '\',
        [IO.Path]::GetFullPath((Join-Path $GrokHome 'grok-hud\runtime')).TrimEnd('\') + '\'
    )
    Get-CimInstance Win32_Process | Where-Object {
        $exe = $_.ExecutablePath
        $_.Name -in @('grok-budget.exe', 'grok-hud.exe') -and $exe -and
        @($roots | Where-Object { $exe.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0 -and
        $_.CommandLine -match '(?:^|\s)--daemon(?:\s|$)'
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function New-GrokHudMonitorTask {
    param(
        [Parameter(Mandatory)][string]$RuntimeExe,
        [Parameter(Mandatory)][string]$GrokHome
    )
    $taskUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    # The GUI-subsystem executable has no console window. Launch it directly:
    # stopping the task must stop the monitor, not leave a shell's child behind.
    if ($GrokHome.Contains('"')) { throw 'Grok home cannot contain a double quote.' }
    $quotedHome = $GrokHome -replace '(\\+)$', '$1$1'
    $action = New-ScheduledTaskAction -Execute $RuntimeExe -Argument ('--grok-home "' + $quotedHome + '"')
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $taskUser
    # No duration means repeat indefinitely, including after a successful exit
    # or a manually stopped task. IgnoreNew makes this a watchdog, not a second daemon.
    $watchdog = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    New-ScheduledTask -Action $action -Trigger @($logon, $watchdog) -Principal $principal -Settings $settings `
        -Description 'Grok HUD account quota monitor (managed by grok-hud installer)'
}

function Wait-GrokHudMonitor {
    param([Parameter(Mandatory)][string]$TaskName, [int]$TimeoutSeconds = 15)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if ((Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop).State -eq 'Running') {
            # Catch immediate startup failures instead of accepting a transient Running state.
            Start-Sleep -Seconds 1
            if ((Get-ScheduledTask -TaskName $TaskName).State -eq 'Running') { return }
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    throw "Quota monitor did not stay running (task result: $($info.LastTaskResult)). Backups have been preserved."
}
