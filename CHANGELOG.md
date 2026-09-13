# Changelog

## 4.0.3 - 2026-09-13

- Make persisted model discovery cache readable, with fast root signatures that invalidate when model roots or Hugging Face repository snapshots change.
- Reuse discovered and classified models throughout one interactive menu session until an explicit rescan.
- Reuse the stable hardware probe throughout one menu session.
- Reuse llama.cpp capability results while the server executable path, size, and modification time remain unchanged.
- Reduce measured unchanged discovery time on the reference library from roughly 11.5 seconds to 21 milliseconds.

## 4.0.2 - 2026-09-13

- Replace the display-only Launch Model menu item with a numbered interactive model, task profile, and installed-harness workflow.
- Make Smart Task Launcher use the same verified workflow with task-first selection.
- Exclude projector sidecars and invalid models from interactive launch choices.
- Render the complete validated plan and require explicit confirmation before loading a model.

## 4.0.1 - 2026-09-13

- Reapply an eligible benchmark winner only when its machine, llama.cpp build, model fingerprint, and task intent match exactly; explicit user tuning still takes precedence.
- Preserve every candidate's tuning fields alongside raw benchmark evidence so a winner is reproducible.
- Make `Statistics -Live` a real continuously refreshing terminal view until interrupted.

## 4.0.0 - 2026-09-13

- Replaced the hardcoded model registry as the primary source with automatic GGUF discovery and direct metadata inspection.
- Added generic model classification, split-shard and projector association, plus a small curated override layer.
- Added conservative hardware-aware profiles and opt-in, evidence-backed per-machine/per-model autotuning.
- Added verified llama.cpp server lifecycle management and single-source client context policy.
- Added extensible adapters for Pi, OMP, OpenCode, Codex, and Claude Code.
- Added safe Hugging Face downloads, group-aware model move/delete operations, live statistics, and Doctor diagnostics.
- Added atomic persistence, configuration backups, rollback, side-by-side installation, manifest-owned uninstall, and preserved v3 reference hash.
- Added a PowerShell 5.1-compatible test runner and coverage across the complete control plane.
