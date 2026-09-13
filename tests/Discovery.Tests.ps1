Invoke-TestCase 'discovery groups a complete split GGUF as one main model' {
    Import-TestModule Gguf
    Import-TestModule Configuration
    Import-TestModule Common
    Import-TestModule Discovery
    $root=Join-Path $script:TestRoot 'complete'
    $null=New-TestShardSet -Root $root -Stem 'future-model' -Count 3
    $models=@(Find-LocalAIModels -Roots @($root) -CachePath (Join-Path $root 'cache.json') -Force)
    $main=@($models | Where-Object Kind -eq 'MainModel')
    Assert-Equal 1 $main.Count
    Assert-Equal 3 $main[0].Shards.Count
    Assert-Equal 'Ready' $main[0].Status
}

Invoke-TestCase 'discovery reports an incomplete shard group as invalid' {
    Import-TestModule Gguf
    Import-TestModule Configuration
    Import-TestModule Common
    Import-TestModule Discovery
    $root=Join-Path $script:TestRoot 'broken'
    $files=@(New-TestShardSet -Root $root -Stem 'broken-model' -Count 3)
    Remove-Item -LiteralPath $files[1] -Force
    $models=@(Find-LocalAIModels -Roots @($root) -CachePath (Join-Path $root 'cache.json') -Force)
    Assert-Equal 'Invalid' $models[0].Status
    Assert-True ($models[0].Error -match 'Missing shard')
}

Invoke-TestCase 'projector sidecar is not selectable as a main model' {
    Import-TestModule Gguf
    Import-TestModule Configuration
    Import-TestModule Common
    Import-TestModule Discovery
    $root=Join-Path $script:TestRoot 'projector'
    $null=New-TestGguf -Path (Join-Path $root 'mmproj-F16.gguf')
    $models=@(Find-LocalAIModels -Roots @($root) -CachePath (Join-Path $root 'cache.json') -Force)
    Assert-Equal 0 @($models | Where-Object Kind -eq 'MainModel').Count
    Assert-Equal 1 @($models | Where-Object Kind -eq 'Projector').Count
}

Invoke-TestCase 'classification derives MoE from metadata without a known-model entry' {
    Import-TestModule Discovery
    $model=[pscustomobject]@{Id='x';Name='Future';Architecture='futuremoe';NativeContext=65536;ExpertCount=64;ActiveExpertCount=4;Quantization='Q4_K_M';HasChatTemplate=$true;MtpHeads=0;LogicalBytes=[long](20GB);Path='C:\models\x.gguf'}
    $machine=[pscustomobject]@{VramBytes=[long](12GB);RamBytes=[long](32GB)}
    $c=Get-LocalAIModelClassification -Model $model -Machine $machine -Overrides @()
    Assert-Equal 'moe' $c.Family.Value
    Assert-Equal 'metadata' $c.Family.Source
}

Invoke-TestCase 'unchanged discovery returns the persisted cache without rewriting it' {
    Import-TestModule Gguf;Import-TestModule Configuration;Import-TestModule Common;Import-TestModule Discovery
    $root=Join-Path $script:TestRoot 'cached-discovery';$cache=Join-Path $script:TestRoot 'cached-models.json'
    $null=New-TestGguf -Path (Join-Path $root 'cached.gguf')
    $first=@(Find-LocalAIModels -Roots @($root) -CachePath $cache -Force)
    $written=(Get-Item -LiteralPath $cache).LastWriteTimeUtc
    Start-Sleep -Milliseconds 50
    $second=@(Find-LocalAIModels -Roots @($root) -CachePath $cache)
    Assert-Equal $written (Get-Item -LiteralPath $cache).LastWriteTimeUtc
    Assert-Equal $first[0].Id $second[0].Id
}

Invoke-TestCase 'discovery cache invalidates when a model root changes' {
    Import-TestModule Gguf;Import-TestModule Configuration;Import-TestModule Common;Import-TestModule Discovery
    $root=Join-Path $script:TestRoot 'changed-discovery';$cache=Join-Path $script:TestRoot 'changed-models.json'
    $null=New-TestGguf -Path (Join-Path $root 'one.gguf')
    Assert-Equal 1 @(Find-LocalAIModels -Roots @($root) -CachePath $cache -Force).Count
    $null=New-TestGguf -Path (Join-Path $root 'two.gguf')
    Assert-Equal 2 @(Find-LocalAIModels -Roots @($root) -CachePath $cache).Count
}

Invoke-TestCase 'discovery cache invalidates for a new snapshot in an existing repository' {
    Import-TestModule Gguf;Import-TestModule Configuration;Import-TestModule Common;Import-TestModule Discovery
    $root=Join-Path $script:TestRoot 'hub';$snapshots=Join-Path $root 'models--owner--repo\snapshots';$cache=Join-Path $script:TestRoot 'snapshot-models.json'
    $null=New-TestGguf -Path (Join-Path $snapshots 'one.gguf')
    Assert-Equal 1 @(Find-LocalAIModels -Roots @($root) -CachePath $cache -Force).Count
    $null=New-TestGguf -Path (Join-Path $snapshots 'two.gguf')
    Assert-Equal 2 @(Find-LocalAIModels -Roots @($root) -CachePath $cache).Count
}
