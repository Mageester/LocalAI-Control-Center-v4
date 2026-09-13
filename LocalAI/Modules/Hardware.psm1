#requires -Version 5.1
Set-StrictMode -Version 2.0

function Invoke-LocalAINativeCapture {
    param([Parameter(Mandatory)][string]$Executable,[string[]]$Arguments=@(),[int]$TimeoutMs=30000)
    $si=New-Object Diagnostics.ProcessStartInfo
    $si.FileName=$Executable
    $si.Arguments=($Arguments | ForEach-Object { ConvertTo-LocalAIWindowsArgument $_ }) -join ' '
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true
    $si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process;$process.StartInfo=$si
    try{
        if(-not $process.Start()){throw "Could not start $Executable."}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($TimeoutMs)){$process.Kill();throw "$Executable timed out."}
        [pscustomobject]@{ExitCode=$process.ExitCode;StdOut=$stdout.Result;StdErr=$stderr.Result}
    } finally {$process.Dispose()}
}

function Get-LocalAILlamaBuild {
    param([string]$LlamaRoot)
    $server=Join-Path $LlamaRoot 'llama-server.exe'
    if(-not(Test-Path -LiteralPath $server -PathType Leaf)){return ''}
    try{
        $result=Invoke-LocalAINativeCapture -Executable $server -Arguments @('--version')
        $text=$result.StdOut+"`n"+$result.StdErr
        $m=[regex]::Match($text,'(?im)version:\s*(\d+)')
        if($m.Success){return $m.Groups[1].Value}
    }catch{}
    return ''
}

function Get-LocalAIMachine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LlamaRoot)
    $cpu='Unknown';$logical=[Environment]::ProcessorCount;$ram=[long]0;$windows=[Environment]::OSVersion.VersionString
    try{$c=Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1;$cpu=[string]$c.Name;$logical=[int]$c.NumberOfLogicalProcessors}catch{}
    try{$cs=Get-CimInstance Win32_ComputerSystem -ErrorAction Stop;$ram=[long]$cs.TotalPhysicalMemory}catch{}
    $gpuName='';$gpuUuid='';$vram=[long]0;$freeVram=[long]0;$driver='';$temperature=$null
    $smi=Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if($smi){
        try{
            $r=Invoke-LocalAINativeCapture -Executable $smi.Source -Arguments @('--query-gpu=name,uuid,memory.total,memory.free,driver_version,temperature.gpu','--format=csv,noheader,nounits')
            $line=($r.StdOut -split "`r?`n" | Where-Object {$_} | Select-Object -First 1)
            if($line){$parts=@($line -split '\s*,\s*');$gpuName=$parts[0];$gpuUuid=$parts[1];$vram=[long]([double]$parts[2]*1MB);$freeVram=[long]([double]$parts[3]*1MB);$driver=$parts[4];$temperature=[int]$parts[5]}
        }catch{}
    }
    [pscustomobject]@{
        Windows=$windows;PowerShell=$PSVersionTable.PSVersion.ToString();Cpu=$cpu;LogicalProcessors=$logical;RamBytes=$ram
        GpuName=$gpuName;GpuUuid=$gpuUuid;VramBytes=$vram;FreeVramBytes=$freeVram;Driver=$driver;GpuTemperature=$temperature
        LlamaBuild=Get-LocalAILlamaBuild -LlamaRoot $LlamaRoot;LlamaRoot=[IO.Path]::GetFullPath($LlamaRoot)
    }
}

function Get-LocalAIMachineFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine)
    $driverMajor=if([string]$Machine.Driver -match '^(\d+)'){$Matches[1]}else{[string]$Machine.Driver}
    $ramBucket=[math]::Floor(([double]$Machine.RamBytes/1GB)+0.5)
    $vramBucket=[math]::Floor(([double]$Machine.VramBytes/256MB)+0.5)*256
    $text=@([string]$Machine.Cpu,[string]$Machine.LogicalProcessors,[string]$ramBucket,[string]$Machine.GpuName,[string]$Machine.GpuUuid,[string]$vramBucket,$driverMajor,[string]$Machine.LlamaBuild,'benchmark-schema-1') -join '|'
    return Get-LocalAIHash -Text $text
}

Export-ModuleMember -Function *
