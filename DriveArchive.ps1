<#
.SYNOPSIS
    Archives a folder to another drive (and compacts it), or restores it to where it came from.

.DESCRIPTION
    The archive mirrors the original location, so no extra metadata is needed:

        Archive:  C:\Users\me\Projects\Foo            ->  <ArchiveRoot>\C\Users\me\Projects\Foo
        Restore:  <ArchiveRoot>\C\Users\me\Projects\Foo  ->  C:\Users\me\Projects\Foo

    Cross-drive moves are done as copy -> verify -> delete source, so the source is never
    removed unless the archived copy matches it. After archiving, files are compacted with
    Windows' compact.exe (WOF, XPRESS8K by default); already-compacted files are skipped.

.PARAMETER Path
    The folder that was right-clicked.

.PARAMETER Mode
    Archive, Restore, or Auto (restore if the folder is inside the archive, otherwise archive).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Path,

    [ValidateSet('Auto', 'Archive', 'Restore')]
    [string] $Mode = 'Auto',

    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),

    [switch] $NoConfirm,

    [switch] $NoPause
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$LogPath = Join-Path $PSScriptRoot 'archive.log'

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

function Write-Step([string] $Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Warn([string] $Message) { Write-Host "WARNING: $Message" -ForegroundColor Yellow }

function Write-Log([string] $Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
}

# Extended-length form so .NET calls work past MAX_PATH.
function Get-LongPath([string] $p) { '\\?\' + $p }

function Get-NormalizedPath([string] $p) {
    $full = [System.IO.Path]::GetFullPath($p.Trim().Trim('"'))
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}

function Test-PathIsUnder([string] $Child, [string] $Parent, [switch] $OrEqual) {
    if ($OrEqual -and $Child.Equals($Parent, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $Child.StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Test-Exists([string] $p) {
    $lp = Get-LongPath $p
    return [System.IO.Directory]::Exists($lp) -or [System.IO.File]::Exists($lp)
}

function Get-ArchiveTarget([string] $Source, [string] $ArchiveRoot) {
    $letter = $Source.Substring(0, 1).ToUpperInvariant()
    return [System.IO.Path]::Combine($ArchiveRoot, $letter, $Source.Substring(3))
}

# Returns the original location for a folder inside the archive, or $null if it isn't in the archive.
function Get-RestoreTarget([string] $Source, [string] $ArchiveRoot) {
    if (-not (Test-PathIsUnder $Source $ArchiveRoot)) { return $null }
    $relative = $Source.Substring($ArchiveRoot.Length + 1)
    if ($relative -notmatch '^[A-Za-z]\\.') {
        throw "This folder is inside the archive but isn't an archived folder (expected $ArchiveRoot\<DriveLetter>\...)."
    }
    return '{0}:\{1}' -f $relative.Substring(0, 1).ToUpperInvariant(), $relative.Substring(2)
}

function Assert-CanArchive([string] $Source, [string] $ArchiveRoot) {
    if ($Source -notmatch '^[A-Za-z]:\\[^\\]') {
        throw "Only folders on lettered drives can be archived (got '$Source')."
    }
    if (Test-PathIsUnder $ArchiveRoot $Source -OrEqual) {
        throw "Can't archive a folder that contains the archive itself ($ArchiveRoot)."
    }
    if (Test-PathIsUnder $PSScriptRoot $Source -OrEqual) {
        throw "Can't archive the folder containing this script ($PSScriptRoot)."
    }
    $protected = @(
        $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
        $env:USERPROFILE, (Split-Path $env:USERPROFILE -Parent)
    ) | Where-Object { $_ }
    foreach ($p in $protected) {
        if (Test-PathIsUnder $p $Source -OrEqual) { throw "Refusing to archive '$Source': it is or contains '$p'." }
    }
    if (Test-PathIsUnder $Source $env:SystemRoot) { throw "Refusing to archive a folder inside $env:SystemRoot." }
}

# Throws if anything inside the folder is open in another program (Windows won't rename it then).
function Assert-NotInUse([string] $Folder) {
    $probe = '{0}.~archive-check-{1}' -f $Folder, [guid]::NewGuid().ToString('N').Substring(0, 8)
    try {
        [System.IO.Directory]::Move((Get-LongPath $Folder), (Get-LongPath $probe))
    } catch {
        throw "The folder or a file in it is in use (close any programs using it and try again).`n$($_.Exception.Message)"
    }
    try {
        [System.IO.Directory]::Move((Get-LongPath $probe), (Get-LongPath $Folder))
    } catch {
        throw "Could not rename the folder back from '$probe' - rename it back to '$Folder' manually.`n$($_.Exception.Message)"
    }
}

# Deletes a tree without following junctions/symlinks (removes the links themselves) and
# clears read-only attributes. Windows PowerShell's Remove-Item -Recurse can follow links.
function Remove-Tree([string] $Folder) {
    $readOnly = [System.IO.FileAttributes]::ReadOnly
    $reparse = [System.IO.FileAttributes]::ReparsePoint

    function Remove-Dir([System.IO.DirectoryInfo] $dir) {
        foreach ($item in @($dir.EnumerateFileSystemInfos())) {
            if ($item -is [System.IO.DirectoryInfo] -and ($item.Attributes -band $reparse) -eq 0) {
                Remove-Dir $item
                continue
            }
            if (($item.Attributes -band $readOnly) -ne 0) { $item.Attributes = $item.Attributes -band (-bnot $readOnly) }
            $item.Delete()
        }
        if (($dir.Attributes -band $readOnly) -ne 0) { $dir.Attributes = $dir.Attributes -band (-bnot $readOnly) }
        $dir.Delete()
    }

    Remove-Dir (New-Object System.IO.DirectoryInfo (Get-LongPath $Folder))
}

function Invoke-Robocopy([string] $Source, [string] $Destination, [string[]] $Options) {
    # Out-Host so robocopy's output is shown rather than becoming part of the return value.
    & robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /SL /SJ @Options | Out-Host
    return $LASTEXITCODE
}

# Copy -> verify -> delete source. On failure the source is left untouched and the partial copy removed.
function Move-AcrossDrives([string] $Source, [string] $Destination) {
    Assert-NotInUse $Source

    Write-Step 'Copying...'
    $code = Invoke-Robocopy $Source $Destination @('/MT:8', '/R:2', '/W:2', '/NDL', '/NP', '/NJH')
    if ($code -ge 8) {
        Write-Warn 'Copy failed; removing the partial copy. The original folder was not touched.'
        if (Test-Exists $Destination) { Remove-Tree $Destination }
        throw "robocopy failed with exit code $code (see output above)."
    }

    Write-Step 'Verifying copy...'
    # /L lists what would still need copying; exit code 0 means source and destination match.
    $code = Invoke-Robocopy $Source $Destination @('/L', '/FFT', '/R:0', '/W:0', '/NDL', '/NP', '/NJH', '/NJS')
    if ($code -ne 0) {
        Write-Warn 'Verification found differences (listed above); removing the copy. The original folder was not touched.'
        Remove-Tree $Destination
        throw "Verification failed (robocopy exit code $code). Was something writing to the folder?"
    }

    Write-Step 'Removing original...'
    try {
        Remove-Tree $Source
    } catch {
        throw "The copy at '$Destination' is complete and verified, but some of the original could not be deleted:`n$($_.Exception.Message)`nDelete what is left of '$Source' manually."
    }
}

function Move-Folder([string] $Source, [string] $Destination) {
    if (Test-Exists $Destination) { throw "Destination already exists: $Destination" }

    $parent = [System.IO.Path]::GetDirectoryName($Destination)
    [void][System.IO.Directory]::CreateDirectory((Get-LongPath $parent))

    if ([System.IO.Path]::GetPathRoot($Source) -eq [System.IO.Path]::GetPathRoot($Destination)) {
        try {
            Write-Step 'Moving (same drive)...'
            [System.IO.Directory]::Move((Get-LongPath $Source), (Get-LongPath $Destination))
            return
        } catch [System.IO.IOException] {
            # ERROR_NOT_SAME_DEVICE: same letter but a different volume (e.g. a mounted folder).
            if (($_.Exception.HResult -band 0xFFFF) -ne 17) { throw }
        }
    }
    Move-AcrossDrives $Source $Destination
}

function Invoke-Compact([string] $Folder, [string] $Algorithm) {
    $format = (New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot($Folder))).DriveFormat
    if ($format -ne 'NTFS') {
        Write-Warn "Skipping compaction: $Folder is on $format, and compact /exe requires NTFS."
        return
    }
    Write-Step "Compacting with $Algorithm (already-compacted files are skipped)..."

    # compact /s follows junctions out of the folder, so list the real directories ourselves
    # (not descending into links) and pass them to compact.exe as "dir\*" in batches.
    # compact.exe can't handle paths longer than MAX_PATH, so those directories are skipped.
    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $patterns = New-Object System.Collections.Generic.List[string]
    $tooLong = 0
    $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    $stack.Push((New-Object System.IO.DirectoryInfo (Get-LongPath $Folder)))
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $path = $dir.FullName.Substring(4)
        if ($path.Length -lt 248) { $patterns.Add("$path\*") } else { $tooLong++ }
        foreach ($sub in $dir.EnumerateDirectories()) {
            if (($sub.Attributes -band $reparse) -eq 0) { $stack.Push($sub) }
        }
    }

    $batches = New-Object System.Collections.Generic.List[object]
    $batch = $null
    $length = 0
    foreach ($p in $patterns) {
        if ($null -eq $batch -or $length + $p.Length -gt 30000) {
            $batch = New-Object System.Collections.Generic.List[string]
            $batches.Add($batch)
            $length = 0
        }
        $batch.Add($p)
        $length += $p.Length + 3
    }

    $failed = $false
    foreach ($b in $batches) {
        & compact.exe /c /a /i /q "/exe:$Algorithm" @($b) |
            Where-Object { $_.Trim() -and $_ -notmatch '^\s*Compressing files in ' } | Out-Host
        if ($LASTEXITCODE -ne 0) { $failed = $true }
    }
    if ($failed) { Write-Warn 'compact.exe reported errors; some files may be uncompressed.' }
    if ($tooLong -gt 0) { Write-Warn "$tooLong folder(s) have paths too long for compact.exe and were left uncompressed." }
}

# Removes now-empty mirror folders between a restored folder's old location and the archive root.
function Remove-EmptyParents([string] $Folder, [string] $ArchiveRoot) {
    $dir = [System.IO.Path]::GetDirectoryName($Folder)
    while ($dir -and (Test-PathIsUnder $dir $ArchiveRoot)) {
        $lp = Get-LongPath $dir
        if ([System.IO.Directory]::EnumerateFileSystemEntries($lp).GetEnumerator().MoveNext()) { break }
        [System.IO.Directory]::Delete($lp)
        $dir = [System.IO.Path]::GetDirectoryName($dir)
    }
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------

$config = $null
$exitCode = 0
try {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config not found: $ConfigPath (run Install.ps1)." }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $archiveRoot = Get-NormalizedPath $config.ArchiveRoot
    $source = Get-NormalizedPath $Path

    if (-not [System.IO.Directory]::Exists((Get-LongPath $source))) { throw "Folder not found: $source" }

    $restoreTarget = Get-RestoreTarget $source $archiveRoot
    if ($Mode -eq 'Auto') { $Mode = if ($restoreTarget) { 'Restore' } else { 'Archive' } }

    if ($Mode -eq 'Archive') {
        if ($restoreTarget) { throw "This folder is already in the archive. Use Restore instead." }
        Assert-CanArchive $source $archiveRoot
        if (-not (Test-Path -LiteralPath ([System.IO.Path]::GetPathRoot($archiveRoot)))) {
            throw "Archive drive for '$archiveRoot' is not available."
        }
        $destination = Get-ArchiveTarget $source $archiveRoot
    } else {
        if (-not $restoreTarget) { throw "This folder is not in the archive ($archiveRoot), so there is nothing to restore." }
        if (-not (Test-Path -LiteralPath ([System.IO.Path]::GetPathRoot($restoreTarget)))) {
            throw "Original drive for '$restoreTarget' is not available."
        }
        $destination = $restoreTarget
    }

    $Host.UI.RawUI.WindowTitle = "$Mode - $(Split-Path $source -Leaf)"
    Write-Host ''
    Write-Host "  $($Mode.ToUpper())" -ForegroundColor Green
    Write-Host "  From: $source"
    Write-Host "  To:   $destination"
    Write-Host ''

    if (Test-Exists $destination) { throw "Destination already exists: $destination" }

    if ($config.Confirm -and -not $NoConfirm) {
        $answer = Read-Host 'Proceed? [Y/n]'
        if ($answer -and $answer -notmatch '^\s*y(es)?\s*$') {
            Write-Host 'Cancelled.'
            exit 1
        }
    }

    Move-Folder $source $destination

    if ($Mode -eq 'Archive') {
        Invoke-Compact $destination $config.CompactAlgorithm
    } else {
        Remove-EmptyParents $source $archiveRoot
    }

    Write-Log "$($Mode.ToUpper())  $source  ->  $destination"
    Write-Host ''
    Write-Host "Done: $destination" -ForegroundColor Green
} catch {
    $exitCode = 1
    Write-Log "FAILED $Mode  $Path  :  $($_.Exception.Message -replace '\s*\r?\n\s*', ' ')"
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}

if (-not $NoPause) {
    if ($exitCode -ne 0 -or ($config -and $config.PauseOnSuccess)) {
        Read-Host 'Press Enter to close' | Out-Null
    } else {
        Start-Sleep -Seconds 3
    }
}
exit $exitCode
