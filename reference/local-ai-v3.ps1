#requires -Version 5.1
<#
.SYNOPSIS
All-in-one local AI control center for llama.cpp and coding agents.
.DESCRIPTION
Select one local GGUF, runtime profile, vision mode, MTP mode, and coding harness.
The resulting launch plan is the single source of truth for llama.cpp context and
client configuration. The script safely synchronizes Pi, OMP, OpenCode, Codex,
and Claude Code launch settings, starts llama-server, waits for health, verifies
the served alias, and then launches the selected harness in your project folder.
Existing Pi/OMP configuration is backed up before managed edits. OpenCode/Codex
use generated local overrides and Claude Code uses process-scoped environment
variables, so cloud account configuration is preserved. No model weights are
downloaded automatically.
.EXAMPLE
.\local-ai.ps1
.EXAMPLE
.\local-ai.ps1 -Model qwen38-9b -Profile Daily -Vision Gpu -Mtp Auto -Harness Pi -ProjectDir C:\Development\MyProject
.EXAMPLE
.\local-ai.ps1 -Model qwen36 -Profile MaxContext -Vision Off -Mtp On -Harness OpenCode -StopExistingServer
.EXAMPLE
.\local-ai.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [string]$Model = '',
    [ValidateSet('Daily','MaxContext','Fast','Baseline')][string]$Profile = 'Daily',
    [ValidateSet('Off','Gpu','Cpu')][string]$Vision = 'Off',
    [ValidateSet('Auto','On','Off')][string]$Mtp = 'Auto',
    [string]$ModelPath = '',
    [string]$ProjectorPath = '',
    [string]$DraftPath = '',
    [ValidateRange(0,262144)][int]$Context = 0,
    [ValidateSet('Default','q8_0','q4_0','f16')][string]$KV = 'Default',
    [ValidateRange(0,8192)][int]$FitTargetMiB = 0,
    [ValidateRange(0,64)][int]$Threads = 0,
    [ValidateRange(0,64)][int]$ThreadsBatch = 0,
    [ValidateRange(0,2048)][int]$UBatch = 0,
    [ValidateRange(1,65535)][int]$Port = 8080,
    [ValidateSet('Pi','OMP','OpenCode','Codex','Claude','Server','None')][string]$Harness = '',
    [string]$ProjectDir = '',
    [switch]$SyncOnly,
    [switch]$StopExistingServer,
    [ValidateRange(10,600)][int]$ServerReadyTimeoutSec = 180,
    [switch]$DryRun,
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:ControlRoot = Join-Path $env:USERPROFILE '.local-ai-control'
$script:BackupRoot = Join-Path $script:ControlRoot 'backups'
$script:BackupSessionDir = ''
$script:ManagedBlockBegin = '  # BEGIN LOCAL-AI-CONTROL'
$script:ManagedBlockEnd = '  # END LOCAL-AI-CONTROL'

# BEGIN_PRESETS_JSON
$script:PresetData = @'
{
  "profiles": {
    "Daily":      {"context":131072,"kvMoe":"q8_0","kvGemma":"q8_0","fitTargetMiB":1024,"cacheRamMiB":1536,"checkpoints":8,"batch":2048,"ubatchMoe":1024,"ubatchGemma":512},
    "MaxContext": {"context":262144,"kvMoe":"q8_0","kvGemma":"q8_0","fitTargetMiB":1536,"cacheRamMiB":1536,"checkpoints":8,"batch":2048,"ubatchMoe":1024,"ubatchGemma":512},
    "Fast":       {"context":65536, "kvMoe":"q8_0","kvGemma":"q8_0","fitTargetMiB":1024,"cacheRamMiB":1024,"checkpoints":8,"batch":2048,"ubatchMoe":1024,"ubatchGemma":512},
    "Baseline":   {"context":131072,"kvMoe":"q4_0","kvGemma":"q8_0","fitTargetMiB":1536,"cacheRamMiB":1536,"checkpoints":8,"batch":2048,"ubatchMoe":1024,"ubatchGemma":512}
  },
  "models": [
    {"id":"qwen35","number":"1","name":"Qwen 3.5 35B-A3B Q4_K_M","alias":"qwen35-a3b","family":"moe","architecture":"qwen35moe","repoPattern":"models--bartowski--Qwen_Qwen3.5-35B-A3B-GGUF","localFolder":"","filePatterns":["Qwen_Qwen3.5-35B-A3B-Q4_K_M.gguf","Qwen_Qwen3.5-35B-A3B-Q4_K_M-00001-of-*.gguf"],"contextCeiling":262144,"temperature":0.6,"topP":0.95,"topK":20,"preserveReasoning":false},
    {"id":"qwen36","number":"2","name":"Qwen 3.6 35B-A3B UD-Q4_K_M","alias":"qwen36-a3b","family":"moe","architecture":"qwen35moe","repoPattern":"models--unsloth--Qwen3.6-35B-A3B-MTP-GGUF","localFolder":"","filePatterns":["Qwen3.6-35B-A3B-UD-Q4_K_M.gguf","Qwen3.6-35B-A3B-UD-Q4_K_M-00001-of-*.gguf"],"contextCeiling":262144,"temperature":0.6,"topP":0.95,"topK":20,"preserveReasoning":true},
    {"id":"qwen36-uncensored","number":"3","name":"Qwen 3.6 35B-A3B Uncensored / HauhauCS","alias":"qwen36-uncensored","family":"moe","architecture":"qwen35moe","repoPattern":"models--HauhauCS--Qwen3.6-35B-A3B*","localFolder":"","filePatterns":["*UD-Q4_K_M*.gguf","*Q4_K_M*.gguf"],"contextCeiling":262144,"temperature":0.6,"topP":0.95,"topK":20,"preserveReasoning":true},
    {"id":"tiel","number":"4","name":"Tiel Coder 35B-A3B UD-Q4_K_XL","alias":"tiel-coder","family":"moe","architecture":"qwen35moe","repoPattern":"","localFolder":"models/Tiel-MTP","filePatterns":["Tiel-Coder-35B-A3B-MTP-UD-Q4_K_XL.gguf","Tiel-Coder-35B-A3B-MTP-UD-Q4_K_XL-00001-of-*.gguf"],"contextCeiling":262144,"temperature":0.4,"topP":0.95,"topK":20,"preserveReasoning":false},
    {"id":"gemma","number":"5","name":"Gemma 4 E4B Q4_0 / ggml-org","alias":"gemma4-fast","family":"gemma","architecture":"gemma4","repoPattern":"models--ggml-org--gemma-4-E4B-it-GGUF","localFolder":"","filePatterns":["gemma-4-E4B-it-Q4_0.gguf"],"contextCeiling":131072,"temperature":1.0,"topP":0.95,"topK":64,"preserveReasoning":false},
    {"id":"ravenx","number":"6","name":"RavenX CyberAgent 35B v5.1 Q4_K_M","alias":"ravenx","family":"moe","architecture":"qwen35moe","repoPattern":"models--deadbydawn101--RavenX-CyberAgent-Qwen3.6-35B-A3B-Opus-4.7-OpenMythos-Pentester-BugHunter-RATH-GGUF","localFolder":"","filePatterns":["RavenX-CyberAgent-35B-v5.1-Q4_K_M.gguf"],"contextCeiling":262144,"temperature":0.7,"topP":0.9,"topK":20,"preserveReasoning":true},
    {"id":"qwen35-9b","number":"7","name":"Qwen 3.5 9B Q4_K_M / Bartowski","alias":"qwen35-9b","family":"dense","architecture":"qwen35","repoPattern":"models--bartowski--Qwen_Qwen3.5-9B-GGUF","localFolder":"","filePatterns":["Qwen_Qwen3.5-9B-Q4_K_M.gguf","Qwen3.5-9B-Q4_K_M.gguf"],"contextCeiling":262144,"temperature":0.6,"topP":0.95,"topK":20,"preserveReasoning":true},
    {"id":"qwen38-9b","number":"8","name":"Qwen3.8 9B Distill Q5_K_M / Empero","alias":"qwen38-9b","family":"dense","architecture":"qwen35","repoPattern":"models--empero-ai--Qwen3.8-9B-Distill-GGUF","localFolder":"","filePatterns":["Qwen3.8-9B-Q5_K_M.gguf"],"contextCeiling":262144,"temperature":0.6,"topP":0.95,"topK":20,"preserveReasoning":true}
  ]
}
'@ | ConvertFrom-Json
# END_PRESETS_JSON

