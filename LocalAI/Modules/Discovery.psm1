#requires -Version 5.1
Set-StrictMode -Version 2.0

function Get-LocalAIModelRoots {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallRoot,$Settings=$null)
    $hub=if($env:HF_HUB_CACHE){$env:HF_HUB_CACHE}elseif($env:HF_HOME){Join-Path $env:HF_HOME 'hub'}else{Join-Path $env:USERPROFILE '.cache\huggingface\hub'}
    $roots=@($hub,(Join-Path $InstallRoot 'models'))
    if($Settings -and $Settings.PSObject.Properties['modelRoots']){$roots+=@($Settings.modelRoots)}
    return @($roots | Where-Object {$_} | ForEach-Object {[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$_))} | Select-Object -Unique)
}

function Resolve-LocalAIGgufPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $current=(Get-Item -LiteralPath $Path -Force).FullName
    for($i=0;$i -lt 8;$i++){
        $item=Get-Item -LiteralPath $current -Force
        $target=$null
        if($item.PSObject.Properties['Target']){$target=@($item.Target | Where-Object {$_} | Select-Object -First 1)}
        if(-not $target -and $item.Length -le 512){
            try{$candidate=(Get-Content -LiteralPath $current -Raw -ErrorAction Stop).Trim();if($candidate -match '^\.\.[\\/]\.\.[\\/]blobs[\\/]'){$target=$candidate}}catch{}
        }
        if(-not $target){return $current}
        $next=[string]$target
        if(-not[IO.Path]::IsPathRooted($next)){$next=Join-Path $item.DirectoryName $next}
        $current=[IO.Path]::GetFullPath($next)
        if(-not(Test-Path -LiteralPath $current -PathType Leaf)){throw "Broken GGUF link: $Path -> $current"}
    }
    throw "GGUF link resolution exceeded the safety limit: $Path"
}

function Get-LocalAIFileKind {
    param([string]$Name)
    if($Name -match '(?i)^(mmproj|projector)[-_.]'){return 'Projector'}
    if($Name -match '(?i)^(mtp|draft)[-_.]'){return 'MtpDraft'}
    return 'MainModel'
}

function New-LocalAIModelRecord {
    param([IO.FileInfo[]]$Files,[string]$Kind,[string]$Error='')
    $ordered=@($Files | Sort-Object Name)
    $path=$ordered[0].FullName;$resolved='';$summary=$null;$logical=[long]0
    try{
        foreach($file in $ordered){$actual=Resolve-LocalAIGgufPath $file.FullName;$logical+=(Get-Item -LiteralPath $actual).Length;if(-not $resolved){$resolved=$actual}}
        $summary=Get-LocalAIGgufSummary -Path $resolved
    }catch{if(-not $Error){$Error=$_.Exception.Message}}
    $name=if($summary){$summary.Name}else{[IO.Path]::GetFileNameWithoutExtension($path)}
    $arch=if($summary){$summary.Architecture}else{''}
    [pscustomobject]@{
        Id='model-'+(Get-LocalAIHash -Text $path).Substring(0,12);Kind=$Kind;Status=if($Error){'Invalid'}else{'Ready'};Error=$Error
        Name=$name;Path=$path;ResolvedPath=$resolved;Shards=@($ordered | ForEach-Object {$_.FullName});LogicalBytes=$logical
        Architecture=$arch;NativeContext=if($summary){$summary.NativeContext}else{[long]0};Quantization=if($summary){$summary.Quantization}else{'Unknown'}
        HasChatTemplate=if($summary){$summary.HasChatTemplate}else{$false};ChatTemplate=if($summary){$summary.ChatTemplate}else{''}
        MtpHeads=if($summary){$summary.MtpHeads}else{0};ExpertCount=if($summary){$summary.ExpertCount}else{0};ActiveExpertCount=if($summary){$summary.ActiveExpertCount}else{0}
        SupportsPreserveReasoning=if($summary){$summary.SupportsPreserveReasoning}else{$false}
    }
}

function Get-LocalAIModelRootSignature {
    param([Parameter(Mandatory)][string[]]$Roots)
    $evidence=New-Object Collections.Generic.List[string]
    foreach($root in @($Roots|Select-Object -Unique)){
        $full=[IO.Path]::GetFullPath($root);$evidence.Add($full)
        if(-not(Test-Path -LiteralPath $full -PathType Container)){$evidence.Add('<missing>');continue}
        $rootItem=Get-Item -LiteralPath $full -Force;$evidence.Add([string]$rootItem.LastWriteTimeUtc.Ticks)
        foreach($item in @(Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue|Sort-Object FullName)){
            $length=if($item.PSIsContainer){0}else{[long]$item.Length}
            $evidence.Add(('{0}|{1}|{2}|{3}' -f $item.Name,$item.PSIsContainer,$item.LastWriteTimeUtc.Ticks,$length))
            if($item.PSIsContainer){
                foreach($child in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue|Sort-Object FullName)){
                    $childLength=if($child.PSIsContainer){0}else{[long]$child.Length}
                    $evidence.Add(('{0}\{1}|{2}|{3}|{4}' -f $item.Name,$child.Name,$child.PSIsContainer,$child.LastWriteTimeUtc.Ticks,$childLength))
                }
            }
        }
    }
    return Get-LocalAIHash -Text ($evidence -join [char]31)
}

