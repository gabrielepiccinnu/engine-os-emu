#!/bin/bash
# Boots the armhf Engine OS QEMU VM built by vm-build.sh.
#
#     bash vm-run.sh --window   RECOMMENDED: native QEMU window on the desktop,
#                               far more responsive than the browser. From
#                               Windows use _tools/vm-window.ps1, which also
#                               brings it to the front and starts Engine.
#     bash vm-run.sh --gl       like --window but with virgl: the guest OpenGL
#                               calls are executed by the host. Requires
#                               bash mesa-upgrade.sh first
#     bash vm-run.sh --web      watch it in the browser, no client needed
#                               http://localhost:6080/vnc.html?autoconnect=true&resize=scale
#     bash vm-run.sh            window on the desktop (WSLg/X11) if DISPLAY is
#                               set, otherwise VNC on 127.0.0.1:5901
#     bash vm-run.sh --vnc      force VNC even when DISPLAY is available
#     bash vm-run.sh -f         run in the foreground
#     bash vm-run.sh --stop     stop the VM
#     bash vm-run.sh --ssh      open a shell in the VM
#     bash vm-run.sh --shot x.ppm  capture the screen through the QEMU monitor
#
# Access points:
#     window  -> device console, interactive (root autologin)
#     serial  -> _vm/boot.log
#     SSH     -> ssh -p 2222 -i _vm/id_vm root@127.0.0.1
#     monitor -> socat - unix:/tmp/qmon
#
# On WSL2 with WSLg the GTK window appears directly on the Windows desktop.
#
# Notes:
#  - the monitor socket MUST live on a Linux filesystem (/tmp). On /mnt/...
#    (drvfs) QEMU fails with "Operation not supported".
#  - the cmdline carries "console=ttyAMA0 console=tty1": the last one wins as
#    /dev/console, so systemd output ends up on the framebuffer and the whole
#    boot is visible in the window. From that point on boot.log only receives
#    kernel messages.

set -e
BASE="$(cd "$(dirname "$0")/.." && pwd)"
VM="$BASE/_vm"
KV=6.1.0-50-armmp
MON=/tmp/qmon

# Tunables, for comparing configurations without editing this file.
#   SMP=8 bash vm-run.sh     more vCPUs: llvmpipe runs one rasterizer thread
#                            per guest CPU, so this is what parallelises the
#                            drawing. Needs a matching virt-inmusic$SMP.dtb,
#                            because the DTB describes the CPUs AND the RAM.
#   MEM=3072 bash vm-run.sh  guest RAM (same DTB caveat)
#   TB=512 bash vm-run.sh    TCG translation block cache, in MiB
#   CACHE=unsafe bash vm-run.sh   ignore guest flushes: faster, but a crash can
#                            leave the filesystem broken
#   XRES=640 YRES=400 bash vm-run.sh   the virtio-gpu preferred mode, which is
#                            what Qt picks. Rasterisation is ~95% of the guest's
#                            CPU time and scales with the pixel count, so this
#                            trades resolution for frame rate directly. Keep the
#                            8:5 ratio of the 800x1280 panel.
SMP="${SMP:-4}"
MEM="${MEM:-2048}"
TB="${TB:-}"
CACHE_MODE="${CACHE:-}"
GPUOPT=""
[ -n "${XRES:-}" ] && GPUOPT="$GPUOPT,xres=$XRES"
[ -n "${YRES:-}" ] && GPUOPT="$GPUOPT,yres=$YRES"
# vm-build.sh already generates virt-inmusic.dtb with 4 CPUs; VMs built earlier
# have the 4 CPU DTB in virt-inmusic4.dtb. Prefer that one when it exists.
DTB="$VM/virt-inmusic.dtb"
[ -f "$VM/virt-inmusic4.dtb" ] && DTB="$VM/virt-inmusic4.dtb"
# a DTB built for this exact CPU count wins: booting -smp N against a DTB that
# describes a different number of CPUs leaves the extra ones unused
[ -f "$VM/virt-inmusic$SMP.dtb" ] && DTB="$VM/virt-inmusic$SMP.dtb"