function Initialize-GgufReader {
    if ('LocalLauncher.GgufReaderV1' -as [type]) { return }
    # Reads only the GGUF metadata; tensor data and tokenizer arrays are skipped.
    # C# avoids slow PowerShell loops over hundreds of thousands of vocabulary entries.
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
namespace LocalLauncher {
    public static class GgufReaderV1 {
        private static void Skip(BinaryReader r, ulong n) {
            long left = r.BaseStream.Length - r.BaseStream.Position;
            if (n > (ulong)left) throw new InvalidDataException("Truncated GGUF metadata.");
            r.BaseStream.Seek((long)n, SeekOrigin.Current);
        }
        private static string Text(BinaryReader r) {
            ulong n = r.ReadUInt64();
            if (n > 16777216UL || n > (ulong)(r.BaseStream.Length-r.BaseStream.Position))
                throw new InvalidDataException("Invalid GGUF string length.");
            return Encoding.UTF8.GetString(r.ReadBytes((int)n));
        }
        private static object Value(BinaryReader r, uint t, bool keep, int depth) {
            if (depth > 4) throw new InvalidDataException("Invalid nested GGUF array.");
            switch (t) {
                case 0: return r.ReadByte();
                case 1: return r.ReadSByte();
                case 2: return r.ReadUInt16();
                case 3: return r.ReadInt16();
                case 4: return r.ReadUInt32();
                case 5: return r.ReadInt32();
                case 6: return r.ReadSingle();
                case 7: return r.ReadByte() != 0;
                case 8: if (keep) return Text(r); Skip(r, r.ReadUInt64()); return null;
                case 9:
                    uint et = r.ReadUInt32(); ulong count = r.ReadUInt64();
                    if (count > 10000000UL) throw new InvalidDataException("Invalid GGUF array length.");
                    int size = et==0 || et==1 || et==7 ? 1 : et==2 || et==3 ? 2 :
                               et==4 || et==5 || et==6 ? 4 : et==10 || et==11 || et==12 ? 8 : 0;
                    if (size != 0) Skip(r, checked(count * (ulong)size));
                    else for (ulong i=0; i<count; ++i) Value(r, et, false, depth+1);
                    return null;
                case 10: return r.ReadUInt64();
                case 11: return r.ReadInt64();
                case 12: return r.ReadDouble();
                default: throw new InvalidDataException("Unsupported GGUF metadata type: " + t);
            }
        }
        public static Dictionary<string, object> Read(string path) {
            var result = new Dictionary<string, object>(StringComparer.Ordinal);
            using (var f = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (var r = new BinaryReader(f, Encoding.UTF8)) {
                if (r.ReadUInt32()!=0x46554747) throw new InvalidDataException("Not a little-endian GGUF file.");
                uint version = r.ReadUInt32();
                if (version!=2 && version!=3) throw new InvalidDataException("Unsupported GGUF version.");
                r.ReadUInt64(); ulong count = r.ReadUInt64();
                if (count>100000UL) throw new InvalidDataException("Invalid GGUF metadata count.");
                for (ulong i=0; i<count; ++i) {
                    string key=Text(r); uint type=r.ReadUInt32();
                    bool keep = key=="general.architecture" || key=="general.name" ||
                        key=="tokenizer.chat_template" || key.EndsWith(".context_length", StringComparison.Ordinal) ||
                        key.EndsWith(".nextn_predict_layers", StringComparison.Ordinal);
                    object val=Value(r,type,keep,0);
                    if (keep && val!=null) result[key]=val;
                }
            }
            return result;
        }
    }
}
'@
}

function Get-ModelSpec([string]$Selection) {
    $found = @($script:PresetData.models | Where-Object {
        $_.number -eq $Selection -or $_.id -eq $Selection -or $_.alias -eq $Selection
    })
    if ($found.Count -ne 1) { throw "Unknown model '$Selection'. Use 1-8, the model ID, or its alias." }
    return $found[0]
}

function Get-HubPath {
    if ($env:HF_HUB_CACHE) { return $env:HF_HUB_CACHE }
    if ($env:HF_HOME) { return (Join-Path $env:HF_HOME 'hub') }
    return (Join-Path $env:USERPROFILE '.cache/huggingface/hub')
}

function Resolve-LocalModel($Spec, [string]$ExplicitPath) {
    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
            throw "Model file does not exist: $ExplicitPath"
        }
        return (Get-Item -LiteralPath $ExplicitPath).FullName
    }
    $folders = New-Object 'System.Collections.Generic.List[string]'
    if ($Spec.localFolder) { $folders.Add((Join-Path $PSScriptRoot $Spec.localFolder)) }
    if ($Spec.repoPattern) {
        $hub = Get-HubPath
        if (Test-Path -LiteralPath $hub -PathType Container) {
            $repos = @(Get-ChildItem -LiteralPath $hub -Directory | Where-Object { $_.Name -like $Spec.repoPattern } | Sort-Object FullName)
            foreach ($repo in $repos) {
                $snapshots = Join-Path $repo.FullName 'snapshots'
                $ref = Join-Path $repo.FullName 'refs/main'
                if (Test-Path -LiteralPath $ref -PathType Leaf) {
                    $revision = (Get-Content -LiteralPath $ref -Raw).Trim()
                    if ($revision -match '^[a-fA-F0-9]{40}$') {
                        $folders.Add((Join-Path $snapshots $revision))
                    }
                }
                if (Test-Path -LiteralPath $snapshots -PathType Container) {
                    foreach ($dir in @(Get-ChildItem -LiteralPath $snapshots -Directory | Sort-Object LastWriteTimeUtc -Descending)) {
                        $folders.Add($dir.FullName)
                    }
                }
            }
        }
    }
    # Pattern priority preserves the requested quant. Never silently pick BF16 or a projector.
    foreach ($pattern in $Spec.filePatterns) {
        foreach ($folder in @($folders | Select-Object -Unique)) {
            if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
            $candidates = @(Get-ChildItem -LiteralPath $folder -File -Filter '*.gguf' | Where-Object {
                $_.Name -like $pattern -and $_.Name -notmatch '^(mmproj|mtp[-_])' -and
                ($_.Name -notmatch '-\d{5}-of-\d{5}\.gguf$' -or $_.Name -match '-00001-of-\d{5}\.gguf$')
            } | Sort-Object Name)
            if ($candidates.Count -gt 0) { return $candidates[0].FullName }
        }
    }
    throw "No matching local GGUF found for $($Spec.name). Expected: $($Spec.filePatterns -join ', '). Use -ModelPath for a different local copy. No download was attempted."
}

function Assert-ModelParts([string]$Path) {
    $file = Get-Item -LiteralPath $Path
    if ($file.Name -match '^(mmproj|mtp[-_])') { throw 'A projector or MTP sidecar cannot be the main model.' }
    if ($file.Name -match '^(.*)-(\d{5})-of-(\d{5})\.gguf$') {
        $stem=$Matches[1]; $part=[int]$Matches[2]; $count=[int]$Matches[3]
        if ($part -ne 1 -or $count -lt 1 -or $count -gt 1000) { throw 'Select shard 00001 of a valid GGUF set.' }
        for ($i=1; $i -le $count; $i++) {
            $shard = Join-Path $file.DirectoryName ('{0}-{1:D5}-of-{2:D5}.gguf' -f $stem,$i,$count)
            if (-not (Test-Path -LiteralPath $shard -PathType Leaf)) { throw "Missing GGUF shard: $shard" }
        }
    }
}

function Get-ModelMetadata([string]$Path, $Spec) {
    Initialize-GgufReader
    $raw = [LocalLauncher.GgufReaderV1]::Read($Path)
    if (-not $raw.ContainsKey('general.architecture')) { throw 'GGUF architecture metadata is missing.' }
    $arch = [string]$raw['general.architecture']
    if ($arch -ne $Spec.architecture) { throw "Selected preset expects $($Spec.architecture), but this file is $arch." }
    $ctxKey = "$arch.context_length"
    if (-not $raw.ContainsKey($ctxKey) -or [long]$raw[$ctxKey] -lt 1) { throw 'GGUF native context metadata is missing or invalid; refusing to guess.' }
    $headKey = "$arch.nextn_predict_layers"
    $heads = 0
    if ($raw.ContainsKey($headKey)) { $heads = [int]$raw[$headKey] }
    $template = ''
    if ($raw.ContainsKey('tokenizer.chat_template')) { $template = [string]$raw['tokenizer.chat_template'] }
    if (-not $template) { throw 'This GGUF has no embedded chat template. Do not run an agent with a guessed template.' }
    return [pscustomobject]@{
        Architecture=$arch; NativeContext=[long]$raw[$ctxKey]; MtpHeads=$heads
        SupportsPreserve=($template -match 'preserve_thinking|supports_preserve_reasoning')
    }
}


function Find-HfCachedFile([string]$RepoFolderName, [string[]]$FileNames) {
    $hub = Get-HubPath
    $repo = Join-Path $hub $RepoFolderName
    if (-not (Test-Path -LiteralPath $repo -PathType Container)) { return '' }

    $folders = New-Object 'System.Collections.Generic.List[string]'
    $ref = Join-Path $repo 'refs/main'
    $snapshots = Join-Path $repo 'snapshots'
    if (Test-Path -LiteralPath $ref -PathType Leaf) {
        $revision = (Get-Content -LiteralPath $ref -Raw).Trim()
        if ($revision -match '^[a-fA-F0-9]{40}$') { $folders.Add((Join-Path $snapshots $revision)) }
    }
    if (Test-Path -LiteralPath $snapshots -PathType Container) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $snapshots -Directory | Sort-Object LastWriteTimeUtc -Descending)) {
            $folders.Add($dir.FullName)
        }
    }

    foreach ($name in $FileNames) {
        foreach ($folder in @($folders | Select-Object -Unique)) {
            $candidate = Join-Path $folder $name
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return (Get-Item -LiteralPath $candidate).FullName
            }
        }
    }
    return ''
}

function Get-Qwen9BVisionProjectors {
    # These are the two projectors Aidan downloaded. Qwen3.8-9B Distill keeps the
    # Qwen3.5-9B multimodal architecture, but Empero does not ship its own mmproj;
    # therefore the cross-repo projector path is treated as experimental and is
    # always shown explicitly before launch.
    $q8 = Find-HfCachedFile 'models--cmp-nct--Qwen3.5-9B-GGUF' @('mmproj-Qwen3.5-9B-Q8_0.gguf')
    $f16 = Find-HfCachedFile 'models--unsloth--Qwen3.5-9B-GGUF' @('mmproj-F16.gguf')
    return [pscustomobject]@{ Q8=$q8; F16=$f16 }
}

