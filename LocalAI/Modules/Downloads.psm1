#requires -Version 5.1
Set-StrictMode -Version 2.0

function ConvertFrom-LocalAIHuggingFaceReference {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Reference)
    $uri=$null
    if(-not[uri]::TryCreate($Reference,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Host -ine 'huggingface.co'){
        throw 'Reference must be an https://huggingface.co URL.'
    }
    $segments=@($uri.AbsolutePath.Trim('/') -split '/')
    if($segments.Count -lt 5 -or $segments[2] -notin @('resolve','blob')){throw 'Hugging Face URL must identify a repository file through /resolve/ or /blob/.'}
    $repo=[uri]::UnescapeDataString($segments[0]+'/'+$segments[1]);$revision=[uri]::UnescapeDataString($segments[3]);$file=[uri]::UnescapeDataString(($segments[4..($segments.Count-1)]-join '/'))
    return New-LocalAIDownloadPlan -Repository $repo -FileName $file -Revision $revision
}

function New-LocalAIDownloadPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string]$FileName,[string]$Revision='main',[string]$Destination='')
    if($Repository -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}/[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$'){throw 'Invalid Hugging Face repository; expected owner/name.'}
    if($Revision -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$' -or $Revision -match '\.\.' ){throw 'Invalid Hugging Face revision.'}
    if($FileName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,239}\.gguf$' -or [IO.Path]::GetFileName($FileName) -cne $FileName){throw 'Invalid GGUF filename; paths and traversal are not accepted.'}
    $arguments=@('download',$Repository,$FileName,'--revision',$Revision)
    if($Destination){
        $full=[IO.Path]::GetFullPath($Destination);if($full.TrimEnd('\') -ieq [IO.Path]::GetPathRoot($full).TrimEnd('\')){throw 'Download destination cannot be a drive root.'}
        $Destination=$full;$arguments+=@('--local-dir',$full)
    }
    [pscustomobject]@{SchemaVersion=1;Repository=$Repository;FileName=$FileName;Revision=$Revision;Destination=$Destination;Executable='';Arguments=$arguments;Networked=$true}
}

function Invoke-LocalAIDownload {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan,[switch]$Confirm,[string]$LogPath='')
    if(-not$Confirm){throw "Download requires explicit confirmation: $($Plan.Repository) / $($Plan.FileName) @ $($Plan.Revision)"}
    $command=Get-Command hf.exe,hf,huggingface-cli -ErrorAction SilentlyContinue|Select-Object -First 1
    if(-not$command){throw 'Hugging Face CLI was not found. Install the official hf CLI first.'}
    if(-not$LogPath){$LogPath=Join-Path ([IO.Path]::GetTempPath()) ('local-ai-download-'+[guid]::NewGuid().ToString('N')+'.log')}
    $parent=Split-Path -Parent $LogPath;if(-not(Test-Path -LiteralPath $parent)){[void](New-Item -ItemType Directory -Path $parent -Force)}
    $args=($Plan.Arguments|ForEach-Object{ConvertTo-LocalAIWindowsArgument $_})-join ' '
    $p=Start-Process -FilePath $command.Source -ArgumentList $args -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $LogPath -RedirectStandardError ($LogPath+'.err')
    if($p.ExitCode -ne 0){throw "Hugging Face download failed with exit code $($p.ExitCode). See $LogPath.err"}
    [pscustomobject]@{Succeeded=$true;ExitCode=0;Repository=$Plan.Repository;FileName=$Plan.FileName;LogPath=$LogPath}
}

function New-LocalAIModelMovePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Model,[Parameter(Mandatory)][string]$DestinationRoot,[Parameter(Mandatory)][string[]]$AllowedRoots)
    if($Model.Status -ne 'Ready'){throw "Model is not ready and cannot be moved: $($Model.Error)"}
    if($Model.Kind -ne 'MainModel'){throw 'Only a complete main model group can be moved.'}
    $destination=[IO.Path]::GetFullPath($DestinationRoot)
    if($destination.TrimEnd('\') -ieq [IO.Path]::GetPathRoot($destination).TrimEnd('\')){throw 'Destination cannot be a drive root.'}
    $files=@()
    foreach($sourceValue in @($Model.Shards)){
        $null=Test-LocalAISafePath -Path $sourceValue -AllowedRoots $AllowedRoots -Operation Move
        if(-not(Test-Path -LiteralPath $sourceValue -PathType Leaf)){throw "Model file is missing: $sourceValue"}
        $target=Join-Path $destination ([IO.Path]::GetFileName($sourceValue))
        if(Test-Path -LiteralPath $target){throw "Destination already exists: $target"}
        $files+=[pscustomobject]@{Source=[IO.Path]::GetFullPath($sourceValue);Destination=$target;Bytes=(Get-Item -LiteralPath $sourceValue).Length}
    }
    [pscustomobject]@{SchemaVersion=1;ModelId=$Model.Id;DestinationRoot=$destination;Files=$files;TotalBytes=[long](($files|Measure-Object Bytes -Sum).Sum)}
}

function Move-LocalAIModelGroup {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan,[switch]$Confirm)
    if(-not$Confirm){throw "Move requires explicit confirmation: $($Plan.Files.Count) file(s) to $($Plan.DestinationRoot)"}
    if(-not(Test-Path -LiteralPath $Plan.DestinationRoot)){[void](New-Item -ItemType Directory -Path $Plan.DestinationRoot -Force)}
    $moved=New-Object Collections.Generic.List[object]
    try{
        foreach($file in $Plan.Files){Move-Item -LiteralPath $file.Source -Destination $file.Destination -ErrorAction Stop;$moved.Add($file)}
    }catch{
        foreach($file in @($moved|Sort-Object -Descending)){if(Test-Path -LiteralPath $file.Destination){Move-Item -LiteralPath $file.Destination -Destination $file.Source -Force -ErrorAction SilentlyContinue}}
        throw
    }
    return $moved.ToArray()
}

function Remove-LocalAIModelGroup {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Model,[Parameter(Mandatory)][string[]]$AllowedRoots,[switch]$Confirm,[switch]$Permanent)
    if(-not$Confirm){throw "Removal requires explicit confirmation for $(@($Model.Shards).Count) file(s)."}
    foreach($path in @($Model.Shards)){$null=Test-LocalAISafePath -Path $path -AllowedRoots $AllowedRoots -Operation Delete}
    if(-not$Permanent){
        try{Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop;foreach($path in @($Model.Shards)){[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path,'OnlyErrorDialogs','SendToRecycleBin')}}catch{throw "Recycle Bin removal failed. No permanent deletion was attempted: $($_.Exception.Message)"}
    }else{foreach($path in @($Model.Shards)){Remove-Item -LiteralPath $path -Force -ErrorAction Stop}}
    return $true
}

Export-ModuleMember -Function *
