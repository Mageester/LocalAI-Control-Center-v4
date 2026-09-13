Invoke-TestCase 'backup restores an unchanged managed file' {
    Import-TestModule Common
    Import-TestModule Configuration
    Import-TestModule Harnesses
    $original=Join-Path $script:TestRoot 'config.json';[IO.File]::WriteAllText($original,'before')
    $session=New-LocalAIBackupSession -BackupRoot (Join-Path $script:TestRoot 'backups') -Operation 'test'
    $record=Backup-LocalAIFile -Session $session -Path $original
    [IO.File]::WriteAllText($original,'managed')
    $record.PostHash=(Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash
    Assert-True (Restore-LocalAIBackup -Record $record)
    Assert-Equal 'before' (Get-Content -LiteralPath $original -Raw)
}

Invoke-TestCase 'rollback refuses a file changed after the managed edit' {
    Import-TestModule Common
    Import-TestModule Configuration
    Import-TestModule Harnesses
    $original=Join-Path $script:TestRoot 'conflict.json';[IO.File]::WriteAllText($original,'before')
    $session=New-LocalAIBackupSession -BackupRoot (Join-Path $script:TestRoot 'backups') -Operation 'test'
    $record=Backup-LocalAIFile -Session $session -Path $original
    [IO.File]::WriteAllText($original,'managed');$record.PostHash=(Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash
    [IO.File]::WriteAllText($original,'user change')
    Assert-Throws { Restore-LocalAIBackup -Record $record } 'changed since'
}
