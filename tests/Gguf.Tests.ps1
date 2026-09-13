Invoke-TestCase 'GGUF reader accepts an unknown future architecture' {
    Import-TestModule Gguf
    $path=New-TestGguf -Metadata ([ordered]@{
        'general.architecture'='futurearch'
        'general.name'='Future Coder 12B Q5_K_M'
        'futurearch.context_length'=[uint32]131072
        'tokenizer.chat_template'='{{ messages }}'
    })
    $m=Get-LocalAIGgufSummary -Path $path
    Assert-Equal 'futurearch' $m.Architecture
    Assert-Equal ([long]131072) $m.NativeContext
    Assert-Equal 'Future Coder 12B Q5_K_M' $m.Name
}

Invoke-TestCase 'GGUF reader rejects a declared string beyond its safety limit' {
    Import-TestModule Gguf
    $path=New-MalformedTestGguf -DeclaredStringLength ([uint64]::MaxValue)
    Assert-Throws { Read-LocalAIGgufMetadata -Path $path } 'safety limit'
}

Invoke-TestCase 'GGUF reader skips tokenizer arrays and continues reading metadata' {
    Import-TestModule Gguf
    $metadata=[ordered]@{
        'general.architecture'='qwen'
        'general.name'='Array Test'
        'qwen.context_length'=[uint32]32768
        'tokenizer.chat_template'='preserve_thinking {{ messages }}'
    }
    $path=New-TestGguf -Metadata $metadata -IncludeTokenArray
    $m=Get-LocalAIGgufSummary -Path $path
    Assert-Equal 'qwen' $m.Architecture
    Assert-True $m.SupportsPreserveReasoning
}

Invoke-TestCase 'GGUF summary reports missing chat template without inventing one' {
    Import-TestModule Gguf
    $path=New-TestGguf -Metadata ([ordered]@{
        'general.architecture'='qwen'
        'qwen.context_length'=[uint32]32768
    })
    $m=Get-LocalAIGgufSummary -Path $path
    Assert-Equal '' $m.ChatTemplate
    Assert-Equal $false $m.HasChatTemplate
}
