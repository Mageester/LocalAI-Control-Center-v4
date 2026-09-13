#requires -Version 5.1
Set-StrictMode -Version 2.0
$script:ManagedBegin='  # BEGIN LOCAL-AI-CONTROL-V4'
$script:ManagedEnd='  # END LOCAL-AI-CONTROL-V4'

function Set-LocalAIObjectProperty {
    param([Parameter(Mandatory)]$Object,[Parameter(Mandatory)][string]$Name,$Value)
    $property=$Object.PSObject.Properties[$Name]
    if($property){$property.Value=$Value}else{$Object.PSObject.Properties.Add((New-Object Management.Automation.PSNoteProperty($Name,$Value)))}
}

function Test-LocalAIHarnessAdapter {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Adapter)
    foreach($name in @('schemaVersion','id','displayName','executableCandidates','configurationStrategy','install')){
        if(-not$Adapter.PSObject.Properties[$name]){throw "Adapter is missing required field '$name'."}
    }
    if([string]$Adapter.id -notmatch '^[a-z][a-z0-9-]{0,31}$'){throw 'Adapter id is invalid.'}
    if(@('PiJson','OmpYaml','OpenCodeJson','CodexToml','Environment') -notcontains [string]$Adapter.configurationStrategy){throw 'Adapter configuration strategy is invalid.'}
    if($Adapter.install.mode -eq 'command'){
        if([string]$Adapter.install.executable -notmatch '^[a-zA-Z0-9_.-]+$'){throw 'Install executable is invalid.'}
        foreach($argument in @($Adapter.install.arguments)){
            if([string]$argument -match '[;&|`\r\n]'){throw "Install argument contains a forbidden shell metacharacter: $argument"}
        }
    }
    return $true
}

function Get-LocalAIHarnessAdapters {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ShippedRoot,[string]$UserRoot='')
    $files=@()
    if(Test-Path -LiteralPath $ShippedRoot){$files+=@(Get-ChildItem -LiteralPath $ShippedRoot -File -Filter '*.json'|Where-Object Name -notlike '*.example.json')}
    if($UserRoot -and (Test-Path -LiteralPath $UserRoot)){$files+=@(Get-ChildItem -LiteralPath $UserRoot -File -Filter '*.json')}
    $byId=[ordered]@{}
    foreach($file in $files){$adapter=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json;$null=Test-LocalAIHarnessAdapter $adapter;$byId[[string]$adapter.id]=$adapter}
    return @($byId.Values)
}

function Get-LocalAIHarnessStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Adapter)
    $command=$null
    foreach($name in @($Adapter.executableCandidates)){$candidate=Get-Command $name -ErrorAction SilentlyContinue|Select-Object -First 1;if($candidate){$command=$candidate;break}}
    [pscustomobject]@{Id=$Adapter.id;DisplayName=$Adapter.displayName;Installed=[bool]$command;Command=if($command){$command.Source}else{''};InstallMode=$Adapter.install.mode;GuidanceUrl=$Adapter.install.guidanceUrl}
}

function New-LocalAIBackupSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupRoot,[Parameter(Mandatory)][string]$Operation)
    $id=(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $path=Join-Path $BackupRoot $id
    [void](New-Item -ItemType Directory -Path $path -Force)
    $session=[pscustomobject]@{SchemaVersion=1;Id=$id;Operation=$Operation;Path=$path;CreatedAt=(Get-Date).ToString('o');Records=(New-Object Collections.Generic.List[object])}
    $null=Write-LocalAIJsonAtomic -Path (Join-Path $path 'manifest.json') -Value ([pscustomobject]@{schemaVersion=1;id=$id;operation=$Operation;createdAt=$session.CreatedAt;records=@()})
    return $session
}

function Save-LocalAIBackupManifest {
    param($Session)
    $records=@($Session.Records|ForEach-Object{$_})
    $value=[pscustomobject]@{schemaVersion=1;id=$Session.Id;operation=$Session.Operation;createdAt=$Session.CreatedAt;records=$records}
    $null=Write-LocalAIJsonAtomic -Path (Join-Path $Session.Path 'manifest.json') -Value $value
}

