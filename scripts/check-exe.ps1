# Launches the exported game, waits for it to load, screenshots only its window from the real
# screen, then closes it. Usage: pwsh scripts/check-exe.ps1 [-Seconds 10]
param([int]$Seconds = 10)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root "client/export/windows/Aurelhaven.exe"
$out = Join-Path $root "out/exe-check.png"
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
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
  [Win]::SetForegroundWindow($h) | Out-Null
  Start-Sleep -Milliseconds 700
  $r = New-Object Win+RECT
  [Win]::GetWindowRect($h, [ref]$r) | Out-Null
  $w = $r.Right - $r.Left; $hgt = $r.Bottom - $r.Top
  $bmp = New-Object System.Drawing.Bitmap $w, $hgt
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
  $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  "Captured the game window ${w}x${hgt} to $out"
} finally {
  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
}