function Select-InteractiveVision($Spec, [string]$ModelFile, [string]$ProfileName) {
    Write-Host "`n========== VISION ==========" -ForegroundColor Cyan

    if ($Spec.id -eq 'qwen38-9b' -or $Spec.id -eq 'qwen35-9b') {
        $p = Get-Qwen9BVisionProjectors
        $q8State = if ($p.Q8) { 'FOUND' } else { 'missing' }
        $f16State = if ($p.F16) { 'FOUND' } else { 'missing' }

        if ($Spec.id -eq 'qwen38-9b') {
            Write-Host ' Qwen3.8-9B Distill vision uses the downloaded Qwen3.5-9B projector experimentally.' -ForegroundColor DarkYellow
        }
        Write-Host ' [0] Off                                   [default]'
        Write-Host (" [1] GPU + Q8 projector  - fastest vision          [{0}]" -f $q8State)
        Write-Host (" [2] CPU + Q8 projector  - preserves VRAM          [{0}]" -f $q8State)
        Write-Host (" [3] GPU + F16 projector - highest projector prec. [{0}]" -f $f16State)
        Write-Host (" [4] CPU + F16 projector - preserves VRAM          [{0}]" -f $f16State)
        if ($ProfileName -eq 'MaxContext') {
            Write-Host ' 262K note: CPU + Q8 is recommended if GPU VRAM is tight; GPU vision can force auto-fit/offload.' -ForegroundColor Yellow
        } else {
            Write-Host ' 128K note: GPU + Q8 is the recommended speed/VRAM balance.' -ForegroundColor DarkGray
        }
        $choice = Read-Host 'Select vision [Enter = 0 Off]'
        if (-not $choice) { $choice='0' }
        switch ($choice) {
            '0' { return [pscustomobject]@{ Vision='Off'; Projector='' } }
            '1' {
                if (-not $p.Q8) { throw 'Q8 vision projector is not in the Hugging Face cache. Download cmp-nct/Qwen3.5-9B-GGUF mmproj-Qwen3.5-9B-Q8_0.gguf.' }
                return [pscustomobject]@{ Vision='Gpu'; Projector=$p.Q8 }
            }
            '2' {
                if (-not $p.Q8) { throw 'Q8 vision projector is not in the Hugging Face cache. Download cmp-nct/Qwen3.5-9B-GGUF mmproj-Qwen3.5-9B-Q8_0.gguf.' }
                return [pscustomobject]@{ Vision='Cpu'; Projector=$p.Q8 }
            }
            '3' {
                if (-not $p.F16) { throw 'F16 vision projector is not in the Hugging Face cache. Download unsloth/Qwen3.5-9B-GGUF mmproj-F16.gguf.' }
                return [pscustomobject]@{ Vision='Gpu'; Projector=$p.F16 }
            }
            '4' {
                if (-not $p.F16) { throw 'F16 vision projector is not in the Hugging Face cache. Download unsloth/Qwen3.5-9B-GGUF mmproj-F16.gguf.' }
                return [pscustomobject]@{ Vision='Cpu'; Projector=$p.F16 }
            }
            default { throw 'Invalid vision selection.' }
        }
    }

    # Other models keep the original safe behavior: OFF by default, with GPU/CPU
    # options only if a compatible projector is already beside the selected GGUF.
    $dir = Split-Path -Parent $ModelFile
    $names = @('mmproj-BF16.gguf')
    if ($Spec.family -eq 'gemma') { $names=@('mmproj-gemma-4-E4B-it-Q8_0.gguf','mmproj-gemma-4-E4B-it-BF16.gguf') }
    $localProjector=''
    foreach ($name in $names) {
        $candidate=Join-Path $dir $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $localProjector=(Get-Item -LiteralPath $candidate).FullName; break }
    }
    Write-Host ' [0] Off [default]'
    if ($localProjector) {
        Write-Host ' [1] GPU projector'
        Write-Host ' [2] CPU projector (save VRAM)'
    } else {
        Write-Host ' No compatible local projector was auto-detected for this model.' -ForegroundColor DarkGray
    }
    $choice=Read-Host 'Select vision [Enter = 0 Off]'
    if (-not $choice) { $choice='0' }
    switch ($choice) {
        '0' { return [pscustomobject]@{ Vision='Off'; Projector='' } }
        '1' {
            if (-not $localProjector) { throw 'No compatible projector was found beside this model. Re-run with -Vision Gpu -ProjectorPath <verified-mmproj>.' }
            return [pscustomobject]@{ Vision='Gpu'; Projector=$localProjector }
        }
        '2' {
            if (-not $localProjector) { throw 'No compatible projector was found beside this model. Re-run with -Vision Cpu -ProjectorPath <verified-mmproj>.' }
            return [pscustomobject]@{ Vision='Cpu'; Projector=$localProjector }
        }
        default { throw 'Invalid vision selection.' }
    }
}

function Resolve-Extras($Spec, [string]$Path, $Metadata, [string]$VisionMode, [string]$MtpMode, [string]$Projector, [string]$Draft) {
    $dir = Split-Path -Parent $Path
    $extra = [ordered]@{ Vision=$VisionMode; Projector=''; Mtp=$false; Draft=''; ReserveMiB=0; Note='' }
    if ($VisionMode -ne 'Off') {
        if ($Projector) {
            if (-not (Test-Path -LiteralPath $Projector -PathType Leaf)) { throw "Projector missing: $Projector" }
            $extra.Projector = (Get-Item -LiteralPath $Projector).FullName
        } else {
            if ($Spec.id -eq 'qwen38-9b' -or $Spec.id -eq 'qwen35-9b') {
                # Prefer the smaller Q8 projector when -Vision is supplied non-interactively.
                $p=Get-Qwen9BVisionProjectors
                if ($p.Q8) { $extra.Projector=$p.Q8 }
                elseif ($p.F16) { $extra.Projector=$p.F16 }
            }
            if (-not $extra.Projector) {
                # Same-snapshot fallback for models that ship their own projector.
                $names = @('mmproj-BF16.gguf')
                if ($Spec.family -eq 'gemma') { $names = @('mmproj-gemma-4-E4B-it-Q8_0.gguf','mmproj-gemma-4-E4B-it-BF16.gguf') }
                foreach ($name in $names) {
                    $candidate = Join-Path $dir $name
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $extra.Projector=$candidate; break }
                }
            }
            if (-not $extra.Projector) { throw 'Vision requested but no compatible local projector was found. Supply -ProjectorPath for a verified compatible projector, or use -Vision Off.' }
        }
        if ($VisionMode -eq 'Gpu') {
            $extra.ReserveMiB += [int][math]::Ceiling((Get-Item -LiteralPath $extra.Projector).Length / 1MB) + 512
        }
    } elseif ($Projector) { throw '-ProjectorPath requires -Vision Gpu or -Vision Cpu.' }

    if ($MtpMode -eq 'Off') {
        if ($Draft) { throw '-DraftPath cannot be combined with -Mtp Off.' }
        return [pscustomobject]$extra
    }
    if ($Spec.family -eq 'gemma') {
        if ($Draft) {
            if (-not (Test-Path -LiteralPath $Draft -PathType Leaf)) { throw "MTP draft file missing: $Draft" }
            $extra.Draft=(Get-Item -LiteralPath $Draft).FullName
        } else {
            $candidate = Join-Path $dir ('mtp-' + (Split-Path -Leaf $Path))
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $extra.Draft=$candidate }
        }
        if ($extra.Draft) {
            $extra.Mtp=$true
            $extra.ReserveMiB += [int][math]::Ceiling((Get-Item -LiteralPath $extra.Draft).Length / 1MB) + 256
        } elseif ($MtpMode -eq 'On') {
            throw 'Gemma MTP needs its matching mtp-gemma-4-E4B-it-*.gguf sidecar. It is not present locally. Use -Mtp Off or supply -DraftPath.'
        } else { $extra.Note='Gemma MTP OFF: matching local MTP sidecar not found.' }
    } else {
        if ($Draft) { throw 'These Qwen-family presets use an embedded MTP head, not -DraftPath.' }
        if ($MtpMode -eq 'On') {
            if ($Metadata.MtpHeads -lt 1) { throw 'MTP requested but this GGUF does not declare an embedded MTP head.' }
            $extra.Mtp=$true
            # Main-model fitter is not a benchmark and separate speculative allocations need room.
            $extra.ReserveMiB += 1024
        } else { $extra.Note='MTP OFF by default for Qwen-family models: use -Mtp On only for a measured A/B test.' }
    }
    return [pscustomobject]$extra
}

