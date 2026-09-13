function Invoke-LocalAIControllerForTest {
    param([string[]]$Arguments)
    $output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:ProjectRoot 'local-ai-v4.ps1') @Arguments 2>&1
    if($LASTEXITCODE -ne 0){throw "Controller failed ($LASTEXITCODE): $($output -join "`n")"}
    return ($output -join "`n")
}

Invoke-TestCase 'SelfTest command emits parseable JSON with a passing result' {
    $text=Invoke-LocalAIControllerForTest @('-Command','SelfTest','-Json')
    $value=$text|ConvertFrom-Json
    Assert-Equal $true $value.passed
    Assert-True ($value.checks -ge 5)
}

Invoke-TestCase 'ListModels JSON uses automatic discovery through the command entry point' {
    $root=Join-Path $script:TestRoot 'command-models'
    $null=New-TestGguf -Path (Join-Path $root 'future-Q5_K_M.gguf')
    $text=Invoke-LocalAIControllerForTest @('-Command','ListModels','-InstallRoot',$script:TestRoot,'-StateRoot',(Join-Path $script:TestRoot 'state'),'-ModelRoot',$root,'-NoDefaultModelRoots','-Json')
    $models=@($text|ConvertFrom-Json)
    Assert-Equal 1 $models.Count
    Assert-Equal 'qwen' $models[0].Architecture
}

Invoke-TestCase 'cmd wrapper passes arguments to the PowerShell controller' {
    $output=& cmd.exe /d /c (Join-Path $script:ProjectRoot 'local-ai.cmd') -Command SelfTest -Json 2>&1
    if($LASTEXITCODE -ne 0){throw "CMD wrapper failed: $($output -join "`n")"}
    $value=($output -join "`n")|ConvertFrom-Json
    Assert-Equal $true $value.passed
}

Invoke-TestCase 'Models move dry run plans every shard without moving files' {
    $root=Join-Path $script:TestRoot 'move-command-source';$destination=Join-Path $script:TestRoot 'move-command-destination'
    $files=@(New-TestShardSet -Root $root -Stem command-model -Count 2)
    $list=Invoke-LocalAIControllerForTest @('-Command','ListModels','-InstallRoot',$script:TestRoot,'-StateRoot',(Join-Path $script:TestRoot 'move-state'),'-ModelRoot',$root,'-NoDefaultModelRoots','-Json')|ConvertFrom-Json
    $text=Invoke-LocalAIControllerForTest @('-Command','Models','-ModelAction','Move','-Model',$list.Id,'-Destination',$destination,'-InstallRoot',$script:TestRoot,'-StateRoot',(Join-Path $script:TestRoot 'move-state'),'-ModelRoot',$root,'-NoDefaultModelRoots','-DryRun','-Json')
    $plan=$text|ConvertFrom-Json
    Assert-Equal 2 $plan.Files.Count
    Assert-True (Test-Path -LiteralPath $files[0])
    Assert-True (-not(Test-Path -LiteralPath $destination))
}

Invoke-TestCase 'Harness preview derives alias and context without editing configuration' {
    $root=Join-Path $script:TestRoot 'harness-preview';$modelPath=New-TestGguf -Path (Join-Path $root 'preview.gguf')
    $text=Invoke-LocalAIControllerForTest @('-Command','Harnesses','-HarnessAction','PreviewConfig','-Harness','codex','-Model',$modelPath,'-InstallRoot',$script:TestRoot,'-StateRoot',(Join-Path $script:TestRoot 'preview-state'),'-ModelRoot',$root,'-NoDefaultModelRoots','-Json')
    $config=$text|ConvertFrom-Json
    Assert-Equal 'CodexToml' $config.Strategy
    Assert-Equal 32768 $config.Context
    Assert-True (-not(Test-Path -LiteralPath $config.Path))
}

Invoke-TestCase 'Plan reuses an applicable stored machine and model benchmark' {
    $root=Join-Path $script:TestRoot 'benchmark-plan';$state=Join-Path $script:TestRoot 'benchmark-plan-state'
    $modelPath=New-TestGguf -Path (Join-Path $root 'benchmarked.gguf')
    $initial=(Invoke-LocalAIControllerForTest @('-Command','Plan','-Model',$modelPath,'-InstallRoot',$script:TestRoot,'-StateRoot',$state,'-ModelRoot',$root,'-NoDefaultModelRoots','-Profile','Auto','-DryRun','-Json')|ConvertFrom-Json)
    Import-TestModule Common;Import-TestModule Configuration;Import-TestModule Hardware
    $paths=Get-LocalAIPaths -InstallRoot $script:TestRoot -StateRoot $state
    $machine=Get-LocalAIMachine -LlamaRoot $script:TestRoot
    $record=[pscustomobject]@{MachineFingerprint=Get-LocalAIMachineFingerprint $machine;ModelFingerprint=$initial.ModelFingerprint;Intent='Auto';Winner=[pscustomobject]@{Context=16384;KV='q4_0';Batch=1024;UBatch=256;Threads=8;ThreadsBatch=16;FitTargetMiB=1536}}
    $null=Write-LocalAIJsonAtomic -Path $paths.Benchmarks -Value ([pscustomobject]@{schemaVersion=1;records=@($record)})
    $applied=(Invoke-LocalAIControllerForTest @('-Command','Plan','-Model',$modelPath,'-InstallRoot',$script:TestRoot,'-StateRoot',$state,'-ModelRoot',$root,'-NoDefaultModelRoots','-Profile','Auto','-DryRun','-Json')|ConvertFrom-Json)
    Assert-Equal 16384 $applied.Context
    Assert-Equal 'q4_0' $applied.KV
    Assert-Equal 'benchmark' $applied.Provenance.Context
}

Invoke-TestCase 'menu launch option invokes the interactive launch flow instead of printing a recipe' {
    $source=Get-Content -LiteralPath (Join-Path $script:ProjectRoot 'local-ai-v4.ps1') -Raw
    Assert-True ($source -match "'1'\s*\{\s*Invoke-ControllerInteractiveLaunch")
    Assert-True ($source -notmatch 'Launch from any terminal with:')
}
