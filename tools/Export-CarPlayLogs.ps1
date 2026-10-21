#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,
    [string]$HdcPath,
    [string]$Device,
    [string]$BundleName = 'com.fandy.carplayhw'
)

$ErrorActionPreference = 'Stop'
if ($BundleName -notmatch '^[A-Za-z0-9_.]+$') {
    throw 'Invalid bundle name.'
}
if (-not $HdcPath) {
    $installed = Get-Command hdc -ErrorAction SilentlyContinue
    if ($installed) {
        $HdcPath = $installed.Source
    } else {
        $HdcPath = Join-Path $env:ProgramFiles 'Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
    }
}
if (-not (Test-Path -LiteralPath $HdcPath -PathType Leaf)) {
    throw 'HDC was not found. Supply -HdcPath pointing to your installed SDK.'
}
$deviceArguments = @()

function Invoke-HdcText {
    param([string[]]$HdcArguments)
    $output = & $HdcPath @deviceArguments @HdcArguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { "$_" }) -join "`n"
    if ($exitCode -ne 0 -or $text -match '\[Fail\]|Permission denied|No such file|not found|inaccessible|need connect-key') {
        throw "HDC failed ($exitCode): $text"
    }
    return $text
}

$targets = (Invoke-HdcText @('list', 'targets')) -split '\r?\n' |
    Where-Object { $_.Trim() -and $_ -notmatch '^\[Empty\]$' } |
    ForEach-Object { $_.Trim() }
if ($Device) {
    if ($targets -notcontains $Device) {
        throw 'The specified device is not connected or authorized.'
    }
} elseif (@($targets).Count -eq 1) {
    $Device = @($targets)[0]
} else {
    throw 'Connect and authorize one device, or specify -Device when several are connected.'
}
$deviceArguments = @('-t', $Device)

# HDC's -b mount exposes app paths relative to its root; the root itself need not be listable.
$remoteDirectory = 'data/storage/el2/base/haps/entry/files/carplay-logs'
$names = (Invoke-HdcText @('shell', '-b', $BundleName, "ls $remoteDirectory")) -split '\r?\n' |
    Where-Object { $_ -match '^session-\d{8}T\d{9}Z-\d+\.log$' }
if (@($names).Count -eq 0) {
    throw 'There are no persisted session logs to retrieve.'
}
$destination = Join-Path $OutputDirectory ('carplay-export-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))
if (Test-Path -LiteralPath $destination) {
    throw 'The export destination already exists; refusing to overwrite it.'
}
$null = New-Item -Path $destination -ItemType Directory
foreach ($name in $names) {
    $remoteFile = "$remoteDirectory/$name"
    $sizeText = (Invoke-HdcText @('shell', '-b', $BundleName, "stat -c %s $remoteFile")).Trim()
    if ($sizeText -notmatch '^\d+$') {
        throw "Cannot determine persisted size of $name."
    }
    $size = [long]$sizeText
    # Read exactly the observed prefix so active-session appends do not invalidate the snapshot.
    $encoded = Invoke-HdcText @('shell', '-b', $BundleName, "head -c $size $remoteFile | base64")
    $bytes = [Convert]::FromBase64String($encoded)
    if ($bytes.LongLength -ne $size) {
        throw "Incomplete retrieval of $name. The file may have rotated; retry or use in-app Export."
    }
    [IO.File]::WriteAllBytes((Join-Path $destination $name), $bytes)
}
$hilog = Invoke-HdcText @('shell', 'hilog', '-x', '-T', 'CarPlayHarmony')
[IO.File]::WriteAllText((Join-Path $destination 'hilog.txt'), $hilog, [Text.UTF8Encoding]::new($false))
Write-Output "Retrieved $(@($names).Count) persisted session snapshots and the currently retained app-tag hilog buffer."
Write-Output "Output: $destination"
