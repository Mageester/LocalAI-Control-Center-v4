#requires -Version 5.1
Set-StrictMode -Version 2.0

function New-LocalAIDiagnosticResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Code,[Parameter(Mandatory)][ValidateSet('Pass','Warning','Fail','Skipped')][string]$Status,[Parameter(Mandatory)][string]$Message,$Evidence=$null,[string]$Remediation='')
    [pscustomobject]@{Code=$Code;Status=$Status;Message=$Message;Evidence=$Evidence;Remediation=$Remediation}
}

function ConvertTo-LocalAIRedactedText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $value=[regex]::Replace($Text,'(?i)(Authorization\s*:\s*Bearer\s+)[^\s"'']+','$1[REDACTED]')
    $value=[regex]::Replace($value,'(?i)((?:HF_TOKEN|OPENAI_API_KEY|ANTHROPIC_API_KEY|API_KEY)\s*[=:]\s*)[^\s"'']+','$1[REDACTED]')
    $value=[regex]::Replace($value,'(?i)\bhf_[a-z0-9]{16,}\b','[REDACTED]')
    return $value
}

function Get-LocalAIDefaultGpuMetric {
    $command=Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if(-not$command){throw 'nvidia-smi.exe was not found.'}
    $line=& $command.Source '--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw' '--format=csv,noheader,nounits' 2>$null|Select-Object -First 1
    if(-not$line){throw 'nvidia-smi returned no metrics.'}
    $p=@($line -split '\s*,\s*')
    [pscustomobject]@{Name=$p[0];UtilizationPercent=[double]$p[1];MemoryUsedMiB=[double]$p[2];MemoryTotalMiB=[double]$p[3];TemperatureC=[double]$p[4];PowerWatts=[double]$p[5]}
}

function Get-LocalAIDefaultMemoryMetric {
    $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    [pscustomobject]@{TotalBytes=[long]$os.TotalVisibleMemorySize*1KB;FreeBytes=[long]$os.FreePhysicalMemory*1KB}
}

function Get-LocalAIStatistics {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    $gpu=$null;$gpuError='';$memory=$null;$memoryError=''
    try{$gpu=if($Context.PSObject.Properties['NvidiaProbe']){& $Context.NvidiaProbe}else{Get-LocalAIDefaultGpuMetric}}catch{$gpuError=$_.Exception.Message}
    try{$memory=if($Context.PSObject.Properties['MemoryProbe']){& $Context.MemoryProbe}else{Get-LocalAIDefaultMemoryMetric}}catch{$memoryError=$_.Exception.Message}
    $active=if($Context.PSObject.Properties['ActiveState']){$Context.ActiveState}else{$null}
    [pscustomobject]@{
        Timestamp=(Get-Date).ToString('o')
        Gpu=[pscustomobject]@{Status=if($gpu){'Available'}else{'Unavailable'};Value=$gpu;Error=$gpuError}
        Memory=[pscustomobject]@{Status=if($memory){'Available'}else{'Unavailable'};Value=$memory;Error=$memoryError}
        Server=[pscustomobject]@{Status=if($active){'Recorded'}else{'Stopped/Unknown'};Value=$active}
    }
}

