# Windows data migration helpers shared by install.ps1 and tests/migrate-data.ps1.

function Copy-GrokHudMissingTree {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Destination)) {
        $null = New-Item -ItemType Directory -Path $Destination -Force
    }
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) {
            Copy-GrokHudMissingTree -Source $item.FullName -Destination $target
        } elseif (-not (Test-Path -LiteralPath $target)) {
            Copy-Item -LiteralPath $item.FullName -Destination $target
        }
    }
}

function Copy-GrokHudLegacyData {
    param([string]$Legacy, [string]$Target)
    if (-not (Test-Path -LiteralPath $Legacy)) { return }
    $null = New-Item -ItemType Directory -Path $Target -Force
    $targetDb = Join-Path $Target 'history.sqlite3'
    $legacyDb = Join-Path $Legacy 'history.sqlite3'
    $copyDb = $false
    $copySidecars = $false
    $targetWal = Join-Path $Target 'history.sqlite3-wal'
    if (Test-Path -LiteralPath $legacyDb) {
        if (-not (Test-Path -LiteralPath $targetDb) -or (Get-Item -LiteralPath $targetDb).Length -eq 0) {
            $copyDb = $true
            $copySidecars = $true
        } elseif ((Get-FileHash -LiteralPath $targetDb -Algorithm SHA256).Hash -eq
                  (Get-FileHash -LiteralPath $legacyDb -Algorithm SHA256).Hash -and
                  (-not (Test-Path -LiteralPath $targetWal) -or (Get-Item -LiteralPath $targetWal).Length -eq 0)) {
            # A previous install may have copied only the database. If the
            # target has no WAL yet, the legacy sidecars still belong to it.
            $copySidecars = $true
        }
    }
    if ($copyDb) {
        Copy-Item -LiteralPath $legacyDb -Destination $targetDb -Force
    }
    if ($copySidecars) {
        foreach ($name in @('history.sqlite3-wal', 'history.sqlite3-shm', 'history.sqlite3-journal')) {
            $source = Join-Path $Legacy $name
            if (Test-Path -LiteralPath $source) {
                Copy-Item -LiteralPath $source -Destination (Join-Path $Target $name) -Force
            }
        }
    }
    foreach ($item in Get-ChildItem -LiteralPath $Legacy -Force) {
        if ($item.Name -in @('history.sqlite3', 'history.sqlite3-wal', 'history.sqlite3-shm', 'history.sqlite3-journal', 'runtime', 'source', 'statusline.cmd')) { continue }
        $destination = Join-Path $Target $item.Name
        if ($item.Name -eq 'backups') {
            Copy-GrokHudMissingTree -Source $item.FullName -Destination $destination
        } elseif (-not (Test-Path -LiteralPath $destination)) {
            Copy-Item -LiteralPath $item.FullName -Destination $destination -Recurse -Force
        }
    }
}