function New-LaunchPlan($Spec, $Metadata, $Extra, [string]$ModelFile, [string]$ProfileName,
                        [int]$RequestedContext, [string]$RequestedKV, [int]$RequestedFit,
                        [int]$RequestedThreads, [int]$RequestedBatchThreads, [int]$RequestedUBatch,
                        [int]$ServerPort, [string]$LogPath) {
    $p = $script:PresetData.profiles.$ProfileName
    $cap = [long][math]::Min($Metadata.NativeContext, $Spec.contextCeiling)
    if ($RequestedContext -gt $cap) { throw "Requested context $RequestedContext exceeds the supported preset/file ceiling $cap." }
    $ctx = [int][math]::Min($p.context,$cap)
    if ($RequestedContext -gt 0) { $ctx=$RequestedContext }
    if ($ctx -lt 512) { throw 'Context must be at least 512 tokens.' }
    $cache = $p.kvMoe; $ub=$p.ubatchMoe; $t=12; $tb=24
    if ($Spec.family -eq 'gemma') { $cache=$p.kvGemma; $ub=$p.ubatchGemma; $tb=12 }
    $cacheRam = [int]$p.cacheRamMiB
    if ($Spec.family -eq 'dense') {
        switch ($ProfileName) {
            'Daily'      { $cacheRam = 3072 }
            'MaxContext' { $cacheRam = 4096 }
            'Fast'       { $cacheRam = 1536 }
            'Baseline'   { $cacheRam = 3072 }
        }
    }
    # Qwen3.8-9B Q5 is tuned specifically for this 12 GB RTX 4070.
    # Daily keeps Q8 KV quality at 128K. MaxContext uses Q4 KV + smaller ubatch
    # so the full native 262K window can remain GPU-resident without sacrificing Q5 weights.
    if ($Spec.id -eq 'qwen38-9b') {
        switch ($ProfileName) {
            'Daily'      { $cache='q8_0'; $ub=1024; $cacheRam=3072 }
            'MaxContext' { $cache='q4_0'; $ub=512;  $cacheRam=4096 }
            'Fast'       { $cache='q8_0'; $ub=1024; $cacheRam=1536 }
            'Baseline'   { $cache='q4_0'; $ub=1024; $cacheRam=3072 }
        }
    }
    if ($RequestedKV -ne 'Default') { $cache=$RequestedKV }
    if ($RequestedThreads -gt 0) { $t=$RequestedThreads }
    if ($RequestedBatchThreads -gt 0) { $tb=$RequestedBatchThreads }
    if ($RequestedUBatch -gt 0) { $ub=$RequestedUBatch }
    if ($ub -gt $p.batch) { throw 'Physical batch must not exceed logical batch.' }
    $fit = [int]$p.fitTargetMiB
    if ($Spec.id -eq 'qwen38-9b') {
        # 1024 MiB is deliberate: 1536 MiB may make auto-fit offload layers at 262K,
        # which costs more speed than the extra Windows safety margin is worth.
        $fit = 1024
    }
    if ($RequestedFit -gt 0) {
        if ($RequestedFit -lt 1024) { throw 'Keep at least 1024 MiB of fitting headroom on this Windows desktop.' }
        $fit=$RequestedFit
    }
    $fit += $Extra.ReserveMiB
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $a = @(
        '--model',$ModelFile,'--alias',$Spec.alias,'--host','127.0.0.1','--port',"$ServerPort",
        '--ctx-size',"$ctx",'--parallel','1',
        '--gpu-layers','auto','--fit','on','--fit-target',"$fit",'--load-mode','none',
        '--flash-attn','on','--cache-type-k',$cache,'--cache-type-v',$cache,
        '--batch-size',"$($p.batch)",'--ubatch-size',"$ub",'--threads',"$t",'--threads-batch',"$tb",
        '--cache-prompt','--cache-ram',"$cacheRam",
        '--ctx-checkpoints',"$($p.checkpoints)",'--checkpoint-min-step','8192',
        '--jinja','--reasoning','on','--reasoning-budget','-1',
        '--temp',([double]$Spec.temperature).ToString($culture),
        '--top-p',([double]$Spec.topP).ToString($culture),'--top-k',"$($Spec.topK)",
        '--min-p','0','--repeat-penalty','1','--presence-penalty','0',
        '--threads-http','4','--cors-origins','localhost','--verbosity','4','--log-file',$LogPath
    )
    if ($Spec.preserveReasoning -and $Metadata.SupportsPreserve) { $a += '--reasoning-preserve' }
    if ($Extra.Vision -eq 'Off') { $a += '--no-mmproj' }
    else {
        $a += @('--mmproj',$Extra.Projector)
        if ($Extra.Vision -eq 'Cpu') { $a += '--no-mmproj-offload' }
    }
    if ($Extra.Mtp) {
        $draftMax='1'
        if ($Spec.family -eq 'gemma') { $a += @('--model-draft',$Extra.Draft); $draftMax='2' }
        $a += @('--spec-type','draft-mtp','--spec-draft-n-max',$draftMax,'--spec-draft-n-min','0','--gpu-layers-draft','all')
    } else { $a += @('--spec-type','none') }
    return [pscustomobject]@{
        Alias=$Spec.alias; Profile=$ProfileName; Context=$ctx; NativeContext=$Metadata.NativeContext
        KV=$cache; FitTargetMiB=$fit; Threads=$t; ThreadsBatch=$tb; UBatch=$ub
        Mtp=[bool]$Extra.Mtp; Vision=$Extra.Vision; CacheRamMiB=$cacheRam
        Port=$ServerPort
        ServerBaseUrl=("http://127.0.0.1:{0}" -f $ServerPort)
        OpenAIBaseUrl=("http://127.0.0.1:{0}/v1" -f $ServerPort)
        HealthUrl=("http://127.0.0.1:{0}/health" -f $ServerPort)
        Arguments=[string[]]$a; LogPath=$LogPath
    }
}

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $Path -Force)
    }
}

function Write-TextAtomic([string]$Path, [string]$Content) {
    $parent = Split-Path -Parent $Path
    if ($parent) { Ensure-Directory $parent }
    $temp = "$Path.tmp-$PID-$([Guid]::NewGuid().ToString('N'))"
    $utf8 = [Text.UTF8Encoding]::new($false)
    try {
        [IO.File]::WriteAllText($temp, $Content, $utf8)
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-BackupSessionDir {
    if (-not $script:BackupSessionDir) {
        Ensure-Directory $script:BackupRoot
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $script:BackupSessionDir = Join-Path $script:BackupRoot $stamp
        Ensure-Directory $script:BackupSessionDir
    }
    return $script:BackupSessionDir
}

function Backup-ConfigFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $dir = Get-BackupSessionDir
    $safe = $Path -replace '[:\\/]+','_'
    $safe = $safe.Trim('_')
    $dest = Join-Path $dir $safe
    Copy-Item -LiteralPath $Path -Destination $dest -Force
    return $dest
}

function Read-JsonOrEmpty([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{} }
    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return [pscustomobject]@{} }
    try { return ($raw | ConvertFrom-Json) }
    catch { throw "Could not parse JSON in $Path. $($_.Exception.Message)" }
}

function Set-ObjectProperty($Object, [string]$Name, $Value) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { $Object.$Name = $Value }
    else { $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value }
}

function New-ZeroCost {
    return [pscustomobject]@{ input=0; output=0; cacheRead=0; cacheWrite=0 }
}

function Test-ModelReasoning($Spec) {
    return (@('tiel','gemma') -notcontains [string]$Spec.id)
}

function Get-ClientMaxTokens($Plan) {
    $candidate = [int][math]::Floor([double]$Plan.Context / 8.0)
    if ($candidate -lt 8192) { $candidate=8192 }
    if ($candidate -gt 32768) { $candidate=32768 }
    return $candidate
}

function Get-CompactionPolicy([int]$ContextWindow) {
    if ($ContextWindow -ge 131072) { $reserve=32768 }
    elseif ($ContextWindow -ge 65536) { $reserve=16384 }
    else { $reserve=8192 }
    if ($reserve -ge $ContextWindow) { $reserve=[int][math]::Max(1024,[math]::Floor($ContextWindow/4)) }
    $keep=$reserve
    $auto=[int]($ContextWindow-$reserve)
    return [pscustomobject]@{ Reserve=$reserve; Keep=$keep; AutoCompact=$auto }
}

function New-PiModelConfig($Entry, $Plan, $Extra) {
    $ctx=[int][math]::Min(131072,[int]$Entry.contextCeiling)
    if ([string]$Entry.alias -eq [string]$Plan.Alias) { $ctx=[int]$Plan.Context }
    $reasoning=Test-ModelReasoning $Entry
    $input=@('text')
    if ([string]$Entry.alias -eq [string]$Plan.Alias -and $Extra.Vision -ne 'Off') { $input=@('text','image') }
    $model=[ordered]@{
        id=[string]$Entry.alias
        name=("{0} - {1}K" -f [string]$Entry.name,[int][math]::Round($ctx/1024))
        reasoning=[bool]$reasoning
        input=$input
        contextWindow=$ctx
        maxTokens=(Get-ClientMaxTokens ([pscustomobject]@{ Context=$ctx }))
        cost=(New-ZeroCost)
    }
    if ($reasoning) {
        $model['compat']=[pscustomobject]@{ thinkingFormat='qwen-chat-template' }
    }
    return [pscustomobject]$model
}

function Sync-PiConfig($Plan, $Spec, $Extra) {
    # Plan.Context is authoritative. Never let Pi advertise more context for the active model than llama.cpp serves.
    $agentDir=Join-Path $env:USERPROFILE '.pi\agent'
    $modelsPath=Join-Path $agentDir 'models.json'
    $settingsPath=Join-Path $agentDir 'settings.json'
    Ensure-Directory $agentDir
    [void](Backup-ConfigFile $modelsPath)
    [void](Backup-ConfigFile $settingsPath)

    $root=Read-JsonOrEmpty $modelsPath
    if ($null -eq $root.PSObject.Properties['providers'] -or $null -eq $root.providers) { Set-ObjectProperty $root 'providers' ([pscustomobject]@{}) }

    $all=@()
    foreach ($entry in $script:PresetData.models) { $all += New-PiModelConfig $entry $Plan $Extra }
    $provider=[pscustomobject]@{
        baseUrl=[string]$Plan.OpenAIBaseUrl
        api='openai-completions'
        apiKey='local'
        compat=[pscustomobject]@{
            supportsDeveloperRole=$false
            supportsReasoningEffort=$false
            supportsUsageInStreaming=$false
            maxTokensField='max_tokens'
        }
        models=$all
    }
    Set-ObjectProperty $root.providers 'local-qwen' $provider
    Write-TextAtomic $modelsPath ($root | ConvertTo-Json -Depth 40)

    $settings=Read-JsonOrEmpty $settingsPath
    Set-ObjectProperty $settings 'defaultProvider' 'local-qwen'
    Set-ObjectProperty $settings 'defaultModel' ([string]$Plan.Alias)
    if ($null -eq $settings.PSObject.Properties['compaction'] -or $null -eq $settings.compaction) { Set-ObjectProperty $settings 'compaction' ([pscustomobject]@{}) }
    Set-ObjectProperty $settings.compaction 'enabled' $true
    if ($null -eq $settings.compaction.PSObject.Properties['modelOverrides'] -or $null -eq $settings.compaction.modelOverrides) {
        Set-ObjectProperty $settings.compaction 'modelOverrides' ([pscustomobject]@{})
    }
    foreach ($model in $all) {
        $policy=Get-CompactionPolicy ([int]$model.contextWindow)
        Set-ObjectProperty $settings.compaction.modelOverrides ("local-qwen/{0}" -f $model.id) ([pscustomobject]@{
            reserveTokens=$policy.Reserve
            keepRecentTokens=$policy.Keep
        })
    }
    Write-TextAtomic $settingsPath ($settings | ConvertTo-Json -Depth 40)

    $verify=Get-Content -LiteralPath $modelsPath -Raw | ConvertFrom-Json
    $active=@($verify.providers.'local-qwen'.models | Where-Object { $_.id -eq $Plan.Alias })
    if ($active.Count -ne 1 -or [int]$active[0].contextWindow -ne [int]$Plan.Context) {
        throw "Pi config verification failed: active model $($Plan.Alias) is not exactly $($Plan.Context) tokens."
    }
    return [pscustomobject]@{ ModelsPath=$modelsPath; SettingsPath=$settingsPath }
}