function Backup-LocalAIFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path);$exists=Test-Path -LiteralPath $full -PathType Leaf
    $backup=Join-Path $Session.Path (([IO.Path]::GetFileName($full))+'.'+$Session.Records.Count+'.bak')
    $hash=''
    if($exists){Copy-Item -LiteralPath $full -Destination $backup -Force;$hash=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash}
    $record=[pscustomobject]@{OriginalPath=$full;BackupPath=if($exists){$backup}else{''};OriginalExisted=$exists;PreHash=$hash;PostHash=''}
    $Session.Records.Add($record);Save-LocalAIBackupManifest $Session
    return $record
}

function Restore-LocalAIBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record,[switch]$Force)
    if(Test-Path -LiteralPath $Record.OriginalPath -PathType Leaf){
        $current=(Get-FileHash -LiteralPath $Record.OriginalPath -Algorithm SHA256).Hash
        if($Record.PostHash -and $current -ne $Record.PostHash -and -not$Force){throw "File changed since the managed edit: $($Record.OriginalPath)"}
    }
    if($Record.OriginalExisted){
        if(-not(Test-Path -LiteralPath $Record.BackupPath -PathType Leaf)){throw "Backup is missing: $($Record.BackupPath)"}
        Copy-Item -LiteralPath $Record.BackupPath -Destination $Record.OriginalPath -Force
    }elseif(Test-Path -LiteralPath $Record.OriginalPath){Remove-Item -LiteralPath $Record.OriginalPath -Force}
    return $true
}

