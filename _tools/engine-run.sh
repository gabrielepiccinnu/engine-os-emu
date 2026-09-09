#!/bin/bash
# Starts the Engine DJ application inside the emulated VM, with a working GUI.
#
# Run on the HOST (WSL/Linux) with the VM already started by vm-run.sh:
#     bash engine-run.sh
#
# Then watch the QEMU window, or the browser if the VM was started with --web:
# http://localhost:6080/vnc.html?autoconnect=true&resize=scale
#
# ----------------------------------------------------------------------------
# THE FIVE OBSTACLES, AND HOW THEY ARE OVERCOME
# ----------------------------------------------------------------------------
#
# 1. PRODUCT CODE
#    Engine reads /sys/firmware/devicetree/base/inmusic,product-code. Solved by
#    injecting the property into the QEMU DTB (see vm-build.sh).
#
# 2. IRQ AFFINITY
#    Engine looks up the control surface UART IRQ in /proc/interrupts and sets
#    its CPU. Under QEMU it does not exist: a file in which the real PL011 IRQ
#    is renamed "ttyS0" is bind-mounted over /proc/interrupts. It has to be a
#    genuine SPI IRQ (the arch_timer is per-CPU and the write fails with EIO).
#    -smp 4 is also required: with 2 CPUs the app computes "CPU -2" and aborts.
#
# 3. DRM MASTER
#    getty@tty1 has Restart=always: stopping it is not enough, systemd restarts
#    it and it reclaims the framebuffer. It has to be MASKED, then fbcon is
#    unbound. Without this drmModeSetCrtc fails with EACCES (Permission denied).
#
# 4. TOUCH INPUT
#    The Mixstream Pro is a touch device and the UI is built on QTouchEvent.
#    virtio-tablet only exposes ABS_X/ABS_Y and BTN_LEFT: udev labels it
#    ID_INPUT_MOUSE and Qt's evdevtouch plugin never picks it up
#    ("Found matching devices QList()"). The uinput-touch bridge reads the
#    tablet and republishes the events as a real touchscreen via /dev/uinput.
#
# 5. PIXEL FORMAT  <-- the real blocker, found by intercepting libdrm
#    Qt EGLFS creates the GBM surface as ARGB8888 (AR24). The virtio-gpu
#    primary plane only accepts XRGB8888 (XR24): with an AR24 FB the kernel
#    refuses drmModeSetCrtc with EINVAL and the page flips return ENOSPC.
#    On the real device the Mali accepts AR24, so the firmware has no reason to
#    pick anything else. The drmspy.so shim rewrites AR24 -> XR24.
#
# The shim technique is taken from ep122_shim in nsaintot/cdj3k-emu.
# ----------------------------------------------------------------------------

set -e
BASE="$(cd "$(dirname "$0")/.." && pwd)"
VM="$BASE/_vm"
TOOLS="$BASE/_tools"

cp -f "$VM/id_vm" /tmp/id_vm; chmod 600 /tmp/id_vm
SSHOPT="-p 2222 -i /tmp/id_vm -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -o LogLevel=ERROR"

echo "== building the DRM shim for armhf =="
if ! command -v arm-linux-gnueabihf-gcc > /dev/null; then
    echo "cross compiler missing: apt-get install -y gcc-arm-linux-gnueabihf" >&2
    exit 1
fi
arm-linux-gnueabihf-gcc -shared -fPIC -O2 -w -o /tmp/drmspy.so "$TOOLS/drmspy.c" -ldl
arm-linux-gnueabihf-gcc -O2 -w -o /tmp/uinput-touch "$TOOLS/uinput-touch.c"
cp -f /tmp/drmspy.so /tmp/uinput-touch "$VM/"
scp -P 2222 -i /tmp/id_vm -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR /tmp/drmspy.so root@127.0.0.1:/tmp/drmspy.so > /dev/null
# if the bridge is already running the file is busy (ETXTBSY): copy it
# alongside and rename, which on Linux is always allowed.
scp -P 2222 -i /tmp/id_vm -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR /tmp/uinput-touch root@127.0.0.1:/tmp/uinput-touch.new > /dev/null

# EXTRA_ENV="LP_NUM_THREADS=2" bash engine-run.sh -> extra environment for the
# Engine process. Rasterisation is ~95% of the guest's CPU time, so this is
# where the llvmpipe knobs (LP_*, MESA_*) can be tried out.
EXTRA_ENV="${EXTRA_ENV:-}"

# QT_DEBUG_INPUT=1 bash engine-run.sh -> qt.qpa.input logging in /tmp/engine.log
QTRULES=""
[ -n "${QT_DEBUG_INPUT:-}" ] && QTRULES="qt.qpa.input=true"

