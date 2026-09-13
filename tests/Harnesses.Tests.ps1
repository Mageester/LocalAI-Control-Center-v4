function New-HarnessTestPlan {
    [pscustomobject]@{Alias='local-a';Context=131072;OpenAIBaseUrl='http://127.0.0.1:8080/v1';ServerBaseUrl='http://127.0.0.1:8080';ClientPolicy=[pscustomobject]@{ContextWindow=131072;MaxOutputTokens=16384;CompactionReserve=32768;AutoCompactThreshold=98304};Vision='Off'}
}

Invoke-TestCase 'all shipped harness adapters receive plan alias and context' {
    Import-TestModule Common
    Import-TestModule Configuration
    Import-TestModule Harnesses
    $adapters=Get-LocalAIHarnessAdapters -ShippedRoot (Join-Path $script:ProjectRoot 'LocalAI\Adapters')
    Assert-Equal 5 $adapters.Count
    foreach($adapter in $adapters){
        $config=Get-LocalAIHarnessConfiguration -Adapter $adapter -Plan (New-HarnessTestPlan) -StateRoot $script:TestRoot
        $serialized=$config | ConvertTo-Json -Depth 20
        Assert-True ($serialized -match 'local-a') "Adapter $($adapter.id) omitted the alias."
        Assert-True ($serialized -match '131072') "Adapter $($adapter.id) omitted the context."
    }
}

Invoke-TestCase 'Pi managed configuration preserves unrelated cloud providers' {
    Import-TestModule Common
    Import-TestModule Configuration
    Import-TestModule Harnesses
    $adapter=(Get-LocalAIHarnessAdapters -ShippedRoot (Join-Path $script:ProjectRoot 'LocalAI\Adapters')|Where-Object id -eq 'pi')
    $path=Join-Path $script:TestRoot 'pi-models.json'
    $existing=[pscustomobject]@{providers=[pscustomobject]@{cloud=[pscustomobject]@{apiKey='preserve-me'}}}
    $null=Write-LocalAIJsonAtomic -Path $path -Value $existing
    $config=Get-LocalAIHarnessConfiguration -Adapter $adapter -Plan (New-HarnessTestPlan) -StateRoot $script:TestRoot
    $config.Path=$path
    $session=New-LocalAIBackupSession -BackupRoot (Join-Path $script:TestRoot 'backups') -Operation 'pi-test'
    $null=Set-LocalAIHarnessConfiguration -Adapter $adapter -Configuration $config -BackupSession $session
    $actual=Read-LocalAIJson -Path $path
    Assert-Equal 'preserve-me' $actual.providers.cloud.apiKey
    Assert-Equal 131072 $actual.providers.'local-llama'.models[0].contextWindow
}

Invoke-TestCase 'adapter validation rejects install argument shell fragments' {
    Import-TestModule Harnesses
    $adapter=[pscustomobject]@{schemaVersion=1;id='bad';displayName='Bad';executableCandidates=@('bad');versionArguments=@('--version');install=[pscustomobject]@{mode='command';executable='npm.cmd';arguments=@('install','pkg;whoami')};configurationStrategy='Environment';launchArguments=@()}
    Assert-Throws { Test-LocalAIHarnessAdapter -Adapter $adapter } 'argument'
}
