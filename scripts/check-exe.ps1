# Launches the exported game, waits for it to load, captures the game window's own contents
# (PrintWindow, so other windows on top don't matter), closes it, then fails if the game's log
# contains any ERROR line. Usage: pwsh scripts/check-exe.ps1 [-Seconds 12] [-Exe <path>]
param([int]$Seconds = 12, [string]$Exe = "")

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$exe = if ($Exe) { $Exe } else { Join-Path $root "client/export/windows/Aurelhaven.exe" }
$out = Join-Path $root "out/exe-check.png"
$log = Join-Path $env:APPDATA "Godot/app_userdata/Aurelhaven/logs/godot.log"
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
if (Test-Path $log) { Remove-Item $log -Force }

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[Win]::SetProcessDPIAware() | Out-Null

$p = Start-Process -FilePath $exe -PassThru
try {
  Start-Sleep -Seconds $Seconds
  $p.Refresh()
  if ($p.HasExited) { throw "The game exited early with code $($p.ExitCode)." }
  $h = $p.MainWindowHandle
  if ($h -eq [IntPtr]::Zero) { throw "The game has no visible window." }
  $r = New-Object Win+RECT
  [Win]::GetClientRect($h, [ref]$r) | Out-Null
  $w = $r.Right - $r.Left; $hgt = $r.Bottom - $r.Top
  $bmp = New-Object System.Drawing.Bitmap $w, $hgt
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  # 1 = PW_CLIENTONLY, 2 = PW_RENDERFULLCONTENT (needed for GPU-rendered windows).
  [Win]::PrintWindow($h, $hdc, 3) | Out-Null
  $g.ReleaseHdc($hdc)
  $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  "Captured the game window ${w}x${hgt} to $out"
} finally {
  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
}

Start-Sleep -Milliseconds 500
if (-not (Test-Path $log)) { throw "No game log at $log." }
$errors = @(Select-String -Path $log -Pattern "ERROR")
if ($errors.Count -gt 0) {
  $errors | Select-Object -First 10 | ForEach-Object { $_.Line }
  throw "The game logged $($errors.Count) error line(s)."
}
"Game log is clean: 0 error lines."
