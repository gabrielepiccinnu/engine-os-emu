#!/usr/bin/env bash
# Boots the VM with QEMU running natively on macOS, in a Cocoa window.
#
#     bash vm-run-macos.sh          RECOMMENDED: VNC on 127.0.0.1:5903, opened
#                                   with Screen Sharing. Keeps the device
#                                   resolution, see the note below.
#     bash vm-run-macos.sh --cocoa  QEMU's own Cocoa window. Nicer, but the
#                                   guest comes up at 640x400, see below.
#     bash vm-run-macos.sh -f       run in the foreground
#     bash vm-run-macos.sh --stop   stop the VM
#     bash vm-run-macos.sh --ssh    open a shell in the VM
#     bash vm-run-macos.sh --shot x.ppm   capture through the QEMU monitor
#
# WHY THIS EXISTS
# The build needs Linux and root (loop devices, an armhf cross compiler), which
# on macOS means the container in docker/. Running the VM needs none of that:
# only qemu-system-arm and the artifacts the container produced. Keeping QEMU
# on the host removes the VNC round trip that the container has to use for lack
# of a display, and the Docker VM layer with it.
#
#     brew install qemu
#     bash docker/eos.sh export     copies the artifacts out of the volume
#     bash _tools/vm-run-macos.sh
#     bash _tools/engine-run.sh     starts Engine, over SSH, as usual
#
# WHY THE VNC SERVER HAS A PASSWORD
# QEMU with no password offers exactly one security type, "None". Apple's
# Screen Sharing will not use it: it asks for a password for "localhost" that
# nothing can satisfy, on every connection. Offering VNC authentication instead
# is what makes that client work, so a password is set through the monitor
# after startup. It guards a socket bound to 127.0.0.1, so it is there to
# satisfy the client rather than to protect anything; VNC authentication is
# DES based and takes 8 characters at most. Override it with VNC_PASSWORD.
#
# WHY NOT THE COCOA WINDOW BY DEFAULT
# The virtio-gpu kernel driver takes its preferred mode from the size the host
# reports for the display, and Qt EGLFS picks the preferred one. Under
# -display cocoa on a Retina screen that size comes back as 640x400 whatever
# xres and yres are set to, so the interface renders at a quarter of the pixels
# and clipped. The framebuffer console still shows the full size, which makes
# it easy to miss. Neither edid=off nor asking for a larger mode changes it.
# Over VNC nothing reports a display size and the guest keeps the mode it was
# given, so that is the default here.
#
# The tunables of vm-run.sh are here too, with the same meaning:
#     SMP, MEM, TB, CACHE, XRES, YRES
set -e

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM="$BASE/_vm"
KV=6.1.0-50-armmp
MON=/tmp/qmon-macos

SMP="${SMP:-4}"
MEM="${MEM:-2048}"
TB="${TB:-}"
CACHE_MODE="${CACHE:-writeback}"
# The panel is 800x1280 and the framebuffer is that rotated, so 1280x800 is the
# device resolution and the default here.
#
# edid=off matters on a Retina display. QEMU's Cocoa UI reports the window size
# in points rather than pixels, so on a 2x screen the EDID virtio-gpu generates
# advertises exactly half of it, 640x400. Qt EGLFS picks the preferred mode from
# that EDID, so the interface came up at a quarter of the pixels and clipped,
# while the framebuffer console stayed at the full size, which makes it look
# like the mode was right. With no EDID the guest takes the mode from xres/yres.
GPUOPT=",xres=${XRES:-1280},yres=${YRES:-800},edid=off"

DTB="$VM/virt-inmusic.dtb"
[ -f "$VM/virt-inmusic$SMP.dtb" ] && DTB="$VM/virt-inmusic$SMP.dtb"

vssh() {
    cp -f "$VM/id_vm" /tmp/id_vm_macos 2>/dev/null; chmod 600 /tmp/id_vm_macos
    ssh -p 2222 -i /tmp/id_vm_macos -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 "$@"
}

