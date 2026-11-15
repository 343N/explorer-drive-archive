<#
.SYNOPSIS
    Removes the archive entries from the folder right-click menu. Archived folders are left in place.
#>
$ErrorActionPreference = 'Stop'

foreach ($name in 'DriveArchive.Archive', 'DriveArchive.Restore') {
    $key = "HKCU:\Software\Classes\Directory\shell\$name"
    if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force }
}

Write-Host 'Context menu entries removed. Archived folders were not touched.' -ForegroundColor Green