function Get-LocalAIHarnessConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Adapter,[Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][string]$StateRoot)
    $null=Test-LocalAIHarnessAdapter $Adapter
    $provider=[pscustomobject]@{baseUrl=$Plan.OpenAIBaseUrl;api='openai-completions';apiKey='local';compat=[pscustomobject]@{supportsDeveloperRole=$false;supportsReasoningEffort=$false;maxTokensField='max_tokens'};models=@([pscustomobject]@{id=$Plan.Alias;name="$($Plan.Alias) (llama.cpp local)";reasoning=$true;input=@('text');contextWindow=[int]$Plan.Context;maxTokens=[int]$Plan.ClientPolicy.MaxOutputTokens;cost=[pscustomobject]@{input=0;output=0;cacheRead=0;cacheWrite=0}})}
    switch([string]$Adapter.configurationStrategy){
        'PiJson'{return [pscustomobject]@{Strategy='PiJson';Path=Join-Path $env:USERPROFILE '.pi\agent\models.json';SettingsPath=Join-Path $env:USERPROFILE '.pi\agent\settings.json';Provider=$provider;Alias=$Plan.Alias;Context=[int]$Plan.Context;ClientPolicy=$Plan.ClientPolicy}}
        'OmpYaml'{
            $dir=if($env:PI_CODING_AGENT_DIR){$env:PI_CODING_AGENT_DIR}else{Join-Path $env:USERPROFILE '.omp\agent'}
            $lines=@($script:ManagedBegin,'  local-llama:',"    baseUrl: $($Plan.OpenAIBaseUrl)",'    auth: none','    api: openai-completions','    models:',"      - id: $($Plan.Alias)","        name: '$($Plan.Alias) (llama.cpp local)'",'        reasoning: true','        input: [text]',"        contextWindow: $($Plan.Context)","        maxTokens: $($Plan.ClientPolicy.MaxOutputTokens)",$script:ManagedEnd)
            return [pscustomobject]@{Strategy='OmpYaml';Path=Join-Path $dir 'models.yml';Content=($lines -join "`r`n");Alias=$Plan.Alias;Context=[int]$Plan.Context}
        }
        'OpenCodeJson'{
            $model=[ordered]@{};$model[[string]$Plan.Alias]=[pscustomobject]@{name="$($Plan.Alias) (llama.cpp local)";limit=[pscustomobject]@{context=[int]$Plan.Context;output=[int]$Plan.ClientPolicy.MaxOutputTokens}}
            $content=[pscustomobject]@{'$schema'='https://opencode.ai/config.json';model="local-llama/$($Plan.Alias)";provider=[pscustomobject]@{'local-llama'=[pscustomobject]@{npm='@ai-sdk/openai-compatible';name='llama.cpp Local';options=[pscustomobject]@{baseURL=$Plan.OpenAIBaseUrl};models=[pscustomobject]$model}}}
            return [pscustomobject]@{Strategy='OpenCodeJson';Path=Join-Path $StateRoot 'opencode.local.json';Content=$content;Alias=$Plan.Alias;Context=[int]$Plan.Context}
        }
        'CodexToml'{
            $alias=([string]$Plan.Alias).Replace('\','\\').Replace('"','\"');$base=([string]$Plan.OpenAIBaseUrl).Replace('\','\\').Replace('"','\"')
            $content=@("model = `"$alias`"",'model_provider = "local_llama"',"model_context_window = $($Plan.Context)","model_auto_compact_token_limit = $($Plan.ClientPolicy.AutoCompactThreshold)",'','[model_providers.local_llama]','name = "llama.cpp Local"',"base_url = `"$base`"",'wire_api = "responses"','requires_openai_auth = false','')-join "`r`n"
            return [pscustomobject]@{Strategy='CodexToml';Path=Join-Path $StateRoot 'codex.local.toml';Content=$content;Alias=$Plan.Alias;Context=[int]$Plan.Context}
        }
        'Environment'{
            $envMap=[ordered]@{ANTHROPIC_BASE_URL=$Plan.ServerBaseUrl;ANTHROPIC_AUTH_TOKEN='local';ANTHROPIC_MODEL=$Plan.Alias;ANTHROPIC_DEFAULT_OPUS_MODEL=$Plan.Alias;ANTHROPIC_DEFAULT_SONNET_MODEL=$Plan.Alias;ANTHROPIC_DEFAULT_HAIKU_MODEL=$Plan.Alias;CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1';DISABLE_PROMPT_CACHING='1';LOCAL_AI_CONTEXT_WINDOW=[string]$Plan.Context}
            return [pscustomobject]@{Strategy='Environment';Environment=[pscustomobject]$envMap;Alias=$Plan.Alias;Context=[int]$Plan.Context}
        }
    }
}

function Set-LocalAIHarnessConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Adapter,[Parameter(Mandatory)]$Configuration,[Parameter(Mandatory)]$BackupSession)
    if($Configuration.Strategy -eq 'Environment'){return [pscustomobject]@{Strategy='Environment';Changed=$false;Environment=$Configuration.Environment}}
    $record=Backup-LocalAIFile -Session $BackupSession -Path $Configuration.Path
    switch($Configuration.Strategy){
        'PiJson'{
            $root=Read-LocalAIJson -Path $Configuration.Path -Default ([pscustomobject]@{})
            if(-not$root.PSObject.Properties['providers']){Set-LocalAIObjectProperty $root 'providers' ([pscustomobject]@{})}
            Set-LocalAIObjectProperty $root.providers 'local-llama' $Configuration.Provider
            $null=Write-LocalAIJsonAtomic -Path $Configuration.Path -Value $root
            $settingsRecord=Backup-LocalAIFile -Session $BackupSession -Path $Configuration.SettingsPath
            $settings=Read-LocalAIJson -Path $Configuration.SettingsPath -Default ([pscustomobject]@{})
            Set-LocalAIObjectProperty $settings 'defaultProvider' 'local-llama';Set-LocalAIObjectProperty $settings 'defaultModel' $Configuration.Alias
            Set-LocalAIObjectProperty $settings 'localAIContextWindow' $Configuration.Context
            $null=Write-LocalAIJsonAtomic -Path $Configuration.SettingsPath -Value $settings
            $settingsRecord.PostHash=(Get-FileHash -LiteralPath $Configuration.SettingsPath -Algorithm SHA256).Hash
        }
        'OmpYaml'{
            if(Test-Path -LiteralPath $Configuration.Path){$text=Get-Content -LiteralPath $Configuration.Path -Raw;$text=[regex]::Replace($text,'(?ms)^  # BEGIN LOCAL-AI-CONTROL-V4\r?\n.*?^  # END LOCAL-AI-CONTROL-V4\r?\n?','');if($text -notmatch '(?m)^providers:\s*$'){throw "OMP config has no root providers key: $($Configuration.Path)"};$text=[regex]::Replace($text,'(?m)^providers:\s*$',{"providers:`r`n$($Configuration.Content)"},1)}else{$text="providers:`r`n$($Configuration.Content)`r`n"}
            $null=Write-LocalAITextAtomic -Path $Configuration.Path -Content $text
        }
        'OpenCodeJson'{$null=Write-LocalAIJsonAtomic -Path $Configuration.Path -Value $Configuration.Content}
        'CodexToml'{$null=Write-LocalAITextAtomic -Path $Configuration.Path -Content $Configuration.Content}
    }
    $record.PostHash=(Get-FileHash -LiteralPath $Configuration.Path -Algorithm SHA256).Hash;Save-LocalAIBackupManifest $BackupSession
    return [pscustomobject]@{Strategy=$Configuration.Strategy;Changed=$true;Path=$Configuration.Path;Backup=$record}
}

