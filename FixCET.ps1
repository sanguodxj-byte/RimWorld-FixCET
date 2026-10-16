# RimWorld 1.7 CET startup fix - Windows 10
#
# Symptom : the game exits immediately. No window, no error dialog, and no
#           Player.log is written. Launched from a console it prints:
#               Fatal error.
#               Your Windows doesn't fully support CET.
#               Please install all available Windows updates.
#           Exit code 0x80131506.
#
# Cause   : RimWorld.exe is marked CETCOMPAT in its PE debug directory, so
#           Windows enables hardware shadow stacks for the process. The
#           bundled .NET 10 runtime then fail-fasts, because it requires
#           QueueUserAPC2 - an API that exists only on Windows 11. No Windows
#           10 update can satisfy that check.
#
# Fix     : clear that one flag bit. The original file is backed up first and
#           the result is verified. The exe is otherwise untouched.
#
# Usage   : put this file next to RimWorld.exe, then run
#               powershell -ExecutionPolicy Bypass -File .\FixCET.ps1
#               powershell -ExecutionPolicy Bypass -File .\FixCET.ps1 -Report
#               powershell -ExecutionPolicy Bypass -File .\FixCET.ps1 -Restore
#
# Note    : a Steam integrity check or game update restores the flag, so run
#           this again afterwards.

[CmdletBinding()]
param([switch]$Report, [switch]$Restore)

$ErrorActionPreference = 'Stop'

function Get-CetOffset([byte[]]$b) {
    # Walk the PE debug directory for IMAGE_DEBUG_TYPE_EX_DLLCHARACTERISTICS
    # (type 20) and return the file offset of its 4-byte value, else -1.
    $pe   = [BitConverter]::ToInt32($b, 0x3C)
    $coff = $pe + 4
    $nsec = [BitConverter]::ToUInt16($b, $coff + 2)
    $osz  = [BitConverter]::ToUInt16($b, $coff + 16)
    $opt  = $coff + 20
    $magic = [BitConverter]::ToUInt16($b, $opt)
    $dd   = $opt + $(if ($magic -eq 0x20B) { 112 } else { 96 })
    $drva = [BitConverter]::ToUInt32($b, $dd + 48)
    $dsz  = [BitConverter]::ToUInt32($b, $dd + 52)
    if ($drva -eq 0 -or $dsz -eq 0) { return -1 }

    $st = $opt + $osz
    $off = -1
    for ($i = 0; $i -lt $nsec; $i++) {
        $s  = $st + $i * 40
        $va = [BitConverter]::ToUInt32($b, $s + 12)
        $vs = [BitConverter]::ToUInt32($b, $s + 8)
        $rp = [BitConverter]::ToUInt32($b, $s + 20)
        $rs = [BitConverter]::ToUInt32($b, $s + 16)
        if ($drva -ge $va -and $drva -lt $va + [Math]::Max($vs, $rs)) {
            $off = [int]($rp + $drva - $va)
            break
        }
    }
    if ($off -lt 0) { return -1 }

    $cnt = [int]($dsz / 28)
    for ($i = 0; $i -lt $cnt; $i++) {
        $e = $off + $i * 28
        if ([BitConverter]::ToUInt32($b, $e + 12) -eq 20) {
            return [int][BitConverter]::ToUInt32($b, $e + 24)
        }
    }
    return -1
}

