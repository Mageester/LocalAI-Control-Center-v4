#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$Destination='C:\llamacpp',
    [string]$SourceV3='',
    [switch]$PassThru
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$sourceRoot=$PSScriptRoot
$destinationFull=[IO.Path]::GetFullPath($Destination)
if($destinationFull.TrimEnd('\') -ieq [IO.Path]::GetPathRoot($destinationFull).TrimEnd('\')){throw 'Installation destination cannot be a drive root.'}
$legacyPath=Join-Path $destinationFull 'local-ai.ps1'
if(Test-Path -LiteralPath $legacyPath -PathType Leaf){
    # The installed launcher is authoritative: back up the exact file the user
    # currently relies on, even when a packaged reference was also supplied.
    $sourceV3Full=(Get-Item -LiteralPath $legacyPath).FullName
}elseif($SourceV3 -and (Test-Path -LiteralPath $SourceV3 -PathType Leaf)){
    $sourceV3Full=(Get-Item -LiteralPath $SourceV3).FullName
}else{
    $sourceV3Full=''
}
$writes=New-Object Collections.Generic.List[object]
$backups=New-Object Collections.Generic.List[object]
$topFiles=@('local-ai.cmd','local-ai-v4.ps1','Install-LocalAI.ps1','Uninstall-LocalAI.ps1','README.md','MIGRATION.md','CHANGELOG.md')
foreach($name in $topFiles){
    $source=Join-Path $sourceRoot $name
    if(Test-Path -LiteralPath $source -PathType Leaf){$writes.Add([pscustomobject]@{Source=$source;Destination=Join-Path $destinationFull $name;RelativePath=$name})}
}
foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'LocalAI') -Recurse -File)){
    $relative='LocalAI'+$file.FullName.Substring((Join-Path $sourceRoot 'LocalAI').Length)
    $writes.Add([pscustomobject]@{Source=$file.FullName;Destination=Join-Path $destinationFull $relative;RelativePath=$relative})
}
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
if($sourceV3Full){
    $backupPath=Join-Path $destinationFull ("local-ai-v3-backups\$stamp\local-ai.ps1")
    $backups.Add([pscustomobject]@{Source=$sourceV3Full;Destination=$backupPath;Sha256=(Get-FileHash -LiteralPath $sourceV3Full -Algorithm SHA256).Hash})
}
$plan=[pscustomobject]@{SchemaVersion=1;Destination=$destinationFull;Writes=$writes.ToArray();Backups=$backups.ToArray();PreservesLegacyPath=$legacyPath}
if($WhatIfPreference){if($PassThru){return $plan};return}
if(-not(Test-Path -LiteralPath (Join-Path $destinationFull 'llama-server.exe') -PathType Leaf)){throw "llama-server.exe was not found in '$destinationFull'. Use the llama.cpp installation directory."}
if($PSCmdlet.ShouldProcess($destinationFull,'Install Local AI Control Center v4 beside the preserved v3 launcher')){
    [void](New-Item -ItemType Directory -Path $destinationFull -Force)
    foreach($backup in $backups){[void](New-Item -ItemType Directory -Path (Split-Path -Parent $backup.Destination) -Force);Copy-Item -LiteralPath $backup.Source -Destination $backup.Destination -Force;if((Get-FileHash -LiteralPath $backup.Destination -Algorithm SHA256).Hash -ne $backup.Sha256){throw 'The v3 backup hash does not match its source.'}}
    $installed=New-Object Collections.Generic.List[object]
    foreach($write in $writes){[void](New-Item -ItemType Directory -Path (Split-Path -Parent $write.Destination) -Force);Copy-Item -LiteralPath $write.Source -Destination $write.Destination -Force;$installed.Add([pscustomobject]@{relativePath=$write.RelativePath;sha256=(Get-FileHash -LiteralPath $write.Destination -Algorithm SHA256).Hash})}
    $manifest=[pscustomobject]@{schemaVersion=1;installedAt=(Get-Date).ToString('o');sourceRoot=$sourceRoot;legacyV3Path=$legacyPath;legacyV3Sha256=if($sourceV3Full){(Get-FileHash -LiteralPath $sourceV3Full -Algorithm SHA256).Hash}else{''};files=$installed.ToArray()}
    $json=$manifest|ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText((Join-Path $destinationFull 'local-ai-v4.install.json'),$json,(New-Object Text.UTF8Encoding($false)))
}
if($PassThru){return $plan}
Write-Host "Local AI Control Center v4 installed to $destinationFull" -ForegroundColor Green
Write-Host "The legacy launcher remains at $(Join-Path $destinationFull 'local-ai.ps1')."
Write-Host "Start v4 with $(Join-Path $destinationFull 'local-ai.cmd')."
