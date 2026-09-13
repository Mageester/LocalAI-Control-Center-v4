#requires -Version 5.1
[CmdletBinding()]
param([string]$Pattern='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$script:Passed=0
$script:Failed=0
$script:Failures=New-Object Collections.Generic.List[string]

function Invoke-TestCase {
    param([string]$Name,[scriptblock]$Test)
    try {
        & $Test
        $script:Passed++
        Write-Host "PASS $Name" -ForegroundColor Green
    } catch {
        $script:Failed++
        $detail="$Name`: $($_.Exception.Message)"
        $script:Failures.Add($detail)
        Write-Host "FAIL $detail" -ForegroundColor Red
    }
}

try {
    $files=@(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.Tests.ps1' | Sort-Object Name)
    if($Pattern){ $files=@($files | Where-Object BaseName -match $Pattern) }
    if($files.Count -eq 0){ throw "No test files matched '$Pattern'." }
    foreach($file in $files){ . $file.FullName }
} finally {
    Remove-TestRoot
}

Write-Host "`nRESULT: $script:Passed passed, $script:Failed failed"
if($script:Failed -gt 0){ $script:Failures | ForEach-Object { Write-Host " - $_" }; exit 1 }
exit 0
