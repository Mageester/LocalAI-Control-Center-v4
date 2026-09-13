Invoke-TestCase 'packaged v3 hash exactly matches the recorded original hash' {
    $actual=(Get-FileHash -LiteralPath (Join-Path $script:ProjectRoot 'reference\local-ai-v3.ps1') -Algorithm SHA256).Hash
    $expected=(Get-Content -LiteralPath (Join-Path $script:ProjectRoot 'reference\V3-SHA256.txt') -Raw).Trim()
    Assert-Equal $expected $actual
}

Invoke-TestCase 'installer plan never replaces the legacy local-ai.ps1 path' {
    $destination=Join-Path $script:TestRoot 'install-target';[void](New-Item -ItemType Directory -Path $destination -Force)
    Copy-Item -LiteralPath (Join-Path $script:ProjectRoot 'reference\local-ai-v3.ps1') -Destination (Join-Path $destination 'local-ai.ps1')
    $plan=& (Join-Path $script:ProjectRoot 'Install-LocalAI.ps1') -Destination $destination -SourceV3 (Join-Path $script:ProjectRoot 'reference\local-ai-v3.ps1') -WhatIf -PassThru
    Assert-Equal 0 @($plan.Writes|Where-Object RelativePath -eq 'local-ai.ps1').Count
    Assert-Equal 1 @($plan.Backups|Where-Object Source -eq (Join-Path $destination 'local-ai.ps1')).Count
}

Invoke-TestCase 'installer what-if leaves the destination unchanged' {
    $destination=Join-Path $script:TestRoot 'whatif-target';[void](New-Item -ItemType Directory -Path $destination -Force)
    $before=@(Get-ChildItem -LiteralPath $destination -Force).Count
    $null=& (Join-Path $script:ProjectRoot 'Install-LocalAI.ps1') -Destination $destination -SourceV3 (Join-Path $script:ProjectRoot 'reference\local-ai-v3.ps1') -WhatIf -PassThru
    Assert-Equal $before @(Get-ChildItem -LiteralPath $destination -Force).Count
}

Invoke-TestCase 'uninstaller what-if targets only manifest-owned v4 files' {
    $destination=Join-Path $script:TestRoot 'uninstall-target';[void](New-Item -ItemType Directory -Path $destination -Force)
    [IO.File]::WriteAllText((Join-Path $destination 'local-ai.ps1'),'legacy')
    $manifest=[pscustomobject]@{schemaVersion=1;files=@([pscustomobject]@{relativePath='local-ai-v4.ps1';sha256='x'})}
    $manifest|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $destination 'local-ai-v4.install.json')
    $plan=& (Join-Path $script:ProjectRoot 'Uninstall-LocalAI.ps1') -Destination $destination -WhatIf -PassThru
    Assert-Equal 0 @($plan.Removes|Where-Object RelativePath -eq 'local-ai.ps1').Count
}
