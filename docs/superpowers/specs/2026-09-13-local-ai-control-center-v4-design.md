# Local AI Control Center v4 Design

## Purpose

Local AI Control Center v4 is a Windows-first, terminal-based control plane for local GGUF models, llama.cpp servers, and coding harnesses. It replaces v3's hardcoded model catalogue with automatic discovery and metadata-driven classification while retaining v3's strongest safety property: one authoritative launch plan controls the server and every client context.

The first supported environment is Windows 11, Windows PowerShell 5.1, llama.cpp b10229 or newer, an NVIDIA RTX 4070 with 12 GB VRAM, a Ryzen 9 7900X3D, and 32 GB RAM. Hardware detection and profile generation must not encode those components as universal assumptions. A future machine or compatible GGUF must receive a conservative usable configuration without a source-code change.

## Scope

Version 4 will provide:

- automatic discovery of local GGUFs from Hugging Face caches and configurable folders;
- metadata inspection, shard validation, and classification of main models, projectors, and draft/MTP sidecars;
- safe instant profiles and user overrides;
- a small curated model-tuning layer that only overrides derived defaults;
- optional benchmark/autotune with results scoped to a machine and model fingerprint;
- model inventory, Hugging Face download, move, and delete workflows with confirmations;
- detection, installation guidance/actions, managed configuration, and launch for Pi, OMP, OpenCode, Codex, and Claude Code;
- a manifest-based adapter contract for additional OpenAI-compatible harnesses;
- llama.cpp server start, stop, inspect, health verification, and log access;
- live GPU, RAM, process, port, and server statistics;
- Doctor diagnostics for launcher, hardware, models, llama.cpp, server flags, ports, harnesses, and synchronized contexts;
- atomic state writes, configuration backups, session manifests, and rollback;
- an interactive menu and a complete non-interactive command surface;
- offline self-tests and non-destructive live-machine checks.

The system will not automatically upload model data, install software silently, benchmark on first launch, edit cloud-provider profiles, guess a missing chat template for agent use, pair a projector with an unverified incompatible model, or terminate an unrelated process merely because it owns the desired port.

## Packaging and Migration

The distributable layout is:

```text
LocalAI-Control-Center-v4/
|-- local-ai.cmd
|-- local-ai-v4.ps1
|-- Install-LocalAI.ps1
|-- Uninstall-LocalAI.ps1
|-- README.md
|-- MIGRATION.md
|-- CHANGELOG.md
|-- LocalAI/
|   |-- LocalAI.psd1
|   |-- Modules/
|   |   |-- Common.psm1
|   |   |-- Configuration.psm1
|   |   |-- Hardware.psm1
|   |   |-- Gguf.psm1
|   |   |-- Discovery.psm1
|   |   |-- Profiles.psm1
|   |   |-- Runtime.psm1
|   |   |-- Harnesses.psm1
|   |   |-- Downloads.psm1
|   |   |-- Benchmark.psm1
|   |   |-- Diagnostics.psm1
|   |   `-- UI.psm1
|   |-- Adapters/
|   |   |-- pi.json
|   |   |-- omp.json
|   |   |-- opencode.json
|   |   |-- codex.json
|   |   |-- claude.json
|   |   `-- custom.example.json
|   `-- Config/
|       |-- defaults.json
|       |-- profiles.json
|       `-- model-overrides.json
|-- tests/
|   |-- Invoke-Tests.ps1
|   |-- TestHelpers.ps1
|   `-- *.Tests.ps1
`-- reference/
    |-- local-ai-v3.ps1
    `-- V3-SHA256.txt
```

Installation defaults to `C:\llamacpp`, where the existing llama.cpp binaries reside. The installer must:

1. verify PowerShell 5.1 or newer and locate `llama-server.exe`;
2. compute and record the existing `local-ai.ps1` SHA-256 hash;
3. copy v3 to a timestamped backup and the package's `reference` directory without modifying its bytes;
4. install v4 modules and create `local-ai.cmd` plus `local-ai-v4.ps1` alongside the existing launcher;
5. avoid replacing `local-ai.ps1`, `start-local.cmd`, model files, logs, or existing user state;
6. offer an explicit, separately confirmed option to make the v4 command the user's preferred shortcut.

The `.cmd` entry point invokes Windows PowerShell with `-NoProfile -ExecutionPolicy Bypass -File` and passes through all arguments. This changes policy only for the child process. Running `local-ai.ps1` must continue to invoke v3 after migration.

## Runtime and State Boundaries

Code and shipped defaults live under the installation directory. Mutable per-user state lives under `%USERPROFILE%\.local-ai-control\v4`:

```text
v4/
|-- settings.json
|-- models.json
|-- active.json
|-- benchmarks.json
|-- adapters/
|-- backups/<timestamp>/manifest.json
|-- logs/<timestamp>-<operation>.log
`-- cache/server-capabilities.json
```

