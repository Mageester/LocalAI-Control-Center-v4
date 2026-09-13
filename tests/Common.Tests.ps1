Invoke-TestCase 'atomic JSON round trip preserves values' {
    Import-TestModule Common
    Import-TestModule Configuration
    $path=Join-Path $script:TestRoot 'state\settings.json'
    $null=Write-LocalAIJsonAtomic -Path $path -Value ([pscustomobject]@{schemaVersion=1;name='alpha'})
    $actual=Read-LocalAIJson -Path $path
    Assert-Equal 'alpha' $actual.name
}

Invoke-TestCase 'invalid JSON is quarantined before default is returned' {
    Import-TestModule Common
    Import-TestModule Configuration
    $path=Join-Path $script:TestRoot 'state\settings.json'
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
    [IO.File]::WriteAllText($path,'{broken',[Text.UTF8Encoding]::new($false))
    $actual=Read-LocalAIJson -Path $path -Default ([pscustomobject]@{schemaVersion=1;safe=$true})
    Assert-True $actual.safe
    Assert-Equal 1 @(Get-ChildItem (Split-Path -Parent $path) -Filter '*.corrupt-*').Count
}

Invoke-TestCase 'drive root is never a safe model target' {
    Import-TestModule Common
    Assert-Throws { Test-LocalAISafePath -Path 'C:\' -AllowedRoots @('C:\models') -Operation Delete } 'protected'
}

Invoke-TestCase 'path outside allowed roots is rejected' {
    Import-TestModule Common
    Assert-Throws { Test-LocalAISafePath -Path 'C:\Windows\notepad.exe' -AllowedRoots @('C:\models') -Operation Move } 'outside'
}

Invoke-TestCase 'overlay merge retains base values and replaces supplied fields' {
    Import-TestModule Common
    $actual=Merge-LocalAIObject -Base ([pscustomobject]@{a=1;b=2;nested=[pscustomobject]@{x=1;y=2}}) -Overlay ([pscustomobject]@{b=3;nested=[pscustomobject]@{y=4}})
    Assert-Equal 1 $actual.a
    Assert-Equal 3 $actual.b
    Assert-Equal 1 $actual.nested.x
    Assert-Equal 4 $actual.nested.y
}