# Disk images: if vm-fastdisk.sh has copied them onto ext4 use those, otherwise
# the ones on /mnt/d, which pay the 9p latency on every request.
IMG="$VM"
# cache=writeback is the default and honours guest flushes. cache=unsafe
# ignores them and is much faster, but a crash can leave the filesystem broken:
# only use it on the working copies in /opt, where the original on D: stays
# intact and vm-fastdisk.sh off restores it.
CACHE="cache=writeback,aio=threads"
if [ -f /opt/az01-vm/rootfs-vm.img ]; then
    IMG=/opt/az01-vm
    CACHE="cache=unsafe,aio=threads"
    echo "disks: $IMG (ext4, cache=unsafe)"
fi
[ -n "$CACHE_MODE" ] && CACHE="cache=$CACHE_MODE,aio=threads"

export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/mnt/wslg/runtime-dir}"

vssh() {
    cp -f "$VM/id_vm" /tmp/id_vm 2>/dev/null; chmod 600 /tmp/id_vm
    ssh -p 2222 -i /tmp/id_vm -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 "$@"
}

FORCE_VNC=0
FORCE_WEB=0
FORCE_GTK=0
USE_GL=0
GPU=(-device "virtio-gpu-device$GPUOPT")
case "${1:-}" in
    --stop)  pkill -f qemu-system-arm; pkill -f websockify 2>/dev/null
             echo "VM stopped"; exit 0 ;;
    --ssh)   shift; vssh "$@"; exit $? ;;
    --shot)  python3 -c "
import socket,sys,time
s=socket.socket(socket.AF_UNIX); s.settimeout(15); s.connect('$MON'); time.sleep(0.5)
try: s.recv(65536)
except Exception: pass
s.sendall(('screendump %s\n' % sys.argv[1]).encode()); time.sleep(5)" "${2:-/tmp/screen.ppm}"
             echo "captured into ${2:-/tmp/screen.ppm}"; exit 0 ;;
    --vnc)   FORCE_VNC=1 ;;
    --web)   FORCE_WEB=1 ;;
    --window) FORCE_GTK=1 ;;
    --gl)     FORCE_GTK=1; USE_GL=1 ;;
esac

# --web is the most reliable option: no client, just watch it in the browser.
# On WSL2 the GTK window is sometimes not rendered by WSLg (the title shows
# "[WARN:COPY MODE]" and no window opens); noVNC works around that.
if [ "$FORCE_GTK" = 1 ]; then
    # Native window on the Windows desktop through WSLg. The window is created
    # correctly: the "it does not open" of the early attempts was only WSLg
    # leaving it in the background (the title appears in the taskbar as
    # "[WARN:COPY MODE] QEMU ..."). vm-window.ps1 brings it to the front from
    # Windows.
    #   gl=off        WSLg is in copy mode here, with no GPU acceleration:
    #                 asking for OpenGL gains nothing and can give a black screen
    #   zoom-to-fit   the panel is 800x1280 portrait and does not fit in 1080,
    #                 so the content scales with the window
    pkill -f websockify 2>/dev/null || true
    export GDK_BACKEND=x11
    unset WAYLAND_DISPLAY
    if [ "$USE_GL" = 1 ]; then
        # virtio-gpu-gl + virglrenderer: the guest OpenGL calls are executed by
        # the x86 host instead of the emulated ARM CPU. Requires the
        # virtio_gpu_dri.so driver in the guest, which mesa-upgrade.sh installs.
        DISPLAY_OPT=(-display gtk,gl=on,zoom-to-fit=on)
        GPU=(-device "virtio-gpu-gl-device$GPUOPT")
        echo "display: native window with virgl (rendering on the host)"
    else
        DISPLAY_OPT=(-display gtk,gl=off,zoom-to-fit=on)
        GPU=(-device "virtio-gpu-device$GPUOPT")
        echo "display: native QEMU window on the desktop"
    fi
