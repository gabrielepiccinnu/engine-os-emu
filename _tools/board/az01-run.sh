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

if [ "${1:-}" = "stop" ]; then
    # the main thread is renamed EMain, so pkill by name misses it: pidof goes by the binary
    kill $(pidof Engine OfflineAnalyzer) 2>/dev/null || true
    sleep 2; kill -9 $(pidof Engine OfflineAnalyzer) 2>/dev/null || true
    pkill -x uinput-touch 2>/dev/null || true
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
# 3. the display
systemctl stop getty@tty1 2>/dev/null || true
for v in /sys/class/vtconsole/*/; do case "$(cat $v/name)" in *frame*) echo 0 > $v/bind 2>/dev/null;; esac; done
echo performance > /sys/devices/platform/ffa30000.gpu/devfreq/ffa30000.gpu/governor 2>/dev/null || true
modprobe snd_seq_midi 2>/dev/null || true

# 3b. the touchscreen. Engine's interface answers touch, not mouse clicks,
#     so the bridge from _tools/uinput-touch.c turns the USB mouse into one
#     (relative movement integrated, left button = finger). It must exist
#     before Engine starts and udev must have labelled it a touchscreen.
if [ -x /root/uinput-touch ] && ! pidof uinput-touch > /dev/null; then
    modprobe uinput 2>/dev/null || true
    W=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null | cut -d, -f1); H=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null | cut -d, -f2)
    setsid /root/uinput-touch -w "${W:-1920}" -h "${H:-1080}" < /dev/null > /dev/null 2>&1 &
    sleep 2; udevadm settle --timeout=5 2>/dev/null || true
fi

kill $(pidof Engine OfflineAnalyzer) 2>/dev/null || true; sleep 1
kill -9 $(pidof Engine OfflineAnalyzer) 2>/dev/null || true
rm -f $R/tmp/engine_runguard.lock

# 4. the chroot, in its own mount namespace so nothing leaks into Armbian.
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
exec chroot $R /bin/sh -c '
  # the system bus, so edisksd (drives) and the rest are reachable and activatable
  mkdir -p /run/dbus
  [ -s /etc/machine-id ] || dbus-uuidgen > /etc/machine-id
  dbus-daemon --system --fork
  export LD_LIBRARY_PATH=/usr/qt/lib
  export QT_QPA_PLATFORM=eglfs
  export QT_LOGGING_RULES=\"qt.qpa.*=true\"
  [ -f /usr/Engine/Scripts/setup-screenrotation.sh ] && . /usr/Engine/Scripts/setup-screenrotation.sh $PRODUCT
  cd /usr/Engine
  exec ./Engine -d0 -loggerOptions \"Type, Message, Thread, Category, SplitLongLines\"
'
" > $R/root/engine.log 2>&1 &
echo "Engine started, log: $R/root/engine.log"
