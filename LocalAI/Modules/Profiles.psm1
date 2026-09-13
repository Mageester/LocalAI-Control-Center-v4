#requires -Version 5.1
Set-StrictMode -Version 2.0

function Get-LocalAIProfileDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Intent)
    $path=Join-Path (Split-Path -Parent $PSScriptRoot) 'Config\profiles.json'
    $data=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $profile=@($data.profiles | Where-Object id -eq $Intent | Select-Object -First 1)
    if($profile.Count -ne 1){throw "Unknown profile intent '$Intent'."}
    return $profile[0]
}

function Get-LocalAIClientPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(512,1048576)][int64]$Context)
    $reserve=[int64][math]::Min(32768,[math]::Max(4096,[math]::Floor($Context/4)))
    [pscustomobject]@{
        ContextWindow=$Context
        MaxOutputTokens=[int64][math]::Min(16384,[math]::Max(2048,[math]::Floor($Context/8)))
        CompactionReserve=$reserve
        AutoCompactThreshold=$Context-$reserve
    }
}

function Get-LocalAIAlias {
    param($Model)
    $source=if($Model.Id){[string]$Model.Id}else{[string]$Model.Name}
    $alias=($source.ToLowerInvariant() -replace '[^a-z0-9._-]+','-').Trim('-')
    if(-not $alias){$alias='local-model'}
    return $alias
}

function Get-LocalAISafeProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Model,[Parameter(Mandatory)]$Machine,[Parameter(Mandatory)][string]$Intent)
    $definition=Get-LocalAIProfileDefinition -Intent $Intent
    if([long]$Model.NativeContext -lt 512){throw 'GGUF native context metadata is missing or below 512 tokens.'}
    $context=[long][math]::Min([long]$definition.contextTarget,[long]$Model.NativeContext)
    $kv=[string]$definition.kv;$ubatch=[int]$definition.ubatch;$fit=[int]$definition.fitTargetMiB
    $family=if([int]$Model.ExpertCount -gt 0){'moe'}else{'dense'}
    if([long]$Machine.VramBytes -gt 0 -and [long]$Model.LogicalBytes -gt ([long]$Machine.VramBytes-1GB)){
        if($Intent -eq 'Auto'){$context=[long][math]::Min($context,65536)}
        if($Intent -eq 'LongContext'){$kv='q4_0'}
        $ubatch=[math]::Min($ubatch,512)
    }
    $logical=[math]::Max(1,[int]$Machine.LogicalProcessors)
    [pscustomobject]@{
        Intent=$Intent;Context=$context;KV=$kv;Batch=[int]$definition.batch;UBatch=$ubatch;FitTargetMiB=$fit
        Threads=[math]::Max(1,[math]::Floor($logical/2));ThreadsBatch=$logical;Family=$family
        Temperature=if($family -eq 'moe'){0.6}else{0.7};TopP=0.95;TopK=20
    }
}

function Test-LocalAILaunchPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan,$ServerCapabilities=$null)
    if([long]$Plan.Context -lt 512){throw 'Context must be at least 512 tokens.'}
    if([long]$Plan.Context -gt [long]$Plan.NativeContext){throw "Requested context $($Plan.Context) exceeds GGUF native context $($Plan.NativeContext)."}
    $flags=@($Plan.Arguments | Where-Object {$_ -match '^--[a-zA-Z]'})
    if(@($flags|Select-Object -Unique).Count -ne $flags.Count){throw 'Launch plan contains duplicate server flags.'}
    if($ServerCapabilities -and $ServerCapabilities.PSObject.Properties['SupportedFlags']){
        $missing=@($flags | Where-Object {$ServerCapabilities.SupportedFlags -notcontains $_} | Select-Object -Unique)
        if($missing.Count){throw 'llama-server does not advertise required flag(s): '+($missing -join ', ')}
    }
    return $true
}

