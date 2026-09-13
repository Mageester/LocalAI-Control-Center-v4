function New-ProfileTestModel {
    param([long]$NativeContext=131072,[bool]$HasChatTemplate=$true)
    [pscustomobject]@{Id='future-model';Name='Future Coder';Path='C:\models\future.gguf';ResolvedPath='C:\models\future.gguf';Architecture='futurearch';NativeContext=$NativeContext;HasChatTemplate=$HasChatTemplate;ChatTemplate=if($HasChatTemplate){'{{ messages }}'}else{''};MtpHeads=0;ExpertCount=0;LogicalBytes=[long](6GB);Quantization='Q5_K_M';SupportsPreserveReasoning=$false;Shards=@('C:\models\future.gguf');Kind='MainModel';Status='Ready'}
}
function New-ProfileTestMachine {
    [pscustomobject]@{LogicalProcessors=24;RamBytes=[long](32GB);VramBytes=[long](12GB);FreeVramBytes=[long](10GB);LlamaBuild='10229'}
}

Invoke-TestCase 'safe profile context never exceeds native GGUF context' {
    Import-TestModule Common
    Import-TestModule Configuration
    Import-TestModule Profiles
    $plan=New-LocalAILaunchPlan -Model (New-ProfileTestModel -NativeContext 32768) -Machine (New-ProfileTestMachine) -Intent LongContext
    Assert-Equal ([long]32768) $plan.Context
}

Invoke-TestCase 'normal agent profile rejects a missing chat template' {
    Import-TestModule Common
    Import-TestModule Configuration
    Import-TestModule Profiles
    Assert-Throws { New-LocalAILaunchPlan -Model (New-ProfileTestModel -HasChatTemplate $false) -Machine (New-ProfileTestMachine) -Intent CodingQuality } 'chat template'
}

Invoke-TestCase 'explicit context cannot exceed native metadata' {
    Import-TestModule Common
    Import-TestModule Configuration
    Import-TestModule Profiles
    Assert-Throws { New-LocalAILaunchPlan -Model (New-ProfileTestModel -NativeContext 65536) -Machine (New-ProfileTestMachine) -Intent Auto -Overrides @{Context=131072} } 'native context'
}

Invoke-TestCase 'client policy derives context and compaction thresholds from one value' {
    Import-TestModule Profiles
    $p=Get-LocalAIClientPolicy -Context 131072
    Assert-Equal 131072 $p.ContextWindow
    Assert-Equal 32768 $p.CompactionReserve
    Assert-Equal 98304 $p.AutoCompactThreshold
}

Invoke-TestCase 'explicit tuning takes precedence over applicable benchmark tuning' {
    Import-TestModule Profiles
    $model=New-ProfileTestModel -NativeContext 131072
    $plan=New-LocalAILaunchPlan -Model $model -Machine (New-ProfileTestMachine) -Intent Auto -BenchmarkOverrides @{Context=32768;KV='q4_0'} -Overrides @{Context=65536}
    Assert-Equal 65536 $plan.Context
    Assert-Equal 'q4_0' $plan.KV
    Assert-Equal 'explicit' $plan.Provenance.Context
    Assert-Equal 'benchmark' $plan.Provenance.KV
}

Invoke-TestCase 'launch plan rejects a server flag missing from capabilities' {
    Import-TestModule Profiles
    $plan=[pscustomobject]@{Context=4096;NativeContext=4096;Arguments=@('--model','x','--future-flag');ModelPath='x';HasChatTemplate=$true}
    Assert-Throws { Test-LocalAILaunchPlan -Plan $plan -ServerCapabilities ([pscustomobject]@{SupportedFlags=@('--model')}) } '--future-flag'
}

Invoke-TestCase 'launch plan emits each long flag at most once' {
    Import-TestModule Common
    Import-TestModule Configuration
    Import-TestModule Profiles
    $plan=New-LocalAILaunchPlan -Model (New-ProfileTestModel) -Machine (New-ProfileTestMachine) -Intent Auto
    $flags=@($plan.Arguments | Where-Object {$_ -match '^--'})
    Assert-Equal $flags.Count @($flags | Select-Object -Unique).Count
}
