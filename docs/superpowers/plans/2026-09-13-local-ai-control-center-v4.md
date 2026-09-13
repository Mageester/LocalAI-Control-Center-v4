# Local AI Control Center v4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a safe, modular Windows PowerShell 5.1 control center that discovers future GGUF models automatically, derives and validates launch plans, manages llama.cpp and coding harnesses, and retains evidence-backed machine-specific tuning.

**Architecture:** A thin `local-ai-v4.ps1` command router imports focused modules through `LocalAI.psd1`. Shipped JSON is immutable input; user state overlays it under `%USERPROFILE%\.local-ai-control\v4`; every server and harness action consumes one immutable launch plan. Tests run without Pester or real model loads by using a small assertion harness, generated GGUF fixtures, temporary state roots, and injected process/system probes.

**Tech Stack:** Windows PowerShell 5.1, embedded C# via `Add-Type`, JSON, `System.Diagnostics.Process`, Windows CIM, `nvidia-smi`, llama.cpp b10229+, Hugging Face CLI.

**Spec:** `docs/superpowers/specs/2026-09-13-local-ai-control-center-v4-design.md`

## Global Constraints

- Windows 11 and Windows PowerShell 5.1 are the reference runtime; no PowerShell 7-only syntax or cmdlets.
- llama.cpp b10229 is the reference capability floor; feature flags are validated against the installed `llama-server --help`.
- `C:\llamacpp\local-ai.ps1` remains byte-for-byte unchanged and runnable as v3.
- Automatic GGUF discovery is primary; curated entries are optional metadata/tuning overlays, never the source of file existence.
- A valid embedded chat template is required for non-expert agent launch.
- Benchmarking, downloads, installs, moves, deletes, external configuration edits, and real model loads never happen implicitly.
- Harness synchronization happens only after the server health and served alias are verified.
- Every mutable external configuration edit is atomic and backed up with hashes before mutation.
- Dry-run and offline tests do not mutate external configs, start servers, download files, or load models.
- Tests must demonstrate RED before production implementation and GREEN afterward.
- Completion distinguishes offline tests, live non-destructive checks, real inference, and third-party harness validation.

---

### Task 1: Test Harness, Module Manifest, and Safe Persistence

**Files:**
- Create: `tests/Invoke-Tests.ps1`
- Create: `tests/TestHelpers.ps1`
- Create: `tests/Common.Tests.ps1`
- Create: `LocalAI/LocalAI.psd1`
- Create: `LocalAI/Modules/Common.psm1`
- Create: `LocalAI/Modules/Configuration.psm1`
- Create: `LocalAI/Config/defaults.json`
- Create: `LocalAI/Config/profiles.json`
- Create: `LocalAI/Config/model-overrides.json`

**Interfaces:**
- Produces: `Assert-Equal`, `Assert-True`, `Assert-Throws`, `Invoke-TestCase`, `Invoke-LocalAITests`.
- Produces: `Get-LocalAIPaths -InstallRoot <string> -StateRoot <string>`.
- Produces: `Read-LocalAIJson -Path <string> -Default <object>` and `Write-LocalAIJsonAtomic -Path <string> -Value <object>`.
- Produces: `Test-LocalAISafePath -Path <string> -AllowedRoots <string[]> -Operation <string>`.
- Produces: `Merge-LocalAIObject -Base <object> -Overlay <object>`.

- [ ] **Step 1: Write failing persistence and path-safety tests**

```powershell
Invoke-TestCase 'atomic JSON round trip' {
    $path = Join-Path $script:TestRoot 'state\settings.json'
    Write-LocalAIJsonAtomic -Path $path -Value ([pscustomobject]@{ schemaVersion=1; name='alpha' })
    $actual = Read-LocalAIJson -Path $path
    Assert-Equal 'alpha' $actual.name
}
Invoke-TestCase 'drive root is never a safe model target' {
    Assert-Throws { Test-LocalAISafePath -Path 'C:\' -AllowedRoots @('C:\models') -Operation Delete }
}
Invoke-TestCase 'overlay retains base values' {
    $actual=Merge-LocalAIObject ([pscustomobject]@{ a=1; b=2 }) ([pscustomobject]@{ b=3 })
    Assert-Equal 1 $actual.a
    Assert-Equal 3 $actual.b
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern Common`

Expected: non-zero exit with missing `Write-LocalAIJsonAtomic` or missing module manifest.

- [ ] **Step 3: Implement the test harness, paths, persistence, merge, and safety primitives**

