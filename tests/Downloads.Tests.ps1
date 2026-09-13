Invoke-TestCase 'Hugging Face resolve URL is parsed into repository revision and filename' {
    Import-TestModule Common
    Import-TestModule Downloads
    $r=ConvertFrom-LocalAIHuggingFaceReference -Reference 'https://huggingface.co/org/repo/resolve/main/model-Q4_K_M.gguf'
    Assert-Equal 'org/repo' $r.Repository
    Assert-Equal 'main' $r.Revision
    Assert-Equal 'model-Q4_K_M.gguf' $r.FileName
}

Invoke-TestCase 'structured repository rejects shell fragments' {
    Import-TestModule Downloads
    Assert-Throws { New-LocalAIDownloadPlan -Repository 'org/repo;whoami' -FileName 'm.gguf' } 'repository'
}

Invoke-TestCase 'download filename rejects path traversal' {
    Import-TestModule Downloads
    Assert-Throws { New-LocalAIDownloadPlan -Repository 'org/repo' -FileName '..\secret.gguf' } 'filename'
}

Invoke-TestCase 'model move plan includes every shard and preserves names' {
    Import-TestModule Common
    Import-TestModule Downloads
    $source=Join-Path $script:TestRoot 'source';$destination=Join-Path $script:TestRoot 'destination'
    $files=@(New-TestShardSet -Root $source -Stem model -Count 2)
    $model=[pscustomobject]@{Id='model-test';Status='Ready';Kind='MainModel';Shards=$files;Path=$files[0];Error=''}
    $plan=New-LocalAIModelMovePlan -Model $model -DestinationRoot $destination -AllowedRoots @($source)
    Assert-Equal 2 $plan.Files.Count
    Assert-Equal 'model-00001-of-00002.gguf' ([IO.Path]::GetFileName($plan.Files[0].Destination))
}

Invoke-TestCase 'model move plan rejects an incomplete model record' {
    Import-TestModule Downloads
    $model=[pscustomobject]@{Status='Invalid';Kind='MainModel';Shards=@('C:\models\part.gguf');Path='C:\models\part.gguf';Error='Missing shard'}
    Assert-Throws { New-LocalAIModelMovePlan -Model $model -DestinationRoot 'D:\models' -AllowedRoots @('C:\models') } 'not ready'
}
