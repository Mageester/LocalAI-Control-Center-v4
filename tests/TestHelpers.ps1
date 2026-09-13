Set-StrictMode -Version 2.0
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('local-ai-v4-tests-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $script:TestRoot -Force)

function Assert-True {
    param($Condition, [string]$Message='Expected condition to be true.')
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message='')
    if ($Expected -is [array] -or $Actual -is [array]) {
        $expectedJson=$Expected | ConvertTo-Json -Depth 20 -Compress
        $actualJson=$Actual | ConvertTo-Json -Depth 20 -Compress
        if ($expectedJson -cne $actualJson) { throw "Expected $expectedJson but got $actualJson. $Message" }
        return
    }
    if ($Expected -cne $Actual) { throw "Expected '$Expected' but got '$Actual'. $Message" }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Like='')
    $caught=$null
    try { & $Action } catch { $caught=$_ }
    if ($null -eq $caught) { throw 'Expected an exception, but no exception was thrown.' }
    if ($Like -and $caught.Exception.Message -notlike "*$Like*") {
        throw "Expected exception containing '$Like', got '$($caught.Exception.Message)'."
    }
}

function Import-TestModule {
    param([string]$Name)
    Import-Module (Join-Path $script:ProjectRoot "LocalAI\Modules\$Name.psm1") -Force -DisableNameChecking -ErrorAction Stop
}

function Remove-TestRoot {
    if (Test-Path -LiteralPath $script:TestRoot) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Write-TestGgufString {
    param([IO.BinaryWriter]$Writer,[string]$Value)
    $bytes=[Text.Encoding]::UTF8.GetBytes($Value)
    $Writer.Write([uint64]$bytes.Length)
    $Writer.Write($bytes)
}

function New-TestGguf {
    param(
        [string]$Path='',
        [Collections.IDictionary]$Metadata=$null,
        [switch]$IncludeTokenArray
    )
    if(-not $Path){ $Path=Join-Path $script:TestRoot ([guid]::NewGuid().ToString('N')+'.gguf') }
    if($null -eq $Metadata){
        $Metadata=[ordered]@{
            'general.architecture'='qwen'
            'general.name'='Test Qwen'
            'qwen.context_length'=[uint32]32768
            'tokenizer.chat_template'='{{ messages }}'
        }
    }
    $entries=New-Object Collections.Generic.List[object]
    foreach($key in $Metadata.Keys){ $entries.Add([pscustomobject]@{Key=[string]$key;Value=$Metadata[$key]}) }
    if($IncludeTokenArray){ $entries.Add([pscustomobject]@{Key='tokenizer.ggml.tokens';Value=@('one','two')}) }
    $parent=Split-Path -Parent $Path
    if($parent -and -not(Test-Path -LiteralPath $parent)){[void](New-Item -ItemType Directory -Path $parent -Force)}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $writer=New-Object IO.BinaryWriter($stream)
    try{
        $writer.Write([uint32]0x46554747); $writer.Write([uint32]3)
        $writer.Write([uint64]0); $writer.Write([uint64]$entries.Count)
        foreach($entry in $entries){
            Write-TestGgufString $writer $entry.Key
            if($entry.Value -is [array]){
                $writer.Write([uint32]9); $writer.Write([uint32]8); $writer.Write([uint64]$entry.Value.Count)
                foreach($value in $entry.Value){ Write-TestGgufString $writer ([string]$value) }
            } elseif($entry.Value -is [uint32] -or $entry.Value -is [int]){
                $writer.Write([uint32]4); $writer.Write([uint32]$entry.Value)
            } elseif($entry.Value -is [uint64] -or $entry.Value -is [long]){
                $writer.Write([uint32]10); $writer.Write([uint64]$entry.Value)
            } else {
                $writer.Write([uint32]8); Write-TestGgufString $writer ([string]$entry.Value)
            }
        }
    } finally { $writer.Dispose(); $stream.Dispose() }
    return $Path
}

function New-MalformedTestGguf {
    param([uint64]$DeclaredStringLength)
    $path=Join-Path $script:TestRoot 'malformed.gguf'
    $stream=[IO.File]::Open($path,[IO.FileMode]::Create)
    $writer=New-Object IO.BinaryWriter($stream)
    try{
        $writer.Write([uint32]0x46554747);$writer.Write([uint32]3);$writer.Write([uint64]0);$writer.Write([uint64]1)
        $writer.Write($DeclaredStringLength)
    } finally {$writer.Dispose();$stream.Dispose()}
    return $path
}