Implement `Invoke-TestCase` so it records pass/fail, prints the exception on failure, and makes the runner exit 1 when any test fails. `Write-LocalAIJsonAtomic` creates the parent, serializes at depth 50 to a same-directory GUID `.tmp`, re-reads it with `ConvertFrom-Json`, then uses `[IO.File]::Replace` when the destination exists or `[IO.File]::Move` otherwise. `Read-LocalAIJson` quarantines invalid JSON to `<name>.corrupt-<timestamp>` and either returns the supplied default or throws. `Test-LocalAISafePath` resolves full paths, rejects empty/root/protected-root targets, and requires containment within one allowed root.

- [ ] **Step 4: Run focused and full tests and verify GREEN**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern Common`

Expected: exit 0 and all Common tests pass.

- [ ] **Step 5: Commit**

```powershell
git add tests LocalAI
git commit -m "feat: add v4 module foundation and safe persistence"
```

### Task 2: Defensive GGUF Metadata Reader

**Files:**
- Create: `tests/Gguf.Tests.ps1`
- Modify: `tests/TestHelpers.ps1`
- Create: `LocalAI/Modules/Gguf.psm1`

**Interfaces:**
- Consumes: test harness from Task 1.
- Produces: `Initialize-LocalAIGgufReader`.
- Produces: `Read-LocalAIGgufMetadata -Path <string>` returning a case-insensitive dictionary.
- Produces: `Get-LocalAIGgufSummary -Path <string>` returning `Architecture`, `Name`, `NativeContext`, `Quantization`, `ChatTemplate`, `MtpHeads`, expert counts, and selected evidence.

- [ ] **Step 1: Add GGUF fixture writer and failing reader tests**

```powershell
Invoke-TestCase 'reads an unknown architecture without a registry entry' {
    $path=New-TestGguf -Metadata ([ordered]@{
        'general.architecture'='futurearch'
        'general.name'='Future Coder 12B Q5_K_M'
        'futurearch.context_length'=[uint32]131072
        'tokenizer.chat_template'='{{ messages }}'
    })
    $m=Get-LocalAIGgufSummary -Path $path
    Assert-Equal 'futurearch' $m.Architecture
    Assert-Equal 131072 $m.NativeContext
}
Invoke-TestCase 'rejects a metadata string beyond the safety limit' {
    $path=New-MalformedTestGguf -DeclaredStringLength ([uint64]::MaxValue)
    Assert-Throws { Read-LocalAIGgufMetadata -Path $path } 'safety limit'
}
Invoke-TestCase 'skips tokenizer arrays without materializing them' {
    $path=New-TestGguf -IncludeTokenArray
    $m=Read-LocalAIGgufMetadata -Path $path
    Assert-Equal 'qwen' $m['general.architecture']
}
```

- [ ] **Step 2: Run GGUF tests and verify RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern Gguf`

Expected: non-zero exit because `Get-LocalAIGgufSummary` is unavailable.

- [ ] **Step 3: Implement embedded C# GGUF v2/v3 reader**

The compiled reader validates magic/version, metadata count, key/string/array lengths, scalar types, file bounds, and nesting depth. It returns scalar and string values but records a bounded placeholder for large arrays. The PowerShell summary discovers `<architecture>.context_length`, accepts any architecture string, and never uses a curated registry to decide whether a file is readable.