function Escape-YamlSingleQuoted([string]$Value) {
    return $Value.Replace("'","''")
}

function Get-OmpAgentDir {
    if ($env:PI_CODING_AGENT_DIR) { return $env:PI_CODING_AGENT_DIR }
    return (Join-Path $env:USERPROFILE '.omp\agent')
}

function Sync-OmpConfig($Plan, $Spec, $Extra) {
    # OMP gets only the active local model, with Plan.Context as its exact window.
    $agentDir=Get-OmpAgentDir
    Ensure-Directory $agentDir
    $yml=Join-Path $agentDir 'models.yml'
    $yaml=Join-Path $agentDir 'models.yaml'
    if (Test-Path -LiteralPath $yml -PathType Leaf) { $path=$yml }
    elseif (Test-Path -LiteralPath $yaml -PathType Leaf) { $path=$yaml }
    else { $path=$yml }
    [void](Backup-ConfigFile $path)

    $reasoning=Test-ModelReasoning $Spec
    $reasoningText=if ($reasoning) { 'true' } else { 'false' }
    $input=if ($Extra.Vision -ne 'Off') { '[text, image]' } else { '[text]' }
    $maxTokens=Get-ClientMaxTokens $Plan
    $name=Escape-YamlSingleQuoted ([string]$Spec.name)
    $lines=@(
        $script:ManagedBlockBegin,
        '  local-qwen:',
        ("    baseUrl: {0}" -f $Plan.OpenAIBaseUrl),
        '    auth: none',
        '    api: openai-completions',
        '    models:',
        ("      - id: {0}" -f $Plan.Alias),
        ("        name: '{0}'" -f $name),
        ("        reasoning: {0}" -f $reasoningText),
        ("        input: {0}" -f $input),
        ("        contextWindow: {0}" -f $Plan.Context),
        ("        maxTokens: {0}" -f $maxTokens),
        '        cost:',
        '          input: 0',
        '          output: 0',
        '          cacheRead: 0',
        '          cacheWrite: 0',
        '        compat:',
        '          supportsDeveloperRole: false',
        '          supportsReasoningEffort: false'
    )
    if ($reasoning) { $lines += '          thinkingFormat: qwen-chat-template' }
    $lines += $script:ManagedBlockEnd
    $block=$lines -join "`r`n"

    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $text=Get-Content -LiteralPath $path -Raw
        $managed='(?ms)^  # BEGIN LOCAL-AI-CONTROL\r?\n.*?^  # END LOCAL-AI-CONTROL\r?\n?'
        $text=[regex]::Replace($text,$managed,'')
        $rootRx=New-Object Text.RegularExpressions.Regex('(?m)^providers:\s*$')
        if (-not $rootRx.IsMatch($text)) {
            throw "OMP config exists but has no root 'providers:' key: $path. Refusing to rewrite an unknown YAML shape."
        }
        $text=$rootRx.Replace($text,([Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Value+"`r`n"+$block }),1)
    } else {
        $text="providers:`r`n$block`r`n"
    }
    Write-TextAtomic $path $text
    $verify=Get-Content -LiteralPath $path -Raw
    if ($verify -notmatch [regex]::Escape("contextWindow: $($Plan.Context)") -or $verify -notmatch [regex]::Escape("- id: $($Plan.Alias)")) {
        throw 'OMP config verification failed.'
    }
    return [pscustomobject]@{ ModelsPath=$path }
}

function Write-OpenCodeOverride($Plan, $Spec, $Extra) {
    # OpenCode receives Plan.Context through an inline override at launch, so project configs cannot silently replace it.
    Ensure-Directory $script:ControlRoot
    $path=Join-Path $script:ControlRoot 'opencode.local.json'
    [void](Backup-ConfigFile $path)
    $maxTokens=Get-ClientMaxTokens $Plan
    $modelConfig=[ordered]@{
        name=("{0} (llama.cpp local)" -f [string]$Spec.name)
        limit=[ordered]@{ context=[int]$Plan.Context; output=[int]$maxTokens }
    }
    $models=[ordered]@{}
    $models[[string]$Plan.Alias]=$modelConfig
    $provider=[ordered]@{
        npm='@ai-sdk/openai-compatible'
        name='llama.cpp Local'
        options=[ordered]@{ baseURL=[string]$Plan.OpenAIBaseUrl }
        models=$models
    }
    $providers=[ordered]@{ 'local-llama'=$provider }
    $config=[ordered]@{
        '$schema'='https://opencode.ai/config.json'
        model=("local-llama/{0}" -f $Plan.Alias)
        provider=$providers
    }
    Write-TextAtomic $path ($config | ConvertTo-Json -Depth 30)
    $verify=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $activeProperty=$verify.provider.'local-llama'.models.PSObject.Properties[[string]$Plan.Alias]
    if ($verify.model -ne "local-llama/$($Plan.Alias)" -or $null -eq $activeProperty -or [int]$activeProperty.Value.limit.context -ne [int]$Plan.Context) {
        throw 'OpenCode override verification failed.'
    }
    return $path
}

function Escape-TomlString([string]$Value) {
    return $Value.Replace('\','\\').Replace('"','\"')
}

function Write-CodexOverride($Plan, $Spec, $Extra) {
    # Codex uses Responses API and receives Plan.Context via -c overrides at launch.
    Ensure-Directory $script:ControlRoot
    $path=Join-Path $script:ControlRoot 'codex.local.toml'
    [void](Backup-ConfigFile $path)
    $policy=Get-CompactionPolicy ([int]$Plan.Context)
    $alias=Escape-TomlString ([string]$Plan.Alias)
    $base=Escape-TomlString ([string]$Plan.OpenAIBaseUrl)
    $content=@(
        ("model = `"{0}`"" -f $alias),
        'model_provider = "local_llama"',
        ("model_context_window = {0}" -f $Plan.Context),
        ("model_auto_compact_token_limit = {0}" -f $policy.AutoCompact),
        '',
        '[model_providers.local_llama]',
        'name = "llama.cpp Local"',
        ("base_url = `"{0}`"" -f $base),
        'wire_api = "responses"',
        'requires_openai_auth = false',
        ''
    ) -join "`r`n"
    Write-TextAtomic $path $content
    $verify=Get-Content -LiteralPath $path -Raw
    if ($verify -notmatch [regex]::Escape("model_context_window = $($Plan.Context)") -or $verify -notmatch 'wire_api\s*=\s*"responses"') {
        throw 'Codex override verification failed.'
    }
    return $path
}

function Get-ClaudeEnvironment($Plan, $Spec, $Extra) {
    # Claude Code is configured only for the child process; existing account/auth settings stay untouched.
    return @{
        ANTHROPIC_BASE_URL=[string]$Plan.ServerBaseUrl
        ANTHROPIC_AUTH_TOKEN='local'
        ANTHROPIC_MODEL=[string]$Plan.Alias
        ANTHROPIC_DEFAULT_OPUS_MODEL=[string]$Plan.Alias
        ANTHROPIC_DEFAULT_SONNET_MODEL=[string]$Plan.Alias
        ANTHROPIC_DEFAULT_HAIKU_MODEL=[string]$Plan.Alias
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1'
        DISABLE_PROMPT_CACHING='1'
        LOCAL_AI_CONTEXT_WINDOW=("{0}" -f $Plan.Context)
    }
}

function Write-ActiveState($Plan, $Spec, $Extra, [string]$SelectedHarness, $SyncResult) {
    Ensure-Directory $script:ControlRoot
    $path=Join-Path $script:ControlRoot 'active.json'
    $state=[ordered]@{
        updated=(Get-Date).ToString('o')
        model=[string]$Plan.Alias
        modelName=[string]$Spec.name
        profile=[string]$Plan.Profile
        context=[int]$Plan.Context
        kv=[string]$Plan.KV
        vision=[string]$Extra.Vision
        projector=[string]$Extra.Projector
        mtp=[bool]$Plan.Mtp
        port=[int]$Plan.Port
        openAIBaseUrl=[string]$Plan.OpenAIBaseUrl
        harness=$SelectedHarness
        configs=$SyncResult
    }
    Write-TextAtomic $path ($state | ConvertTo-Json -Depth 30)
    return $path
}

function Sync-AllClients($Plan, $Spec, $Extra, [string]$SelectedHarness) {
    # Every adapter consumes the same Plan.Context. This is the context-mismatch guardrail.
    Ensure-Directory $script:ControlRoot
    Write-Host "`nSynchronizing coding clients to $($Plan.Alias) @ $($Plan.Context) tokens..." -ForegroundColor Cyan
    $pi=Sync-PiConfig $Plan $Spec $Extra
    $omp=Sync-OmpConfig $Plan $Spec $Extra
    $openCode=Write-OpenCodeOverride $Plan $Spec $Extra
    $codex=Write-CodexOverride $Plan $Spec $Extra
    $claude=Get-ClaudeEnvironment $Plan $Spec $Extra
    $result=[pscustomobject]@{
        PiModels=$pi.ModelsPath
        PiSettings=$pi.SettingsPath
        OmpModels=$omp.ModelsPath
        OpenCodeOverride=$openCode
        CodexOverride=$codex
        ClaudeEnvironment=$claude
    }
    $state=Write-ActiveState $Plan $Spec $Extra $SelectedHarness $result
    Set-ObjectProperty $result 'ActiveState' $state
    Write-Host 'Client configs synchronized.' -ForegroundColor Green
    return $result
}

function Get-ModelInstallState($Spec) {
    try {
        [void](Resolve-LocalModel $Spec '')
        return 'ready'
    } catch { return 'missing' }
}

function Select-InteractiveMtp($Spec, $Metadata) {
    Write-Host "`n========== MTP ==========" -ForegroundColor Cyan
    Write-Host ' [0] Auto [default] - conservative; Qwen embedded MTP stays off unless explicitly enabled'
    Write-Host ' [1] On             - use compatible embedded/sidecar MTP and reserve VRAM'
    Write-Host ' [2] Off            - force speculative decoding off'
    if ($Metadata.MtpHeads -lt 1 -and $Spec.family -ne 'gemma') {
        Write-Host ' This GGUF does not declare an embedded MTP head; On will be rejected.' -ForegroundColor DarkYellow
    }
    $choice=Read-Host 'Select MTP [Enter = 0 Auto]'
    if (-not $choice) { $choice='0' }
    switch ($choice) {
        '0' { return 'Auto' }
        '1' { return 'On' }
        '2' { return 'Off' }
        default { throw 'Invalid MTP selection.' }
    }
}

function Select-InteractiveHarness {
    Write-Host "`n========== CODING HARNESS ==========" -ForegroundColor Cyan
    Write-Host ' [1] Pi'
    Write-Host ' [2] OMP'
    Write-Host ' [3] OpenCode'
    Write-Host ' [4] Codex'
    Write-Host ' [5] Claude Code'
    Write-Host ' [6] Server only'
    Write-Host ' [0] Sync configs only (do not start llama.cpp)'
    $choice=Read-Host 'Select harness [Enter = 1 Pi]'
    if (-not $choice) { $choice='1' }
    switch ($choice) {
        '0' { return [pscustomobject]@{ Harness='None'; SyncOnly=$true } }
        '1' { return [pscustomobject]@{ Harness='Pi'; SyncOnly=$false } }
        '2' { return [pscustomobject]@{ Harness='OMP'; SyncOnly=$false } }
        '3' { return [pscustomobject]@{ Harness='OpenCode'; SyncOnly=$false } }
        '4' { return [pscustomobject]@{ Harness='Codex'; SyncOnly=$false } }
        '5' { return [pscustomobject]@{ Harness='Claude'; SyncOnly=$false } }
        '6' { return [pscustomobject]@{ Harness='Server'; SyncOnly=$false } }
        default { throw 'Invalid harness selection.' }
    }
}

function Resolve-ProjectDirectory([string]$Requested, [string]$SelectedHarness, [bool]$InteractivePrompt) {
    $current=(Get-Location).Path
    if ($SelectedHarness -eq 'Server' -or $SelectedHarness -eq 'None') { return $current }
    $value=$Requested
    if (-not $value -and $InteractivePrompt) {
        Write-Host "`nCurrent project directory: $current" -ForegroundColor DarkGray
        $value=Read-Host 'Project directory [Enter = current]'
    }
    if (-not $value) { return $current }
    if (-not [IO.Path]::IsPathRooted($value)) { $value=Join-Path $current $value }
    $value=[IO.Path]::GetFullPath($value)
    if (-not (Test-Path -LiteralPath $value -PathType Container)) { throw "Project directory does not exist: $value" }
    return (Get-Item -LiteralPath $value).FullName
}

function Test-TcpPortFree([int]$Number) {
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Number)
    try { $listener.Start(); return $true }
    catch { return $false }
    finally { try { $listener.Stop() } catch {} }
}

function Get-PortOwner([int]$Number) {
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        try {
            $conn=Get-NetTCPConnection -LocalPort $Number -State Listen -ErrorAction Stop | Select-Object -First 1
            if ($conn) {
                $proc=Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
                if ($proc) { return [pscustomobject]@{ Id=[int]$proc.Id; Name=[string]$proc.ProcessName } }
                return [pscustomobject]@{ Id=[int]$conn.OwningProcess; Name='unknown' }
            }
        } catch {}
    }
    try {
        $rows=& netstat -ano -p tcp 2>$null
        foreach ($row in $rows) {
            if ($row -match "^\s*TCP\s+[^\s]*:$Number\s+[^\s]+\s+LISTENING\s+(\d+)\s*$") {
                $id=[int]$Matches[1]
                $proc=Get-Process -Id $id -ErrorAction SilentlyContinue
                $name=if ($proc) { [string]$proc.ProcessName } else { 'unknown' }
                return [pscustomobject]@{ Id=$id; Name=$name }
            }
        }
    } catch {}
    return $null
}

