[CmdletBinding()]
param([switch]$Build, [switch]$ReplaceSource)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$grokHome = if ($env:GROK_HOME) { $env:GROK_HOME } else { Join-Path $env:USERPROFILE '.grok' }

# Run directly from GitHub:
#   irm https://raw.githubusercontent.com/liao666brant/grok-hud/main/install.ps1 | iex
# Running through that pipeline leaves no script root. Download the verified
# release package into a stable source directory and continue from there.
if (-not $root -or -not (Test-Path -LiteralPath (Join-Path $root 'grok-hud\plugin.json'))) {
    if (-not (Get-Command grok -ErrorAction SilentlyContinue)) { throw 'grok CLI not found on PATH.' }
    $sourceRoot = Join-Path $grokHome 'grok-hud\source'
    $releaseUrl = if ($env:GROK_HUD_RELEASE_URL) { $env:GROK_HUD_RELEASE_URL } else { 'https://github.com/liao666brant/grok-hud/releases/latest/download/GrokHUD-windows-x64.zip' }
    $work = Join-Path ([IO.Path]::GetTempPath()) "grok-hud-install-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $work -Force
    try {
        $archive = Join-Path $work 'GrokHUD-windows-x64.zip'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $releaseUrl -OutFile $archive -ErrorAction Stop
        } catch {
            throw ("Cannot download the Windows package from the latest GitHub release:`n  $releaseUrl`n`n" +
                "The release may not include a Windows package yet, or the network request failed.`n" +
                "Download the ZIP from https://github.com/liao666brant/grok-hud/releases/latest,`n" +
                "extract it, and run .\install.ps1 in the extracted directory.")
        }

        $checksumPath = "$archive.sha256"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$releaseUrl.sha256" -OutFile $checksumPath -ErrorAction Stop
        } catch {
            throw ("Cannot download the release checksum:`n  $releaseUrl.sha256`n`n" +
                "Refusing to install an unverified package. Download the ZIP and its .sha256 file`n" +
                "from https://github.com/liao666brant/grok-hud/releases/latest, verify the archive,`n" +
                "extract it, and run .\install.ps1 in the extracted directory.")
        }
        $expected = ((Get-Content -LiteralPath $checksumPath -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
        if ($expected -notmatch '^[0-9a-f]{64}$') { throw 'The release checksum file is malformed.' }
        $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expected -ne $actual) { throw 'Release checksum mismatch.' }

        $extracted = Join-Path $work 'source'
        $null = New-Item -ItemType Directory -Path $extracted -Force
        Expand-Archive -LiteralPath $archive -DestinationPath $extracted -Force
        $nextInstaller = Join-Path $extracted 'install.ps1'
        if (-not (Test-Path -LiteralPath (Join-Path $extracted 'grok-hud\plugin.json')) -or
            -not (Test-Path -LiteralPath $nextInstaller)) {
            throw 'The downloaded package does not contain the installer and plugin.'
        }

        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $sourceRoot) -Force
        $previous = "$sourceRoot.previous"
        if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous -Recurse -Force }
        if (Test-Path -LiteralPath $sourceRoot) { Move-Item -LiteralPath $sourceRoot -Destination $previous }
        try {
            Move-Item -LiteralPath $extracted -Destination $sourceRoot
        } catch {
            if (Test-Path -LiteralPath $previous) { Move-Item -LiteralPath $previous -Destination $sourceRoot }
            throw
        }
        Remove-Item -LiteralPath $previous -Recurse -Force -ErrorAction SilentlyContinue

        $hostExe = if (Get-Command powershell.exe -ErrorAction SilentlyContinue) { 'powershell.exe' } else { 'pwsh' }
        & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sourceRoot 'install.ps1') -ReplaceSource
        if ($LASTEXITCODE -ne 0) { throw "Installer failed with exit code $LASTEXITCODE." }
        return
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$pluginSource = Join-Path $root 'grok-hud'
$binary = Join-Path $pluginSource 'grok-hud.exe'
$monitorBinary = Join-Path $pluginSource 'grok-hud-monitor.exe'
$utf8 = New-Object System.Text.UTF8Encoding($false)
. (Join-Path $root 'scripts\monitor-task.ps1')
. (Join-Path $root 'scripts\migrate-data.ps1')

