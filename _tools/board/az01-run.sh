#!/bin/bash
# Runs Engine OS from the rootfs unpacked in /opt/az01, natively on the Tinker
# Board's RK3288, with Armbian's kernel, DRM/KMS and panfrost underneath.
#
#     az01-run.sh            start Engine (log in /opt/az01/root/engine.log)
#     az01-run.sh stop       stop it and give the console back
#
# What the real unit has and this board has not, and how it is stood in for:
#  - the device tree identity (inmusic,product-code etc.): a copy of the live
#    device tree with those properties added, bind-mounted over the real one
#    inside the chroot's own mount namespace
#  - the control surface UART in /proc/interrupts: the console UART renamed
#    ttyS0 in a copy of the file, bind-mounted the same way
#  - the framebuffer console: unbound, so Engine can become DRM master
#  - the root cgroup: the only place this kernel grants SCHED_FIFO
set -e
R=/opt/az01
S=/run/az01
PRODUCT="${PRODUCT:-NH08}"

# Only the daemons living in the chroot: Armbian runs a dbus-daemon and a
# wpa_supplicant of its own, and killing those by name takes the host down
# with them (its system bus, and everything that talks to it).
kill_chroot_daemons() {
    for p in $(pidof connmand wpa_supplicant dbus-daemon); do
        [ "$(readlink /proc/$p/root 2>/dev/null)" = "$R" ] && kill $p 2>/dev/null
    done
    true
}

if [ "${1:-}" = "stop" ]; then
    # the main thread is renamed EMain, so pkill by name misses it: pidof goes by the binary
    kill $(pidof Engine OfflineAnalyzer) 2>/dev/null || true
    sleep 2; kill -9 $(pidof Engine OfflineAnalyzer) 2>/dev/null || true
    pkill -x uinput-touch 2>/dev/null || true
    kill_chroot_daemons
    for v in /sys/class/vtconsole/*/; do case "$(cat $v/name)" in *frame*) echo 1 > $v/bind 2>/dev/null;; esac; done
    echo "stopped"; exit 0
fi

mkdir -p $S
# 1. the identity
rm -rf $S/dt; mkdir -p $S/dt
cp -r /sys/firmware/devicetree/base $S/dt/
printf '%s\0' "$PRODUCT"       > "$S/dt/base/inmusic,product-code"
printf 'A\0'                   > "$S/dt/base/inmusic,az05-pcb-rev"
printf 'TINKER0000000001\0'    > "$S/dt/base/serial-number"
# 2. the interrupt Engine pins to a CPU
sed 's/ff690000.serial/ttyS0/' /proc/interrupts > $S/interrupts
grep -q ttyS0 $S/interrupts || sed '0,/eth0/s/eth0/ttyS0/' /proc/interrupts > $S/interrupts
# 2b. wlan0 belongs to the chroot's ConnMan, not to Armbian's supplicants
systemctl stop wpa_supplicant 2>/dev/null || true
pkill -f "wpa_supplicant -c /run/netplan" 2>/dev/null || true

# 3. the display
systemctl stop getty@tty1 2>/dev/null || true
for v in /sys/class/vtconsole/*/; do case "$(cat $v/name)" in *frame*) echo 0 > $v/bind 2>/dev/null;; esac; done
# The real unit pins the GPU to "performance"; a bare Tinker Board with no
# heatsink then reaches the critical temperature within the hour and the
# kernel powers it off (HARDWARE PROTECTION shutdown). The default governor
# stays, and GPU_PERFORMANCE=1 is there for a board that is cooled.
[ -n "${GPU_PERFORMANCE:-}" ] && echo performance > /sys/devices/platform/ffa30000.gpu/devfreq/ffa30000.gpu/governor 2>/dev/null
modprobe snd_seq_midi 2>/dev/null || true

# 3a. the pointer. The RK3288 VOP in the mainline kernel has no cursor plane
#     (every plane but the primary is an overlay), so the hardware cursor Qt
#     defaults to has nowhere to go and the mouse is invisible. Engine copies
#     this file verbatim into the QT_QPA_EGLFS_KMS_CONFIG it hands to Qt, and
#     hwcursor=false makes Qt draw the arrow in OpenGL, inside the frame,
#     where the mirror sees it too.
SC=$R/usr/Engine/ScreenConfiguration/Default/ScreenConfiguration.json
if [ -f "$SC" ] && ! grep -q '"hwcursor"' "$SC"; then
    cp -n "$SC" "$SC.orig"
    python3 - "$SC" <<'JSON'
import json, sys
f = sys.argv[1]; d = json.load(open(f)); d["hwcursor"] = False
json.dump(d, open(f, "w"), indent=1)
JSON
fi