elif [ "$FORCE_WEB" = 1 ]; then
    if [ ! -d /usr/share/novnc ]; then
        echo "installing noVNC..."; apt-get install -y -qq novnc websockify
    fi
    pkill -f websockify 2>/dev/null || true
    setsid nohup websockify --web=/usr/share/novnc 0.0.0.0:6080 127.0.0.1:5901 \
        > /tmp/websockify.log 2>&1 < /dev/null &
    sleep 2
    DISPLAY_OPT=(-vnc 127.0.0.1:1)
    echo "display: browser -> http://localhost:6080/vnc.html?autoconnect=true&resize=scale"
elif [ "$FORCE_VNC" = 0 ] && [ -e /tmp/.X11-unix/X0 ]; then
    # GTK on X11 (Xwayland): the Wayland backend under WSLg does not render
    export GDK_BACKEND=x11
    unset WAYLAND_DISPLAY
    DISPLAY_OPT=(-display gtk)
    echo "display: GTK window on the desktop (if it does not appear, use --web)"
else
    DISPLAY_OPT=(-vnc 127.0.0.1:1)
    echo "display: VNC on 127.0.0.1:5901"
fi

for m in /mnt/vmroot /mnt/vmdata /mnt/rfs; do mountpoint -q $m && umount $m; done
pkill -f qemu-system-arm 2>/dev/null || true
sleep 1
rm -f "$VM/boot.log"

QEMU=(qemu-system-arm
  # WITHOUT this virtio-gpu and virtio-input never attach: the legacy
  # virtio-mmio transport does not offer VIRTIO_F_VERSION_1 and the devices end
  # up in state FAILED (0x83). In modern mode they all move to 0x0f.
  -global virtio-mmio.force-legacy=false
  # at least 4 CPUs: Engine assumes the RK3288 quad core for IRQ affinity
  -M virt -cpu cortex-a15 -smp "$SMP" -m "$MEM"
  ${TB:+-accel tcg,tb-size=$TB}
  -dtb "$DTB"
  -kernel "$VM/kdeb/boot/vmlinuz-$KV" -initrd "$VM/initrd.img"
  -append "root=/dev/vda rw console=ttyAMA0 console=tty1 rootwait systemd.show_status=1"
  -drive file="$IMG/rootfs-vm.img",format=raw,if=none,id=hd0,$CACHE
  -device virtio-blk-device,drive=hd0
  -drive file="$IMG/data.img",format=raw,if=none,id=hd1,$CACHE
  -device virtio-blk-device,drive=hd1
  # FAT32 media drive: the only one Engine accepts as a music drive
  -drive file="$IMG/media.img",format=raw,if=none,id=hd2,$CACHE
  -device virtio-blk-device,drive=hd2
  "${GPU[@]}"
  -device virtio-keyboard-device -device virtio-tablet-device
  # without an RNG the boot stalls for minutes on "Load/Save Random Seed"
  -device virtio-rng-device
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22
  -device virtio-net-device,netdev=n0
  # a display backend is required, otherwise virtio-gpu has no scanout
  "${DISPLAY_OPT[@]}"
  -serial "file:$VM/boot.log"
  -monitor "unix:$MON,server,nowait"
  -name "Numark Mixstream Pro - Engine OS 5.0.4"
  -no-reboot)

if [ "${1:-}" = "-f" ]; then
    exec "${QEMU[@]}"
fi

# setsid + nohup: without them QEMU dies when the terminal (or the wsl.exe
# invocation from Windows) exits.
setsid nohup "${QEMU[@]}" > /tmp/qemu.log 2>&1 < /dev/null &
sleep 3
if pgrep -f qemu-system-arm > /dev/null; then
    echo "VM started."
else
    echo "STARTUP FAILED:"; tail -n 5 /tmp/qemu.log; exit 1
fi
echo "  console:  tail -f '$VM/boot.log'"
echo "  ssh:      bash $0 --ssh"
[ "$FORCE_WEB" = 1 ] && \
echo "  browser:  http://localhost:6080/vnc.html?autoconnect=true&resize=scale"
echo
echo "Booting under TCG emulation takes about 4 to 5 minutes."