function Invoke-Grok {
    param([string[]]$Arguments)
    & grok @Arguments
    if ($LASTEXITCODE -ne 0) { throw "grok failed: $($Arguments -join ' ')" }
}

function Remove-GrokHudLegacyPluginEntry {
    param([string]$ConfigPath, [string]$BackupDirectory)
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return }
    $lines = [IO.File]::ReadAllLines($ConfigPath)
    $out = New-Object System.Collections.Generic.List[string]
    $inPlugins = $false
    $inDisabled = $false
    $removed = $false
    foreach ($line in $lines) {
        if ($line -match '^\[plugins\]$') { $inPlugins = $true }
        if ($inPlugins -and $line -match '^disabled = \[$') { $inDisabled = $true }
        if ($inDisabled -and $line -match '^\s*"grok-budget",?\s*$') { $removed = $true; continue }
        if ($inDisabled -and $line -match '^\]') { $inDisabled = $false }
        $out.Add($line)
    }
    if ($removed) {
        Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $BackupDirectory 'config-with-legacy-entry.toml') -Force
        [IO.File]::WriteAllText($ConfigPath, ($out -join "`n") + "`n", $utf8)
    }
}

if ($Build -or -not (Test-Path -LiteralPath $binary) -or -not (Test-Path -LiteralPath $monitorBinary)) {
    Push-Location $root
    try {
        & cargo build --release --locked
        if ($LASTEXITCODE -ne 0) { throw 'Rust build failed.' }
        Copy-Item -LiteralPath (Join-Path $root 'target\release\grok-hud.exe') -Destination $binary -Force
        Copy-Item -LiteralPath (Join-Path $root 'target\release\grok-hud-monitor.exe') -Destination $monitorBinary -Force
    } finally { Pop-Location }
}