function Ensure-ServerPortAvailable([int]$Number, [bool]$AllowStop, [bool]$InteractivePrompt) {
    if (Test-TcpPortFree $Number) { return }
    $owner=Get-PortOwner $Number
    if (-not $owner) { throw "Port $Number is in use, but its owner could not be identified. Nothing was killed." }
    $isLlama=([string]$owner.Name -match '^llama-server(?:\.exe)?$')
    if (-not $isLlama) {
        throw "Port $Number is owned by PID $($owner.Id) ($($owner.Name)), not llama-server. Refusing to stop it."
    }
    $replace=$AllowStop
    if (-not $replace -and $InteractivePrompt) {
        $answer=Read-Host "llama-server PID $($owner.Id) already owns port $Number. Replace it? [Y/n]"
        $replace=(-not $answer -or $answer -match '^[Yy]')
    }
    if (-not $replace) { throw "Port $Number is already owned by llama-server PID $($owner.Id). Re-run with -StopExistingServer to replace it non-interactively." }
    Write-Host "Stopping existing llama-server PID $($owner.Id)..." -ForegroundColor Yellow
    Stop-Process -Id $owner.Id -Force -ErrorAction Stop
    $deadline=(Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPortFree $Number) { return }
        Start-Sleep -Milliseconds 250
    }
    throw "llama-server PID $($owner.Id) stopped, but port $Number did not become free."
}

function ConvertTo-StartProcessArgumentLine([string[]]$Arguments) {
    $quoted=@()
    foreach ($arg in $Arguments) {
        if ($arg -match '[\s"]') { $quoted += ('"' + $arg.Replace('"','\"') + '"') }
        else { $quoted += $arg }
    }
    return ($quoted -join ' ')
}

function Start-LlamaServer([string]$Executable, $Plan, [bool]$InteractivePrompt, [bool]$AllowStop) {
    Ensure-ServerPortAvailable ([int]$Plan.Port) $AllowStop $InteractivePrompt
    $argLine=ConvertTo-StartProcessArgumentLine ([string[]]$Plan.Arguments)
    Write-Host "`nStarting llama.cpp in a separate visible process..." -ForegroundColor Cyan
    # Keep the llama.cpp console visible so live timings, VRAM use, prompt ingest,
    # decode speed, vision processing, and errors remain observable while the
    # selected coding harness runs in this terminal.
    $proc=Start-Process -FilePath $Executable -ArgumentList $argLine -WorkingDirectory $PSScriptRoot -WindowStyle Normal -PassThru
    Write-Host "llama-server PID: $($proc.Id)" -ForegroundColor DarkGray
    return $proc
}

function Wait-LlamaHealth($Plan, $Process, [int]$TimeoutSec) {
    $deadline=(Get-Date).AddSeconds($TimeoutSec)
    $health=[string]$Plan.HealthUrl
    Write-Host "Waiting for llama.cpp model load at $health ..." -ForegroundColor DarkGray
    while ((Get-Date) -lt $deadline) {
        try {
            if ($Process.HasExited) { throw "llama-server exited with code $($Process.ExitCode). Inspect $($Plan.LogPath)." }
            $response=Invoke-WebRequest -Uri $health -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300) {
                Write-Host 'llama.cpp health check passed.' -ForegroundColor Green
                return
            }
        } catch {
            if ($Process.HasExited) { throw "llama-server exited with code $($Process.ExitCode). Inspect $($Plan.LogPath)." }
        }
        Start-Sleep -Milliseconds 750
    }
    throw "llama.cpp did not become healthy within $TimeoutSec seconds. Inspect $($Plan.LogPath)."
}

function Assert-ServedModel($Plan) {
    $uri="$($Plan.OpenAIBaseUrl)/models"
    try { $response=Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 10 -ErrorAction Stop }
    catch { throw "llama.cpp is healthy but $uri failed: $($_.Exception.Message)" }
    $ids=@()
    if ($response.data) { $ids=@($response.data | ForEach-Object { [string]$_.id }) }
    if ($ids -notcontains [string]$Plan.Alias) {
        throw "llama.cpp served model IDs [$($ids -join ', ')], expected alias '$($Plan.Alias)'. Refusing to launch a mismatched client."
    }
    Write-Host "Verified served alias: $($Plan.Alias)" -ForegroundColor Green
}

function Resolve-HarnessCommand([string]$SelectedHarness) {
    # Prefer native/.cmd shims on Windows so npm PowerShell shims do not trip execution-policy rules.
    $names=switch ($SelectedHarness) {
        'Pi' { @('pi','pi.cmd','pi.exe') }
        'OMP' { @('omp','omp.cmd','omp.exe') }
        'OpenCode' { @('opencode','opencode.cmd','opencode.exe') }
        'Codex' { @('codex','codex.cmd','codex.exe') }
        'Claude' { @('claude','claude.cmd','claude.exe','claude-code','claude-code.cmd','claude-code.exe') }
        default { @() }
    }
    foreach ($name in $names) {
        $command=Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) {
            if ($command.PSObject.Properties['Source'] -and $command.Source) { return [string]$command.Source }
            if ($command.PSObject.Properties['Path'] -and $command.Path) { return [string]$command.Path }
            return [string]$command.Name
        }
    }
    if ($names.Count -gt 0) { throw "$SelectedHarness command not found. Expected one of: $($names -join ', ')." }
    return ''
}