# 3c. the sound card and the control surface, the same module as under QEMU
#     built against Armbian's kernel (_vm/snd-combined-board.ko, copied here
#     by board.sh install). Engine identifies the surface in its first half
#     minute, so it must be there before Engine starts.
if [ -f /root/snd-combined.ko ] && ! grep -q Surface /proc/asound/cards 2>/dev/null; then
    for m in snd-pcm snd-rawmidi snd-seq snd-seq-midi; do modprobe $m 2>/dev/null || true; done
    insmod /root/snd-combined.ko id=NH08 name=NH08 channels=16 rate=48000 \
        && echo "virtual sound card and control surface loaded" \
        || echo "WARNING: snd-combined.ko did not load"
fi

# 3b. the touchscreen. Engine's interface answers touch, not mouse clicks,
#     so the bridge from _tools/uinput-touch.c turns the USB mouse into one
#     (relative movement integrated, left button = finger). It must exist
#     before Engine starts and udev must have labelled it a touchscreen.
if [ -x /root/uinput-touch ] && ! pidof uinput-touch > /dev/null; then
    modprobe uinput 2>/dev/null || true
    # the size is the connected output's preferred mode, which is what Engine
    # sets; fb0 keeps reporting the console's mode after fbcon is unbound
    MODE=$(for c in /sys/class/drm/card0-*; do [ "$(cat $c/status)" = connected ] && head -n1 $c/modes && break; done)
    W=${MODE%x*}; H=${MODE#*x}
    setsid /root/uinput-touch -w "${W:-1920}" -h "${H:-1080}" < /dev/null > /dev/null 2>&1 &
    sleep 2; udevadm settle --timeout=5 2>/dev/null || true
fi

kill $(pidof Engine OfflineAnalyzer) 2>/dev/null || true; sleep 1
kill -9 $(pidof Engine OfflineAnalyzer) 2>/dev/null || true
kill_chroot_daemons
rm -f $R/tmp/engine_runguard.lock

# 4. what runs inside the chroot, written where the chroot sees it
cat > $R/root/az01-inner.sh <<'INNER'
# the system bus, so edisksd (drives) and the rest are reachable and activatable
mkdir -p /run/dbus
[ -s /etc/machine-id ] || dbus-uuidgen > /etc/machine-id
dbus-daemon --system --fork
# Wi-Fi: Engine asks ConnMan (net.connman), ConnMan drives wpa_supplicant,
# both on this bus and both started by systemd on the real unit. Armbian has
# let go of wlan0 already, and ConnMan is kept off the Ethernet cable this
# whole session runs over.
grep -q NetworkInterfaceBlacklist /etc/connman/main.conf \
    || sed -i '/^\[General\]/a NetworkInterfaceBlacklist=end0,eth0,sit0,ip6tnl0,lo' /etc/connman/main.conf
(setsid /usr/sbin/wpa_supplicant -u -s < /dev/null > /dev/null 2>&1 &)
sleep 1
(setsid /usr/sbin/connmand -n < /dev/null > /root/connman.log 2>&1 &)
export LD_LIBRARY_PATH=/usr/qt/lib
export QT_QPA_PLATFORM=eglfs
[ -f /root/qtlog.ini ] && export QT_LOGGING_CONF=/root/qtlog.ini
[ -f /usr/Engine/Scripts/setup-screenrotation.sh ] && . /usr/Engine/Scripts/setup-screenrotation.sh "$1"
cd /usr/Engine
exec ./Engine -d0 -loggerOptions "Type, Message, Thread, Category, SplitLongLines"
INNER

# 5. the chroot, in its own mount namespace so nothing leaks into Armbian.
#    Armbian's kernel has RT_GROUP_SCHED, and with cgroup v2 a real-time policy
#    is only granted in the root cgroup: an ssh session's scope gets EPERM on
#    Engine's SCHED_FIFO audio thread, which it treats as fatal. So move there.
unshare -m bash -c "
set -e
echo \$\$ > /sys/fs/cgroup/cgroup.procs
mount --bind /dev $R/dev
mount --bind /dev/pts $R/dev/pts
mount -t proc proc $R/proc
mount --rbind /sys $R/sys
mount -t tmpfs tmpfs $R/tmp
mount -t tmpfs tmpfs $R/run
mkdir -p $R/run/udev; mount --bind /run/udev $R/run/udev
mount --bind $S/dt/base $R/sys/firmware/devicetree/base
mount --bind $S/interrupts $R/proc/interrupts
exec chroot $R /bin/sh /root/az01-inner.sh $PRODUCT
" > $R/root/engine.log 2>&1 &
echo "Engine started, log: $R/root/engine.log"
