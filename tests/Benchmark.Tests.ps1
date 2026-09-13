function New-BenchmarkTestPlan {
    [pscustomobject]@{PlanId='plan-test';ModelId='model-test';ModelFingerprint='model-fp';ModelPath='C:\models\x.gguf';Intent='CodingFast';Context=[long]65536;NativeContext=[long]131072;KV='q8_0';Batch=2048;UBatch=512;Threads=12;ThreadsBatch=24;FitTargetMiB=1024;Mtp=$false;Arguments=@('--model','C:\models\x.gguf')}
}
function New-BenchmarkTestResult {
    param([string]$Id,[double]$Tps,[bool]$ProbePass=$true,[bool]$Succeeded=$true)
    [pscustomobject]@{CandidateId=$Id;Succeeded=$Succeeded;Stable=$Succeeded;PromptTokensPerSecond=$Tps*2;GenerationTokensPerSecond=$Tps;LatencyMs=100;PeakVramMiB=9000;HeadroomMiB=1500;ProbePass=$ProbePass;Error=''}
}

Invoke-TestCase 'autotune candidate matrix is bounded and unique' {
    Import-TestModule Common
    Import-TestModule Benchmark
    $c=@(New-LocalAIBenchmarkMatrix -BasePlan (New-BenchmarkTestPlan) -Intent CodingFast)
    Assert-True ($c.Count -le 16)
    Assert-Equal $c.Count @($c|ForEach-Object CandidateId|Select-Object -Unique).Count
}

Invoke-TestCase 'llama bench arguments use build 10229 flash attention values' {
    Import-TestModule Benchmark
    $candidate=(New-LocalAIBenchmarkMatrix -BasePlan (New-BenchmarkTestPlan) -Intent CodingFast)[0]
    $arguments=@(New-LocalAILlamaBenchArguments -Candidate $candidate)
    $index=[array]::IndexOf($arguments,'-fa')
    Assert-True ($index -ge 0)
    Assert-Equal 'on' $arguments[$index+1]
}

Invoke-TestCase 'different machine fingerprint makes benchmark inapplicable' {
    Import-TestModule Benchmark
    $record=[pscustomobject]@{MachineFingerprint='old';ModelFingerprint='model-fp';Intent='CodingFast';Winner=[pscustomobject]@{CandidateId='a'}}
    $actual=Get-LocalAIApplicableBenchmark -Store @($record) -MachineFingerprint 'new' -ModelFingerprint 'model-fp' -Intent CodingFast
    Assert-Equal $null $actual
}

Invoke-TestCase 'quality intent rejects a faster failed probe result' {
    Import-TestModule Benchmark
    $winner=Select-LocalAIBenchmarkWinner -Results @((New-BenchmarkTestResult -Id fast -Tps 50 -ProbePass $false),(New-BenchmarkTestResult -Id valid -Tps 30 -ProbePass $true)) -Intent CodingQuality
    Assert-Equal 'valid' $winner.CandidateId
}

Invoke-TestCase 'failed candidates are retained as negative evidence' {
    Import-TestModule Benchmark
    $candidates=@([pscustomobject]@{CandidateId='bad'},[pscustomobject]@{CandidateId='good'})
    $results=@(Invoke-LocalAIBenchmark -Candidates $candidates -Runner {param($c) if($c.CandidateId -eq 'bad'){throw 'out of memory'}else{New-BenchmarkTestResult -Id good -Tps 20}})
    Assert-Equal 2 $results.Count
    Assert-Equal $false $results[0].Succeeded
    Assert-True ($results[0].Error -match 'out of memory')
}
