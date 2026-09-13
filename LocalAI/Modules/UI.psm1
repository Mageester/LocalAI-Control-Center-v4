#requires -Version 5.1
Set-StrictMode -Version 2.0

function Read-LocalAIChoice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Allowed,
        [scriptblock]$ReadInput={ Read-Host 'Select' },
        [scriptblock]$WriteOutput={ param($Text) Write-Host $Text -ForegroundColor Yellow }
    )
    while($true) {
        $value=[string](& $ReadInput)
        $value=$value.Trim()
        $match=@($Allowed | Where-Object { $_ -ieq $value } | Select-Object -First 1)
        if($match.Count) { return [string]$match[0] }
        & $WriteOutput ('Choose one of: '+($Allowed -join ', '))
    }
}

function Get-LocalAIPlanText {
    param([Parameter(Mandatory)]$Plan)
    $culture=[Globalization.CultureInfo]::GetCultureInfo('en-US')
    $arguments=$Plan.Arguments | ForEach-Object { ConvertTo-LocalAIWindowsArgument ([string]$_) }
    return @(
        '============================================================',
        (' {0} | {1}' -f $Plan.Alias,$Plan.Intent),
        '============================================================',
        ('Model:        {0}' -f $Plan.ModelPath),
        ('Context:      {0} (native: {1})' -f ([long]$Plan.Context).ToString('N0',$culture),([long]$Plan.NativeContext).ToString('N0',$culture)),
        ('KV / batch:   {0} | {1} / {2}' -f $Plan.KV,$Plan.Batch,$Plan.UBatch),
        ('Threads:      {0} generation / {1} prompt' -f $Plan.Threads,$Plan.ThreadsBatch),
        ('MTP / vision: {0} / {1}' -f $Plan.Mtp,$Plan.Vision),
        ('Endpoint:     {0}' -f $Plan.ServerBaseUrl),
        '',
        'Exact command:',
        ('llama-server.exe '+($arguments -join ' '))
    ) -join [Environment]::NewLine
}

function Show-LocalAIPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan,[switch]$PassThru)
    $text=Get-LocalAIPlanText $Plan
    if($PassThru) { return $text }
    Write-Host $text -ForegroundColor Cyan
}

function Show-LocalAIHeader {
    [CmdletBinding()]
    param($Machine,[int]$ReadyModels=0,[int]$WarningModels=0,[string]$ServerStatus='Stopped/Unknown')
    Clear-Host
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host '                 LOCAL AI CONTROL CENTER v4' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor DarkCyan
    $gpu=if($Machine.GpuName){$Machine.GpuName}else{'CPU / GPU unknown'}
    $ram=[math]::Round([double]$Machine.RamBytes/1GB,1)
    Write-Host ('{0} | {1} | {2} GiB RAM | llama.cpp b{3}' -f $gpu,$Machine.Cpu,$ram,$Machine.LlamaBuild)
    Write-Host ('Models: {0} ready / {1} warning | Server: {2}' -f $ReadyModels,$WarningModels,$ServerStatus) -ForegroundColor DarkGray
}

function Show-LocalAIMainMenu {
    [CmdletBinding()]
    param()
    Write-Host ''
    Write-Host ' [1] Launch Model'
    Write-Host ' [2] Smart Task Launcher'
    Write-Host ' [3] Models'
    Write-Host ' [4] Coding Harnesses'
    Write-Host ' [5] Benchmark / Auto-Tune'
    Write-Host ' [6] Performance & Statistics'
    Write-Host ' [7] Download Models'
    Write-Host ' [8] Server Manager'
    Write-Host ' [9] Doctor / Diagnostics'
    Write-Host ' [S] Settings'
    Write-Host ' [Q] Quit'
    return Read-LocalAIChoice -Allowed @('1','2','3','4','5','6','7','8','9','S','Q') -ReadInput { Read-Host 'Select' }
}

function Show-LocalAIModelTable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Models)
    if($Models.Count -eq 0) { Write-Host 'No GGUF files were discovered.' -ForegroundColor Yellow; return }
    $Models | Select-Object Id,Status,Kind,Name,Architecture,@{N='Context';E={$_.NativeContext}},@{N='GiB';E={[math]::Round($_.LogicalBytes/1GB,2)}},Quantization | Format-Table -AutoSize -Wrap
}

