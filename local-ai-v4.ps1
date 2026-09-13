#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Menu','Discover','ListModels','Models','Plan','Launch','Stop','Status','Doctor','Benchmark','Download','Harnesses','Backup','Rollback','Statistics','SelfTest')][string]$Command='Menu',
    [string]$InstallRoot='',
    [string]$StateRoot='',
    [string[]]$ModelRoot=@(),
    [switch]$NoDefaultModelRoots,
    [string]$Model='',
    [ValidateSet('List','Rescan','Move','Delete')][string]$ModelAction='List',
    [ValidateSet('Auto','CodingQuality','CodingFast','AgentLong','General','DeepReasoning','LongContext','Vision','Expert')][string]$Profile='Auto',
    [ValidateSet('','None','Server','pi','omp','opencode','codex','claude')][string]$Harness='',
    [ValidateSet('List','Install','PreviewConfig','Configure','Launch')][string]$HarnessAction='List',
    [string]$ProjectDir='',
    [ValidateRange(1,65535)][int]$Port=8080,
    [ValidateRange(0,1048576)][int]$Context=0,
    [ValidateSet('','q8_0','q4_0','f16')][string]$KV='',
    [string]$Repository='',
    [string]$FileName='',
    [string]$Revision='main',
    [string]$Destination='',
    [string]$Reference='',
    [string]$BackupId='',
    [switch]$Live,
    [switch]$Json,
    [switch]$DryRun,
    [switch]$NonInteractive,
    [switch]$Confirm,
    [switch]$Permanent
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if(-not $InstallRoot){$InstallRoot=$PSScriptRoot}
Import-Module (Join-Path $PSScriptRoot 'LocalAI\LocalAI.psd1') -Force -DisableNameChecking -ErrorAction Stop
$script:Paths=Get-LocalAIPaths -InstallRoot $InstallRoot -StateRoot $StateRoot
$script:ShippedRoot=Join-Path $PSScriptRoot 'LocalAI'

function Write-ControllerResult {
    param($Value)
    if($Json) { Write-Output (ConvertTo-Json -InputObject $Value -Depth 50); return }
    if($Value -is [string]) { Write-Host $Value; return }
    $Value | Format-List | Out-Host
}

function Get-ControllerSettings {
    $shipped=Read-LocalAIJson -Path (Join-Path $script:ShippedRoot 'Config\defaults.json')
    $user=Read-LocalAIJson -Path $script:Paths.Settings -Default ([pscustomobject]@{})
    return Merge-LocalAIObject -Base $shipped -Overlay $user
}

function Get-ControllerAdapters {
    return @(Get-LocalAIHarnessAdapters -ShippedRoot (Join-Path $script:ShippedRoot 'Adapters') -UserRoot $script:Paths.UserAdapters)
}

function Get-ControllerModels {
    param([switch]$Refresh)
    $settings=Get-ControllerSettings
    if($NoDefaultModelRoots) { $roots=@($ModelRoot) }
    else { $roots=@(Get-LocalAIModelRoots -InstallRoot $InstallRoot -Settings $settings)+@($ModelRoot) }
    $roots=@($roots | Where-Object { $_ } | Select-Object -Unique)
    $cachePath=if($DryRun){''}else{$script:Paths.Models}
    $models=@(Find-LocalAIModels -Roots $roots -CachePath $cachePath -Force:$Refresh)
    $overrides=(Read-LocalAIJson -Path (Join-Path $script:ShippedRoot 'Config\model-overrides.json')).overrides
    $machine=Get-LocalAIMachine -LlamaRoot $InstallRoot
    foreach($entry in $models) {
        $fingerprint=Get-LocalAIHash -Text (@($entry.ResolvedPath,$entry.LogicalBytes,$entry.Architecture,$entry.NativeContext,$entry.Quantization)-join '|')
        $entry | Add-Member NoteProperty Fingerprint $fingerprint -Force
        $entry | Add-Member NoteProperty Classification (Get-LocalAIModelClassification -Model $entry -Machine $machine -Overrides $overrides) -Force
    }
    return $models
}

