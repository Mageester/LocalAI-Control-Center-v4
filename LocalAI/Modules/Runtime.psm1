#requires -Version 5.1
Set-StrictMode -Version 2.0

function Invoke-LocalAIProcessCapture {
    param([Parameter(Mandatory)][string]$Executable,[string[]]$Arguments=@(),[int]$TimeoutMs=30000)
    $si=New-Object Diagnostics.ProcessStartInfo
    $si.FileName=$Executable;$si.Arguments=($Arguments|ForEach-Object{ConvertTo-LocalAIWindowsArgument $_})-join ' '
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    $p=New-Object Diagnostics.Process;$p.StartInfo=$si
    try{
        if(-not$p.Start()){throw "Could not start '$Executable'."}
        $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
        if(-not$p.WaitForExit($TimeoutMs)){$p.Kill();throw "'$Executable' timed out."}
        [pscustomobject]@{ExitCode=$p.ExitCode;StdOut=$out.Result;StdErr=$err.Result}
    }finally{$p.Dispose()}
}

function Get-LocalAIServerFlagsFromHelp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HelpText)
    return @([regex]::Matches($HelpText,'(?<![\w-])--[a-zA-Z][a-zA-Z0-9-]*')|ForEach-Object{$_.Value}|Select-Object -Unique)
}

function Test-LocalAIServerArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments,[Parameter(Mandatory)][string[]]$SupportedFlags)
    $flags=@($Arguments|Where-Object{$_ -match '^--[a-zA-Z][a-zA-Z0-9-]*$'})
    $missing=@($flags|Where-Object{$SupportedFlags -notcontains $_}|Select-Object -Unique)
    if($missing.Count){throw 'llama-server does not advertise required flag(s): '+($missing -join ', ')}
    if(@($flags|Select-Object -Unique).Count -ne $flags.Count){throw 'Duplicate llama-server flag(s) were generated.'}
    return $true
}

function Get-LocalAIServerCapabilities {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Executable,[string]$CachePath='')
    if(-not(Test-Path -LiteralPath $Executable -PathType Leaf)){throw "llama-server is missing: $Executable"}
    $version=Invoke-LocalAIProcessCapture -Executable $Executable -Arguments @('--version')
    $help=Invoke-LocalAIProcessCapture -Executable $Executable -Arguments @('--help')
    if($help.ExitCode -ne 0){throw "llama-server --help failed: $($help.StdErr)"}
    $text=$version.StdOut+"`n"+$version.StdErr
    $match=[regex]::Match($text,'(?im)version:\s*(\d+)')
    $value=[pscustomobject]@{SchemaVersion=1;Executable=(Get-Item -LiteralPath $Executable).FullName;Build=if($match.Success){$match.Groups[1].Value}else{''};SupportedFlags=Get-LocalAIServerFlagsFromHelp ($help.StdOut+"`n"+$help.StdErr);UpdatedAt=(Get-Date).ToString('o')}
    if($CachePath){$null=Write-LocalAIJsonAtomic -Path $CachePath -Value $value}
    return $value
}

function Get-LocalAIPortOwner {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(1,65535)][int]$Port)
    $connection=Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue|Select-Object -First 1
    if(-not$connection){return $null}
    $process=$null
    try{$process=Get-Process -Id $connection.OwningProcess -ErrorAction Stop}catch{}
    [pscustomobject]@{Port=$Port;Pid=[int]$connection.OwningProcess;Name=if($process){$process.ProcessName}else{'Unknown'};Executable=if($process){try{$process.Path}catch{''}}else{''}}
}

function Get-LocalAIProcessInfo {
    param([Parameter(Mandatory)][int]$ProcessId)
    $p=Get-Process -Id $ProcessId -ErrorAction Stop
    [pscustomobject]@{Pid=$p.Id;ProcessStartTime=$p.StartTime.ToUniversalTime().ToString('o');Executable=$p.Path}
}