- [ ] **Step 4: Run GGUF and full tests and verify GREEN**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern Gguf`

Expected: all valid fixtures pass and malformed fixtures are rejected.

- [ ] **Step 5: Commit**

```powershell
git add tests LocalAI/Modules/Gguf.psm1
git commit -m "feat: read GGUF metadata defensively"
```

### Task 3: Hardware Detection, Discovery, and Classification

**Files:**
- Create: `tests/Hardware.Tests.ps1`
- Create: `tests/Discovery.Tests.ps1`
- Create: `LocalAI/Modules/Hardware.psm1`
- Create: `LocalAI/Modules/Discovery.psm1`

**Interfaces:**
- Consumes: `Read-LocalAIGgufMetadata`, configuration paths, atomic JSON.
- Produces: `Get-LocalAIMachine -LlamaRoot <string>`.
- Produces: `Get-LocalAIMachineFingerprint -Machine <object>`.
- Produces: `Get-LocalAIModelRoots -InstallRoot <string> -Settings <object>`.
- Produces: `Find-LocalAIModels -Roots <string[]> -CachePath <string> -Force`.
- Produces: `Get-LocalAIModelClassification -Model <object> -Machine <object> -Overrides <object[]>`.

- [ ] **Step 1: Write failing deterministic hardware/discovery tests**

```powershell
Invoke-TestCase 'fingerprint ignores free-memory drift' {
    $a=[pscustomobject]@{ Cpu='CPU'; LogicalProcessors=24; RamBytes=32GB; GpuName='GPU'; GpuUuid='1'; VramBytes=12GB; Driver='616.56'; LlamaBuild='10229'; FreeVramBytes=10GB }
    $b=$a.PSObject.Copy(); $b.FreeVramBytes=8GB
    Assert-Equal (Get-LocalAIMachineFingerprint $a) (Get-LocalAIMachineFingerprint $b)
}
Invoke-TestCase 'groups one complete three-shard model' {
    New-TestShardSet -Root $script:TestRoot -Stem 'model' -Count 3
    $models=Find-LocalAIModels -Roots @($script:TestRoot) -CachePath (Join-Path $script:TestRoot 'cache.json') -Force
    Assert-Equal 1 @($models | Where-Object Kind -eq 'MainModel').Count
    Assert-Equal 3 $models[0].Shards.Count
}
Invoke-TestCase 'sidecar cannot become the main model' {
    New-TestGguf -Path (Join-Path $script:TestRoot 'mmproj-F16.gguf') | Out-Null
    $models=Find-LocalAIModels -Roots @($script:TestRoot) -CachePath (Join-Path $script:TestRoot 'cache.json') -Force
    Assert-Equal 0 @($models | Where-Object Kind -eq 'MainModel').Count
}
```

- [ ] **Step 2: Run Hardware and Discovery tests and verify RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern 'Hardware|Discovery'`

Expected: missing discovery/hardware functions.

- [ ] **Step 3: Implement generic probes, cache-aware scanning, grouping, and evidence-bearing classification**

Use injectable command/CIM readers in tests. Resolve Hugging Face link files and Windows links, ignore `.incomplete`, `.lock`, `.tmp`, validate all shards, retain per-file errors, infer filename-only fields with `Source='filename'`, and attach curated fields only when all override predicates match.

- [ ] **Step 4: Run focused and full tests and verify GREEN**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern 'Hardware|Discovery'`

Expected: all hardware/discovery tests pass.

- [ ] **Step 5: Commit**

```powershell
git add tests LocalAI/Modules/Hardware.psm1 LocalAI/Modules/Discovery.psm1
git commit -m "feat: discover and classify local GGUF models"
```

### Task 4: Profiles and Immutable Launch Plans

**Files:**
- Create: `tests/Profiles.Tests.ps1`
- Create: `LocalAI/Modules/Profiles.psm1`
- Modify: `LocalAI/Config/profiles.json`
- Modify: `LocalAI/Config/model-overrides.json`

**Interfaces:**
- Consumes: model classification, machine, shipped profiles/overrides, optional benchmarks.
- Produces: `Get-LocalAISafeProfile -Model <object> -Machine <object> -Intent <string>`.
- Produces: `New-LocalAILaunchPlan -Model <object> -Machine <object> -Intent <string> -Overrides <hashtable> -ServerCapabilities <object>`.
- Produces: `Test-LocalAILaunchPlan -Plan <object> -ServerCapabilities <object>`.
- Produces: `Get-LocalAIClientPolicy -Context <int64>`.

- [ ] **Step 1: Write failing precedence and safety tests**

```powershell
Invoke-TestCase 'safe context never exceeds native context' {
    $plan=New-TestLaunchPlan -NativeContext 32768 -Intent LongContext
    Assert-Equal 32768 $plan.Context
}
Invoke-TestCase 'missing chat template blocks normal agent plan' {
    Assert-Throws { New-TestLaunchPlan -ChatTemplate '' -Intent CodingQuality } 'chat template'
}
Invoke-TestCase 'explicit context cannot exceed native metadata' {
    Assert-Throws { New-TestLaunchPlan -NativeContext 65536 -Overrides @{ Context=131072 } } 'native context'
}
Invoke-TestCase 'client policy is derived from the same context' {
    $p=Get-LocalAIClientPolicy -Context 131072
    Assert-Equal 131072 $p.ContextWindow
    Assert-Equal 32768 $p.CompactionReserve
}
```

- [ ] **Step 2: Run Profiles tests and verify RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern Profiles`

Expected: missing launch-plan implementation.

