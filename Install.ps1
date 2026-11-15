<#
.SYNOPSIS
    Writes config.json and adds "Move to archive" / "Restore from archive" to the folder
    right-click menu for the current user (no admin rights needed).

.EXAMPLE
    .\Install.ps1 -ArchiveRoot 'E:\Archive'
#>
[CmdletBinding()]
param(
    [string] $ArchiveRoot = 'E:\Archive',

    [ValidateSet('XPRESS4K', 'XPRESS8K', 'XPRESS16K', 'LZX')]
    [string] $Algorithm = 'XPRESS8K',

    # Ask "Proceed? [Y/n]" before each move.
    [bool] $Confirm = $true,

    # Keep the window open after a successful move (it always stays open on errors).
    [bool] $PauseOnSuccess = $false
)

$ErrorActionPreference = 'Stop'

$ArchiveRoot = [System.IO.Path]::GetFullPath($ArchiveRoot).TrimEnd('\')
if ($ArchiveRoot -notmatch '^[A-Za-z]:\\.+') { throw "ArchiveRoot must be a folder on a lettered drive, e.g. E:\Archive." }

$script = Join-Path $PSScriptRoot 'DriveArchive.ps1'
if (-not (Test-Path -LiteralPath $script)) { throw "DriveArchive.ps1 not found next to Install.ps1." }

[void][System.IO.Directory]::CreateDirectory($ArchiveRoot)

$config = [ordered]@{
    ArchiveRoot      = $ArchiveRoot
    CompactAlgorithm = $Algorithm
    Confirm          = $Confirm
    PauseOnSuccess   = $PauseOnSuccess
}
$config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Encoding UTF8

$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$drive = $ArchiveRoot.Substring(0, 2)
# AppliesTo (an Explorer search query) shows each entry only where it makes sense.
$inArchive = "System.ItemPathDisplay:~<`"$ArchiveRoot\`""

$verbs = @(
    @{ Key = 'DriveArchive.Archive'; Text = "Move to archive ($drive)"; Mode = 'Archive'; AppliesTo = "NOT $inArchive"; Icon = 'imageres.dll,-174' },
    @{ Key = 'DriveArchive.Restore'; Text = 'Restore from archive'; Mode = 'Restore'; AppliesTo = $inArchive; Icon = 'imageres.dll,-5315' }
)

foreach ($v in $verbs) {
    $key = "HKCU:\Software\Classes\Directory\shell\$($v.Key)"
    New-Item -Path "$key\command" -Force | Out-Null
    Set-ItemProperty -LiteralPath $key -Name 'MUIVerb' -Value $v.Text
    Set-ItemProperty -LiteralPath $key -Name 'AppliesTo' -Value $v.AppliesTo
    Set-ItemProperty -LiteralPath $key -Name 'Icon' -Value $v.Icon
    $command = "`"$powershell`" -NoProfile -ExecutionPolicy Bypass -File `"$script`" -Mode $($v.Mode) `"%V`""
    Set-ItemProperty -LiteralPath "$key\command" -Name '(default)' -Value $command
}

Write-Host "Installed. Archive root: $ArchiveRoot  (compaction: $Algorithm)" -ForegroundColor Green
Write-Host 'Right-click a folder (on Windows 11: "Show more options", or Shift+right-click) to use it.'
