# Explorer Drive Archive

## NOTE: This is vibe-coded with Claude.

Right-click a folder → **Move to archive (E:)** moves it to another drive and compacts it with Windows'
`compact /exe:XPRESS8K`. Right-click it in the archive → **Restore from archive** moves it back.

The archive mirrors the original path, so the original location is always visible and recoverable:

```
C:\Users\me\Projects\Foo   <->   E:\Archive\C\Users\me\Projects\Foo
```

## Install

```powershell
powershell -ExecutionPolicy Bypass -File .\Install.ps1 -ArchiveRoot 'E:\Archive'
```

Options: `-Algorithm XPRESS4K|XPRESS8K|XPRESS16K|LZX` (default XPRESS8K), `-Confirm $false` to skip the
"Proceed?" prompt, `-PauseOnSuccess $true` to keep the window open after success. Re-run to change settings.
The menu points at this folder's `DriveArchive.ps1`, so re-run `Install.ps1` if you move the folder.

On Windows 11 the entries are under **Show more options** (or Shift+right-click).

Uninstall: `.\Uninstall.ps1` (archived folders are left where they are).

## How it moves

- **Same drive:** an instant rename.
- **Different drive:** robocopy copy → robocopy verify → delete the original. If the copy or verify fails, the
  partial copy is removed and the original is untouched.
- Before copying, it checks that nothing in the folder is open in another program.
- Junctions and symlinks are moved as links. The folders they point to are never copied, compacted or deleted.
- Restoring removes the empty mirror folders left behind in the archive.

## Compaction

Files are compressed with Windows' compact (WOF, the same mechanism as `compact /exe`) after archiving.
Files that are already compacted are skipped. Reading compacted files is transparent, and writing to one
decompresses it. Folders whose paths are longer than 260 characters are left uncompressed, because
compact.exe can't handle them; you'll see a warning when this happens. Restoring to another drive gives
you normal, uncompressed files.

## Refuses to

Archive drive roots, Windows, Program Files, ProgramData, `C:\Users` or your profile folder itself, the
folder containing the archive, or the folder containing this script. It also refuses to overwrite anything
that already exists at the destination.

Each archive or restore is logged in `archive.log` next to the script.
