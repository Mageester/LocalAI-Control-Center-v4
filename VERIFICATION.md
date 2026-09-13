# Verification report

Verified on 2026-09-13 using Windows 11, Windows PowerShell 5.1.26100.9539, llama.cpp build 10229, an NVIDIA GeForce RTX 4070 with 12,282 MiB VRAM, a Ryzen 9 7900X3D, and 32 GB system RAM.

## Fresh automated verification

- PowerShell parser: **33 tracked files passed**, zero parse errors.
- Offline test suite: **73 passed, 0 failed**.
- `local-ai.cmd` entry point: returned parseable JSON and `passed: true` from eight self-test invariants.
- Git whitespace validation: passed.
- Secret/path scan: no credentials or user-specific absolute source paths found in tracked v4 files.

The tests cover atomic persistence and quarantine, path containment, GGUF v2/v3 bounds handling, unknown architecture parsing, discovery and split shards, projector isolation, hardware fingerprints, safe launch plans, exact server capability checks, PID ownership, served-alias verification, all five harness adapters, backup conflicts, safe model/download plans, benchmark evidence gates, diagnostics, UI input recovery, command routing, v3 integrity, and manifest-owned install/uninstall behavior.

## Live non-destructive checks

The live checks used `C:\llamacpp` and `-DryRun`; they did not load a model or start a server.

- `llama-server.exe` was found and identified as build 10229.
- Automatic scanning found seven GGUF entries: five main models and two projector sidecars, across `qwen35`, `qwen35moe`, `llama`, and `clip` metadata architectures.
- All discovered entries had complete file/shard sets; projectors remained non-selectable as main models.
- An `Auto` plan for a discovered Qwen3.5 9B model selected 65,536 context with Q8 KV, a 1,024 MiB fit target, localhost port 8080, and an alias derived from the discovered model ID.
- Every emitted server flag was accepted by the installed build-10229 `--help` capability surface.
- Current `llama-bench` help confirmed that flash attention expects `on|off|auto`; the runner now emits `-fa on`, protected by a regression test.
- Offline Doctor result: six Pass, one Warning, zero Fail, one Skipped. The warning was expected because the isolated dry-run state directory did not yet exist; the live-server check was intentionally skipped.
- Dry harness previews left the existing Pi model/settings files and OMP model file byte-for-byte unchanged.
- A disposable side-by-side install/uninstall smoke test passed: manifest created, installed self-test passed, v3 hash remained unchanged, v3 remained after uninstall, and the v4 entry point was removed.

## Interactive and real inference acceptance

- Exercised the actual terminal menu against live discovery: `Launch Model` -> numbered Qwen3.5 9B -> Automatic safe default -> Server only.
- The menu rendered the full 65,536-context plan, asked `Load this model now? [y/N]`, accepted `N`, made no change, and returned to the main menu.
- Repeated the plan as a real isolated load on port 18080. llama.cpp loaded the 5.75 GiB model on the RTX 4070; launcher health and exact served-alias verification passed.
- Sent an actual OpenAI-compatible chat-completions request. The served model returned final content `LOCAL_AI_OK` with finish reason `stop`.
- The launcher then stopped its owned server successfully. Pi, OMP, OpenCode, and Codex configuration targets were redirected under a disposable sandbox; normal user harness files were not edited.

## Menu performance acceptance

The installed model library contains seven GGUF entries. Timings on the reference machine before and after the cache fix:

- Persisted discovery before: 10.5-11.5 seconds on every call.
- Cold explicit discovery/rescan: approximately 12.35 seconds; this is expected because GGUF metadata is reread.
- Unchanged persisted discovery after: approximately 20.8 milliseconds.
- llama.cpp capability check before: approximately 260-310 milliseconds on every plan.
- Unchanged capability check after: approximately 2.9 milliseconds.

Hardware and classified model results are also retained for the lifetime of an interactive menu session. Cache invalidation tests cover direct model-root changes and new snapshots inside an existing Hugging Face repository.

## v3 integrity

The following three SHA-256 values matched exactly:

- Live `C:\llamacpp\local-ai.ps1`
- Packaged `reference\local-ai-v3.ps1`
- Recorded `reference\V3-SHA256.txt`

Hash: `7DF0128DD21B9A2C2A8BB85B00CDE245C9FB2CB671408390B73FC8B8668BD20D`

## Deliberately unperformed

These actions require explicit consent or external credentials/resources and were not needed to validate the package safely:

- Full multi-candidate benchmark/autotune run
- Network model download
- Harness installation
- External harness configuration write
- Interactive third-party Pi, OMP, OpenCode, Codex, or Claude Code session

Those are separately guarded by confirmation, active-server verification, backup, and rollback paths. The report therefore establishes offline correctness, compatibility with the installed llama.cpp command surfaces, real GGUF discovery, dry launch planning, and migration safety—not model quality or third-party service behavior.