function Get-ShadowStack([string]$path) {
    # Start the exe suspended (no window, nothing runs) and ask Windows which
    # mitigations it applied, then kill it. 256 = shadow stack off (good),
    # 261 = still on (an exploit-protection override is forcing it).
    $src = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
public static class Probe {
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern bool CreateProcess(string n, string c, IntPtr a, IntPtr b,
    bool inh, uint fl, IntPtr env, string dir, IntPtr si, IntPtr pi);
  [DllImport("kernel32.dll")]
  static extern bool GetProcessMitigationPolicy(IntPtr p, int pol,
    ref uint buf, UIntPtr len);
  [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr p, uint c);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  public static int Run(string path) {
    int ss = IntPtr.Size == 8 ? 104 : 68;
    int ps = IntPtr.Size == 8 ? 24 : 16;
    IntPtr si = Marshal.AllocHGlobal(ss), pi = Marshal.AllocHGlobal(ps);
    try {
      for (int i = 0; i < ss; i++) Marshal.WriteByte(si, i, 0);
      Marshal.WriteInt32(si, 0, ss);
      if (!CreateProcess(path, "\"" + path + "\"", IntPtr.Zero, IntPtr.Zero,
          false, 4, IntPtr.Zero, Path.GetDirectoryName(path), si, pi))
        return -1;
      IntPtr h = Marshal.ReadIntPtr(pi, 0);
      IntPtr t = Marshal.ReadIntPtr(pi, IntPtr.Size);
      try {
        uint v = 0;
        if (!GetProcessMitigationPolicy(h, 15, ref v, (UIntPtr)4)) return -2;
        return (int)v;
      } finally {
        TerminateProcess(h, 1); CloseHandle(t); CloseHandle(h);
      }
    } finally {
      Marshal.FreeHGlobal(si); Marshal.FreeHGlobal(pi);
    }
  }
}
'@
    try { Add-Type -TypeDefinition $src -ErrorAction Stop | Out-Null } catch { }
    try { return [Probe]::Run($path) } catch { return $null }
}

$dir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$exe = Join-Path $dir 'RimWorld.exe'
$bak = "$exe.orig_cetbak"

Write-Host ''
Write-Host 'RimWorld 1.7 CET fix'
Write-Host '===================='
Write-Host "Folder: $dir"
Write-Host ''

if (-not (Test-Path -LiteralPath $exe)) {
    Write-Host 'FAILED - no RimWorld.exe in this folder.'
    Write-Host 'Put this script next to RimWorld.exe and run it again.'
    exit 2
}

$b   = [IO.File]::ReadAllBytes($exe)
$off = Get-CetOffset $b
if ($off -lt 0) {
    Write-Host 'FAILED - CET marker not found.'
    Write-Host 'This does not look like the RimWorld executable.'
    exit 1
}
$val = [BitConverter]::ToUInt32($b, $off)
Write-Host ("CETCOMPAT = 0x{0:X8}" -f $val)

if ($Restore) {
    if (-not (Test-Path -LiteralPath $bak)) {
        Write-Host "FAILED - no backup at $bak"
        exit 1
    }
    if (Get-Process RimWorld -ErrorAction SilentlyContinue) {
        Write-Host 'FAILED - the game is running. Close it first.'
        exit 3
    }
    Copy-Item -LiteralPath $bak -Destination $exe -Force
    $b = [IO.File]::ReadAllBytes($exe)
    Write-Host ("Restored to 0x{0:X8}" -f [BitConverter]::ToUInt32($b, (Get-CetOffset $b)))
    exit 0
}

if ($Report) {
    if ($val -band 1) { Write-Host 'Status: not fixed - run without -Report' }
    else { Write-Host 'Status: already fixed' }
    exit 0
}

if (-not ($val -band 1)) {
    Write-Host 'Already fixed, nothing to do.'
    exit 0
}
if (Get-Process RimWorld -ErrorAction SilentlyContinue) {
    Write-Host 'FAILED - the game is running. Close it first.'
    exit 3
}

if (-not (Test-Path -LiteralPath $bak)) {
    Copy-Item -LiteralPath $exe -Destination $bak
    Write-Host 'Backup created: RimWorld.exe.orig_cetbak'
}

$fs = [IO.File]::Open($exe, [IO.FileMode]::Open,
                      [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $fs.Position = $off
    $fs.Write([BitConverter]::GetBytes([uint32]($val -band 0xFFFFFFFE)), 0, 4)
    $fs.Flush()
} finally { $fs.Dispose() }

$now = [BitConverter]::ToUInt32([IO.File]::ReadAllBytes($exe), $off)
Write-Host ("Written: 0x{0:X8} -> 0x{1:X8}" -f $val, $now)
if ($now -band 1) {
    Write-Host 'FAILED - the write did not stick (blocked by security software?).'
    exit 3
}

Write-Host 'Checking the result...'
switch (Get-ShadowStack $exe) {
    256 { Write-Host 'OK - fixed. You can start the game now.' }
    261 {
        Write-Host 'Flag cleared, but Windows still forces shadow stacks on.'
        Write-Host 'Open Windows Security > App & browser control >'
        Write-Host 'Exploit protection > Program settings and check RimWorld.exe.'
    }
    default { Write-Host 'Flag cleared (live check skipped).' }
}
exit 0