function Start-SelectedHarness([string]$SelectedHarness, $Plan, $Spec, $Extra, $SyncResult, [string]$WorkingDirectory) {
    if ($SelectedHarness -eq 'Server' -or $SelectedHarness -eq 'None') {
        Write-Host "Server ready at $($Plan.OpenAIBaseUrl). No coding harness was started." -ForegroundColor Green
        return
    }
    $command=Resolve-HarnessCommand $SelectedHarness
    $args=@()
    $environment=@{}
    switch ($SelectedHarness) {
        'Pi' {
            $args=@('--provider','local-qwen','--model',[string]$Plan.Alias)
        }
        'OMP' {
            $args=@('--provider','local-qwen','--model',[string]$Plan.Alias)
        }
        'OpenCode' {
            $environment['OPENCODE_CONFIG_CONTENT']=(Get-Content -LiteralPath $SyncResult.OpenCodeOverride -Raw)
        }
        'Codex' {
            $policy=Get-CompactionPolicy ([int]$Plan.Context)
            $inline='{ name = "llama.cpp Local", base_url = "' + [string]$Plan.OpenAIBaseUrl + '", wire_api = "responses", requires_openai_auth = false }'
            $args=@(
                '-c',('model="{0}"' -f $Plan.Alias),
                '-c','model_provider="local_llama"',
                '-c',("model_context_window={0}" -f $Plan.Context),
                '-c',("model_auto_compact_token_limit={0}" -f $policy.AutoCompact),
                '-c',("model_providers.local_llama={0}" -f $inline)
            )
        }
        'Claude' {
            $environment=Get-ClaudeEnvironment $Plan $Spec $Extra
            $args=@('--model',[string]$Plan.Alias)
            Write-Warning 'Claude Code is using llama.cpp Anthropic compatibility directly. Qwen templates can be stricter than native Claude; if Claude Code injects an unsupported message pattern, use Pi/OMP/OpenCode instead.'
        }
        default { throw "Unsupported harness: $SelectedHarness" }
    }

    $old=@{}
    foreach ($key in $environment.Keys) {
        $old[$key]=[Environment]::GetEnvironmentVariable([string]$key,'Process')
        [Environment]::SetEnvironmentVariable([string]$key,[string]$environment[$key],'Process')
    }
    Push-Location $WorkingDirectory
    try {
        Write-Host "`nLaunching $SelectedHarness in $WorkingDirectory" -ForegroundColor Cyan
        & $command @args
    } finally {
        Pop-Location
        foreach ($key in $environment.Keys) {
            [Environment]::SetEnvironmentVariable([string]$key,$old[$key],'Process')
        }
    }
}


function Get-ServerHelp([string]$Executable) {
    # Avoid PowerShell 5.1 treating native stderr from --help as a terminating error.
    $si=New-Object Diagnostics.ProcessStartInfo
    $si.FileName=$Executable; $si.Arguments='--help'; $si.UseShellExecute=$false
    $si.RedirectStandardOutput=$true; $si.RedirectStandardError=$true; $si.CreateNoWindow=$true
    $proc=New-Object Diagnostics.Process
    $proc.StartInfo=$si
    try {
        if (-not $proc.Start()) { throw 'Could not start llama-server --help.' }
        $outTask=$proc.StandardOutput.ReadToEndAsync(); $errTask=$proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(30000)) { $proc.Kill(); throw 'llama-server --help timed out.' }
        $text=$outTask.Result + "`n" + $errTask.Result
        if ($proc.ExitCode -ne 0) { throw "llama-server --help failed. Check CUDA DLLs/build installation.`n$text" }
        return $text
    } finally { $proc.Dispose() }
}

function Assert-ServerFlags([string[]]$Arguments, [string]$HelpText) {
    $supported=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($m in [regex]::Matches($HelpText,'(?<![\w-])--[a-zA-Z][a-zA-Z0-9-]*')) { [void]$supported.Add($m.Value) }
    $missing=@($Arguments | Where-Object { $_ -match '^--[a-zA-Z][a-zA-Z0-9-]*$' -and -not $supported.Contains($_) } | Select-Object -Unique)
    if ($missing.Count -gt 0) {
        throw "This llama-server build does not advertise required flags: $($missing -join ', '). Presets target your logged b10229/c745be2a2. No incompatible flag was silently removed."
    }
}

function Show-Plan($Plan, [string]$Executable, [string]$Path, $Extra) {
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host (' {0} | {1}' -f $Plan.Alias,$Plan.Profile) -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "Model:       $Path"
    Write-Host "Context:     $($Plan.Context) (GGUF native: $($Plan.NativeContext))"
    Write-Host "KV / FA:     $($Plan.KV) K+V / ON"
    Write-Host "Placement:   Auto-fit; $($Plan.FitTargetMiB) MiB target headroom"
    Write-Host "Threads:     $($Plan.Threads) generation / $($Plan.ThreadsBatch) prompt"
    Write-Host "Batch:       2048 logical / $($Plan.UBatch) physical"
    Write-Host "Thinking:    ON, unlimited server-side budget"
    Write-Host "MTP / vision: $($Plan.Mtp) / $($Plan.Vision)"
    if ($Extra.Projector) { Write-Host "Projector:   $($Extra.Projector)" }
    Write-Host "Saved cache: $($Plan.CacheRamMiB) MiB maximum, plus live state/checkpoints"
    Write-Host "Endpoint:    $($Plan.OpenAIBaseUrl)"
    Write-Host "Log:         $($Plan.LogPath)"
    if ($Extra.Note) { Write-Host $Extra.Note -ForegroundColor DarkYellow }
    Write-Host 'Client-supplied sampling/output limits can override server defaults.' -ForegroundColor DarkYellow
    Write-Host "`nExact arguments:"
    $quoted=@($Plan.Arguments | ForEach-Object { "'" + $_.Replace("'","''") + "'" })
    Write-Host ("& '" + $Executable.Replace("'","''") + "' " + ($quoted -join ' '))
    Write-Host ''
}

function Invoke-LauncherSelfTest {
    # Runs on the user's PowerShell without loading a model or launching CUDA.
    $tokens=$null; $parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
    $checks=0
    foreach ($spec in $script:PresetData.models) {
        foreach ($profileName in @('Daily','MaxContext','Fast','Baseline')) {
            $meta=[pscustomobject]@{ NativeContext=$spec.contextCeiling; MtpHeads=1; SupportsPreserve=$true }
            $extra=[pscustomobject]@{ ReserveMiB=0; Vision='Off'; Projector=''; Mtp=$false; Draft='' }
            $plan=New-LaunchPlan $spec $meta $extra 'C:\fixtures\model.gguf' $profileName 0 'Default' 0 0 0 0 8080 'C:\fixtures\server.log'
            if ($plan.Context -gt $spec.contextCeiling -or $plan.Context -lt 512) { throw 'Context ceiling self-test failed.' }
            if ($plan.Arguments -contains '--cpu-moe') { throw 'Blanket CPU offload regression.' }
            if ($plan.Mtp -or $plan.Vision -ne 'Off') { throw 'Unexpected default accelerator allocation.' }
            $flagList=@($plan.Arguments | Where-Object { $_ -match '^--[a-zA-Z]' })
            if (@($flagList | Select-Object -Unique).Count -ne $flagList.Count) { throw 'Duplicate server flags.' }
            Assert-ServerFlags $plan.Arguments ($flagList -join "`n")
            $checks++
        }
    }
    $rejected=$false
    try { Assert-ServerFlags @('--not-a-real-option') '--model --port' } catch { $rejected=$true }
    if (-not $rejected) { throw 'Unsupported flag rejection failed.' }
    $spec=Get-ModelSpec 'gemma'
    $meta=[pscustomobject]@{ NativeContext=131072; MtpHeads=0; SupportsPreserve=$false }
    $extra=[pscustomobject]@{ ReserveMiB=0; Vision='Off'; Projector=''; Mtp=$false; Draft='' }
    $rejected=$false
    try { New-LaunchPlan $spec $meta $extra 'C:\model.gguf' 'Daily' 262144 'Default' 0 0 0 0 8080 'C:\log.txt' | Out-Null } catch { $rejected=$true }
    if (-not $rejected) { throw 'Native context rejection failed.' }
    # A tiny real GGUF metadata fixture validates the compiled reader, including skipped arrays.
    Initialize-GgufReader
    $temp=[IO.Path]::GetTempFileName()
    try {
        $stream=[IO.File]::Open($temp,[IO.FileMode]::Create)
        $writer=New-Object IO.BinaryWriter $stream
        try {
            $writer.Write([uint32]0x46554747); $writer.Write([uint32]3)
            $writer.Write([uint64]0); $writer.Write([uint64]5)
            $keys=@('general.architecture','qwen35moe.context_length','qwen35moe.nextn_predict_layers','tokenizer.ggml.tokens','tokenizer.chat_template')
            foreach ($key in $keys) {
                $bytes=[Text.Encoding]::UTF8.GetBytes($key); $writer.Write([uint64]$bytes.Length); $writer.Write($bytes)
                if ($key -eq 'tokenizer.ggml.tokens') {
                    $writer.Write([uint32]9); $writer.Write([uint32]8); $writer.Write([uint64]2)
                    foreach ($value in @('one','two')) { $b=[Text.Encoding]::UTF8.GetBytes($value); $writer.Write([uint64]$b.Length); $writer.Write($b) }
                } elseif ($key -like '*.context_length' -or $key -like '*.nextn_predict_layers') {
                    $writer.Write([uint32]4); $n=1
                    if ($key -like '*.context_length') { $n=262144 }
                    $writer.Write([uint32]$n)
                } else {
                    $writer.Write([uint32]8); $value='qwen35moe'
                    if ($key -eq 'tokenizer.chat_template') { $value='preserve_thinking {{ messages }}' }
                    $b=[Text.Encoding]::UTF8.GetBytes($value); $writer.Write([uint64]$b.Length); $writer.Write($b)
                }
            }
        } finally { $writer.Dispose(); $stream.Dispose() }
        $r=[LocalLauncher.GgufReaderV1]::Read($temp)
        if ($r['general.architecture'] -ne 'qwen35moe' -or $r['qwen35moe.context_length'] -ne 262144 -or $r['qwen35moe.nextn_predict_layers'] -ne 1) { throw 'GGUF metadata reader self-test failed.' }
        if ($r['tokenizer.chat_template'] -notmatch 'preserve_thinking') { throw 'GGUF array skip self-test failed.' }
        $ravenSpec=Get-ModelSpec 'ravenx'
        $actual=Get-ModelMetadata $temp $ravenSpec
        $autoExtra=Resolve-Extras $ravenSpec $temp $actual 'Off' 'Auto' '' ''
        $onExtra=Resolve-Extras $ravenSpec $temp $actual 'Off' 'On' '' ''
        if ($autoExtra.Mtp -or -not $onExtra.Mtp -or $onExtra.ReserveMiB -lt 1024) { throw 'MoE MTP selection self-test failed.' }
        $actual.MtpHeads=0
        $rejected=$false
        try { Resolve-Extras $ravenSpec $temp $actual 'Off' 'On' '' '' | Out-Null } catch { $rejected=$true }
        if (-not $rejected) { throw 'Missing embedded MTP head was not rejected.' }
    } finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }

    # Control-plane policy checks are pure and do not touch the user's configs.
    $aliases=@($script:PresetData.models | ForEach-Object { [string]$_.alias })
    if (@($aliases | Select-Object -Unique).Count -ne $aliases.Count) { throw 'Duplicate model alias in launcher registry.' }
    $policy128=Get-CompactionPolicy 131072
    $policy262=Get-CompactionPolicy 262144
    if ($policy128.Reserve -ne 32768 -or $policy128.AutoCompact -ne 98304) { throw '128K compaction policy self-test failed.' }
    if ($policy262.Reserve -ne 32768 -or $policy262.AutoCompact -ne 229376) { throw '262K compaction policy self-test failed.' }
    $clientProbe=[pscustomobject]@{ Context=131072 }
    if ((Get-ClientMaxTokens $clientProbe) -ne 16384) { throw 'Client output-limit self-test failed.' }

    Write-Host "PASS: PowerShell parsing, $checks model/profile plans, flag/context rejection, GGUF metadata fixture, MTP selection, and control-plane policies." -ForegroundColor Green
    Write-Host 'This checks launcher/config logic only; CUDA inference and external harness executables are verified during a real launch.'
}

