# Local AI Control Center v4

A modular Windows control plane for local GGUF models, llama.cpp, and coding harnesses. It discovers models automatically, reads GGUF metadata directly, builds conservative hardware-aware launch plans, verifies the model actually served, and keeps every client on one authoritative context configuration.

## Requirements

- Windows 11 and Windows PowerShell 5.1 or newer
- A recent llama.cpp Windows build containing `llama-server.exe` (developed and live-checked with build 10229)
- NVIDIA tooling is optional; discovery still works without it
- `hf.exe` is required only for Hugging Face downloads

The included defaults suit a 12 GB GPU / 32 GB RAM machine, but hardware and model properties are detected at runtime. They are not hardcoded to one computer or model family.

## Install without replacing v3

Extract the release, open Windows PowerShell in that folder, and preview the install:

```powershell
.\Install-LocalAI.ps1 -Destination C:\llamacpp -WhatIf -PassThru
```

Then install:

```powershell
.\Install-LocalAI.ps1 -Destination C:\llamacpp
```

The installer never writes `C:\llamacpp\local-ai.ps1`. If that v3 launcher exists, an exact timestamped backup is made and hash-verified first. Start v4 with:

```powershell
C:\llamacpp\local-ai.cmd
```

See [MIGRATION.md](MIGRATION.md) for migration, rollback, and uninstall details.

## First use

The menu is designed for normal use. Choose **Launch Model** for numbered model, profile, and installed-harness selection, or **Smart Task Launcher** to choose the task first. Both render the validated plan and require an explicit `Y` before loading. The command interface makes every operation scriptable and testable:

```powershell
.\local-ai.cmd -Command Doctor
.\local-ai.cmd -Command Discover
.\local-ai.cmd -Command ListModels
.\local-ai.cmd -Command SelfTest -Json
```

Find a model ID with `ListModels`, preview its authoritative launch plan, then launch it:

```powershell
.\local-ai.cmd -Command Plan -Model <model-id> -Profile Auto -DryRun
.\local-ai.cmd -Command Launch -Model <model-id> -Profile Auto -Harness Server
```

`Launch` waits for the server, checks its health, verifies the served model alias, and only then synchronizes installed harnesses. A failed verification does not rewrite client configuration.

## Model discovery and profiles

Discovery scans the llama.cpp model folder, configured roots, and the Hugging Face cache. It resolves Hugging Face links, groups split GGUF shards, associates projectors, and identifies incomplete or ambiguous sets. A persisted root-signature cache makes unchanged launches fast and automatically invalidates when a model root or Hugging Face repository snapshot changes; **Models -> Rescan** remains the explicit refresh. Unknown future models are classified from metadata and naming evidence; known-model entries in `LocalAI\Config\model-overrides.json` are only a small tuning layer.

Safe profiles are `Auto`, `CodingQuality`, `CodingFast`, `AgentLong`, `General`, `DeepReasoning`, `LongContext`, `Vision`, and `Expert`. A plan is bounded by native context, estimated memory headroom, detected server flags, and explicit overrides:

```powershell
.\local-ai.cmd -Command Plan -Model <model-id> -Profile CodingQuality -Context 65536 -KV q8_0 -DryRun
```

Benchmarking is opt-in because it repeatedly loads the model:

```powershell
.\local-ai.cmd -Command Benchmark -Model <model-id> -Profile CodingFast -DryRun
.\local-ai.cmd -Command Benchmark -Model <model-id> -Profile CodingFast -Confirm
```

Results are recorded by machine fingerprint, llama.cpp build, model fingerprint, and intent. An eligible winner is automatically reused on later plans for that exact combination; explicit user tuning still wins. Failed or incomplete candidates are not promoted.

## Models and downloads

Model operations are group-aware, so a split model is moved or removed as a whole:

```powershell
.\local-ai.cmd -Command Models -ModelAction Move -Model <model-id> -Destination D:\Models -DryRun
.\local-ai.cmd -Command Models -ModelAction Move -Model <model-id> -Destination D:\Models -Confirm
.\local-ai.cmd -Command Models -ModelAction Delete -Model <model-id> -Confirm
```

Deletion uses the Recycle Bin by default. Permanent deletion additionally requires `-Permanent`.

Preview and confirm downloads explicitly:

```powershell
.\local-ai.cmd -Command Download -Reference owner/repo:model.gguf -DryRun
.\local-ai.cmd -Command Download -Repository owner/repo -FileName model.gguf -Destination D:\Models -Confirm
```

Downloads use the Hugging Face CLI, keep a log, and never silently execute an unconfirmed transfer.

## Coding harnesses

Shipped adapters cover Pi, OMP, OpenCode, Codex, and Claude Code. Adapter manifests separate detection, install metadata, configuration, and launch behavior. Add a JSON manifest beside `LocalAI\Adapters\custom.example.json`, or place a user adapter in the state `adapters` directory, to extend the system without modifying the controller.

```powershell
.\local-ai.cmd -Command Harnesses -HarnessAction List
.\local-ai.cmd -Command Harnesses -Harness pi -HarnessAction Install -DryRun
.\local-ai.cmd -Command Harnesses -Harness pi -HarnessAction Install -Confirm
.\local-ai.cmd -Command Harnesses -Harness pi -HarnessAction PreviewConfig -Model <model-id>
```

Actual configuration requires `-Confirm` and a verified launcher-owned active server. Existing configuration is backed up before any write. Use `Backup` and `Rollback` to inspect or restore a session.

## Server, diagnostics, and statistics

```powershell
.\local-ai.cmd -Command Status
.\local-ai.cmd -Command Statistics
.\local-ai.cmd -Command Statistics -Live
.\local-ai.cmd -Command Doctor
.\local-ai.cmd -Command Doctor -Live
.\local-ai.cmd -Command Stop
```

Doctor reports pass/warn/fail findings without repairing the system. Live checks are opt-in. Server state is PID- and command-aware, preventing an unrelated process from being treated as launcher-owned.

## State and customization

Machine-local state defaults to `%USERPROFILE%\.local-ai-control\v4`. It contains settings, discovery cache, benchmark records, logs, backups, and active-server state. Override it with `-StateRoot` for portable or test use.

Edit user settings, not shipped files, when adding model roots. The merged settings schema is based on `LocalAI\Config\defaults.json`. All harnesses receive the same server endpoint, model alias, context window, output allowance, and compaction threshold derived from the selected launch plan.

## Development and tests

No Pester installation is required:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
```

The suite covers persistence, GGUF parsing, discovery and shard safety, hardware classification, profiles, runtime verification, adapters, rollback, downloads, autotune evidence, diagnostics, terminal rendering, command flows, and installation safety.

## Security and operational boundaries

- Plans and preview commands do not start a server or alter external configuration.
- Harness installers, downloads, model mutations, benchmarks, and configuration writes require explicit confirmation.
- Configuration writes use temp-file replacement and pre-write backups.
- Model launch fails closed when required llama.cpp flags are unavailable.
- No API keys, model files, user caches, or machine-local state belong in source control.

No software license is granted by this repository unless a license file is added by the owner.
