#requires -Version 5.1
Set-StrictMode -Version 2.0

function Ensure-LocalAIDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $Path -Force)
    }
    return (Get-Item -LiteralPath $Path).FullName
}

function Get-LocalAIFullPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Path cannot be empty.' }
    return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
}

function Test-LocalAISafePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$AllowedRoots,
        [Parameter(Mandatory)][ValidateSet('Move','Delete','Write','Backup','Restore')][string]$Operation
    )
    $full=Get-LocalAIFullPath $Path
    $driveRoot=[IO.Path]::GetPathRoot($full)
    if ($full.TrimEnd('\') -ieq $driveRoot.TrimEnd('\')) {
        throw "$Operation rejected: a drive root is a protected path."
    }
    $matched=$false
    foreach($rootValue in $AllowedRoots) {
        if ([string]::IsNullOrWhiteSpace($rootValue)) { continue }
        $root=(Get-LocalAIFullPath $rootValue).TrimEnd('\')
        if ($full.TrimEnd('\') -ieq $root) {
            throw "$Operation rejected: an allowed search root is a protected path."
        }
        if ($full.StartsWith($root + '\',[StringComparison]::OrdinalIgnoreCase)) { $matched=$true; break }
    }
    if (-not $matched) { throw "$Operation rejected: '$full' is outside the allowed roots." }
    return $true
}

function ConvertTo-LocalAIHashtable {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) {
        $map=[ordered]@{}
        foreach($key in $Value.Keys) { $map[[string]$key]=ConvertTo-LocalAIHashtable $Value[$key] }
        return $map
    }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        $map=[ordered]@{}
        foreach($property in $Value.PSObject.Properties) { $map[$property.Name]=ConvertTo-LocalAIHashtable $property.Value }
        return $map
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { ConvertTo-LocalAIHashtable $_ })
    }
    return $Value
}

function Merge-LocalAIObject {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Base,[Parameter(Mandatory)]$Overlay)
    $baseMap=ConvertTo-LocalAIHashtable $Base
    $overlayMap=ConvertTo-LocalAIHashtable $Overlay
    if ($baseMap -isnot [Collections.IDictionary] -or $overlayMap -isnot [Collections.IDictionary]) { return $Overlay }
    $result=[ordered]@{}
    foreach($key in $baseMap.Keys) { $result[$key]=$baseMap[$key] }
    foreach($key in $overlayMap.Keys) {
        if ($result.Contains($key) -and $result[$key] -is [Collections.IDictionary] -and $overlayMap[$key] -is [Collections.IDictionary]) {
            $result[$key]=Merge-LocalAIObject $result[$key] $overlayMap[$key]
        } else { $result[$key]=$overlayMap[$key] }
    }
    return [pscustomobject]$result
}

function Get-LocalAIHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function ConvertTo-LocalAIWindowsArgument {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped=[regex]::Replace($Value,'(\\*)"','$1$1\"')
    $escaped=[regex]::Replace($escaped,'(\\+)$','$1$1')
    return '"' + $escaped + '"'
}

Export-ModuleMember -Function *