# MESA24=1 bash engine-run.sh -> use the drivers installed by mesa-upgrade.sh
# instead of the ones in the rootfs, which only have softpipe. With the plain
# virtio-gpu this gives llvmpipe; with virtio-gpu-gl-device (vm-run.sh --gl)
# it gives virgl, and the drawing moves to the host.
QTLIB="/usr/qt/lib"
MESAENV=""
if [ -n "${MESA24:-}" ]; then
    QTLIB="/usr/qt/lib:/opt/mesa24/lib"
    MESAENV="LIBGL_DRIVERS_PATH=/opt/mesa24/dri"
    echo "== graphics drivers: /opt/mesa24 =="
fi

echo "== preparing the guest and starting Engine =="
ssh $SSHOPT root@127.0.0.1 QTRULES="$QTRULES" QTLIB="$QTLIB" MESAENV="$MESAENV" \
    EXTRA_ENV="$EXTRA_ENV" 'sh -s' <<'GUEST'
killall Engine 2>/dev/null
sleep 2

# 5. internal FAT32 media drive.
#    Engine rejects ext4 drives: "Incompatible Format - please reformat the
#    drive to exFAT or FAT32". The systemd .mount loses the race against udev
#    (the by-label symlink appears later), so it is mounted here, with a wait.
if ! mountpoint -q /media/az01-internal 2>/dev/null; then
    modprobe vfat 2>/dev/null
    i=0
    while [ $i -lt 20 ] && [ ! -e /dev/disk/by-label/ENGINEOS ]; do
        sleep 1; i=$((i+1))
    done
    if [ -e /dev/disk/by-label/ENGINEOS ]; then
        mkdir -p /media/az01-internal
        mount -t vfat -o rw,umask=000,flush \
              /dev/disk/by-label/ENGINEOS /media/az01-internal \
            && echo "ENGINEOS drive (FAT32) mounted"
    else
        echo "WARNING: no FAT32 drive labelled ENGINEOS"
    fi
fi

# 3. release the DRM master
# The unit autologs into an interactive shell, and that shell ignores SIGTERM:
# a plain "stop" therefore blocks until systemd's stop timeout expires, which
# under emulation is minutes of dead time on the first run after a boot.
# SIGKILL the cgroup first, so the stop finds nothing left alive.
systemctl mask getty@tty1 2>/dev/null
systemctl kill -s KILL getty@tty1 2>/dev/null
systemctl stop getty@tty1 2>/dev/null
sleep 2
for v in /sys/class/vtconsole/*/; do
    case "$(cat $v/name)" in *frame*) echo 0 > $v/bind 2>/dev/null;; esac
done

# 2. shim for the control surface IRQ
if ! grep -q ttyS0 /proc/interrupts; then
    i=0
    while [ $i -lt 10 ] && umount /proc/interrupts 2>/dev/null; do i=$((i+1)); done
    sed "s/uart-pl011/ttyS0/" /proc/interrupts > /tmp/irq_shim
    mount --bind /tmp/irq_shim /proc/interrupts
fi

# 4. virtual touchscreen, before Engine: udev needs time to mark it
#    ID_INPUT_TOUCHSCREEN, otherwise Qt discards it at startup.
mv -f /tmp/uinput-touch.new /tmp/uinput-touch
chmod +x /tmp/uinput-touch
if ! pidof uinput-touch > /dev/null 2>&1; then
    modprobe uinput 2>/dev/null
    if [ -e /dev/uinput ]; then
        setsid /tmp/uinput-touch -w 800 -h 1280 < /dev/null > /dev/null 2>&1 &
        sleep 2
        udevadm settle --timeout=10 2>/dev/null
        TS=$(for e in /dev/input/event*; do
                 udevadm info --query=property --name=$e 2>/dev/null \
                 | grep -q '^ID_INPUT_TOUCHSCREEN=1' && echo $e
             done | tr '\n' ' ')
        echo "virtual touchscreen: ${TS:-NONE}"
    else
        echo "WARNING: /dev/uinput missing, no touch"
    fi
fi

# the RunGuard leaves a lock behind if the previous instance was killed
rm -f /tmp/engine_runguard.lock /tmp/engine.log /tmp/drmspy.log /tmp/ScreenConfig.json
rm -rf /tmp/EngineOS

# 5. LD_PRELOAD carrying the pixel format rewrite
setsid sh -c "LD_PRELOAD=/tmp/drmspy.so LD_LIBRARY_PATH=$QTLIB \
    QT_LOGGING_RULES='$QTRULES' $MESAENV $EXTRA_ENV \
    QT_QPA_PLATFORM=eglfs /usr/Engine/Engine -d0 > /tmp/engine.log 2>&1" < /dev/null &
echo "Engine started"
GUEST

cat <<'MSG'

Engine is loading: under TCG emulation the first frame takes 1 to 2 minutes.

  Watch:     the QEMU window on the desktop, or, if the VM was started with
             --web, http://localhost:6080/vnc.html?autoconnect=true&resize=scale
  App log:   bash vm-run.sh --ssh tail -f /tmp/engine.log
  DRM log:   bash vm-run.sh --ssh cat /tmp/drmspy.log
  Console:   to get it back -> systemctl unmask getty@tty1 and reboot the VM

MSG