$null = Get-Command grok -ErrorAction Stop
Invoke-Grok @('plugin', 'validate', $pluginSource)
$plugins = (Invoke-Grok @('plugin', 'list', '--json')) | ConvertFrom-Json
$existing = $plugins | Where-Object name -eq 'grok-hud' | Select-Object -First 1
$legacy = $plugins | Where-Object name -eq 'grok-budget' | Select-Object -First 1
$expectedVersion = (Get-Content -LiteralPath (Join-Path $pluginSource 'plugin.json') -Raw | ConvertFrom-Json).version
$binaryVersion = & $binary --version
if ($LASTEXITCODE -ne 0 -or $binaryVersion -ne "grok-hud $expectedVersion") { throw 'Manifest and executable versions differ.' }
$sourceReplacement = $false
if ($existing) {
    $oldSource = [IO.Path]::GetFullPath($existing.source).TrimEnd('\','/')
    if ($oldSource -ne [IO.Path]::GetFullPath($pluginSource).TrimEnd('\','/')) {
        if ($ReplaceSource -or -not (Test-Path -LiteralPath $oldSource)) {
            $sourceReplacement = $true
        } else {
            throw "Existing plugin comes from another directory: $oldSource. Re-run with -ReplaceSource to register this directory instead."
        }
    }
}

$taskName = 'GrokHudMonitor'
$taskDescription = 'Grok HUD account quota monitor (managed by grok-hud installer)'
$legacyTaskName = 'GrokBudgetMonitor'
$legacyTaskDescription = 'Grok Budget account quota monitor (managed by grok-budget installer)'
$null = Get-Command Register-ScheduledTask -ErrorAction Stop
$oldTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($oldTask -and $oldTask.Description -ne $taskDescription) { throw "Task $taskName belongs to another application." }
$legacyTask = Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue
if ($legacyTask -and $legacyTask.Description -ne $legacyTaskDescription) { throw "Task $legacyTaskName belongs to another application." }

$dataDir = Join-Path $grokHome 'grok-hud'
$legacyData = Join-Path $grokHome 'grok-budget'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fffffff'
$hadExistingPlugin = [bool]$existing
$legacyTaskWasEnabled = $legacyTask -and $legacyTask.State -ne 'Disabled'

# Back up BEFORE disabling or removing the legacy installation or touching the
# new one. Creating the data directory is safe because legacy data is copied
# below instead of moved.
$backup = Join-Path $dataDir "backups\$stamp"
$null = New-Item -ItemType Directory -Path $backup -Force
$configPath = Join-Path $grokHome 'config.toml'
$launcher = Join-Path $dataDir 'statusline.cmd'
foreach ($file in @($configPath, $launcher, (Join-Path $grokHome 'installed-plugins\registry.json'))) {
    if (Test-Path -LiteralPath $file) { Copy-Item -LiteralPath $file -Destination $backup -Force }
}
if ($existing -and (Test-Path -LiteralPath $existing.path)) {
    Copy-Item -LiteralPath $existing.path -Destination (Join-Path $backup 'previous-plugin') -Recurse
}
if ($legacy -and (Test-Path -LiteralPath $legacy.path)) {
    Copy-Item -LiteralPath $legacy.path -Destination (Join-Path $backup 'legacy-plugin') -Recurse
}
if ($oldTask) {
    Export-ScheduledTask -TaskName $taskName | Set-Content -LiteralPath (Join-Path $backup 'monitor-task.xml') -Encoding Unicode
}
if ($legacyTask) {
    Export-ScheduledTask -TaskName $legacyTaskName | Set-Content -LiteralPath (Join-Path $backup 'legacy-monitor-task.xml') -Encoding Unicode
}
$legacyLauncher = Join-Path $legacyData 'statusline.cmd'
if (Test-Path -LiteralPath $legacyLauncher) {
    Copy-Item -LiteralPath $legacyLauncher -Destination (Join-Path $backup 'legacy-statusline.cmd') -Force
}

$installComplete = $false
$legacyDisabledByInstaller = $false
trap {
    $errorRecord = $_
    if (-not $installComplete -and $legacyDisabledByInstaller) {
        if ($legacyTask -and $legacyTaskWasEnabled) {
            try {
                $null = Enable-ScheduledTask -TaskName $legacyTaskName
                Start-ScheduledTask -TaskName $legacyTaskName
            } catch { }
        }
        if ($legacy) {
            try { Invoke-Grok @('plugin', 'enable', 'grok-budget') } catch { }
        }
        if (-not $hadExistingPlugin) {
            try { Invoke-Grok @('plugin', 'disable', 'grok-hud') } catch { }
        }
    }
    throw $errorRecord
}

# Stop the old monitor before copying its database, but keep its task, plugin
# and data in place until the replacement monitor has been verified.
if ($legacyTask) {
    $null = Disable-ScheduledTask -TaskName $legacyTaskName
    Stop-ScheduledTask -TaskName $legacyTaskName
    Stop-GrokHudLegacyMonitor -GrokHome $grokHome
    $legacyDisabledByInstaller = $true
}
if ($legacy) {
    try { Invoke-Grok @('plugin', 'disable', 'grok-budget') } catch { }
    $legacyDisabledByInstaller = $true
}
if (Test-Path -LiteralPath $legacyData) {
    try {
        Copy-GrokHudLegacyData -Legacy $legacyData -Target $dataDir
    } catch {
        if ($legacyTask -and $legacyTaskWasEnabled) {
            $null = Enable-ScheduledTask -TaskName $legacyTaskName
            Start-ScheduledTask -TaskName $legacyTaskName
        }
        if ($legacy) { try { Invoke-Grok @('plugin', 'enable', 'grok-budget') } catch { } }
        throw
    }
}
$plugins = (Invoke-Grok @('plugin', 'list', '--json')) | ConvertFrom-Json
$existing = $plugins | Where-Object name -eq 'grok-hud' | Select-Object -First 1

if ($sourceReplacement -and $existing) {
    # Backups are in place; re-register from the new source instead of updating
    # from a path the caller explicitly replaced.
    Invoke-Grok @('plugin', 'uninstall', 'grok-hud', '--confirm', '--keep-data')
    $plugins = (Invoke-Grok @('plugin', 'list', '--json')) | ConvertFrom-Json
    $existing = $plugins | Where-Object name -eq 'grok-hud' | Select-Object -First 1
}

if ($existing) {
    Invoke-Grok @('plugin', 'update', 'grok-hud')
    $listed = (Invoke-Grok @('plugin', 'list', '--json')) | ConvertFrom-Json
    $registered = $listed | Where-Object name -eq 'grok-hud' | Select-Object -First 1
    if ($registered.version -ne $expectedVersion -or $registered.source -ne $pluginSource) {
        # Local update is a no-op in Grok 1.0.41. Re-register via the official CLI.
        # Keep already-open status lines usable while the copied plugin is replaced.
        $rollbackExe = Join-Path $backup 'previous-plugin\grok-hud.exe'
        if (Test-Path -LiteralPath $rollbackExe) {
            [IO.File]::WriteAllText($launcher, '@echo off' + "`r`n" + '"' + $rollbackExe + '" --statusline' + "`r`n", $utf8)
        }
        Invoke-Grok @('plugin', 'uninstall', 'grok-hud', '--confirm', '--keep-data')
        Invoke-Grok @('plugin', 'install', $pluginSource, '--trust')
    }
} else { Invoke-Grok @('plugin', 'install', $pluginSource, '--trust') }
Invoke-Grok @('plugin', 'enable', 'grok-hud')
$plugins = (Invoke-Grok @('plugin', 'list', '--json')) | ConvertFrom-Json
$registered = $plugins | Where-Object name -eq 'grok-hud' | Select-Object -First 1
$installed = $registered.path
if (-not $installed -or $registered.version -ne $expectedVersion) { throw 'Plugin registration/version validation failed.' }

# Grok's local-plugin update can leave a copied installation stale: publish explicitly.
if ([IO.Path]::GetFullPath($installed) -ne [IO.Path]::GetFullPath($pluginSource)) {
    foreach ($relative in @('grok-hud.exe','grok-hud-monitor.exe','plugin.json','hooks\hooks.json','commands\budget.md','report.html')) {
        $destination = Join-Path $installed $relative
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
        $published = $false
        for ($attempt = 0; $attempt -lt 40; $attempt++) {
            try { Copy-Item -LiteralPath (Join-Path $pluginSource $relative) -Destination $destination -Force; $published = $true; break }
            catch { if ($attempt -eq 39) { throw }; Start-Sleep -Milliseconds 250 }
        }
        if (-not $published) { throw "Cannot publish $relative" }
    }
}
$installedExe = Join-Path $installed 'grok-hud.exe'
& $installedExe --version
if ($LASTEXITCODE -ne 0) { throw 'Installed Rust binary failed validation.' }

# A versioned independent runtime avoids Grok's child-process cleanup and update locks.
$runtimeHash = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.Substring(0,12).ToLowerInvariant() + '-' + (Get-FileHash -LiteralPath $monitorBinary -Algorithm SHA256).Hash.Substring(0,12).ToLowerInvariant()
$runtimeDir = Join-Path $dataDir "runtime\$expectedVersion-$runtimeHash"
$null = New-Item -ItemType Directory -Path $runtimeDir -Force
$runtimeExe = Join-Path $runtimeDir 'grok-hud.exe'
$runtimeMonitor = Join-Path $runtimeDir 'grok-hud-monitor.exe'
if (-not (Test-Path -LiteralPath $runtimeExe) -or (Get-FileHash -LiteralPath $runtimeExe).Hash -ne (Get-FileHash -LiteralPath $binary).Hash) {
    Copy-Item -LiteralPath $binary -Destination $runtimeExe -Force
}
if (-not (Test-Path -LiteralPath $runtimeMonitor)) {
    Copy-Item -LiteralPath $monitorBinary -Destination $runtimeMonitor
}
$definition = New-GrokHudMonitorTask -RuntimeExe $runtimeMonitor -GrokHome $grokHome
try {
    if ($oldTask) {
        # Disable before stopping so an existing watchdog cannot race the update.
        $null = Disable-ScheduledTask -TaskName $taskName
        Stop-ScheduledTask -TaskName $taskName
        $stopDeadline = (Get-Date).AddSeconds(15)
        while ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
            if ((Get-Date) -ge $stopDeadline) { throw 'Previous quota monitor did not stop.' }
            Start-Sleep -Milliseconds 250
        }
    }
    Stop-GrokHudLegacyMonitor -GrokHome $grokHome
    $null = Register-ScheduledTask -TaskName $taskName -InputObject $definition -Force
    Start-ScheduledTask -TaskName $taskName
    Wait-GrokHudMonitor -TaskName $taskName
} catch {
    $installError = $_
    try {
        if ($oldTask) {
            $oldXml = [IO.File]::ReadAllText((Join-Path $backup 'monitor-task.xml'))
            $null = Register-ScheduledTask -TaskName $taskName -Xml $oldXml -Force
            if ($oldTask.State -ne 'Disabled') { Start-ScheduledTask -TaskName $taskName }
        } else {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Warning "Could not restore the previous Grok HUD task: $($_.Exception.Message)"
    }
    try {
        if ($legacyTask -and $legacyTaskWasEnabled) {
            $null = Enable-ScheduledTask -TaskName $legacyTaskName
            Start-ScheduledTask -TaskName $legacyTaskName
        }
    } catch {
        Write-Warning "Could not restore the legacy monitor task: $($_.Exception.Message)"
    }
    if ($legacy) {
        try { Invoke-Grok @('plugin', 'enable', 'grok-budget') } catch { }
        if (-not $hadExistingPlugin) {
            try { Invoke-Grok @('plugin', 'disable', 'grok-hud') } catch { }
        }
    }
    throw $installError
}

# Keep the existing launcher path, so already-open sessions pick up Rust immediately.
$launcherText = '@echo off' + "`r`n" + '"' + $runtimeExe + '" --statusline --grok-home "' + $grokHome + '"' + "`r`n"
[IO.File]::WriteAllText($launcher, $launcherText, $utf8)
$existingConfig = if (Test-Path -LiteralPath $configPath) { [IO.File]::ReadAllText($configPath) } else { '' }
$commandValue = ConvertTo-Json -InputObject $launcher -Compress
$block = '[ui.status_line]' + "`n" + 'type = "command"' + "`n" + 'command = ' + $commandValue + "`n" + 'refresh_interval = 1' + "`n"
$pattern = '(?ms)^\[ui\.status_line\][^\n]*\n.*?(?=^\[|\z)'
if ([regex]::IsMatch($existingConfig, $pattern)) {
    $updated = [regex]::Replace($existingConfig, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block + "`n" })
} else { $updated = $existingConfig.TrimEnd() + "`n`n" + $block }
if ($updated -ne $existingConfig) { [IO.File]::WriteAllText($configPath, $updated, $utf8) }
$installComplete = $true

# The replacement task is verified. Remove the old installation and its data;
# failures leave the legacy task, plugin and data disabled but preserved.
$cleanupFailed = $false
$legacyPluginRemoved = -not $legacy
if ($legacyTask) {
    try {
        Unregister-ScheduledTask -TaskName $legacyTaskName -Confirm:$false
    } catch {
        Write-Warning "Could not remove the legacy monitor task: $($_.Exception.Message)"
        $cleanupFailed = $true
    }
}
if ($legacy) {
    try {
        Invoke-Grok @('plugin', 'uninstall', 'grok-budget', '--confirm', '--keep-data')
        $legacyPluginRemoved = $true
    } catch {
        Write-Warning "Could not uninstall the legacy plugin: $($_.Exception.Message)"
        $cleanupFailed = $true
    }
}
if ($legacyPluginRemoved) {
    Remove-GrokHudLegacyPluginEntry -ConfigPath $configPath -BackupDirectory $backup
}
if (-not $cleanupFailed -and (Test-Path -LiteralPath $legacyData)) {
    try {
        Remove-Item -LiteralPath $legacyData -Recurse -Force
    } catch {
        Write-Warning "Could not remove the legacy data directory: $($_.Exception.Message)"
        $cleanupFailed = $true
    }
}
if ($cleanupFailed) {
    Write-Warning 'New installation is active, but some legacy grok-budget files could not be removed. The legacy task and plugin remain disabled; retry the installer or remove them manually.'
}
Write-Host "Installed native runtime: $runtimeExe"
Write-Host "Monitor task: $taskName; automatic recovery every minute. Restart Grok to reload hooks."
Write-Host "Rollback files: $backup"
& $installedExe
if ($LASTEXITCODE -ne 0) { Write-Warning "Installed successfully; quota query unavailable. Run: & '$installedExe' --refresh" }
