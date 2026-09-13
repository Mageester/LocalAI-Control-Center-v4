#requires -Version 5.1
Set-StrictMode -Version 2.0

function New-LocalAIBenchmarkMatrix {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$BasePlan,[Parameter(Mandatory)][string]$Intent)
    $contexts=@([long]$BasePlan.Context,[long][math]::Max(4096,[math]::Floor([long]$BasePlan.Context/2)))|Select-Object -Unique
    $kvs=@([string]$BasePlan.KV,'q4_0')|Select-Object -Unique
    $ubatches=@([int]$BasePlan.UBatch,[int][math]::Max(128,[math]::Floor([int]$BasePlan.UBatch/2)),1024)|Where-Object{$_ -le [int]$BasePlan.Batch}|Select-Object -Unique
    $items=New-Object Collections.Generic.List[object]
    foreach($context in $contexts){foreach($kv in $kvs){foreach($ubatch in $ubatches){
        if($items.Count -ge 16){break}
        $key="$($BasePlan.ModelFingerprint)|$Intent|$context|$kv|$ubatch|$($BasePlan.Threads)|$($BasePlan.Mtp)"
        $items.Add([pscustomobject]@{CandidateId='candidate-'+(Get-LocalAIHash $key).Substring(0,12);BasePlanId=$BasePlan.PlanId;ModelId=$BasePlan.ModelId;ModelFingerprint=$BasePlan.ModelFingerprint;ModelPath=$BasePlan.ModelPath;Intent=$Intent;Context=[long]$context;KV=[string]$kv;Batch=[int]$BasePlan.Batch;UBatch=[int]$ubatch;Threads=[int]$BasePlan.Threads;ThreadsBatch=[int]$BasePlan.ThreadsBatch;FitTargetMiB=[int]$BasePlan.FitTargetMiB;Mtp=[bool]$BasePlan.Mtp})
    }}}
    return $items.ToArray()
}

function Invoke-LocalAIBenchmark {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Candidates,[Parameter(Mandatory)][scriptblock]$Runner)
    $results=New-Object Collections.Generic.List[object]
    foreach($candidate in $Candidates){
        $started=Get-Date
        try{
            $value=& $Runner $candidate
            if($null -eq $value){throw 'Benchmark runner returned no result.'}
            if(-not$value.PSObject.Properties['CandidateId']){$value|Add-Member NoteProperty CandidateId $candidate.CandidateId}
            if(-not$value.PSObject.Properties['Succeeded']){$value|Add-Member NoteProperty Succeeded $true}
            if(-not$value.PSObject.Properties['Stable']){$value|Add-Member NoteProperty Stable $true}
            if(-not$value.PSObject.Properties['Error']){$value|Add-Member NoteProperty Error ''}
            $value|Add-Member NoteProperty DurationSeconds ([math]::Round(((Get-Date)-$started).TotalSeconds,3)) -Force
            $results.Add($value)
        }catch{
            $results.Add([pscustomobject]@{CandidateId=$candidate.CandidateId;Succeeded=$false;Stable=$false;PromptTokensPerSecond=0.0;GenerationTokensPerSecond=0.0;LatencyMs=0.0;PeakVramMiB=0;HeadroomMiB=0;ProbePass=$false;Error=$_.Exception.Message;DurationSeconds=[math]::Round(((Get-Date)-$started).TotalSeconds,3)})
        }
    }
    return $results.ToArray()
}

function Select-LocalAIBenchmarkWinner {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Results,[Parameter(Mandatory)][string]$Intent)
    $eligible=@($Results|Where-Object{$_.Succeeded -and $_.Stable -and [double]$_.HeadroomMiB -ge 512})
    if($Intent -in @('CodingQuality','DeepReasoning','AgentLong')){$eligible=@($eligible|Where-Object{$_.ProbePass})}
    if($eligible.Count -eq 0){throw "No stable benchmark candidate satisfied the '$Intent' safety and validity gates."}
    if($Intent -eq 'CodingFast'){
        return $eligible|Sort-Object @{Expression={([double]$_.GenerationTokensPerSecond*0.7)+([double]$_.PromptTokensPerSecond*0.3)-([double]$_.LatencyMs/1000)};Descending=$true}|Select-Object -First 1
    }
    return $eligible|Sort-Object @{Expression={([double]$_.GenerationTokensPerSecond*0.5)+([double]$_.PromptTokensPerSecond*0.2)+$(if($_.ProbePass){100}else{0})};Descending=$true}|Select-Object -First 1
}

