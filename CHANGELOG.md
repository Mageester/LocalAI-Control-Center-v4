# Changelog

## 4.0.0 - 2026-09-13

- Replaced the hardcoded model registry as the primary source with automatic GGUF discovery and direct metadata inspection.
- Added generic model classification, split-shard and projector association, plus a small curated override layer.
- Added conservative hardware-aware profiles and opt-in, evidence-backed per-machine/per-model autotuning.
- Added verified llama.cpp server lifecycle management and single-source client context policy.
- Added extensible adapters for Pi, OMP, OpenCode, Codex, and Claude Code.
- Added safe Hugging Face downloads, group-aware model move/delete operations, live statistics, and Doctor diagnostics.
- Added atomic persistence, configuration backups, rollback, side-by-side installation, manifest-owned uninstall, and preserved v3 reference hash.
- Added a PowerShell 5.1-compatible test runner and coverage across the complete control plane.
