# RimWorld 1.7 CET startup fix (Windows 10)

Fixes RimWorld **1.7** failing to start on **Windows 10**: the process exits
immediately with no window, no error dialog, and no `Player.log`.

Run `RimWorld.exe` from a console and the real message appears:

```
Fatal error.
Your Windows doesn't fully support CET. Please install all available Windows updates.
```

Exit code `0x80131506` (CLR fail-fast).

## Cause

Two things collide:

1. `RimWorld.exe` is marked **CETCOMPAT** — the first dword of its PE
   debug-directory `EX_DLLCHARACTERISTICS` entry is `0x00000001`. Windows
   therefore enables hardware-enforced stack protection (shadow stacks) for the
   process.

2. The bundled .NET 10 runtime then fail-fasts. With shadow stacks active it
   requires `QueueUserAPC2`, which exists only on Windows 11 (build 22000) and
   Windows Server 2022 (build 20348). Windows 10 does not export it.

So the check can never pass on Windows 10, and no Windows 10 update can change
that — the "install all available Windows updates" advice is misleading.

## Affected systems

Windows 10 with a CET-capable CPU: **Intel 11th gen and later**, **AMD Zen 3 and
later**. On older CPUs Windows never enables shadow stacks, the runtime check
passes, and the game starts normally — which is why it does not reproduce
everywhere.

## Usage

Put `FixCET.ps1` next to `RimWorld.exe` (the game's root folder), then:

```powershell
# fix
powershell -ExecutionPolicy Bypass -File .\FixCET.ps1

# check only, changes nothing
powershell -ExecutionPolicy Bypass -File .\FixCET.ps1 -Report

# restore the original file
powershell -ExecutionPolicy Bypass -File .\FixCET.ps1 -Restore
```

In Explorer you can also right-click the file and choose **Run with PowerShell**.

The script:

- backs the original up as `RimWorld.exe.orig_cetbak` (only once),
- clears bit 0 of the debug-directory dword (`0x00000001` -> `0x00000000`),
- re-reads the value to confirm the write stuck,
- starts the exe suspended and reads back the process mitigation policy to
  confirm shadow stacks are actually off (`0x105` -> `0x100`).

It touches **one byte** of `RimWorld.exe`. No network access, no registry
changes, no temporary files. The whole script is plain-text ASCII — open it in
Notepad and read it.

## Notes

- A Steam **integrity check or game update restores the flag**, so run the
  script again afterwards. That is the only reason this tool has to exist.
- This is a local workaround, not a fix for the game itself. The proper fix is
  for Ludeon to stop marking `RimWorld.exe` CETCOMPAT (MSVC: `/CETCOMPAT:NO`),
  or to let the runtime degrade gracefully when `QueueUserAPC2` is missing.

## Related reports

The same mismatch has been reported against other products that ship a
self-contained .NET 10 runtime with the CETCOMPAT flag set:

- https://github.com/openai/codex/issues/39843
- https://github.com/erikdarlingdata/PerformanceMonitor/issues/5651
