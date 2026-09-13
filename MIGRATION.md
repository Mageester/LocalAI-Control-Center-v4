# Migration from v3

v4 is installed beside v3. It does not rename, edit, or delete the legacy `local-ai.ps1` launcher.

## 1. Prepare

1. Download and extract the v4 release.
2. Confirm `C:\llamacpp\llama-server.exe` exists, or substitute your llama.cpp directory in every command below.
3. Leave the existing `C:\llamacpp\local-ai.ps1` in place.

Optional integrity comparison for the reference v3 included in this release:

```powershell
Get-FileHash .\reference\local-ai-v3.ps1 -Algorithm SHA256
Get-Content .\reference\V3-SHA256.txt
```

## 2. Preview the exact install

```powershell
.\Install-LocalAI.ps1 -Destination C:\llamacpp -WhatIf -PassThru | Format-List
```

The plan must show `PreservesLegacyPath` as `C:\llamacpp\local-ai.ps1`. When that file exists, `Backups` points to a timestamped copy below `C:\llamacpp\local-ai-v3-backups`.

## 3. Install v4 side by side

```powershell
.\Install-LocalAI.ps1 -Destination C:\llamacpp
```

The installer:

1. Backs up the exact installed v3 file and verifies the copied hash.
2. Copies only v4-owned entry points, modules, adapters, configuration, and documentation.
3. Records each installed file and its hash in `local-ai-v4.install.json`.
4. Leaves models, logs, user state, and `local-ai.ps1` untouched.

## 4. Validate before switching daily use

```powershell
C:\llamacpp\local-ai.cmd -Command SelfTest -Json
C:\llamacpp\local-ai.cmd -Command Doctor
C:\llamacpp\local-ai.cmd -Command Discover
C:\llamacpp\local-ai.cmd -Command ListModels
```

Preview a model plan before starting it:

```powershell
C:\llamacpp\local-ai.cmd -Command Plan -Model <model-id> -Profile Auto -DryRun
```

You can continue launching v3 at any time with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\llamacpp\local-ai.ps1
```

## Roll back harness configuration

Every v4 harness write creates a backup session. List sessions:

```powershell
C:\llamacpp\local-ai.cmd -Command Backup
```

Preview the newest rollback, then confirm it:

```powershell
C:\llamacpp\local-ai.cmd -Command Rollback
C:\llamacpp\local-ai.cmd -Command Rollback -Confirm
```

Use `-BackupId <id>` to select an older session.

## Uninstall v4

Preview first:

```powershell
C:\llamacpp\Uninstall-LocalAI.ps1 -Destination C:\llamacpp -WhatIf -PassThru
```

Then uninstall:

```powershell
C:\llamacpp\Uninstall-LocalAI.ps1 -Destination C:\llamacpp
```

The uninstaller reads the install manifest and removes only unchanged v4-owned files. It refuses to remove an installed v4 file whose hash changed, so user edits are preserved for manual review. It always preserves v3, models, logs, and machine-local state.

To remove machine-local v4 state later, review `%LOCALAPPDATA%\LocalAIControlCenter` and delete it manually only after confirming its backups and benchmark records are no longer needed.
