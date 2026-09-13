Invoke-TestCase 'invalid menu input retries and returns the next valid choice' {
    Import-TestModule UI
    $queue=New-Object Collections.Queue;$queue.Enqueue('x');$queue.Enqueue('1')
    $choice=Read-LocalAIChoice -Allowed @('1','Q') -ReadInput {$queue.Dequeue()} -WriteOutput {param($text)}
    Assert-Equal '1' $choice
}

Invoke-TestCase 'plan display includes the authoritative context and exact endpoint' {
    Import-TestModule Common
    Import-TestModule UI
    $plan=[pscustomobject]@{Alias='test';Intent='Auto';Context=65536;NativeContext=131072;KV='q8_0';Batch=2048;UBatch=512;Threads=12;ThreadsBatch=24;Mtp=$false;Vision='Off';ServerBaseUrl='http://127.0.0.1:8080';ModelPath='C:\m.gguf';Arguments=@('--model','C:\m.gguf')}
    $text=Show-LocalAIPlan -Plan $plan -PassThru
    Assert-True ($text -match '65,536')
    Assert-True ($text -match 'http://127.0.0.1:8080')
}

Invoke-TestCase 'interactive model picker excludes projectors and returns numbered main model' {
    Import-TestModule UI
    $models=@(
        [pscustomobject]@{Id='main-a';Kind='MainModel';Status='Ready';Name='Model A';NativeContext=32768;LogicalBytes=4GB;Quantization='Q4'},
        [pscustomobject]@{Id='projector';Kind='Projector';Status='Ready';Name='Projector';NativeContext=0;LogicalBytes=1GB;Quantization='F16'},
        [pscustomobject]@{Id='main-b';Kind='MainModel';Status='Ready';Name='Model B';NativeContext=65536;LogicalBytes=6GB;Quantization='Q5'}
    )
    $selected=Select-LocalAIModelInteractive -Models $models -ReadInput {'2'} -WriteOutput {param($text)}
    Assert-Equal 'main-b' $selected.Id
}

Invoke-TestCase 'interactive profile picker returns the selected safe profile' {
    Import-TestModule UI
    $selected=Select-LocalAIProfileInteractive -ReadInput {'3'} -WriteOutput {param($text)}
    Assert-Equal 'CodingFast' $selected
}

Invoke-TestCase 'interactive confirmation requires an explicit yes' {
    Import-TestModule UI
    Assert-Equal $false (Confirm-LocalAIInteractiveAction -Prompt 'Launch?' -ReadInput {'no'} -WriteOutput {param($text)})
    Assert-Equal $true (Confirm-LocalAIInteractiveAction -Prompt 'Launch?' -ReadInput {'Y'} -WriteOutput {param($text)})
}

Invoke-TestCase 'interactive harness picker offers server plus installed harnesses only' {
    Import-TestModule UI
    $statuses=@(
        [pscustomobject]@{Id='pi';DisplayName='Pi';Installed=$true;Version='1.0'},
        [pscustomobject]@{Id='codex';DisplayName='Codex';Installed=$false;Version=''}
    )
    $selected=Select-LocalAIHarnessInteractive -Statuses $statuses -ReadInput {'2'} -WriteOutput {param($text)}
    Assert-Equal 'pi' $selected
}