function Find-LocalAIModels {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Roots,[string]$CachePath='',[switch]$Force)
    $normalizedRoots=@($Roots|Where-Object{$_}|ForEach-Object{[IO.Path]::GetFullPath($_)}|Select-Object -Unique)
    $rootSignature=Get-LocalAIModelRootSignature -Roots $normalizedRoots
    if(-not$Force -and $CachePath -and (Test-Path -LiteralPath $CachePath -PathType Leaf)){
        try{
            $cached=Read-LocalAIJson -Path $CachePath
            $cachedRoots=@($cached.roots|ForEach-Object{[string]$_})
            if([int]$cached.schemaVersion -eq 2 -and [string]$cached.rootSignature -ceq $rootSignature -and (($cachedRoots -join [char]31) -ceq ($normalizedRoots -join [char]31))){return @($cached.models)}
        }catch{}
    }
    $files=New-Object Collections.Generic.List[IO.FileInfo]
    foreach($root in $normalizedRoots){
        if(-not(Test-Path -LiteralPath $root -PathType Container)){continue}
        try{
            foreach($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.gguf' -ErrorAction SilentlyContinue)){
                if($file.Name -match '(?i)\.(incomplete|partial|tmp)\.gguf$'){continue}
                $files.Add($file)
            }
        }catch{}
    }
    $records=New-Object Collections.Generic.List[object]
    $consumed=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($file in @($files | Sort-Object FullName)){
        if($consumed.Contains($file.FullName)){continue}
        $kind=Get-LocalAIFileKind $file.Name
        if($file.Name -match '^(.*)-(\d{5})-of-(\d{5})\.gguf$'){
            $stem=$Matches[1];$count=[int]$Matches[3]
            $group=@();$missing=@()
            for($i=1;$i -le $count;$i++){
                $candidate=Join-Path $file.DirectoryName ('{0}-{1:D5}-of-{2:D5}.gguf' -f $stem,$i,$count)
                if(Test-Path -LiteralPath $candidate -PathType Leaf){$item=Get-Item -LiteralPath $candidate;$group+=$item;[void]$consumed.Add($item.FullName)}else{$missing+=[IO.Path]::GetFileName($candidate)}
            }
            $error=if($missing.Count){'Missing shard(s): '+($missing -join ', ')}else{''}
            $records.Add((New-LocalAIModelRecord -Files $group -Kind $kind -Error $error))
        }else{
            [void]$consumed.Add($file.FullName)
            $records.Add((New-LocalAIModelRecord -Files @($file) -Kind $kind))
        }
    }
    if($CachePath){
        $cache=[pscustomobject]@{schemaVersion=2;updatedAt=(Get-Date).ToString('o');roots=$normalizedRoots;rootSignature=$rootSignature;models=$records.ToArray()}
        $null=Write-LocalAIJsonAtomic -Path $CachePath -Value $cache
    }
    return $records.ToArray()
}

function Get-LocalAIModelClassification {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Model,[Parameter(Mandatory)]$Machine,[object[]]$Overrides=@())
    $family=if([int]$Model.ExpertCount -gt 0){[pscustomobject]@{Value='moe';Source='metadata';Confidence='high'}}else{[pscustomobject]@{Value='dense';Source='metadata';Confidence='medium'}}
    $roles=New-Object Collections.Generic.List[string]
    if(([string]$Model.Name) -match '(?i)coder|code'){$roles.Add('Coding')}
    if([bool]$Model.HasChatTemplate){$roles.Add('General')}
    if([int]$Model.MtpHeads -gt 0){$roles.Add('Speculative')}
    $fit=if([long]$Machine.VramBytes -le 0){'CPU/Unknown'}elseif([long]$Model.LogicalBytes -lt ([long]$Machine.VramBytes-1GB)){'Excellent'}elseif([long]$Model.LogicalBytes -lt ([long]$Machine.VramBytes+[long]$Machine.RamBytes-6GB)){'Hybrid'}else{'Insufficient'}
    foreach($override in $Overrides){
        if($override.match.architecture -and $override.match.architecture -ne $Model.Architecture){continue}
        if($override.values.family){$family=[pscustomobject]@{Value=[string]$override.values.family;Source='override';Confidence='high'}}
        foreach($role in @($override.values.roles)){if($role -and -not $roles.Contains([string]$role)){$roles.Add([string]$role)}}
    }
    [pscustomobject]@{Family=$family;Roles=@($roles);Fit=[pscustomobject]@{Value=$fit;Source='estimate';Confidence='low'};NativeContext=[long]$Model.NativeContext;Quantization=[string]$Model.Quantization}
}

Export-ModuleMember -Function *