- [ ] **Step 3: Implement derivation, provenance, validation, and server argument construction**

Apply precedence `safety -> generic -> curated -> valid benchmark -> explicit`. Use model bytes and architecture metadata for conservative memory estimates, reserve GPU sidecars/speculation, cap context, validate every emitted flag, forbid duplicates, and return a newly constructed object with no setters used by downstream modules.

- [ ] **Step 4: Run Profiles and full tests and verify GREEN**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern Profiles`

Expected: all profile, precedence, and unsafe-input tests pass.

- [ ] **Step 5: Commit**

```powershell
git add tests LocalAI/Modules/Profiles.psm1 LocalAI/Config
git commit -m "feat: derive safe authoritative launch plans"
```

### Task 5: Owned llama.cpp Server Lifecycle

**Files:**
- Create: `tests/Runtime.Tests.ps1`
- Create: `LocalAI/Modules/Runtime.psm1`

**Interfaces:**
- Consumes: validated `LaunchPlan`, atomic state/log primitives.
- Produces: `Get-LocalAIServerCapabilities -Executable <string> -CachePath <string>`.
- Produces: `Get-LocalAIPortOwner -Port <int>`.
- Produces: `Start-LocalAIServer -Plan <object> -Executable <string> -StatePath <string>`.
- Produces: `Wait-LocalAIServer -Plan <object> -Process <Diagnostics.Process> -TimeoutSec <int>`.
- Produces: `Confirm-LocalAIServedModel -Plan <object>`.
- Produces: `Stop-LocalAIServer -StatePath <string>`.

- [ ] **Step 1: Write failing capability and ownership tests**

```powershell
Invoke-TestCase 'unsupported generated flag is rejected' {
    Assert-Throws { Test-LocalAIServerArguments -Arguments @('--model','x','--future-flag') -HelpText '--model PATH' } '--future-flag'
}
Invoke-TestCase 'PID reuse is rejected' {
    $state=[pscustomobject]@{ Pid=42; ProcessStartTime='2026-01-01T00:00:00Z'; Executable='C:\llama\llama-server.exe' }
    Assert-Throws { Test-LocalAIOwnedProcess -State $state -Actual (New-TestProcessInfo -StartTime '2026-01-02T00:00:00Z') } 'does not match'
}
Invoke-TestCase 'served alias mismatch fails before harness sync' {
    Assert-Throws { Confirm-TestServedModel -Expected 'alpha' -Returned @('beta') } 'alpha'
}
```

- [ ] **Step 2: Run Runtime tests and verify RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern Runtime`

Expected: missing runtime functions.

- [ ] **Step 3: Implement exact native invocation, capability parsing, ownership state, health, alias verification, and bounded cleanup**

Use `Diagnostics.ProcessStartInfo`, explicit Windows argument quoting, redirected logs, initial/ready manifests, process start-time ownership checks, and injected HTTP/process probes for tests. Replacement is allowed only for a verified llama-server from the configured root and only when requested.

