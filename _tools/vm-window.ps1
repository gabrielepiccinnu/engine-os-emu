<#
    Starts Engine OS in a native QEMU WINDOW on the Windows desktop.

        powershell -File _tools\vm-window.ps1              start VM + Engine
        powershell -File _tools\vm-window.ps1 -NoEngine    VM only
        powershell -File _tools\vm-window.ps1 -OnlyFront   bring the window forward
        powershell -File _tools\vm-window.ps1 -Shot out.png   capture the desktop

    Why PowerShell and not bash alone: the window is drawn by WSLg, but stays
    in the background (in the taskbar as "[WARN:COPY MODE] QEMU ..."), and that
    is what looked like "the window does not open" in the early attempts.
    Bringing it to the front requires the Windows APIs, so it has to be done
    from here.

    The window is QEMU's direct display: no VNC, no websocket, no re-encoding
    into a browser canvas. Input reaches the VM as a virtio tablet event and
    the uinput bridge delivers it to Engine as a touch.

    Closing the window SHUTS DOWN the VM.
#>
param(
    [switch]$NoEngine,
    [switch]$OnlyFront,
    [switch]$NoStart,
    [string]$Shot,
    [string]$Distro = 'Ubuntu-22.04'
)

# NOT 'Stop': ssh writes to stderr until the guest sshd is ready, and in
# PowerShell 5.1 the stderr of a native executable with ErrorActionPreference
# set to Stop becomes a terminating error that would kill the script halfway
# through the boot.
$ErrorActionPreference = 'Continue'
$Base    = Split-Path $PSScriptRoot -Parent
$WslBase = (wsl -d $Distro wslpath -a "$Base").Trim()

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$win32 = @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool repaint);
'@

# The Mixstream Pro panel is 800x1280 portrait.
$PanelW = 800
$PanelH = 1280
$U = Add-Type -MemberDefinition $win32 -Name Win -Namespace Az01 -PassThru

function Get-QemuWindow {
    # WSLg projects Linux windows through msrdc: the title is the one given to
    # QEMU with -name, prefixed by the copy mode warning.
    Get-Process msrdc -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -match 'QEMU|Numark|Engine OS' } |
        Select-Object -First 1
}

function Show-QemuWindow {
    param([int]$TimeoutSec = 90)
    $end = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $p = Get-QemuWindow
        if ($p) {
            $h = $p.MainWindowHandle
            $U::ShowWindow($h, 9) | Out-Null            # SW_RESTORE
            # The size has to be applied to the X window: the Windows one is
            # only the msrdc proxy and MoveWindow does not propagate to QEMU.
            $wa     = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $chrome = 62                                 # title bar + menu bar
            $winH   = $wa.Height - 8
            $winW   = [int](($winH - $chrome) * $PanelW / $PanelH)
            wsl -d $Distro -u root bash "$WslBase/_tools/vm-fit.sh" $winW $winH | Out-Null
            $U::SetForegroundWindow($h) | Out-Null
            Write-Host "window brought to the front: $($p.MainWindowTitle)"
            return $true
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $end)
    Write-Host "WARNING: QEMU window not found within $TimeoutSec s"
    return $false
}

function Save-Desktop {
    param([string]$Path)
    $b   = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
    $g   = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
    $bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host "screenshot saved: $Path"
}

if ($Shot)      { Save-Desktop -Path $Shot; exit 0 }
if ($OnlyFront) { Show-QemuWindow | Out-Null; exit 0 }

if (-not $NoStart) {
    Write-Host "== starting the VM with the native display =="
    wsl -d $Distro -u root bash "$WslBase/_tools/vm-run.sh" --window
}

Show-QemuWindow | Out-Null

Write-Host "== waiting for the boot (4 to 5 minutes under TCG emulation) =="
wsl -d $Distro -u root bash "$WslBase/_tools/vm-wait.sh" 10
if ($LASTEXITCODE -ne 0) { Write-Host "the guest is not responding: check _vm/boot.log"; exit 1 }

if (-not $NoEngine) {
    Write-Host "== starting Engine =="
    wsl -d $Distro -u root bash "$WslBase/_tools/engine-run.sh"
}

Show-QemuWindow | Out-Null
Write-Host ""
Write-Host "The window is the VM display. Closing it shuts the VM down."
Write-Host "The mouse acts as a finger on the Mixstream touchscreen."
