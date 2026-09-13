Invoke-TestCase 'machine fingerprint ignores free memory and temperature drift' {
    Import-TestModule Common
    Import-TestModule Hardware
    $a=[pscustomobject]@{Cpu='CPU';LogicalProcessors=24;RamBytes=[long](32GB);GpuName='GPU';GpuUuid='GPU-1';VramBytes=[long](12GB);Driver='616.56';LlamaBuild='10229';FreeVramBytes=[long](10GB);GpuTemperature=40}
    $b=$a.PSObject.Copy();$b.FreeVramBytes=[long](8GB);$b.GpuTemperature=70
    Assert-Equal (Get-LocalAIMachineFingerprint -Machine $a) (Get-LocalAIMachineFingerprint -Machine $b)
}

Invoke-TestCase 'machine fingerprint changes with llama build' {
    Import-TestModule Common
    Import-TestModule Hardware
    $a=[pscustomobject]@{Cpu='CPU';LogicalProcessors=24;RamBytes=[long](32GB);GpuName='GPU';GpuUuid='GPU-1';VramBytes=[long](12GB);Driver='616.56';LlamaBuild='10229'}
    $b=$a.PSObject.Copy();$b.LlamaBuild='10300'
    Assert-True ((Get-LocalAIMachineFingerprint $a) -ne (Get-LocalAIMachineFingerprint $b))
}
