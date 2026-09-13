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