function Install-LocalAIHarness {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Adapter,[switch]$Confirm)
    $null=Test-LocalAIHarnessAdapter $Adapter
    if(-not$Confirm){throw "Installation requires explicit confirmation. Source: $($Adapter.install.guidanceUrl)"}
    if($Adapter.install.mode -ne 'command'){throw "Automated installation is unavailable. Follow: $($Adapter.install.guidanceUrl)"}
    $command=Get-Command $Adapter.install.executable -ErrorAction SilentlyContinue|Select-Object -First 1
    if(-not$command){throw "Required installer '$($Adapter.install.executable)' was not found."}
    $p=Start-Process -FilePath $command.Source -ArgumentList (($Adapter.install.arguments|ForEach-Object{ConvertTo-LocalAIWindowsArgument $_})-join ' ') -Wait -PassThru -WindowStyle Hidden
    if($p.ExitCode -ne 0){throw "Harness installation failed with exit code $($p.ExitCode)."}
    $status=Get-LocalAIHarnessStatus $Adapter;if(-not$status.Installed){throw 'Installer exited successfully but the harness command was not found.'};return $status
}

function Start-LocalAIHarness {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Adapter,[Parameter(Mandatory)]$Configuration,[Parameter(Mandatory)][string]$ProjectDirectory)
    if(-not(Test-Path -LiteralPath $ProjectDirectory -PathType Container)){throw "Project directory does not exist: $ProjectDirectory"}
    $status=Get-LocalAIHarnessStatus $Adapter;if(-not$status.Installed){throw "$($Adapter.displayName) is not installed."}
    $args=@();switch($Adapter.id){'pi'{$args=@('--provider','local-llama','--model',$Configuration.Alias)}'omp'{$args=@('--provider','local-llama','--model',$Configuration.Alias)}'opencode'{$args=@('--config',$Configuration.Path,'--model',"local-llama/$($Configuration.Alias)")}'codex'{$args=@('-c',"model=$($Configuration.Alias)",'-c','model_provider=local_llama','-c',"model_context_window=$($Configuration.Context)")}'claude'{$args=@('--model',$Configuration.Alias)}}
    $old=@{};if($Configuration.PSObject.Properties['Environment']){foreach($property in $Configuration.Environment.PSObject.Properties){$old[$property.Name]=[Environment]::GetEnvironmentVariable($property.Name,'Process');[Environment]::SetEnvironmentVariable($property.Name,[string]$property.Value,'Process')}}
    Push-Location $ProjectDirectory
    try{& $status.Command @args}finally{Pop-Location;foreach($key in $old.Keys){[Environment]::SetEnvironmentVariable($key,$old[$key],'Process')}}
}

Export-ModuleMember -Function *