function Get-ControllerRoots {
    $settings=Get-ControllerSettings
    if($NoDefaultModelRoots){return @($ModelRoot|Where-Object{$_}|Select-Object -Unique)}
    return @(@(Get-LocalAIModelRoots -InstallRoot $InstallRoot -Settings $settings)+@($ModelRoot)|Where-Object{$_}|Select-Object -Unique)
}

function Select-ControllerModel {
    param([object[]]$Models,[string]$Selection)
    $ready=@($Models | Where-Object { $_.Kind -eq 'MainModel' -and $_.Status -eq 'Ready' })
    if(-not $Selection) {
        if($ready.Count) { return $ready[0] }
        throw 'No ready main GGUF model was discovered.'
    }
    $selected=@($Models | Where-Object { $_.Id -ieq $Selection -or $_.Path -ieq $Selection -or $_.ResolvedPath -ieq $Selection -or $_.Name -ieq $Selection })
    if($selected.Count -ne 1) { throw "Model selection '$Selection' matched $($selected.Count) entries. Use an exact model ID." }
    return $selected[0]
}

function New-ControllerPlan {
    param([string]$Selection,[string]$Intent)
    $selected=Select-ControllerModel -Models @(Get-ControllerModels) -Selection $Selection
    $machine=Get-LocalAIMachine -LlamaRoot $InstallRoot
    $benchmarkOverrides=@{}
    if(Test-Path -LiteralPath $script:Paths.Benchmarks -PathType Leaf){
        $store=Read-LocalAIJson -Path $script:Paths.Benchmarks
        $record=@(Get-LocalAIApplicableBenchmark -Store $store -MachineFingerprint (Get-LocalAIMachineFingerprint $machine) -ModelFingerprint $selected.Fingerprint -Intent $Intent|Select-Object -First 1)
        if($record.Count -eq 1){$benchmarkOverrides=Get-LocalAIBenchmarkPlanOverrides -Winner $record[0].Winner}
    }
    $server=Join-Path $InstallRoot 'llama-server.exe'
    $capabilities=$null
    if(Test-Path -LiteralPath $server -PathType Leaf) {
        $capabilityCache=if($DryRun){''}else{Join-Path $script:Paths.Cache 'server-capabilities.json'}
        $capabilities=Get-LocalAIServerCapabilities -Executable $server -CachePath $capabilityCache
    }
    $explicit=@{}
    if($Context -gt 0) { $explicit.Context=$Context }
    if($KV) { $explicit.KV=$KV }
    $log=Join-Path $script:Paths.Logs ((Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+$selected.Id+'.log')
    return New-LocalAILaunchPlan -Model $selected -Machine $machine -Intent $Intent -BenchmarkOverrides $benchmarkOverrides -Overrides $explicit -ServerCapabilities $capabilities -Port $Port -LogPath $log
}

function Invoke-ControllerLaunch {
    $plan=New-ControllerPlan -Selection $Model -Intent $Profile
    if($DryRun) { return $plan }
    $selectedAdapter=$null
    if($Harness -and $Harness -notin @('None','Server')) {
        $selectedAdapter=Get-ControllerAdapters | Where-Object id -eq $Harness | Select-Object -First 1
        if(-not $selectedAdapter) { throw "Unknown harness '$Harness'." }
        $status=Get-LocalAIHarnessStatus $selectedAdapter
        if(-not $status.Installed) { throw "$($selectedAdapter.displayName) is not installed; install it before loading a model." }
    }
    $process=$null
    try {
        $process=Start-LocalAIServer -Plan $plan -Executable (Join-Path $InstallRoot 'llama-server.exe') -StatePath $script:Paths.Active
        $null=Wait-LocalAIServer -Plan $plan -Process $process -TimeoutSec ([int](Get-ControllerSettings).serverReadyTimeoutSeconds)
        $null=Confirm-LocalAIServedModel -Plan $plan
        $session=New-LocalAIBackupSession -BackupRoot $script:Paths.Backups -Operation ('launch-'+$plan.PlanId)
        $configs=[ordered]@{}
        foreach($adapter in Get-ControllerAdapters) {
            $status=Get-LocalAIHarnessStatus $adapter
            if(-not $status.Installed -and $adapter.id -ne $Harness) { continue }
            $configuration=Get-LocalAIHarnessConfiguration -Adapter $adapter -Plan $plan -StateRoot $script:Paths.StateRoot
            $configs[$adapter.id]=Set-LocalAIHarnessConfiguration -Adapter $adapter -Configuration $configuration -BackupSession $session
        }
        $ready=[pscustomobject]@{Ready=$true;Plan=$plan;ServerPid=$process.Id;BackupSession=$session.Path;Configurations=[pscustomobject]$configs}
        if($selectedAdapter) {
            $configuration=Get-LocalAIHarnessConfiguration -Adapter $selectedAdapter -Plan $plan -StateRoot $script:Paths.StateRoot
            $project=if($ProjectDir){$ProjectDir}else{(Get-Location).Path}
            Start-LocalAIHarness -Adapter $selectedAdapter -Configuration $configuration -ProjectDirectory $project
        }
        return $ready
    } catch {
        if($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Invoke-ControllerDoctor {
    $models=@(Get-ControllerModels)
    $machine=Get-LocalAIMachine -LlamaRoot $InstallRoot
    $active=if(Test-Path -LiteralPath $script:Paths.Active){Read-LocalAIJson -Path $script:Paths.Active}else{$null}
    $contextObject=[pscustomobject]@{InstallRoot=[IO.Path]::GetFullPath($InstallRoot);StateRoot=$script:Paths.StateRoot;Models=$models;Machine=$machine;Adapters=@(Get-ControllerAdapters);ServerCapabilities=$null;ActiveState=$active}
    return @(Invoke-LocalAIDoctor -Context $contextObject -Live:$Live)
}

function Invoke-ControllerCommand {
    param([string]$Name)
    switch($Name) {
        'Discover' { return @(Get-ControllerModels -Refresh) }
        'ListModels' { return @(Get-ControllerModels) }
        'Models' {
            if($ModelAction -eq 'List'){return @(Get-ControllerModels)}
            if($ModelAction -eq 'Rescan'){return @(Get-ControllerModels -Refresh)}
            $models=@(Get-ControllerModels);$selected=Select-ControllerModel -Models $models -Selection $Model;$roots=@(Get-ControllerRoots)
            if($ModelAction -eq 'Move'){
                if(-not$Destination){throw 'Models Move requires -Destination.'}
                $movePlan=New-LocalAIModelMovePlan -Model $selected -DestinationRoot $Destination -AllowedRoots $roots
                if($DryRun){return $movePlan}
                return @(Move-LocalAIModelGroup -Plan $movePlan -Confirm:$Confirm)
            }
            if($DryRun){return [pscustomobject]@{Action='Delete';ModelId=$selected.Id;Files=$selected.Shards;Permanent=[bool]$Permanent}}
            return [pscustomobject]@{Removed=Remove-LocalAIModelGroup -Model $selected -AllowedRoots $roots -Confirm:$Confirm -Permanent:$Permanent;ModelId=$selected.Id}
        }
        'Plan' { return New-ControllerPlan -Selection $Model -Intent $Profile }
        'Launch' { return Invoke-ControllerLaunch }
        'Stop' { return [pscustomobject]@{Stopped=Stop-LocalAIServer -StatePath $script:Paths.Active} }
        'Status' { if(Test-Path -LiteralPath $script:Paths.Active){return Read-LocalAIJson -Path $script:Paths.Active};return [pscustomobject]@{Status='Stopped/Unknown'} }
        'Harnesses' {
            $adapters=@(Get-ControllerAdapters)
            if($HarnessAction -eq 'List'){return @($adapters|ForEach-Object{Get-LocalAIHarnessStatus $_})}
            $adapter=$adapters|Where-Object id -eq $Harness|Select-Object -First 1
            if(-not$adapter){throw "Harness action '$HarnessAction' requires an exact -Harness id."}
            if($HarnessAction -eq 'Install'){if($DryRun){return $adapter.install};return Install-LocalAIHarness -Adapter $adapter -Confirm:$Confirm}
            $plan=New-ControllerPlan -Selection $Model -Intent $Profile
            $configuration=Get-LocalAIHarnessConfiguration -Adapter $adapter -Plan $plan -StateRoot $script:Paths.StateRoot
            if($HarnessAction -eq 'PreviewConfig'){return $configuration}
            if(-not$Confirm){throw "Harness $HarnessAction requires -Confirm."}
            if(-not(Test-Path -LiteralPath $script:Paths.Active)){throw 'Harness configuration requires a verified launcher-owned active server.'}
            $active=Read-LocalAIJson -Path $script:Paths.Active
            if($active.Alias -cne $plan.Alias){throw "Active server alias '$($active.Alias)' does not match plan alias '$($plan.Alias)'."}
            $null=Confirm-LocalAIServedModel -Plan $plan
            $session=New-LocalAIBackupSession -BackupRoot $script:Paths.Backups -Operation ('harness-'+$HarnessAction+'-'+$Harness)
            $applied=Set-LocalAIHarnessConfiguration -Adapter $adapter -Configuration $configuration -BackupSession $session
            if($HarnessAction -eq 'Launch'){$project=if($ProjectDir){$ProjectDir}else{(Get-Location).Path};Start-LocalAIHarness -Adapter $adapter -Configuration $configuration -ProjectDirectory $project}
            return $applied
        }
        'Statistics' {
            $active=if(Test-Path -LiteralPath $script:Paths.Active){Read-LocalAIJson -Path $script:Paths.Active}else{$null}
            $statisticsContext=[pscustomobject]@{ActiveState=$active}
            if($Live){
                if($Json){throw 'Live statistics is an interactive stream and cannot be combined with -Json.'}
                Write-Host 'Live statistics - press Ctrl+C to stop.' -ForegroundColor Cyan
                Watch-LocalAIStatistics -Context $statisticsContext -IntervalSeconds ([int](Get-ControllerSettings).refreshSeconds) -Writer {param($sample) Clear-Host;Write-Host 'LOCAL AI LIVE STATISTICS - press Ctrl+C to stop' -ForegroundColor Cyan;$sample|Format-List|Out-Host}
                return
            }
            return Get-LocalAIStatistics -Context $statisticsContext
        }
        'Doctor' { return Invoke-ControllerDoctor }
        'Download' {
            $plan=if($Reference){ConvertFrom-LocalAIHuggingFaceReference -Reference $Reference}else{New-LocalAIDownloadPlan -Repository $Repository -FileName $FileName -Revision $Revision -Destination $Destination}
            if($DryRun){return $plan}
            return Invoke-LocalAIDownload -Plan $plan -Confirm:$Confirm -LogPath (Join-Path $script:Paths.Logs ('download-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log'))
        }
        'Benchmark' {
            $plan=New-ControllerPlan -Selection $Model -Intent $Profile
            $candidates=@(New-LocalAIBenchmarkMatrix -BasePlan $plan -Intent $Profile)
            if($DryRun){return $candidates}
            if(-not $Confirm){throw 'Benchmarking loads the model repeatedly and requires -Confirm.'}
            $bench=Join-Path $InstallRoot 'llama-bench.exe'
            $results=@(Invoke-LocalAIBenchmark -Candidates $candidates -Runner { param($candidate) Invoke-LocalAILlamaBenchCandidate -Candidate $candidate -Executable $bench })
            $winner=Select-LocalAIBenchmarkWinner -Results $results -Intent $Profile
            $machine=Get-LocalAIMachine -LlamaRoot $InstallRoot
            $record=[pscustomobject]@{SchemaVersion=1;CreatedAt=(Get-Date).ToString('o');MachineFingerprint=Get-LocalAIMachineFingerprint $machine;ModelFingerprint=$plan.ModelFingerprint;Intent=$Profile;Winner=$winner;Results=$results}
            $null=Save-LocalAIBenchmarkRecord -Path $script:Paths.Benchmarks -Record $record
            return $record
        }
        'Backup' {
            if(-not(Test-Path -LiteralPath $script:Paths.Backups)){return @()}
            return @(Get-ChildItem -LiteralPath $script:Paths.Backups -Directory | Sort-Object Name -Descending | ForEach-Object { Read-LocalAIJson -Path (Join-Path $_.FullName 'manifest.json') })
        }
        'Rollback' {
            if($BackupId){$directory=Join-Path $script:Paths.Backups $BackupId}else{$latest=Get-ChildItem -LiteralPath $script:Paths.Backups -Directory | Sort-Object Name -Descending | Select-Object -First 1;$directory=if($latest){$latest.FullName}else{''}}
            if(-not $directory){throw 'No backup session is available.'}
            $manifest=Read-LocalAIJson -Path (Join-Path $directory 'manifest.json')
            if(-not $Confirm){return $manifest}
            foreach($record in @($manifest.records)){Restore-LocalAIBackup -Record $record | Out-Null}
            return [pscustomobject]@{Restored=$true;BackupId=$manifest.id}
        }
        'SelfTest' {
            $checks=0
            $null=Get-LocalAIHash -Text 'self-test';$checks++
            $policy=Get-LocalAIClientPolicy -Context 131072;if($policy.AutoCompactThreshold -ne 98304){throw 'Client policy invariant failed.'};$checks++
            $adapters=@(Get-ControllerAdapters);if($adapters.Count -ne 5){throw 'Shipped adapter count invariant failed.'};$checks++
            foreach($adapter in $adapters){$null=Test-LocalAIHarnessAdapter -Adapter $adapter;$checks++}
            return [pscustomobject]@{passed=$true;checks=$checks;powerShell=$PSVersionTable.PSVersion.ToString();version='4.0.1'}
        }
        default { throw "Unsupported command '$Name'." }
    }
}

function Invoke-ControllerMenu {
    while($true) {
        $machine=Get-LocalAIMachine -LlamaRoot $InstallRoot
        $models=@(Get-ControllerModels)
        $ready=@($models | Where-Object Status -eq 'Ready').Count
        $serverStatus=if(Test-Path -LiteralPath $script:Paths.Active){'Recorded'}else{'Stopped/Unknown'}
        Show-LocalAIHeader -Machine $machine -ReadyModels $ready -WarningModels ($models.Count-$ready) -ServerStatus $serverStatus
        $choice=Show-LocalAIMainMenu
        if($choice -eq 'Q'){return}
        switch($choice) {
            '1' { Show-LocalAIModelTable -Models $models;Write-Host '';Write-Host 'Launch from any terminal with:' -ForegroundColor Cyan;Write-Host '.\local-ai.cmd -Command Launch -Model <model-id> -Profile Auto -Harness Server' }
            '2' { Write-Host 'Choose a task profile, then use Launch Model:';Write-Host 'CodingQuality | CodingFast | AgentLong | General | DeepReasoning | LongContext | Vision' }
            '3' { Show-LocalAIModelTable -Models $models }
            '4' { Invoke-ControllerCommand -Name Harnesses | Format-Table -AutoSize | Out-Host }
            '5' { Write-Host '.\local-ai.cmd -Command Benchmark -Model <model-id> -Profile CodingFast -Confirm' }
            '6' { Invoke-ControllerCommand -Name Statistics | Format-List | Out-Host }
            '7' { Write-Host '.\local-ai.cmd -Command Download -Repository owner/repo -FileName model.gguf -Confirm' }
            '8' { Invoke-ControllerCommand -Name Status | Format-List | Out-Host }
            '9' { Show-LocalAIDoctorResults -Results @(Invoke-ControllerDoctor) }
            'S' { Get-ControllerSettings | ConvertTo-Json -Depth 20 | Write-Host }
        }
        [void](Read-Host 'Press Enter to continue')
    }
}

try {
    if($Command -eq 'Menu') {
        if($Json){throw 'Menu does not support -Json.'}
        Invoke-ControllerMenu
        exit 0
    }
    $result=Invoke-ControllerCommand -Name $Command
    Write-ControllerResult -Value $result
    exit 0
} catch {
    if($Json){Write-Output ([pscustomobject]@{error=$_.Exception.Message;command=$Command}|ConvertTo-Json -Compress)}
    else{[Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")}
    exit 1
}