Every mutable JSON document has `schemaVersion`, `updatedAt`, and its domain payload. Unknown properties are retained when practical. Writes use a same-directory temporary file, validation by re-reading the serialized JSON, and atomic replacement. Corrupt state is quarantined with a timestamp and replaced only after the user is told. Shipped configuration is read-only; user configuration overlays it by stable identifiers.

Paths are handled as literal paths. No destructive operation accepts an empty path, a drive root, the installation root, the state root, a model-search root, a wildcard-expanded target, or a target outside the model roots unless the user explicitly supplied that exact path. Move and delete screens show the resolved path, linked-file target, shard group, and byte count before confirmation. Deletion defaults to the Recycle Bin when available and otherwise requires a second explicit confirmation.

## Core Contracts

### Machine fingerprint

`Get-LocalAIMachine` returns a stable object containing Windows version, PowerShell version, CPU model/core counts, total RAM, GPU names/UUIDs/VRAM/driver where available, llama.cpp executable path, and llama.cpp build identifier. The benchmark fingerprint hashes the performance-relevant normalized fields: CPU model and logical processors, total RAM bucket, selected GPU UUID/name and VRAM, driver major version, llama.cpp build, and launcher benchmark-schema version.

Missing `nvidia-smi` does not prevent CPU-only use. NVIDIA-specific recommendations and statistics are marked unavailable rather than invented.

### Model identity and metadata

The GGUF reader is implemented with an embedded C# type loaded once from PowerShell. It reads GGUF v2/v3 headers and metadata key/value pairs, skips tensors and large tokenizer arrays safely, checks all declared lengths before allocation or seeking, and imposes limits on metadata count, key length, string length, array nesting, and array length. Unsupported or malformed metadata produces a classified error instead of a partial trusted record.

A model fingerprint combines the canonical path, resolved file identity, logical shard-set names and sizes, first-shard SHA-256 sample/full hash policy, GGUF general name, architecture, parameter/file type metadata when present, and total logical bytes. Link stubs in the Hugging Face cache are resolved before byte sizing and metadata access.

`Get-LocalAIModelMetadata` exposes at least:

- architecture and general name;
- native context key/value discovered from `<architecture>.context_length`;
- quantization/file type and size;
- block/layer, embedding, expert, and active-expert counts when present;
- embedded chat template presence and relevant reasoning markers;
- embedded next-token prediction/MTP metadata when present;
- projector/draft indicators;
- raw selected metadata used to explain classification.

An unknown architecture is still inventoried. It receives only conservative profiles if it declares a valid positive native context and an embedded chat template. Agent launch is blocked when no embedded template exists unless the user supplies an explicit template file using expert mode; the launcher never guesses one.

### Discovery

Default search roots are:

- `%HF_HUB_CACHE%` when set;
- `%HF_HOME%\hub` when set and `HF_HUB_CACHE` is not set;
- `%USERPROFILE%\.cache\huggingface\hub` otherwise;
- `<InstallRoot>\models`;
- user-added literal directories from settings.

Discovery traverses only existing roots, handles access failures per directory, ignores lock/temp/partial-download files, groups split files matching `-00001-of-NNNNN.gguf`, and reports missing or duplicate shards. A shard group has one selectable main entry. Files beginning with or classified as `mmproj`, projector, MTP, or draft are sidecars and cannot be selected as the main model.

Sidecar pairing is evidence-based: same repository/snapshot or directory, compatible architecture/family metadata when available, and curated overrides for known cross-repository relationships. Ambiguous candidates remain unpaired and are shown for expert selection.

Discovery caches records by resolved path, length, and last-write time. A rescan reuses unchanged valid metadata, removes vanished entries from the current inventory without deleting history, and persists errors so Doctor can explain them. New files appear without editing configuration or code.

### Classification

Classification derives rather than asserts:

- dense versus MoE from expert metadata;
- context ceiling from GGUF metadata;
- quantization from metadata with filename fallback labeled as inferred;
- reasoning support from template and known metadata markers;
- vision and MTP availability from compatible sidecars/embedded fields;
- likely roles from architecture, name tokens, template, and curated hints;
- approximate memory fit from logical model bytes, KV estimate, projector/draft reserve, detected free/total VRAM, and system RAM.

Every classification field records its evidence source (`metadata`, `filename`, `override`, `benchmark`, or `unknown`) and a confidence level. Curated overrides match stable metadata/filename predicates and may adjust labels, task hints, sampling defaults, verified sidecar relationships, and bounded tuning values. They never replace discovered paths or raise context above native metadata.

## Profiles and Authoritative Launch Plan

Shipped intent profiles are `Auto`, `CodingQuality`, `CodingFast`, `AgentLong`, `General`, `DeepReasoning`, `LongContext`, `Vision`, and `Expert`. Each describes goals and safe ranges rather than a fixed model command.

The profile engine combines, in order:

1. hard safety ceilings from metadata and hardware;
2. shipped generic defaults;
3. a matching curated model override;
4. a valid benchmark winner for the exact machine/model/profile fingerprint;
5. explicit command-line or interactive expert overrides.

The result is a new `LaunchPlan` object. No module mutates it after construction. It contains the plan/schema version, model identity, all shard/sidecar paths, alias, profile and task, context and client context, KV types, batch/ubatch, threads, GPU placement/fit target, Flash Attention, cache settings, sampling defaults, reasoning policy, endpoint URLs, server flags, expected server identity, log path, and provenance for each tunable field.

Safety rules inherited from v3 remain mandatory:

- context is positive and never exceeds GGUF native context;
- main shard sets are complete before launch;
- sidecars cannot be main models;
- projectors and draft models must exist and be compatible or explicitly accepted in expert mode;
- MTP is off unless embedded/paired support is proved, then remains profile/benchmark controlled;
- VRAM reserves include GPU projectors and speculative allocations;
- no blanket CPU MoE offload is introduced as a generic default;
- server arguments contain no duplicate flags;
- every generated long flag is advertised by the installed `llama-server --help`;
- the plan prints exact arguments and explains derived choices before mutation or launch;
- dry-run performs discovery, metadata, plan, compatibility, and flag validation but changes no files and starts nothing.

The initial conservative target for the reference RTX 4070 machine preserves free VRAM headroom and prioritizes a successful load. The launcher must describe this as a safe estimate, not an optimized claim. Only benchmark evidence can promote a setting as machine-optimized.

## Server Lifecycle

The runtime module locates llama.cpp tools relative to the install root or an explicit configured directory and records build capabilities. It starts `llama-server.exe` without shell interpolation, redirects output to a session log, and writes an initial launch manifest.

Before start it checks the requested port. An existing process is stopped only when all of the following are true: the user requested replacement, the process can be identified, it is a llama-server process, and the resolved executable belongs to the configured llama.cpp installation. Otherwise the launcher reports the owner and offers another port.

After start, v4 waits with a bounded timeout, detects premature process exit, calls the health endpoint, reads the model listing, and verifies the expected alias. Harness synchronization occurs only after the server proves what it serves. If later setup fails, a server started by this invocation is stopped; a pre-existing server is never stopped as cleanup.

`active.json` stores PID, process start time, executable, plan ID, endpoint, model fingerprint, manifest, and ownership token. Stop and restart operations revalidate PID plus process start time and executable before acting, preventing PID-reuse errors.

Server Manager provides list/status, start from saved plan, stop owned server, restart, health/model verification, open log, and copy endpoint/command. It does not claim management of an externally launched server.

## Harness Adapters and Context Synchronization

Each adapter manifest defines a stable ID, display name, executable candidates, version probe, supported endpoint protocol, installation methods, configuration strategy, launch argument template, environment mapping, and capability notes. Shipped adapters cover Pi, OMP, OpenCode, Codex, and Claude Code. User adapters live in the state directory and are schema-validated; invalid adapters are disabled with a diagnostic.

Install actions are explicit. The screen displays the package manager, exact command, source package, and expected executable, then asks for confirmation. Installation runs directly without `Invoke-Expression`, captures a log, verifies the executable/version afterward, and never elevates privileges automatically. When no verified automated method exists, the adapter presents copyable official installation guidance instead of guessing.

Configuration strategies preserve v3's cloud-safety boundaries:

- Pi and OMP: back up files and update only a uniquely delimited managed local-model block;
- OpenCode and Codex: generate launcher-owned local override files and pass them explicitly;
- Claude Code: use process-scoped environment variables and launch arguments, restoring the previous process environment afterward;
- custom adapters: default to process-scoped environment/arguments; direct file mutation must be explicitly declared and backed up.

The adapter consumes only the immutable `LaunchPlan`. Endpoint, model alias, context window, client maximum output, compaction reserve/threshold, sampling defaults, and reasoning settings therefore come from one source. Client context must equal the server plan context unless an adapter has a documented lower ceiling, in which case Doctor reports the reduction prominently. Cloud-provider entries and credentials are never removed or overwritten.

Harness Manager provides detect, version, install/update guidance, preview config, apply config, restore backup, and launch in a validated project directory. Harness presence is checked before a costly model load when one is selected.

## Model Manager and Downloads

Model Manager lists installed models, search roots, validation state, total logical bytes, roles, fit estimate, sidecars, and benchmark status. It can add/remove search roots, rescan, reveal a file, move a complete model group, recycle/delete a complete model group, and launch or benchmark a selection.

Downloads use `hf.exe`/`huggingface-cli` when available and support repository plus filename, a parseable Hugging Face URL, or a curated suggestion. The launcher previews repository, revision when supplied, filename, destination/cache behavior, and command. It requires confirmation, records progress/output, recognizes partial files, and rescans only after a successful exit. Authentication tokens are inherited from the tool or process environment and are never written to launcher logs/state. Arbitrary shell fragments are rejected; repository/revision/filename are passed as separate arguments.

Search of the remote Hugging Face catalogue is optional and clearly marked as networked. Offline inventory and launch remain fully functional without Hugging Face tools or connectivity.

## Benchmark and Autotune

Autotune is opt-in and starts from a model plus task profile. It builds a bounded candidate matrix around safe defaults: context tier, KV type, ubatch, thread counts, fit target/GPU placement, and MTP only when proven. It does not attempt an unbounded Cartesian product.

Each candidate goes through:

1. static validation against metadata, hardware budget, and supported flags;
2. a bounded server start/load test;
3. warm-up;
4. repeated prompt-processing and generation measurements;
5. optional fixed local quality/correctness probes appropriate to the selected task;
6. health, output-validity, memory-headroom, and crash checks;
7. cleanup of only the benchmark-owned process.

Failed or out-of-memory candidates are retained as negative evidence. Scores keep raw prompt tokens/second, generation tokens/second, latency, peak VRAM/RAM, stability, context, and probe results. The winner is selected using the declared profile objective and minimum safety headroom; raw data remains inspectable. A result is eligible only for the exact machine/model/llama.cpp/benchmark-schema fingerprint and becomes stale when any fingerprint component changes.

Autotune never labels a model smarter or better from throughput alone. Quality probes are local regression indicators, not general intelligence measurements. The user can pin, unpin, compare, export, or delete benchmark records.

## Statistics and Doctor

The live statistics screen refreshes at a configurable interval and shows available GPU utilization, VRAM used/total, temperature, power, system RAM, server PID/runtime, endpoint health, active model/profile/context, and recent log throughput when parseable. Individual metric failures render as unavailable and do not terminate the dashboard. Exit restores normal console behavior.

Doctor has offline and live modes and emits `Pass`, `Warning`, `Fail`, or `Skipped` results with a stable code, human explanation, evidence, and remediation. Checks include:

- PowerShell and Windows compatibility;
- install/state directory read/write access;
- JSON schemas and recoverability;
- llama.cpp binary/build and adjacent CUDA/runtime dependencies;
- advertised flags required by generated plans;
- hardware detection and available memory;
- configured roots, broken Hugging Face links, partial downloads, malformed GGUFs, shard completeness, templates, and sidecar ambiguity;
- active port ownership and stale process state;
- harness command/version detection and adapter validity;
- backup manifests and rollback targets;
- active server health, served alias, and synchronized client contexts.

Doctor is non-destructive by default. Fix actions are individually described and confirmed. The report can be saved with secrets and tokens redacted.

## Backups, Rollback, and Logs

Before any managed external configuration edit, v4 creates one operation-scoped backup session. Its manifest records timestamp, operation, original path, backup path, pre-change hash, post-change hash, and strategy. Rollback verifies the current and expected hashes, previews conflicts, and never overwrites a file changed since the managed edit without explicit confirmation.