VNC_PASSWORD="${VNC_PASSWORD:-engineos}"
DISPLAY_OPT=(-vnc 127.0.0.1:3,password=on)
# The password goes in the URL, so Screen Sharing opens without prompting.
VIEW="vnc://:$VNC_PASSWORD@localhost:5903"
if [ "${1:-}" = "--cocoa" ]; then
    # zoom-to-fit: the panel is 800x1280 in portrait and the window is rotated
    DISPLAY_OPT=(-display cocoa,zoom-to-fit=on)
    VIEW="the QEMU window"
    shift
fi

case "${1:-}" in
    --stop)  pkill -f 'qemu-system-arm -global' 2>/dev/null || true
             echo "VM stopped"; exit 0 ;;
    --ssh)   shift; vssh "$@"; exit $? ;;
    --shot)  python3 -c "
import socket,sys,time
s=socket.socket(socket.AF_UNIX); s.settimeout(15); s.connect('$MON'); time.sleep(0.5)
try: s.recv(65536)
except Exception: pass
s.sendall(('screendump %s\n' % sys.argv[1]).encode()); time.sleep(5)" "${2:-/tmp/screen.ppm}"
             echo "captured into ${2:-/tmp/screen.ppm}"; exit 0 ;;
esac

command -v qemu-system-arm > /dev/null || {
    echo "qemu-system-arm not found: brew install qemu" >&2; exit 1; }
for f in "$VM/rootfs-vm.img" "$VM/vmlinuz-$KV" "$VM/initrd.img" "$DTB"; do
    [ -f "$f" ] || { echo "missing $f: bash docker/eos.sh export" >&2; exit 1; }
done

pkill -f 'qemu-system-arm -global' 2>/dev/null || true
sleep 1
rm -f "$VM/boot.log" "$MON"

QEMU=(qemu-system-arm
  -global virtio-mmio.force-legacy=false
  -M virt -cpu cortex-a15 -smp "$SMP" -m "$MEM"
  ${TB:+-accel tcg,tb-size=$TB}
  -dtb "$DTB"
  -kernel "$VM/vmlinuz-$KV" -initrd "$VM/initrd.img"
  -append "root=/dev/vda rw console=ttyAMA0 console=tty1 rootwait systemd.show_status=1"
  -drive file="$VM/rootfs-vm.img",format=raw,if=none,id=hd0,cache=$CACHE_MODE,aio=threads
  -device virtio-blk-device,drive=hd0
  -drive file="$VM/data.img",format=raw,if=none,id=hd1,cache=$CACHE_MODE,aio=threads
  -device virtio-blk-device,drive=hd1
  -drive file="$VM/media.img",format=raw,if=none,id=hd2,cache=$CACHE_MODE,aio=threads
  -device virtio-blk-device,drive=hd2
  -device "virtio-gpu-device$GPUOPT"
  -device virtio-keyboard-device -device virtio-tablet-device
  -device virtio-rng-device
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22
  -device virtio-net-device,netdev=n0
  "${DISPLAY_OPT[@]}"
  -serial "file:$VM/boot.log"
  -monitor "unix:$MON,server,nowait"
  -name "Numark Mixstream Pro - Engine OS 5.0.4"
  -no-reboot)

if [ "${1:-}" = "-f" ]; then
    exec "${QEMU[@]}"
fi

nohup "${QEMU[@]}" > /tmp/qemu-macos.log 2>&1 < /dev/null &
sleep 3
if pgrep -f 'qemu-system-arm -global' > /dev/null; then
    if [ "${DISPLAY_OPT[0]}" = "-vnc" ]; then
        # set_password needs the monitor, which is only up once QEMU is
        # running, hence here rather than on the command line
        python3 -c "
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect('$MON'); time.sleep(0.5)
try: s.recv(65536)
except Exception: pass
s.sendall(('set_password vnc %s\n' % sys.argv[1]).encode()); time.sleep(0.5)" \
            "$VNC_PASSWORD" 2>/dev/null || echo "  (could not set the VNC password)"
        echo "VM started. Watch it at:  open '$VIEW'"
        echo "  VNC password: $VNC_PASSWORD"
    else
        echo "VM started. Watch it at: $VIEW"
    fi
else
    echo "STARTUP FAILED:"; tail -n 8 /tmp/qemu-macos.log; exit 1
fi
echo "  console:  tail -f '$VM/boot.log'"
echo "  ssh:      bash $0 --ssh"
echo "  engine:   bash $BASE/_tools/engine-run.sh"
