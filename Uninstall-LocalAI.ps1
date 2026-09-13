#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$Destination='C:\llamacpp',
    [switch]$KeepState=$true,
    [switch]$PassThru
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$destinationFull=[IO.Path]::GetFullPath($Destination)
if($destinationFull.TrimEnd('\') -ieq [IO.Path]::GetPathRoot($destinationFull).TrimEnd('\')){throw 'Uninstall destination cannot be a drive root.'}
$manifestPath=Join-Path $destinationFull 'local-ai-v4.install.json'
if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw "v4 installation manifest is missing: $manifestPath"}
$manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
$removes=@($manifest.files|ForEach-Object{[pscustomobject]@{RelativePath=[string]$_.relativePath;Path=Join-Path $destinationFull ([string]$_.relativePath);ExpectedSha256=[string]$_.sha256}})
$plan=[pscustomobject]@{SchemaVersion=1;Destination=$destinationFull;Removes=$removes;Preserves=@((Join-Path $destinationFull 'local-ai.ps1'),(Join-Path $destinationFull 'models'),(Join-Path $destinationFull 'logs'));KeepState=[bool]$KeepState}
if($WhatIfPreference){if($PassThru){return $plan};return}
if($PSCmdlet.ShouldProcess($destinationFull,'Remove manifest-owned Local AI Control Center v4 files')){
    $conflicts=@()
    foreach($entry in $removes){
        if(-not(Test-Path -LiteralPath $entry.Path -PathType Leaf)){continue}
        $actual=(Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256).Hash
        if($actual -ne $entry.ExpectedSha256){$conflicts+=$entry.Path;continue}
        Remove-Item -LiteralPath $entry.Path -Force
    }
    if($conflicts.Count){throw "Uninstall preserved modified v4 file(s): $($conflicts -join ', '). Remove them manually after review."}
    Remove-Item -LiteralPath $manifestPath -Force
    $moduleRoot=Join-Path $destinationFull 'LocalAI'
    if((Test-Path -LiteralPath $moduleRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $moduleRoot -Recurse -Force).Count -eq 0){Remove-Item -LiteralPath $moduleRoot -Force}
}
if($PassThru){return $plan}
Write-Host 'Local AI Control Center v4 files were removed. v3, models, logs, and user state were preserved.' -ForegroundColor Green
