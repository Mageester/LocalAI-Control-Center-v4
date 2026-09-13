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

function Show-LocalAIDoctorResults {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Results)
    foreach($result in $Results) {
        $color=switch($result.Status){'Pass'{'Green'}'Warning'{'Yellow'}'Fail'{'Red'}default{'DarkGray'}}
        Write-Host ('[{0}] {1}: {2}' -f $result.Status,$result.Code,$result.Message) -ForegroundColor $color
    }
}

Export-ModuleMember -Function *