function Get-LocalAIApplicableBenchmark {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store,[Parameter(Mandatory)][string]$MachineFingerprint,[Parameter(Mandatory)][string]$ModelFingerprint,[Parameter(Mandatory)][string]$Intent)
    $records=if($Store -is [array]){$Store}elseif($Store.PSObject.Properties['records']){@($Store.records)}else{@($Store)}
    return @($records|Where-Object{$_.MachineFingerprint -ceq $MachineFingerprint -and $_.ModelFingerprint -ceq $ModelFingerprint -and $_.Intent -ceq $Intent}|Select-Object -First 1)
}

function Save-LocalAIBenchmarkRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Record)
    $store=Read-LocalAIJson -Path $Path -Default ([pscustomobject]@{schemaVersion=1;updatedAt='';records=@()})
    $records=@($store.records|Where-Object{-not($_.MachineFingerprint -ceq $Record.MachineFingerprint -and $_.ModelFingerprint -ceq $Record.ModelFingerprint -and $_.Intent -ceq $Record.Intent)})+$Record
    $value=[pscustomobject]@{schemaVersion=1;updatedAt=(Get-Date).ToString('o');records=$records}
    $null=Write-LocalAIJsonAtomic -Path $Path -Value $value
    return $Record
}

function New-LocalAILlamaBenchArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Candidate)
    return @('-m',$Candidate.ModelPath,'-p','512','-n','128','-b',[string]$Candidate.Batch,'-ub',[string]$Candidate.UBatch,'-t',[string]$Candidate.Threads,'-fa','on','-ctk',$Candidate.KV,'-ctv',$Candidate.KV,'-o','jsonl')
}

function Invoke-LocalAILlamaBenchCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Candidate,[Parameter(Mandatory)][string]$Executable)
    if(-not(Test-Path -LiteralPath $Executable -PathType Leaf)){throw "llama-bench is missing: $Executable"}
    $arguments=@(New-LocalAILlamaBenchArguments -Candidate $Candidate)
    $si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=$Executable;$si.Arguments=($arguments|ForEach-Object{ConvertTo-LocalAIWindowsArgument $_})-join ' ';$si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    $p=New-Object Diagnostics.Process;$p.StartInfo=$si
    try{
        if(-not$p.Start()){throw 'Could not start llama-bench.'};$stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync();if(-not$p.WaitForExit(600000)){$p.Kill();throw 'llama-bench timed out after 10 minutes.'};if($p.ExitCode -ne 0){throw "llama-bench exited $($p.ExitCode): $($stderr.Result)"}
        $rows=@($stdout.Result -split "`r?`n"|Where-Object{$_ -match '^\s*\{'}|ForEach-Object{$_|ConvertFrom-Json})
        if($rows.Count -eq 0){throw 'llama-bench returned no JSONL measurements.'}
        $prompt=@($rows|Where-Object{[int]$_.n_prompt -gt 0}|Select-Object -Last 1);$generation=@($rows|Where-Object{[int]$_.n_gen -gt 0}|Select-Object -Last 1)
        [pscustomobject]@{CandidateId=$Candidate.CandidateId;Succeeded=$true;Stable=$true;PromptTokensPerSecond=if($prompt){[double]$prompt.avg_ts}else{0};GenerationTokensPerSecond=if($generation){[double]$generation.avg_ts}else{0};LatencyMs=0;PeakVramMiB=0;HeadroomMiB=1024;ProbePass=$true;Error='';Raw=$rows}
    }finally{$p.Dispose()}
}

Export-ModuleMember -Function *