Generated files are written atomically. Logs identify the operation, plan ID, commands with secret-bearing arguments redacted, exit codes, and errors. Launch manifests have `Created` and `Ready` phases like v3 so an interrupted setup is distinguishable from a verified server. Default retention is bounded by count and age and cleanup never includes model files or unrecognized directories.

## Terminal Experience and Command Surface

Interactive startup shows a compact header with detected GPU, CPU, RAM, llama.cpp build, server state, and counts of ready/warning/error models. The primary menu is:

```text
[1] Launch Model
[2] Smart Task Launcher
[3] Models
[4] Coding Harnesses
[5] Benchmark / Auto-Tune
[6] Performance & Statistics
[7] Download Models
[8] Server Manager
[9] Doctor / Diagnostics
[S] Settings
[Q] Quit
```

Color is supplemental; status always has text. Narrow terminals fall back to simple lines. Input loops reject invalid choices without losing state. Expensive or destructive actions include a summary and confirmation. Errors lead with the actionable cause and include the log path when one exists.

The non-interactive surface mirrors interactive operations. At minimum it supports `-Command Menu|Discover|ListModels|Plan|Launch|Stop|Status|Doctor|Benchmark|Download|Harnesses|Backup|Rollback|SelfTest`, plus model/profile/task/harness/project/server and `-Json`, `-DryRun`, `-NonInteractive` options. Commands return zero only when their requested operation succeeds and structured JSON goes to stdout without decorative text.

## Compatibility

All shipped PowerShell parses and runs under Windows PowerShell 5.1 with `Set-StrictMode -Version 2.0`. The implementation avoids PowerShell 7-only syntax and cmdlets. Native processes use `System.Diagnostics.ProcessStartInfo` or argument arrays with explicit Windows-safe quoting rather than evaluated command strings. Text written for machine consumption is UTF-8 with a documented encoding compatible with PowerShell 5.1 readers.

llama.cpp b10229 is the reference capability floor, but flags are capability-detected. A newer build is accepted when it advertises required flags. A missing optional flag disables the dependent feature; a missing required flag blocks that plan rather than silently dropping it.

## Testing and Acceptance

The test runner uses PowerShell only and must work without Pester. Tests import modules in isolation and use temporary directories and generated fixtures. They do not load a real model, edit real harness configuration, download files, or stop processes unless a separate live acceptance command is explicitly chosen.

Automated coverage includes:

- parsing every script/module under PowerShell 5.1;
- GGUF v2/v3 scalar, string, array-skip, malformed length, and unsupported type fixtures;
- discovery of ordinary files, Hugging Face links, split sets, missing shards, ignored partials, and sidecars;
- metadata-driven dense/MoE/context/template/MTP classification and unknown architectures;
- generic profile ceilings, memory reserves, override precedence, benchmark precedence, and explicit overrides;
- launch-plan immutability expectations, duplicate flags, unsupported flags, unsafe context, and exact argument construction;
- machine/model fingerprint stability and benchmark staleness;
- adapter schema validation and context synchronization for all five shipped adapters;
- atomic writes, corrupt-state quarantine, backups, hash-conflict rollback, and path-safety rejection;
- port/process ownership decisions, health timeout, served-alias mismatch, and cleanup ownership;
- command exit codes, JSON output cleanliness, redaction, and menu input recovery.

Acceptance requires fresh evidence from:

1. the full offline test suite with zero failures;
2. v4 `SelfTest` with zero failures;
3. a dry-run against at least one actual discovered model, proving link resolution, metadata, plan, and b10229 flag compatibility without mutation;
4. non-destructive Doctor output on the target machine;
5. verification that the installed and packaged v3 backup hashes equal the original `C:\llamacpp\local-ai.ps1` hash;
6. verification that dry-run and Doctor did not alter external harness configurations;
7. an explicit list of any unperformed resource-intensive acceptance, including real CUDA model load, benchmark matrix, download, harness installation, or interactive harness session.

Completion claims must distinguish offline logic verification, live non-destructive validation, real inference validation, and external harness validation. Passing tests alone does not prove throughput, model quality, network downloads, or third-party harness behavior.

## Delivery

The finished delivery includes the complete source tree, preserved v3 reference and hash, install/uninstall/migration instructions, test runner and fixtures, default configuration and adapter manifests, changelog, verification report with commands and results, and a ZIP archive. The package is first built and verified in the workspace; installation into `C:\llamacpp` occurs only as an explicit migration step after package verification.
