#requires -Version 5.1
Set-StrictMode -Version 2.0

function Get-LocalAIPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallRoot,[string]$StateRoot='')
    if (-not $StateRoot) { $StateRoot=Join-Path $env:USERPROFILE '.local-ai-control\v4' }
    [pscustomobject]@{
        InstallRoot=[IO.Path]::GetFullPath($InstallRoot)
        ModuleRoot=Join-Path $InstallRoot 'LocalAI'
        StateRoot=[IO.Path]::GetFullPath($StateRoot)
        Settings=Join-Path $StateRoot 'settings.json'
        Models=Join-Path $StateRoot 'models.json'
        Active=Join-Path $StateRoot 'active.json'
        Benchmarks=Join-Path $StateRoot 'benchmarks.json'
        Backups=Join-Path $StateRoot 'backups'
        Logs=Join-Path $StateRoot 'logs'
        Cache=Join-Path $StateRoot 'cache'
        UserAdapters=Join-Path $StateRoot 'adapters'
    }
}

function Read-LocalAIJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,$Default=$null)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ($PSBoundParameters.ContainsKey('Default')) { return $Default }
        throw "JSON file does not exist: $Path"
    }
    try { return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) }
    catch {
        $stamp=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $quarantine="$Path.corrupt-$stamp"
        Move-Item -LiteralPath $Path -Destination $quarantine -Force
        if ($PSBoundParameters.ContainsKey('Default')) { return $Default }
        throw "Invalid JSON was quarantined to '$quarantine': $($_.Exception.Message)"
    }
}

function Write-LocalAIJsonAtomic {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Value)
    $parent=Split-Path -Parent $Path
    if (-not $parent) { throw "A parent directory is required for '$Path'." }
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    $temp=Join-Path $parent ((Split-Path -Leaf $Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $encoding=New-Object Text.UTF8Encoding($false)
    try {
        $json=$Value | ConvertTo-Json -Depth 50
        [IO.File]::WriteAllText($temp,$json,$encoding)
        [void](Get-Content -LiteralPath $temp -Raw | ConvertFrom-Json -ErrorAction Stop)
        if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::Replace($temp,$Path,$null) }
        else { [IO.File]::Move($temp,$Path) }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
    return (Get-Item -LiteralPath $Path).FullName
}

function Get-LocalAIConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallRoot,[string]$StateRoot='')
    $paths=Get-LocalAIPaths -InstallRoot $InstallRoot -StateRoot $StateRoot
    $shipped=Read-LocalAIJson -Path (Join-Path $paths.ModuleRoot 'Config\defaults.json')
    $user=Read-LocalAIJson -Path $paths.Settings -Default ([pscustomobject]@{})
    [pscustomobject]@{ Paths=$paths; Settings=Merge-LocalAIObject -Base $shipped -Overlay $user }
}

Export-ModuleMember -Function *