$serverProcess=$null
$serverStarted=$false
try {
    if ($SelfTest) { Invoke-LauncherSelfTest; return }
    $server=Join-Path $PSScriptRoot 'llama-server.exe'
    if (-not (Test-Path -LiteralPath $server -PathType Leaf)) { throw "Place local-ai.ps1 beside llama-server.exe. Missing: $server" }

    $interactiveModel=(-not $PSBoundParameters.ContainsKey('Model'))
    $interactiveSession=($interactiveModel -or -not $PSBoundParameters.ContainsKey('Harness'))
    if (-not $Model) {
        Write-Host "`n================ LOCAL AI CONTROL CENTER ================" -ForegroundColor Cyan
        Write-Host ' One model plan -> llama.cpp + Pi + OMP + OpenCode + Codex + Claude Code' -ForegroundColor DarkGray
        Write-Host ''
        foreach ($entry in $script:PresetData.models) {
            $state=Get-ModelInstallState $entry
            if ($state -eq 'ready') {
                Write-Host (' [{0}] {1}  [ready]' -f $entry.number,$entry.name) -ForegroundColor White
            } else {
                Write-Host (' [{0}] {1}  [missing]' -f $entry.number,$entry.name) -ForegroundColor DarkGray
            }
        }
        Write-Host ' [Q] Quit'
        $Model=Read-Host 'Select model [Enter = 8 Qwen3.8 9B Distill]'
        if (-not $Model) { $Model='8' }
        if ($Model -match '^[Qq]$') { return }

        if (-not $PSBoundParameters.ContainsKey('Profile')) {
            Write-Host "`n========== PROFILE ==========" -ForegroundColor Cyan
            Write-Host ' [1] Daily       128K, quality-oriented KV, strong default'
            Write-Host ' [2] MaxContext  Native context up to 262K (Qwen3.8-9B uses Q4 KV)'
            Write-Host ' [3] Fast        64K, Q8 KV, maximum responsiveness'
            Write-Host ' [4] Baseline    128K comparison / Q4 KV for MoE'
            $pChoice=Read-Host 'Select profile [Enter = 1 Daily]'
            switch ($pChoice) {
                '' { $Profile='Daily' }; '1' { $Profile='Daily' }; '2' { $Profile='MaxContext' }
                '3' { $Profile='Fast' }; '4' { $Profile='Baseline' }
                default { throw 'Invalid profile selection.' }
            }
        }
    }

    $spec=Get-ModelSpec $Model
    $path=Resolve-LocalModel $spec $ModelPath
    Assert-ModelParts $path
    $metadata=Get-ModelMetadata $path $spec

    # Vision is an interactive choice unless explicitly pinned on the command line.
    if (-not $PSBoundParameters.ContainsKey('Vision') -and -not $DryRun) {
        $visionChoice=Select-InteractiveVision $spec $path $Profile
        $Vision=$visionChoice.Vision
        if (-not $ProjectorPath) { $ProjectorPath=$visionChoice.Projector }
    }

    # MTP is also a first-class launcher choice now.
    if (-not $PSBoundParameters.ContainsKey('Mtp') -and -not $DryRun) {
        $Mtp=Select-InteractiveMtp $spec $metadata
    }

    $selectedHarness=$Harness
    if ($SyncOnly) { $selectedHarness='None' }
    elseif (-not $selectedHarness -and -not $DryRun) {
        $hChoice=Select-InteractiveHarness
        $selectedHarness=$hChoice.Harness
        if ($hChoice.SyncOnly) { $SyncOnly=$true }
    }
    if (-not $selectedHarness) { $selectedHarness='Server' }

    $workingDirectory=(Get-Location).Path
    if (-not $DryRun -and -not $SyncOnly) {
        $workingDirectory=Resolve-ProjectDirectory $ProjectDir $selectedHarness ($interactiveSession -and -not $PSBoundParameters.ContainsKey('ProjectDir'))
        # Fail before a costly model load when the requested harness is not installed.
        if ($selectedHarness -ne 'Server' -and $selectedHarness -ne 'None') { [void](Resolve-HarnessCommand $selectedHarness) }
    }

    $extras=Resolve-Extras $spec $path $metadata $Vision $Mtp $ProjectorPath $DraftPath
    $logDir=Join-Path $PSScriptRoot 'logs'
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $log=Join-Path $logDir "$($spec.alias)-$Profile-$stamp.log"
    $plan=New-LaunchPlan $spec $metadata $extras $path $Profile $Context $KV $FitTargetMiB $Threads $ThreadsBatch $UBatch $Port $log
    $helpText=Get-ServerHelp $server
    Assert-ServerFlags $plan.Arguments $helpText
    Show-Plan $plan $server $path $extras
    Write-Host "Harness:     $selectedHarness"
    if ($selectedHarness -ne 'Server' -and $selectedHarness -ne 'None') { Write-Host "Project:     $workingDirectory" }

    if ($DryRun) {
        Write-Host 'DRY RUN: model metadata, context, projector and llama-server flags validated; no files changed and nothing launched.' -ForegroundColor Green
        return
    }

    if ($SyncOnly) {
        $sync=Sync-AllClients $plan $spec $extras 'None'
        Write-Host "`nSYNC ONLY complete for $($plan.Alias) @ $($plan.Context) tokens." -ForegroundColor Green
        Write-Host "Backups: $script:BackupSessionDir" -ForegroundColor DarkGray
        return
    }

    if ($spec.family -eq 'moe' -and (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
        try {
            $os=Get-CimInstance Win32_OperatingSystem
            $freeGiB=[math]::Round($os.FreePhysicalMemory / 1MB,1)
            Write-Host "Free system RAM before load: $freeGiB GiB"
            if ($freeGiB -lt 16) { Write-Warning 'Less than 16 GiB free. Close other model servers/VMs/heavy apps; fitting VRAM does not guarantee sufficient system RAM.' }
        } catch { Write-Warning 'System RAM availability could not be read.' }
    }

    Ensure-Directory $logDir
    $initialManifest=[ordered]@{
        Created=(Get-Date).ToString('o')
        LauncherVersion='3.0-control-center'
        Model=$path
        Harness=$selectedHarness
        Project=$workingDirectory
        Plan=$plan
        PowerShell=$PSVersionTable.PSVersion.ToString()
    }
    Write-TextAtomic ($log+'.launch.json') ($initialManifest | ConvertTo-Json -Depth 20)

    $serverProcess=Start-LlamaServer $server $plan $interactiveSession ([bool]$StopExistingServer)
    $serverStarted=$true
    Wait-LlamaHealth $plan $serverProcess $ServerReadyTimeoutSec
    Assert-ServedModel $plan

    # Only point all harnesses at the plan after the actual server has proven what it serves.
    $sync=Sync-AllClients $plan $spec $extras $selectedHarness
    $finalManifest=[ordered]@{
        Created=$initialManifest.Created
        Ready=(Get-Date).ToString('o')
        LauncherVersion='3.0-control-center'
        Model=$path
        ServerPid=$serverProcess.Id
        Harness=$selectedHarness
        Project=$workingDirectory
        Plan=$plan
        Configs=$sync
        PowerShell=$PSVersionTable.PSVersion.ToString()
    }
    Write-TextAtomic ($log+'.launch.json') ($finalManifest | ConvertTo-Json -Depth 30)

    Start-SelectedHarness $selectedHarness $plan $spec $extras $sync $workingDirectory

    if ($serverProcess -and -not $serverProcess.HasExited) {
        Write-Host "`nllama-server is still running as PID $($serverProcess.Id)." -ForegroundColor DarkGray
        Write-Host "Log: $($plan.LogPath)" -ForegroundColor DarkGray
        Write-Host 'Re-run local-ai.ps1 to switch models; the launcher can safely replace an existing llama-server.' -ForegroundColor DarkGray
    }
} catch {
    if ($serverStarted -and $serverProcess -and -not $serverProcess.HasExited) {
        Write-Warning "Stopping llama-server PID $($serverProcess.Id) because launcher setup failed."
        Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
    }
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