function Select-LocalAIModelInteractive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Models,
        [scriptblock]$ReadInput={Read-Host 'Select model'},
        [scriptblock]$WriteOutput={param($Text) Write-Host $Text}
    )
    $choices=@($Models|Where-Object{$_.Kind -eq 'MainModel' -and $_.Status -eq 'Ready'})
    if($choices.Count -eq 0){& $WriteOutput 'No ready main GGUF model is available.';return $null}
    & $WriteOutput '';& $WriteOutput 'READY MODELS'
    for($i=0;$i -lt $choices.Count;$i++){
        $model=$choices[$i];$gib=[math]::Round([double]$model.LogicalBytes/1GB,2);$architecture=if($model.PSObject.Properties['Architecture']){$model.Architecture}else{'unknown'}
        & $WriteOutput (' [{0}] {1} | {2} | {3:N0} ctx | {4} GiB' -f ($i+1),$model.Name,$architecture,[long]$model.NativeContext,$gib)
    }
    & $WriteOutput ' [B] Back'
    $allowed=@(1..$choices.Count|ForEach-Object{[string]$_})+@('B')
    $selection=Read-LocalAIChoice -Allowed $allowed -ReadInput $ReadInput -WriteOutput $WriteOutput
    if($selection -eq 'B'){return $null}
    return $choices[[int]$selection-1]
}

function Select-LocalAIProfileInteractive {
    [CmdletBinding()]
    param(
        [scriptblock]$ReadInput={Read-Host 'Select profile'},
        [scriptblock]$WriteOutput={param($Text) Write-Host $Text}
    )
    $profiles=@(
        [pscustomobject]@{Id='Auto';Label='Automatic safe default'},
        [pscustomobject]@{Id='CodingQuality';Label='Coding - maximum quality'},
        [pscustomobject]@{Id='CodingFast';Label='Coding - fast'},
        [pscustomobject]@{Id='AgentLong';Label='Agentic long-running work'},
        [pscustomobject]@{Id='General';Label='General assistant'},
        [pscustomobject]@{Id='DeepReasoning';Label='Deep reasoning'},
        [pscustomobject]@{Id='LongContext';Label='Largest safe context'},
        [pscustomobject]@{Id='Vision';Label='Vision'},
        [pscustomobject]@{Id='Expert';Label='Manual expert controls'}
    )
    & $WriteOutput '';& $WriteOutput 'TASK PROFILE'
    for($i=0;$i -lt $profiles.Count;$i++){& $WriteOutput (' [{0}] {1}' -f ($i+1),$profiles[$i].Label)}
    & $WriteOutput ' [B] Back'
    $allowed=@(1..$profiles.Count|ForEach-Object{[string]$_})+@('B')
    $selection=Read-LocalAIChoice -Allowed $allowed -ReadInput $ReadInput -WriteOutput $WriteOutput
    if($selection -eq 'B'){return $null}
    return [string]$profiles[[int]$selection-1].Id
}

function Select-LocalAIHarnessInteractive {
    [CmdletBinding()]
    param(
        [object[]]$Statuses=@(),
        [scriptblock]$ReadInput={Read-Host 'Select target'},
        [scriptblock]$WriteOutput={param($Text) Write-Host $Text}
    )
    $choices=@([pscustomobject]@{Id='Server';DisplayName='Server only'})+@($Statuses|Where-Object Installed)
    & $WriteOutput '';& $WriteOutput 'LAUNCH TARGET'
    for($i=0;$i -lt $choices.Count;$i++){& $WriteOutput (' [{0}] {1}' -f ($i+1),$choices[$i].DisplayName)}
    & $WriteOutput ' [B] Back'
    $allowed=@(1..$choices.Count|ForEach-Object{[string]$_})+@('B')
    $selection=Read-LocalAIChoice -Allowed $allowed -ReadInput $ReadInput -WriteOutput $WriteOutput
    if($selection -eq 'B'){return $null}
    return [string]$choices[[int]$selection-1].Id
}

function Confirm-LocalAIInteractiveAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [scriptblock]$ReadInput={param($Text) Read-Host $Text},
        [scriptblock]$WriteOutput={param($Text) Write-Host $Text}
    )
    $answer=[string](& $ReadInput "$Prompt [y/N]")
    if($answer.Trim() -ieq 'y'){return $true}
    & $WriteOutput 'Cancelled. Nothing was started or changed.'
    return $false
}

function Show-LocalAIDoctorResults {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Results)
    foreach($result in $Results) {
        $color=switch($result.Status){'Pass'{'Green'}'Warning'{'Yellow'}'Fail'{'Red'}default{'DarkGray'}}
        Write-Host ('[{0}] {1}: {2}' -f $result.Status,$result.Code,$result.Message) -ForegroundColor $color
    }
}

Export-ModuleMember -Function *