function Test-LocalAIOwnedProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State,[Parameter(Mandatory)]$Actual)
    $expectedTime=([datetime]::Parse([string]$State.ProcessStartTime)).ToUniversalTime().ToString('o')
    $actualTime=([datetime]::Parse([string]$Actual.ProcessStartTime)).ToUniversalTime().ToString('o')
    if([int]$State.Pid -ne [int]$Actual.Pid -or $expectedTime -cne $actualTime -or [IO.Path]::GetFullPath([string]$State.Executable) -ine [IO.Path]::GetFullPath([string]$Actual.Executable)){
        throw 'Recorded server process does not match the current process; refusing to act on a reused or unrelated PID.'
    }
    return $true
}

function Confirm-LocalAIModelList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExpectedAlias,[Parameter(Mandatory)][string[]]$ModelIds)
    if($ModelIds -cnotcontains $ExpectedAlias){throw "Server did not advertise expected model alias '$ExpectedAlias'. Returned: $($ModelIds -join ', ')"}
    return $true
}

function Start-LocalAIServer {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][string]$Executable,[Parameter(Mandatory)][string]$StatePath,[switch]$ReplaceOwned)
    if(-not(Test-Path -LiteralPath $Executable -PathType Leaf)){throw "llama-server is missing: $Executable"}
    $owner=Get-LocalAIPortOwner -Port $Plan.Port
    if($owner){throw "Port $($Plan.Port) is already owned by PID $($owner.Pid) ($($owner.Name)). Stop it explicitly or select another port."}
    $logParent=Split-Path -Parent $Plan.LogPath;if(-not(Test-Path -LiteralPath $logParent)){[void](New-Item -ItemType Directory -Path $logParent -Force)}
    $argLine=($Plan.Arguments|ForEach-Object{ConvertTo-LocalAIWindowsArgument $_})-join ' '
    $stdout=$Plan.LogPath+'.stdout.log';$stderr=$Plan.LogPath+'.stderr.log'
    $process=Start-Process -FilePath $Executable -ArgumentList $argLine -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $state=[pscustomobject]@{SchemaVersion=1;PlanId=$Plan.PlanId;Pid=$process.Id;ProcessStartTime=$process.StartTime.ToUniversalTime().ToString('o');Executable=(Get-Item -LiteralPath $Executable).FullName;Alias=$Plan.Alias;Endpoint=$Plan.ServerBaseUrl;LogPath=$Plan.LogPath;CreatedAt=(Get-Date).ToString('o');Owned=$true}
    $null=Write-LocalAIJsonAtomic -Path $StatePath -Value $state
    return $process
}

function Wait-LocalAIServer {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)]$Process,[ValidateRange(1,600)][int]$TimeoutSec=180)
    $deadline=(Get-Date).AddSeconds($TimeoutSec);$last=''
    while((Get-Date)-lt$deadline){
        if($Process.HasExited){throw "llama-server exited with code $($Process.ExitCode). See $($Plan.LogPath).stderr.log"}
        try{$response=Invoke-RestMethod -Uri $Plan.HealthUrl -Method Get -TimeoutSec 5 -UseBasicParsing;if($response){return $true}}catch{$last=$_.Exception.Message}
        Start-Sleep -Milliseconds 500
    }
    throw "llama-server health check timed out after $TimeoutSec seconds. Last error: $last"
}

function Confirm-LocalAIServedModel {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)
    $response=Invoke-RestMethod -Uri ($Plan.OpenAIBaseUrl+'/models') -Method Get -TimeoutSec 10 -UseBasicParsing
    $ids=@($response.data|ForEach-Object{[string]$_.id})
    return Confirm-LocalAIModelList -ExpectedAlias $Plan.Alias -ModelIds $ids
}

function Stop-LocalAIServer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StatePath)
    $state=Read-LocalAIJson -Path $StatePath
    $actual=Get-LocalAIProcessInfo -ProcessId $state.Pid
    $null=Test-LocalAIOwnedProcess -State $state -Actual $actual
    Stop-Process -Id $state.Pid -Force -ErrorAction Stop
    Remove-Item -LiteralPath $StatePath -Force
    return $true
}

Export-ModuleMember -Function *
