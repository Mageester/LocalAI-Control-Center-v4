Set-StrictMode -Version 2.0
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('local-ai-v4-tests-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $script:TestRoot -Force)

function Assert-True {
    param($Condition, [string]$Message='Expected condition to be true.')
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message='')
    if ($Expected -is [array] -or $Actual -is [array]) {
        $expectedJson=$Expected | ConvertTo-Json -Depth 20 -Compress
        $actualJson=$Actual | ConvertTo-Json -Depth 20 -Compress
        if ($expectedJson -cne $actualJson) { throw "Expected $expectedJson but got $actualJson. $Message" }
        return
    }
    if ($Expected -cne $Actual) { throw "Expected '$Expected' but got '$Actual'. $Message" }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Like='')
    $caught=$null
    try { & $Action } catch { $caught=$_ }
    if ($null -eq $caught) { throw 'Expected an exception, but no exception was thrown.' }
    if ($Like -and $caught.Exception.Message -notlike "*$Like*") {
        throw "Expected exception containing '$Like', got '$($caught.Exception.Message)'."
    }
}

function Import-TestModule {
    param([string]$Name)
    Import-Module (Join-Path $script:ProjectRoot "LocalAI\Modules\$Name.psm1") -Force -DisableNameChecking -ErrorAction Stop
}

function Remove-TestRoot {
    if (Test-Path -LiteralPath $script:TestRoot) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