function New-LocalAILaunchPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)]$Machine,
        [Parameter(Mandatory)][ValidateSet('Auto','CodingQuality','CodingFast','AgentLong','General','DeepReasoning','LongContext','Vision','Expert')][string]$Intent,
        [hashtable]$Overrides=@{},
        $ServerCapabilities=$null,
        [ValidateRange(1,65535)][int]$Port=8080,
        [string]$LogPath=''
    )
    $templateFile=if($Overrides.ContainsKey('TemplateFile')){[string]$Overrides['TemplateFile']}else{''}
    $projector=if($Overrides.ContainsKey('Projector')){[string]$Overrides['Projector']}else{''}
    $visionMode=if($Overrides.ContainsKey('Vision')){[string]$Overrides['Vision']}else{'Gpu'}
    $draftPath=if($Overrides.ContainsKey('DraftPath')){[string]$Overrides['DraftPath']}else{''}
    $mtpRequested=($Overrides.ContainsKey('Mtp') -and [bool]$Overrides['Mtp'])
    if($Model.Status -and $Model.Status -ne 'Ready'){throw "Model is not ready: $($Model.Error)"}
    if($Model.Kind -and $Model.Kind -ne 'MainModel'){throw 'A projector or draft sidecar cannot be used as the main model.'}
    if(-not[bool]$Model.HasChatTemplate){
        if($Intent -ne 'Expert' -or -not $templateFile){throw 'A verified embedded chat template is required for agent profiles; use Expert with an explicit TemplateFile.'}
        if(-not(Test-Path -LiteralPath $templateFile -PathType Leaf)){throw "Template file does not exist: $templateFile"}
    }
    $safe=Get-LocalAISafeProfile -Model $Model -Machine $Machine -Intent $Intent
    $context=[long]$safe.Context;$kv=[string]$safe.KV;$batch=[int]$safe.Batch;$ubatch=[int]$safe.UBatch
    $fit=[int]$safe.FitTargetMiB;$threads=[int]$safe.Threads;$threadsBatch=[int]$safe.ThreadsBatch
    foreach($pair in @(@('Context','context'),@('KV','kv'),@('Batch','batch'),@('UBatch','ubatch'),@('FitTargetMiB','fit'),@('Threads','threads'),@('ThreadsBatch','threadsBatch'))){
        if($Overrides.ContainsKey($pair[0])){Set-Variable -Name $pair[1] -Value $Overrides[$pair[0]]}
    }
    if($context -gt [long]$Model.NativeContext){throw "Requested context $context exceeds GGUF native context $($Model.NativeContext)."}
    if($context -lt 512){throw 'Context must be at least 512 tokens.'}
    if($ubatch -gt $batch){throw 'Physical batch must not exceed logical batch.'}
    if($fit -lt 512){throw 'Fit target must preserve at least 512 MiB of headroom.'}
    $alias=Get-LocalAIAlias $Model
    $modelPath=if($Model.ResolvedPath){[string]$Model.ResolvedPath}else{[string]$Model.Path}
    if(-not $LogPath){$LogPath=Join-Path ([IO.Path]::GetTempPath()) ("local-ai-$alias.log")}
    $culture=[Globalization.CultureInfo]::InvariantCulture
    $args=@(
        '--model',$modelPath,'--alias',$alias,'--host','127.0.0.1','--port',[string]$Port,
        '--ctx-size',[string]$context,'--parallel','1','--gpu-layers','auto','--fit','on','--fit-target',[string]$fit,'--load-mode','none',
        '--flash-attn','on','--cache-type-k',$kv,'--cache-type-v',$kv,'--batch-size',[string]$batch,'--ubatch-size',[string]$ubatch,
        '--threads',[string]$threads,'--threads-batch',[string]$threadsBatch,'--cache-prompt','--cache-ram','2048',
        '--ctx-checkpoints','8','--checkpoint-min-step','8192','--jinja','--reasoning','on','--reasoning-budget','-1',
        '--temp',([double]$safe.Temperature).ToString($culture),'--top-p',([double]$safe.TopP).ToString($culture),'--top-k',[string]$safe.TopK,
        '--min-p','0','--repeat-penalty','1','--presence-penalty','0','--threads-http','4','--cors-origins','localhost','--verbosity','4','--log-file',$LogPath
    )
    if($Model.SupportsPreserveReasoning){$args+='--reasoning-preserve'}
    if($projector){
        $args+=@('--mmproj',$projector)
        if($visionMode -eq 'Cpu'){$args+='--no-mmproj-offload'}
    }else{$args+='--no-mmproj'}
    $mtp=$false
    if($mtpRequested){
        if([int]$Model.MtpHeads -lt 1 -and -not $draftPath){throw 'MTP requested but no embedded head or explicit draft model is available.'}
        if($draftPath){$args+=@('--model-draft',$draftPath)}
        $args+=@('--spec-type','draft-mtp','--spec-draft-n-max','1','--spec-draft-n-min','0','--gpu-layers-draft','all');$mtp=$true
    }else{$args+=@('--spec-type','none')}
    if($templateFile){$args+=@('--chat-template-file',$templateFile)}
    $client=Get-LocalAIClientPolicy -Context $context
    $plan=[pscustomobject]@{
        SchemaVersion=1;PlanId='plan-'+(Get-LocalAIHash (($args -join [char]31)+[char]31+$Intent)).Substring(0,16)
        CreatedAt=(Get-Date).ToString('o');ModelId=[string]$Model.Id;ModelFingerprint=if($Model.PSObject.Properties['Fingerprint']){$Model.Fingerprint}else{''}
        ModelPath=$modelPath;Shards=@($Model.Shards);Alias=$alias;Intent=$Intent;Context=$context;NativeContext=[long]$Model.NativeContext
        KV=$kv;Batch=$batch;UBatch=$ubatch;FitTargetMiB=$fit;Threads=$threads;ThreadsBatch=$threadsBatch;Mtp=$mtp
        Vision=if($projector){$visionMode}else{'Off'};HasChatTemplate=[bool]$Model.HasChatTemplate
        Port=$Port;ServerBaseUrl="http://127.0.0.1:$Port";OpenAIBaseUrl="http://127.0.0.1:$Port/v1";HealthUrl="http://127.0.0.1:$Port/health"
        LogPath=$LogPath;ClientPolicy=$client;Arguments=[string[]]$args
        Provenance=[pscustomobject]@{Context=if($Overrides.ContainsKey('Context')){'explicit'}else{'derived'};KV=if($Overrides.ContainsKey('KV')){'explicit'}else{'derived'};Intent=$Intent}
    }
    $null=Test-LocalAILaunchPlan -Plan $plan -ServerCapabilities $ServerCapabilities
    return $plan
}

Export-ModuleMember -Function *
