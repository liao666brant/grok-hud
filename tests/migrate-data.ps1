[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\migrate-data.ps1')
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("grok-hud-migrate-test-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmp -Force

function Assert-Content {
    param([string]$Path, [string]$Expected)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Missing file: $Path" }
    if ([IO.File]::ReadAllText($Path) -ne $Expected) { throw "Unexpected content in $Path" }
}

function Assert-Absent {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { throw "Unexpected path: $Path" }
}

function Write-Text {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if ($parent) { $null = New-Item -ItemType Directory -Path $parent -Force }
    [IO.File]::WriteAllText($Path, $Text)
}

try {
    # A pre-created target (the bootstrap creates its source directory there)
    # must still receive the database, WAL/SHM, old backups and other files.
    $legacy = Join-Path $tmp 'legacy'
    $target = Join-Path $tmp 'target'
    Write-Text (Join-Path $legacy 'history.sqlite3') 'database'
    Write-Text (Join-Path $legacy 'history.sqlite3-wal') 'wal'
    Write-Text (Join-Path $legacy 'history.sqlite3-shm') 'shm'
    Write-Text (Join-Path $legacy 'history.sqlite3-journal') 'journal'
    Write-Text (Join-Path $legacy 'backups\20260101-000000\snapshot.txt') 'old backup'
    Write-Text (Join-Path $legacy 'notes.txt') 'notes'
    Write-Text (Join-Path $legacy '.hidden') 'hidden'
    Write-Text (Join-Path $legacy 'runtime\old.exe') 'old runtime'
    Write-Text (Join-Path $legacy 'statusline.cmd') 'old launcher'
    Write-Text (Join-Path $legacy 'source\old.txt') 'old source'
    Write-Text (Join-Path $target 'backups\20260202-000000\snapshot.txt') 'new backup'
    Write-Text (Join-Path $target 'source\current.txt') 'current source'

    Copy-GrokHudLegacyData -Legacy $legacy -Target $target
    Assert-Content (Join-Path $target 'history.sqlite3') 'database'
    Assert-Content (Join-Path $target 'history.sqlite3-wal') 'wal'
    Assert-Content (Join-Path $target 'history.sqlite3-shm') 'shm'
    Assert-Content (Join-Path $target 'history.sqlite3-journal') 'journal'
    Assert-Content (Join-Path $target 'notes.txt') 'notes'
    Assert-Content (Join-Path $target '.hidden') 'hidden'
    Assert-Content (Join-Path $target 'backups\20260101-000000\snapshot.txt') 'old backup'
    Assert-Content (Join-Path $target 'backups\20260202-000000\snapshot.txt') 'new backup'
    Assert-Content (Join-Path $target 'source\current.txt') 'current source'
    Assert-Absent (Join-Path $target 'runtime')
    Assert-Absent (Join-Path $target 'statusline.cmd')
    Assert-Absent (Join-Path $target 'source\old.txt')

    # A different target database wins; its missing WAL must not be filled from
    # an unrelated legacy database.
    $legacy2 = Join-Path $tmp 'legacy2'
    $target2 = Join-Path $tmp 'target2'
    Write-Text (Join-Path $legacy2 'history.sqlite3') 'legacy database'
    Write-Text (Join-Path $legacy2 'history.sqlite3-wal') 'legacy wal'
    Write-Text (Join-Path $target2 'history.sqlite3') 'target database'
    Copy-GrokHudLegacyData -Legacy $legacy2 -Target $target2
    Assert-Content (Join-Path $target2 'history.sqlite3') 'target database'
    Assert-Absent (Join-Path $target2 'history.sqlite3-wal')

    # If an earlier install copied only the database, an identical target
    # database means the WAL/SHM sidecars still belong to it.
    $legacy3 = Join-Path $tmp 'legacy3'
    $target3 = Join-Path $tmp 'target3'
    Write-Text (Join-Path $legacy3 'history.sqlite3') 'same database'
    Write-Text (Join-Path $legacy3 'history.sqlite3-wal') 'recent wal'
    Write-Text (Join-Path $legacy3 'history.sqlite3-shm') 'recent shm'
    Write-Text (Join-Path $target3 'history.sqlite3') 'same database'
    Copy-GrokHudLegacyData -Legacy $legacy3 -Target $target3
    Assert-Content (Join-Path $target3 'history.sqlite3-wal') 'recent wal'
    Assert-Content (Join-Path $target3 'history.sqlite3-shm') 'recent shm'

    # If the target already has its own WAL, keep it instead of replacing newer
    # history with the legacy sidecar.
    $legacy3b = Join-Path $tmp 'legacy3b'
    $target3b = Join-Path $tmp 'target3b'
    Write-Text (Join-Path $legacy3b 'history.sqlite3') 'same database'
    Write-Text (Join-Path $legacy3b 'history.sqlite3-wal') 'legacy wal'
    Write-Text (Join-Path $target3b 'history.sqlite3') 'same database'
    Write-Text (Join-Path $target3b 'history.sqlite3-wal') 'target wal'
    Copy-GrokHudLegacyData -Legacy $legacy3b -Target $target3b
    Assert-Content (Join-Path $target3b 'history.sqlite3-wal') 'target wal'

    # A missing target is created and all retained files are copied.
    $legacy4 = Join-Path $tmp 'legacy4'
    $target4 = Join-Path $tmp 'target4'
    Write-Text (Join-Path $legacy4 'history.sqlite3') 'db'
    Write-Text (Join-Path $legacy4 'runtime\monitor') 'runtime'
    Write-Text (Join-Path $legacy4 'backups\old\data') 'snapshot'
    Copy-GrokHudLegacyData -Legacy $legacy4 -Target $target4
    Assert-Content (Join-Path $target4 'history.sqlite3') 'db'
    Assert-Content (Join-Path $target4 'backups\old\data') 'snapshot'
    Assert-Absent (Join-Path $target4 'runtime')

    Write-Host 'Legacy data migration tests passed.'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
