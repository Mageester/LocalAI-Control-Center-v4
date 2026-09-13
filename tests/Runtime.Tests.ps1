Invoke-TestCase 'runtime rejects a generated flag not advertised by llama server' {
    Import-TestModule Common
    Import-TestModule Runtime
    Assert-Throws { Test-LocalAIServerArguments -Arguments @('--model','x','--future-flag') -SupportedFlags @('--model') } '--future-flag'
}

Invoke-TestCase 'runtime accepts values that begin with ordinary text' {
    Import-TestModule Runtime
    Assert-True (Test-LocalAIServerArguments -Arguments @('--model','C:\models\x.gguf','--port','8080') -SupportedFlags @('--model','--port'))
}

Invoke-TestCase 'process ownership rejects PID reuse with a different start time' {
    Import-TestModule Runtime
    $state=[pscustomobject]@{Pid=42;ProcessStartTime='2026-01-01T00:00:00.0000000Z';Executable='C:\llama\llama-server.exe'}
    $actual=[pscustomobject]@{Pid=42;ProcessStartTime='2026-01-02T00:00:00.0000000Z';Executable='C:\llama\llama-server.exe'}
    Assert-Throws { Test-LocalAIOwnedProcess -State $state -Actual $actual } 'does not match'
}

Invoke-TestCase 'process ownership rejects a different executable' {
    Import-TestModule Runtime
    $state=[pscustomobject]@{Pid=42;ProcessStartTime='2026-01-01T00:00:00.0000000Z';Executable='C:\llama\llama-server.exe'}
    $actual=[pscustomobject]@{Pid=42;ProcessStartTime='2026-01-01T00:00:00.0000000Z';Executable='C:\Windows\notepad.exe'}
    Assert-Throws { Test-LocalAIOwnedProcess -State $state -Actual $actual } 'does not match'
}

Invoke-TestCase 'served model verification rejects an alias mismatch' {
    Import-TestModule Runtime
    Assert-Throws { Confirm-LocalAIModelList -ExpectedAlias 'alpha' -ModelIds @('beta') } 'alpha'
}

Invoke-TestCase 'served model verification accepts the exact alias' {
    Import-TestModule Runtime
    Assert-True (Confirm-LocalAIModelList -ExpectedAlias 'alpha' -ModelIds @('beta','alpha'))
}

Invoke-TestCase 'unchanged server executable reuses capability cache' {
    Import-TestModule Common;Import-TestModule Configuration;Import-TestModule Runtime
    $exe=Join-Path $script:TestRoot 'fake-server.exe';[IO.File]::WriteAllBytes($exe,[byte[]](1,2,3))
    $cache=Join-Path $script:TestRoot 'capabilities.json';$script:capabilityCalls=0
    $runner={param($file,$arguments) $script:capabilityCalls++;if($arguments[0] -eq '--version'){[pscustomobject]@{ExitCode=0;StdOut='version: 10229';StdErr=''}}else{[pscustomobject]@{ExitCode=0;StdOut='--model --ctx-size';StdErr=''}}}
    $null=Get-LocalAIServerCapabilities -Executable $exe -CachePath $cache -Runner $runner
    $null=Get-LocalAIServerCapabilities -Executable $exe -CachePath $cache -Runner $runner
    Assert-Equal 2 $script:capabilityCalls
}