- [ ] **Step 4: Run Runtime and full tests and verify GREEN**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern Runtime`

Expected: runtime tests pass without launching a real server.

- [ ] **Step 5: Commit**

```powershell
git add tests LocalAI/Modules/Runtime.psm1
git commit -m "feat: manage verified llama server lifecycle"
```

### Task 6: Backups, Rollback, and Harness Adapters

**Files:**
- Create: `tests/Harnesses.Tests.ps1`
- Create: `tests/Backups.Tests.ps1`
- Create: `LocalAI/Modules/Harnesses.psm1`
- Create: `LocalAI/Adapters/pi.json`
- Create: `LocalAI/Adapters/omp.json`
- Create: `LocalAI/Adapters/opencode.json`
- Create: `LocalAI/Adapters/codex.json`
- Create: `LocalAI/Adapters/claude.json`
- Create: `LocalAI/Adapters/custom.example.json`

**Interfaces:**
- Consumes: immutable plan, safe persistence, path safety.
- Produces: `Get-LocalAIHarnessAdapters`, `Test-LocalAIHarnessAdapter`, `Get-LocalAIHarnessStatus`.
- Produces: `New-LocalAIBackupSession`, `Backup-LocalAIFile`, `Restore-LocalAIBackup`.
- Produces: `Get-LocalAIHarnessConfiguration -Adapter <object> -Plan <object>`.
- Produces: `Set-LocalAIHarnessConfiguration -Adapter <object> -Plan <object> -BackupSession <object>`.
- Produces: `Install-LocalAIHarness -Adapter <object> -Confirm`, `Start-LocalAIHarness`.

- [ ] **Step 1: Write failing adapter synchronization and rollback-conflict tests**

```powershell
Invoke-TestCase 'all shipped adapters receive the plan context and alias' {
    foreach($adapter in Get-TestShippedAdapters) {
        $config=Get-LocalAIHarnessConfiguration -Adapter $adapter -Plan (New-TestPlan -Alias local-a -Context 131072)
        Assert-True ($config.Serialized -match 'local-a')
        Assert-True ($config.Serialized -match '131072')
    }
}
Invoke-TestCase 'rollback refuses a subsequently edited file' {
    $record=New-TestBackupThenManagedEdit
    Add-Content -LiteralPath $record.OriginalPath -Value 'user change'
    Assert-Throws { Restore-LocalAIBackup -Record $record } 'changed since'
}
Invoke-TestCase 'invalid custom install shell fragment is rejected' {
    $adapter=New-TestAdapter -InstallArguments @('package; Remove-Item C:\')
    Assert-Throws { Test-LocalAIHarnessAdapter $adapter } 'argument'
}
```

- [ ] **Step 2: Run Harnesses and Backups tests and verify RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern 'Harnesses|Backups'`

Expected: missing adapter/backup implementation.

- [ ] **Step 3: Implement schema-validated adapters and v3-compatible safety strategies**

Pi/OMP use uniquely delimited managed blocks with backup. OpenCode/Codex use launcher-owned override files. Claude uses process-scoped environment restored in `finally`. Custom adapters default to arguments/environment and cannot request file mutation without an explicit supported strategy. Install commands are executable plus argument arrays, never evaluated strings.

- [ ] **Step 4: Run focused and full tests and verify GREEN**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern 'Harnesses|Backups'`

Expected: all adapters validate and context/rollback tests pass.

- [ ] **Step 5: Commit**

```powershell
git add tests LocalAI/Modules/Harnesses.psm1 LocalAI/Adapters
git commit -m "feat: add safe harness adapters and rollback"
```

### Task 7: Model Manager and Hugging Face Downloads

**Files:**
- Create: `tests/Downloads.Tests.ps1`
- Create: `LocalAI/Modules/Downloads.psm1`

**Interfaces:**
- Consumes: model roots/discovery, safe paths, process invocation.
- Produces: `ConvertFrom-LocalAIHuggingFaceReference -Reference <string>`.
- Produces: `New-LocalAIDownloadPlan -Repository <string> -FileName <string> -Revision <string> -Destination <string>`.
- Produces: `Invoke-LocalAIDownload -Plan <object> -Confirm`.
- Produces: `Move-LocalAIModelGroup`, `Remove-LocalAIModelGroup`.

- [ ] **Step 1: Write failing parsing and injection/path tests**

```powershell
Invoke-TestCase 'parses a Hugging Face resolve URL into fields' {
    $r=ConvertFrom-LocalAIHuggingFaceReference 'https://huggingface.co/org/repo/resolve/main/model-Q4_K_M.gguf'
    Assert-Equal 'org/repo' $r.Repository
    Assert-Equal 'main' $r.Revision
    Assert-Equal 'model-Q4_K_M.gguf' $r.FileName
}
Invoke-TestCase 'rejects repository shell fragments' {
    Assert-Throws { New-LocalAIDownloadPlan -Repository 'org/repo;whoami' -FileName 'm.gguf' } 'repository'
}
Invoke-TestCase 'move includes every shard' {
    $group=New-TestShardSet -Root $script:TestRoot -Stem model -Count 2
    $plan=Get-TestMovePlan $group (Join-Path $script:TestRoot 'destination')
    Assert-Equal 2 $plan.Files.Count
}
```

- [ ] **Step 2: Run Downloads tests and verify RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern Downloads`

Expected: missing download-plan functions.

- [ ] **Step 3: Implement structured download plans and group-safe move/remove operations**

Validate `owner/repository`, revision, literal filename, and destination separately. Resolve `hf.exe` before planning. Display exact fields and redacted command, require confirmation, capture exit/log, and rescan only on exit 0. Group operations reject incomplete shards and protected/broad paths; remove uses the Recycle Bin where available.

- [ ] **Step 4: Run Downloads and full tests and verify GREEN**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern Downloads`

Expected: parser, injection, shard, and path tests pass without network access.

- [ ] **Step 5: Commit**

```powershell
git add tests LocalAI/Modules/Downloads.psm1
git commit -m "feat: manage local models and safe HF downloads"
```

### Task 8: Benchmark Records and Bounded Autotune

**Files:**
- Create: `tests/Benchmark.Tests.ps1`
- Create: `LocalAI/Modules/Benchmark.psm1`

**Interfaces:**
- Consumes: safe profile, launch-plan builder, runtime ownership, fingerprints, atomic JSON.
- Produces: `New-LocalAIBenchmarkMatrix -BasePlan <object> -Intent <string>`.
- Produces: `Invoke-LocalAIBenchmark -Candidates <object[]> -Runner <scriptblock>`.
- Produces: `Select-LocalAIBenchmarkWinner -Results <object[]> -Intent <string>`.
- Produces: `Get-LocalAIApplicableBenchmark -Store <object> -MachineFingerprint <string> -ModelFingerprint <string> -Intent <string>`.

- [ ] **Step 1: Write failing boundedness, staleness, and selection tests**

```powershell
Invoke-TestCase 'candidate matrix is bounded and unique' {
    $c=New-LocalAIBenchmarkMatrix -BasePlan (New-TestPlan) -Intent CodingFast
    Assert-True ($c.Count -le 16)
    Assert-Equal $c.Count @($c | ForEach-Object CandidateId | Select-Object -Unique).Count
}
Invoke-TestCase 'different llama build makes a result stale' {
    $r=New-TestBenchmarkRecord -MachineFingerprint old
    Assert-Equal $null (Get-LocalAIApplicableBenchmark -Store @($r) -MachineFingerprint new -ModelFingerprint $r.ModelFingerprint -Intent $r.Intent)
}
Invoke-TestCase 'quality intent rejects faster invalid probe result' {
    $winner=Select-LocalAIBenchmarkWinner -Results @((New-TestResult -Id fast -Tps 50 -ProbePass $false),(New-TestResult -Id valid -Tps 30 -ProbePass $true)) -Intent CodingQuality
    Assert-Equal 'valid' $winner.CandidateId
}
```

- [ ] **Step 2: Run Benchmark tests and verify RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern Benchmark`

Expected: missing benchmark functions.

- [ ] **Step 3: Implement candidate generation, injected runner, raw metrics, scoring, and exact fingerprint eligibility**

Limit candidate count, validate before running, retain negative/OOM evidence, score speed intents by throughput/latency with headroom gates, score quality intents only among valid probe results, and never describe throughput as intelligence.

- [ ] **Step 4: Run Benchmark and full tests and verify GREEN**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern Benchmark`

Expected: deterministic benchmark policy tests pass without real inference.

- [ ] **Step 5: Commit**

```powershell
git add tests LocalAI/Modules/Benchmark.psm1
git commit -m "feat: store evidence-backed bounded autotuning"
```

### Task 9: Diagnostics and Live Statistics

**Files:**
- Create: `tests/Diagnostics.Tests.ps1`
- Create: `LocalAI/Modules/Diagnostics.psm1`

**Interfaces:**
- Consumes: configuration, machine, discovery, runtime, adapters, backups.
- Produces: `New-LocalAIDiagnosticResult -Code <string> -Status <string> -Message <string> -Evidence <object>`.
- Produces: `Invoke-LocalAIDoctor -Context <object> -Live`.
- Produces: `Get-LocalAIStatistics -Context <object>`.
- Produces: `Export-LocalAIDoctorReport -Results <object[]> -Path <string>`.

- [ ] **Step 1: Write failing status/redaction/degradation tests**

```powershell
Invoke-TestCase 'metric failure becomes unavailable rather than fatal' {
    $s=Get-LocalAIStatistics -Context (New-TestContext -NvidiaProbe { throw 'missing' })
    Assert-Equal 'Unavailable' $s.Gpu.Status
}
Invoke-TestCase 'Doctor reports missing shard as fail' {
    $r=Invoke-LocalAIDoctor -Context (New-TestContextWithMissingShard)
    Assert-Equal 'Fail' (@($r | Where-Object Code -eq 'MODEL_SHARDS')[0].Status)
}
Invoke-TestCase 'export redacts tokens' {
    $text=ConvertTo-LocalAIRedactedText 'Authorization: Bearer hf_secretvalue'
    Assert-True ($text -notmatch 'secretvalue')
}
```

- [ ] **Step 2: Run Diagnostics tests and verify RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern Diagnostics`

Expected: missing diagnostic/statistics functions.

- [ ] **Step 3: Implement stable diagnostic codes, offline/live modes, independent metric probes, and redacted export**

Every check returns Pass/Warning/Fail/Skipped with evidence and remediation. Live-only HTTP/process checks are Skipped offline. Statistics catches each metric independently. Redaction covers common authorization headers, API-key environment names, HF tokens, and adapter secret fields.

- [ ] **Step 4: Run Diagnostics and full tests and verify GREEN**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern Diagnostics`

Expected: diagnostics pass with no live dependencies.

- [ ] **Step 5: Commit**

```powershell
git add tests LocalAI/Modules/Diagnostics.psm1
git commit -m "feat: add Doctor and resilient live statistics"
```

### Task 10: Terminal UI and Command Router

**Files:**
- Create: `tests/UI.Tests.ps1`
- Create: `tests/Commands.Tests.ps1`
- Create: `LocalAI/Modules/UI.psm1`
- Create: `local-ai-v4.ps1`
- Create: `local-ai.cmd`

**Interfaces:**
- Consumes: all prior modules.
- Produces: `Show-LocalAIMenu`, `Read-LocalAIChoice`, `Show-LocalAIPlan`, and screen functions.
- Produces: command surface `Menu|Discover|ListModels|Plan|Launch|Stop|Status|Doctor|Benchmark|Download|Harnesses|Backup|Rollback|SelfTest`.

- [ ] **Step 1: Write failing command and input-loop tests**

```powershell
Invoke-TestCase 'invalid menu input retries without losing the next valid input' {
    $queue=New-Object Collections.Queue
    $queue.Enqueue('x'); $queue.Enqueue('1')
    $choice=Read-LocalAIChoice -Allowed @('1','Q') -ReadInput { $queue.Dequeue() } -WriteOutput { param($s) }
    Assert-Equal '1' $choice
}
Invoke-TestCase 'JSON command emits parseable JSON only' {
    $text=Invoke-TestCommand -Arguments @('-Command','ListModels','-Json')
    $value=$text | ConvertFrom-Json
    Assert-True ($null -ne $value)
}
Invoke-TestCase 'cmd wrapper uses process-only bypass and passes arguments' {
    $cmd=Get-Content -LiteralPath (Join-Path $script:ProjectRoot 'local-ai.cmd') -Raw
    Assert-True ($cmd -match '-ExecutionPolicy Bypass')
    Assert-True ($cmd -match '%\*')
}
```

- [ ] **Step 2: Run UI and Commands tests and verify RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern 'UI|Commands'`

Expected: missing router/UI and wrapper.

- [ ] **Step 3: Implement thin orchestration and clean interactive screens**

Router initializes paths/config once and dispatches. `-Json` reserves stdout for JSON, sends errors to stderr, and suppresses decoration. `-DryRun` reaches plan validation but not mutation/runtime. Interactive screens use text labels plus color, simple narrow-terminal fallback, confirmation for costly/destructive work, and log paths in actionable failures.

- [ ] **Step 4: Run UI, Commands, and full tests and verify GREEN**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern 'UI|Commands'`

Expected: command parsing, JSON cleanliness, wrapper, and menu recovery pass.

- [ ] **Step 5: Commit**

```powershell
git add tests LocalAI/Modules/UI.psm1 local-ai-v4.ps1 local-ai.cmd
git commit -m "feat: add v4 terminal control center"
```

### Task 11: Installer, Preserved v3, Documentation, and Uninstaller

**Files:**
- Create: `tests/Install.Tests.ps1`
- Create: `Install-LocalAI.ps1`
- Create: `Uninstall-LocalAI.ps1`
- Create: `reference/local-ai-v3.ps1`
- Create: `reference/V3-SHA256.txt`
- Create: `README.md`
- Create: `MIGRATION.md`
- Create: `CHANGELOG.md`

**Interfaces:**
- Consumes: complete source tree and known original v3 path.
- Produces: `Install-LocalAI.ps1 -Destination <string> -SourceV3 <string> -WhatIf`.
- Produces: `Uninstall-LocalAI.ps1 -Destination <string> -KeepState -WhatIf`.

- [ ] **Step 1: Copy v3 byte-for-byte, record its hash, and write failing installer tests**

```powershell
Invoke-TestCase 'packaged v3 hash matches recorded hash' {
    $actual=(Get-FileHash (Join-Path $script:ProjectRoot 'reference\local-ai-v3.ps1') -Algorithm SHA256).Hash
    $expected=(Get-Content (Join-Path $script:ProjectRoot 'reference\V3-SHA256.txt') -Raw).Trim()
    Assert-Equal $expected $actual
}
Invoke-TestCase 'installer never targets local-ai.ps1 for replacement' {
    $plan=& (Join-Path $script:ProjectRoot 'Install-LocalAI.ps1') -Destination $script:TestRoot -SourceV3 (Join-Path $script:ProjectRoot 'reference\local-ai-v3.ps1') -WhatIf -PassThru
    Assert-Equal 0 @($plan.Writes | Where-Object RelativePath -eq 'local-ai.ps1').Count
}
```

- [ ] **Step 2: Run Install tests and verify RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern Install`

Expected: installer files/functions are missing while the v3 hash assertion passes.

- [ ] **Step 3: Implement safe install/uninstall plans and complete user documentation**

Installer verifies version/server, creates a timestamped v3 backup, installs only v4-owned paths, and supports `-WhatIf`. Uninstaller removes only manifest-owned v4 files after hash/conflict checks and preserves state by default. README documents menus and commands; MIGRATION documents backup, install, coexistence, validation, rollback, and reinstall; CHANGELOG distinguishes v3-preserved behavior and v4 additions.

- [ ] **Step 4: Run Install and full tests and verify GREEN**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Pattern Install`

Expected: hashes match and install plans never overwrite v3.

- [ ] **Step 5: Commit**

```powershell
git add tests Install-LocalAI.ps1 Uninstall-LocalAI.ps1 reference README.md MIGRATION.md CHANGELOG.md
git commit -m "docs: add safe migration and preserved v3 reference"
```

### Task 12: Fresh Verification, Live Dry Run, and Delivery Archive

**Files:**
- Create: `VERIFICATION.md`
- Create outside repository: `outputs/LocalAI-Control-Center-v4.zip`

**Interfaces:**
- Consumes: all tasks and live `C:\llamacpp` installation/cache.
- Produces: verified source package, evidence report, and ZIP.

- [ ] **Step 1: Run parser and full offline test suite fresh**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$errors=@(); Get-ChildItem -Recurse -File -Include *.ps1,*.psm1,*.psd1 | ForEach-Object { $t=$null; $e=$null; [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$t,[ref]$e); $errors += $e }; if($errors.Count){$errors|Format-List; exit 1}"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
```

Expected: both commands exit 0; test output reports zero failures.

- [ ] **Step 2: Run v4 SelfTest and non-destructive live Doctor**

Run:

```powershell
.\local-ai.cmd -Command SelfTest
.\local-ai.cmd -Command Doctor -InstallRoot C:\llamacpp -Json > doctor.json
Get-Content .\doctor.json -Raw | ConvertFrom-Json | Out-Null
```

Expected: SelfTest exits 0; Doctor output is parseable JSON. Warnings about model cache links or optional tools are documented rather than hidden.

- [ ] **Step 3: Run a non-mutating dry plan against an actual discovered model**

Run:

```powershell
$models = .\local-ai.cmd -Command ListModels -InstallRoot C:\llamacpp -Json | ConvertFrom-Json
$modelId = @($models | Where-Object Status -eq 'Ready' | Select-Object -First 1).Id
if (-not $modelId) { throw 'No ready discovered model is available for the live dry plan.' }
.\local-ai.cmd -Command Plan -InstallRoot C:\llamacpp -Model $modelId -Profile Auto -DryRun -Json
```

Expected: exit 0 with metadata, context not above native, exact supported b10229 flags, and no external writes/process starts. The model ID is selected from current discovery output rather than hardcoded.

- [ ] **Step 4: Verify v3 integrity and external-config non-mutation**

Record SHA-256 for `C:\llamacpp\local-ai.ps1`, packaged `reference\local-ai-v3.ps1`, and any external config files before/after dry validation. Expected: both v3 hashes equal the recorded source hash; external config hashes are unchanged.

- [ ] **Step 5: Write verification boundaries and create archive**

`VERIFICATION.md` records exact commands, timestamps, exit codes, test counts, Doctor results, dry-plan evidence, hashes, and explicit unperformed actions: real CUDA load, full benchmark, network download, harness install, and interactive third-party session unless the user separately opts in.

Create the ZIP from tracked source files only and verify extraction into a temporary directory followed by the full offline tests.

- [ ] **Step 6: Commit verification report**

```powershell
git add VERIFICATION.md
git commit -m "test: verify v4 package and live dry run"
```