function Invoke-LocalAIDoctor {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[switch]$Live)
    $results=New-Object Collections.Generic.List[object]
    if($PSVersionTable.PSVersion.Major -ge 5){$results.Add((New-LocalAIDiagnosticResult 'POWERSHELL_VERSION' 'Pass' "PowerShell $($PSVersionTable.PSVersion) is supported." $PSVersionTable.PSVersion.ToString()))}else{$results.Add((New-LocalAIDiagnosticResult 'POWERSHELL_VERSION' 'Fail' 'PowerShell 5.1 or newer is required.' $PSVersionTable.PSVersion.ToString() 'Install Windows PowerShell 5.1.'))}
    $server=Join-Path $Context.InstallRoot 'llama-server.exe'
    if(Test-Path -LiteralPath $server -PathType Leaf){$results.Add((New-LocalAIDiagnosticResult 'LLAMA_SERVER' 'Pass' 'llama-server.exe is present.' $server))}else{$results.Add((New-LocalAIDiagnosticResult 'LLAMA_SERVER' 'Fail' 'llama-server.exe is missing.' $server 'Install a compatible llama.cpp build in the selected root.'))}
    $build=[string]$Context.Machine.LlamaBuild
    if($build -match '^\d+$' -and [int]$build -ge 10229){$results.Add((New-LocalAIDiagnosticResult 'LLAMA_BUILD' 'Pass' "llama.cpp build $build meets the reference floor." $build))}elseif($build){$results.Add((New-LocalAIDiagnosticResult 'LLAMA_BUILD' 'Warning' "llama.cpp build '$build' is below or not comparable to b10229." $build 'Upgrade llama.cpp or rely on capability checks.'))}else{$results.Add((New-LocalAIDiagnosticResult 'LLAMA_BUILD' 'Warning' 'llama.cpp build could not be identified.' $null 'Run llama-server.exe --version and inspect its output.'))}
    if(Test-Path -LiteralPath $Context.StateRoot -PathType Container){$results.Add((New-LocalAIDiagnosticResult 'STATE_ROOT' 'Pass' 'State directory exists.' $Context.StateRoot))}else{$results.Add((New-LocalAIDiagnosticResult 'STATE_ROOT' 'Warning' 'State directory does not exist yet.' $Context.StateRoot 'It will be created on the first mutating operation.'))}
    $badShards=@();$badTemplates=@()
    foreach($model in @($Context.Models)){
        if($model.Status -eq 'Invalid' -and [string]$model.Error -match '(?i)shard'){$badShards+=$model.Id;continue}
        foreach($shard in @($model.Shards)){if(-not(Test-Path -LiteralPath $shard -PathType Leaf)){$badShards+=$model.Id;break}}
        if($model.Kind -eq 'MainModel' -and -not[bool]$model.HasChatTemplate){$badTemplates+=$model.Id}
    }
    if($badShards.Count){$results.Add((New-LocalAIDiagnosticResult 'MODEL_SHARDS' 'Fail' "$($badShards.Count) model(s) have missing shards." @($badShards|Select-Object -Unique) 'Complete or remove the partial shard set.'))}else{$results.Add((New-LocalAIDiagnosticResult 'MODEL_SHARDS' 'Pass' 'No missing model shards were detected.' @()))}
    if($badTemplates.Count){$results.Add((New-LocalAIDiagnosticResult 'MODEL_TEMPLATES' 'Warning' "$($badTemplates.Count) main model(s) have no embedded chat template." @($badTemplates) 'Use an explicit verified template only in Expert mode.'))}else{$results.Add((New-LocalAIDiagnosticResult 'MODEL_TEMPLATES' 'Pass' 'Discovered main models include chat templates or no main models were scanned.' @()))}
    $invalidAdapters=@()
    foreach($adapter in @($Context.Adapters)){try{$null=Test-LocalAIHarnessAdapter $adapter}catch{$invalidAdapters+=[string]$adapter.id}}
    if($invalidAdapters.Count){$results.Add((New-LocalAIDiagnosticResult 'HARNESS_ADAPTERS' 'Fail' 'One or more harness adapters are invalid.' $invalidAdapters 'Repair or remove invalid user adapters.'))}else{$results.Add((New-LocalAIDiagnosticResult 'HARNESS_ADAPTERS' 'Pass' "$(@($Context.Adapters).Count) harness adapter(s) validated." @($Context.Adapters|ForEach-Object{$_.id})))}
    if($Live){
        $active=if($Context.PSObject.Properties['ActiveState']){$Context.ActiveState}else{$null}
        if($active){
            try{$health=Invoke-RestMethod -Uri ($active.Endpoint.TrimEnd('/')+'/health') -TimeoutSec 5 -UseBasicParsing;$results.Add((New-LocalAIDiagnosticResult 'SERVER_LIVE' 'Pass' 'The recorded server health endpoint responded.' $health))}catch{$results.Add((New-LocalAIDiagnosticResult 'SERVER_LIVE' 'Fail' "The recorded server health endpoint failed: $($_.Exception.Message)" $active.Endpoint 'Inspect the server log or clear stale active state.'))}
        }else{$results.Add((New-LocalAIDiagnosticResult 'SERVER_LIVE' 'Warning' 'No launcher-owned active server is recorded.' $null))}
    }else{$results.Add((New-LocalAIDiagnosticResult 'SERVER_LIVE' 'Skipped' 'Live server checks were not requested.' $null))}
    return $results.ToArray()
}

function Export-LocalAIDoctorReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Results,[Parameter(Mandatory)][string]$Path)
    $json=[pscustomobject]@{schemaVersion=1;createdAt=(Get-Date).ToString('o');results=$Results}|ConvertTo-Json -Depth 40
    $null=Write-LocalAITextAtomic -Path $Path -Content (ConvertTo-LocalAIRedactedText $json)
    return $Path
}

Export-ModuleMember -Function *
