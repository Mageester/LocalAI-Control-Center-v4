Invoke-TestCase 'statistics marks a failed GPU probe unavailable without failing other metrics' {
    Import-TestModule Diagnostics
    $context=[pscustomobject]@{NvidiaProbe={throw 'nvidia-smi missing'};MemoryProbe={ [pscustomobject]@{TotalBytes=[long](32GB);FreeBytes=[long](20GB)} };ActiveState=$null}
    $s=Get-LocalAIStatistics -Context $context
    Assert-Equal 'Unavailable' $s.Gpu.Status
    Assert-Equal 'Available' $s.Memory.Status
}

Invoke-TestCase 'Doctor reports a missing shard as a stable failure code' {
    Import-TestModule Diagnostics
    $model=[pscustomobject]@{Id='broken';Status='Invalid';Error='Missing shard(s): model-00002-of-00002.gguf';Shards=@('C:\missing\model-00001-of-00002.gguf');HasChatTemplate=$true}
    $context=[pscustomobject]@{InstallRoot=$script:TestRoot;StateRoot=$script:TestRoot;Models=@($model);Machine=[pscustomobject]@{GpuName='';RamBytes=[long](32GB);LlamaBuild='10229'};Adapters=@();ServerCapabilities=$null}
    $r=@(Invoke-LocalAIDoctor -Context $context)
    Assert-Equal 'Fail' (@($r|Where-Object Code -eq 'MODEL_SHARDS')[0].Status)
}

Invoke-TestCase 'redaction removes bearer and Hugging Face token values' {
    Import-TestModule Diagnostics
    $text=ConvertTo-LocalAIRedactedText "Authorization: Bearer hf_abcdefghijklmnopqrstuvwxyz123456`nHF_TOKEN=hf_zyxwvutsrqponmlkjihgfedcba987654"
    Assert-True ($text -notmatch 'abcdefghijklmnopqrstuvwxyz')
    Assert-True ($text -notmatch 'zyxwvutsrqponml')
    Assert-True ($text -match '\[REDACTED\]')
}

Invoke-TestCase 'offline Doctor skips live server checks' {
    Import-TestModule Diagnostics
    $context=[pscustomobject]@{InstallRoot=$script:TestRoot;StateRoot=$script:TestRoot;Models=@();Machine=[pscustomobject]@{GpuName='';RamBytes=[long](32GB);LlamaBuild=''};Adapters=@();ServerCapabilities=$null}
    $r=@(Invoke-LocalAIDoctor -Context $context)
    Assert-Equal 'Skipped' (@($r|Where-Object Code -eq 'SERVER_LIVE')[0].Status)
}

Invoke-TestCase 'live statistics emits repeated independent samples' {
    Import-TestModule Diagnostics
    $samples=New-Object Collections.Generic.List[object]
    $context=[pscustomobject]@{NvidiaProbe={throw 'not installed'};MemoryProbe={[pscustomobject]@{TotalBytes=32GB;FreeBytes=16GB}};ActiveState=$null}
    Watch-LocalAIStatistics -Context $context -SampleCount 3 -IntervalSeconds 1 -Writer {$samples.Add($args[0])} -Sleeper {param($seconds)}
    Assert-Equal 3 $samples.Count
    Assert-Equal 'Unavailable' $samples[2].Gpu.Status
}
