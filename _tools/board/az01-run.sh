#!/bin/bash
# Runs Engine OS from the rootfs unpacked in /opt/az01, natively on the Tinker
# Board's RK3288, with Armbian's kernel, DRM/KMS and panfrost underneath.
#
#     az01-run.sh            start Engine (log in /opt/az01/root/engine.log)
#     az01-run.sh stop       stop it and give the console back; the chroot's
#                            daemons (D-Bus, ConnMan, BlueZ, edisksd) stay,
#                            and so does the Wi-Fi connection
#     az01-run.sh stop-all   take those down as well
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
    for p in $(pidof connmand wpa_supplicant dbus-daemon edisksd bluetoothd); do
        [ "$(readlink /proc/$p/root 2>/dev/null)" = "$R" ] && kill $p 2>/dev/null
    done
    true
}

# "stop" leaves the chroot's daemons running, D-Bus, ConnMan, BlueZ,
# edisksd and the supplicant: the Wi-Fi driver fails its first associations
# after every fresh start of the supplicant, so a connection is worth
# keeping across restarts of Engine. "stop all" takes everything down.
if [ "${1:-}" = "stop" ] || [ "${1:-}" = "stop-all" ]; then
    # the main thread is renamed EMain, so pkill by name misses it: pidof goes by the binary
    kill $(pidof Engine OfflineAnalyzer) 2>/dev/null || true
    sleep 2; kill -9 $(pidof Engine OfflineAnalyzer) 2>/dev/null || true
    pkill -x uinput-touch 2>/dev/null || true
    [ "$1" = "stop-all" ] && kill_chroot_daemons
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
# 2b. wlan0 belongs to the chroot's ConnMan, not to Armbian's supplicants,
#     and hci0 to the chroot's BlueZ
systemctl stop wpa_supplicant 2>/dev/null || true
pkill -f "wpa_supplicant -c /run/netplan" 2>/dev/null || true
systemctl stop bluetooth 2>/dev/null || true
rfkill unblock bluetooth 2>/dev/null || true
# a fresh start of BlueZ gets a fresh controller: the RTL8723BS stops
# answering after a while, and a rebind of its serdev reloads its firmware
if ! pgrep -x bluetoothd > /dev/null && [ -e /sys/bus/serial/drivers/hci_uart_h5/serial0-0 ]; then
    echo serial0-0 > /sys/bus/serial/drivers/hci_uart_h5/unbind; sleep 2
    echo serial0-0 > /sys/bus/serial/drivers/hci_uart_h5/bind; sleep 4
fi

# 2c. what edisksd may see. It reads the udev database, and Engine puts up
#     "Incompatible Format" for every ext4 device in it: the SD card Armbian
#     runs from, its log2ram, the zram swap. The database is Armbian's, and
#     its ID_FS_* properties are what mounts Armbian's root at boot, so it is
#     not edited: the chroot gets an overlay of it in which those entries
#     carry no filesystem, and a new USB stick still shows through from below.
UD=$S/udev; rm -rf $UD; mkdir -p $UD/upper/data $UD/work
for f in /run/udev/data/b*; do
    case "$(grep '^E:ID_FS_TYPE=' $f 2>/dev/null | cut -d= -f2)" in
        ext4|ext3|ext2|swap|btrfs|xfs|f2fs) grep -vE '^E:ID_FS_' $f > $UD/upper/data/$(basename $f) ;;
    esac
done

# 3. the display
systemctl stop getty@tty1 2>/dev/null || true
for v in /sys/class/vtconsole/*/; do case "$(cat $v/name)" in *frame*) echo 0 > $v/bind 2>/dev/null;; esac; done
# The real unit pins the GPU to "performance"; a bare Tinker Board with no
# heatsink then reaches the critical temperature within the hour and the
# kernel powers it off (HARDWARE PROTECTION shutdown). The default governor
# stays, and GPU_PERFORMANCE=1 is there for a board that is cooled.
[ -n "${GPU_PERFORMANCE:-}" ] && echo performance > /sys/devices/platform/ffa30000.gpu/devfreq/ffa30000.gpu/governor 2>/dev/null
# The device's own device tree tops the GPU at 400 MHz (four OPPs, 100 to
# 400) and the CPU at 1608 MHz on demand; the Tinker Board offers 600 and
# 1800. 400 is what Engine was tuned against, and cooler than 600.
echo 400000000 > /sys/devices/platform/ffa30000.gpu/devfreq/ffa30000.gpu/max_freq 2>/dev/null || true
modprobe snd_seq_midi 2>/dev/null || true

# 3a. the pointer. The RK3288 VOP in the mainline kernel has no cursor plane
#     (every plane but the primary is an overlay), so the hardware cursor Qt
#     defaults to has nowhere to go and the mouse is invisible. Engine copies
#     this file verbatim into the QT_QPA_EGLFS_KMS_CONFIG it hands to Qt, and
#     hwcursor=false makes Qt draw the arrow in OpenGL, inside the frame,
#     where the mirror sees it too.
#     The mode too: the display's preferred one is 1920x1080 on a TV, which
#     is twice the pixels of the device's own 1280x800 panel for the GPU to
#     fill and for the mirror to copy and encode, with the heat that goes with
#     it. Engine lays its interface out to whatever the mode is. Qt matches
#     the entry by connector name, HDMI1 here; MODE= picks another.
MODE="${MODE:-1280x800}"
#     No display at all is fine too: Engine wants a screen, not a monitor.
#     With nothing on the HDMI the connector is forced on, the kernel offers
#     its EDID-less modes, and the picture lives in the DRM buffer the mirror
#     reads. video=HDMI-A-1:1280x800@60e on the kernel command line
#     (armbianEnv.txt, extraargs) adds the device's own mode to that list.
CONN=/sys/class/drm/card0-HDMI-A-1
if [ "$(cat $CONN/status)" != connected ]; then
    echo on > $CONN/status; sleep 2
    echo "no display: HDMI connector forced on ($(head -n1 $CONN/modes))"
fi
grep -qx "$MODE" $CONN/modes || { echo "mode $MODE not offered, using $(head -n1 $CONN/modes)"; MODE=$(head -n1 $CONN/modes); }
SC=$R/usr/Engine/ScreenConfiguration/Default/ScreenConfiguration.json
if [ -f "$SC" ]; then
    cp -n "$SC" "$SC.orig"
    python3 - "$SC" "$MODE" <<'JSON'
import json, sys
f, mode = sys.argv[1], sys.argv[2]
d = json.load(open(f)); d["hwcursor"] = False
outs = [o for o in d.get("outputs", []) if o.get("name") != "HDMI1"]
outs.append({"name": "HDMI1", "mode": mode})
d["outputs"] = outs
json.dump(d, open(f, "w"), indent=1)
JSON
fi
echo "$MODE" > $S/mode

# 3c. the sound card and the control surface, the same module as under QEMU
#     built against Armbian's kernel (_vm/snd-combined-board.ko, copied here
#     by board.sh install). Engine identifies the surface in its first half
#     minute, so it must be there before Engine starts.
if [ -f /root/snd-combined.ko ] && ! grep -q Surface /proc/asound/cards 2>/dev/null; then
    for m in snd-pcm snd-rawmidi snd-seq snd-seq-midi; do modprobe $m 2>/dev/null || true; done
    # PERIOD_MIN=1024 gives Engine 21 ms periods instead of the 10.7 it asks
    # for: on this board's throttled CPU it misses 10.7 ms periods now and then
    insmod /root/snd-combined.ko id=NH08 name=NH08 channels=16 rate=48000 period_min="${PERIOD_MIN:-0}" \
        && echo "virtual sound card and control surface loaded" \
        || echo "WARNING: snd-combined.ko did not load"
fi

# 3d. the HiFiBerry DAC+, when az01-hifiberry-dtb.sh put it in the device
#     tree: its PCM5122 codec driver is not in Armbian's kernel, so the one
#     pcm512x-board-build.sh built is loaded here (no modpost, no DT alias,
#     so nothing loads it on its own) and the "HiFiBerry" card appears
if [ -f /root/snd-soc-pcm512x-i2c.ko ] && [ -d /proc/device-tree/i2c@ff140000/pcm5122@4d ] \
   && ! grep -q HiFiBerry /proc/asound/cards 2>/dev/null; then
    modprobe snd-soc-core 2>/dev/null || true
    insmod /root/snd-soc-pcm512x-i2c.ko && echo "HiFiBerry DAC+ codec loaded" || echo "WARNING: pcm512x did not load"
fi

# 3b. the touchscreen. Engine's interface answers touch, not mouse clicks,
#     so the bridge from _tools/uinput-touch.c turns the USB mouse into one
#     (relative movement integrated, left button = finger). It must exist
#     before Engine starts and udev must have labelled it a touchscreen.
if [ -x /root/uinput-touch ] && ! pidof uinput-touch > /dev/null; then
    modprobe uinput 2>/dev/null || true
    # the size is the connected output's preferred mode, which is what Engine
    # sets; fb0 keeps reporting the console's mode after fbcon is unbound
    W=${MODE%x*}; H=${MODE#*x}
    setsid /root/uinput-touch -w "${W:-1920}" -h "${H:-1080}" < /dev/null > /dev/null 2>&1 &
    sleep 2; udevadm settle --timeout=5 2>/dev/null || true
fi

kill $(pidof Engine OfflineAnalyzer) 2>/dev/null || true; sleep 1
kill -9 $(pidof Engine OfflineAnalyzer) 2>/dev/null || true
rm -f $R/tmp/engine_runguard.lock

# 4. what runs inside the chroot, written where the chroot sees it
cat > $R/root/az01-inner.sh <<'INNER'
# the system bus, so edisksd (drives) and the rest are reachable and activatable
mkdir -p /run/dbus
[ -s /etc/machine-id ] || dbus-uuidgen > /etc/machine-id
alive() { [ -s "/run/az01-$1.pid" ] && kill -0 "$(cat "/run/az01-$1.pid")" 2>/dev/null; }
launch() { n=$1; shift; alive $n && return; setsid "$@" < /dev/null > /root/$n.log 2>&1 & echo $! > /run/az01-$n.pid; }
if ! alive dbus; then
    rm -f /run/dbus/pid /run/dbus/system_bus_socket
    dbus-daemon --system --fork --print-pid > /run/az01-dbus.pid
fi
# the drives: Engine asks edisksd over the bus for them, and the service file
# activates it through systemd only (Exec=/bin/false), so it is started here
launch edisksd /usr/libexec/edisksd
# Wi-Fi: Engine asks ConnMan (net.connman), ConnMan drives wpa_supplicant,
# both on this bus and both started by systemd on the real unit. Armbian has
# let go of wlan0 already, and ConnMan is kept off the Ethernet cable this
# whole session runs over.
grep -q NetworkInterfaceBlacklist /etc/connman/main.conf \
    || sed -i '/^\[General\]/a NetworkInterfaceBlacklist=end0,eth0,sit0,ip6tnl0,lo' /etc/connman/main.conf
# Networks Engine has joined are kept as favourites that reconnect on their
# own: Engine leaves them Favorite=false, and then nothing reconnects after a
# restart, and a Connect asked before a scan has run answers "Input/output
# error", which Engine shows as a Wi-Fi login error. A scan is requested
# once ConnMan is up, and it takes it from there.
for f in /var/lib/connman/wifi_*/settings; do
    [ -f "$f" ] || continue
    grep -q "^Favorite=true" "$f" || sed -i 's/^Favorite=.*/Favorite=true/' "$f"
    grep -q "^AutoConnect=" "$f" || echo "AutoConnect=true" >> "$f"
done
alive wpa || { launch wpa /usr/sbin/wpa_supplicant -u -f /root/wpa.log; sleep 1; }
launch connman /usr/sbin/connmand -n
cat > /root/az01-wifi.sh <<'WIFI'
# power the Wi-Fi, scan, then connect to a network Engine has joined
# before; ConnMan does not do the last step by itself here, and a Connect
# before a scan has completed answers "Input/output error", so it is tried
# a few times, each after a fresh scan
sleep 5
dbus-send --system --dest=net.connman /net/connman/technology/wifi net.connman.Technology.SetProperty string:Powered variant:boolean:true > /dev/null 2>&1
for try in 1 2 3 4 5 6; do
    dbus-send --system --dest=net.connman /net/connman/technology/wifi net.connman.Technology.Scan > /dev/null 2>&1
    sleep 8
    for d in /var/lib/connman/wifi_*_managed_psk; do
        [ -d "$d" ] || continue
        r=$(dbus-send --system --print-reply --dest=net.connman "/net/connman/service/$(basename "$d")" net.connman.Service.Connect 2>&1 | tail -n 1)
        echo "try $try $(basename "$d"): $r"
        case "$r" in *"method return"*|*AlreadyConnected*) exit 0 ;; esac
    done
    sleep 4
done
WIFI
ip link show wlan0 2>/dev/null | grep -q "state UP" || (setsid sh /root/az01-wifi.sh < /dev/null > /root/wifi.log 2>&1 &)
# Bluetooth: Engine talks to BlueZ (org.bluez) on this bus, "NoUsableAdapter"
# without it; the adapter is the board's own hci0, left alone by Armbian
[ -x /usr/libexec/bluetooth/bluetoothd ] && launch bluetoothd /usr/libexec/bluetooth/bluetoothd -n
(sleep 5; busctl --system set-property org.bluez /org/bluez/hci0 org.bluez.Adapter1 Powered b true > /dev/null 2>&1) &
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
mkdir -p $S/run; mount --bind $S/run $R/run
mkdir -p $R/run/udev; mount -t overlay overlay -o lowerdir=/run/udev,upperdir=$UD/upper,workdir=$UD/work $R/run/udev
mount --bind $S/dt/base $R/sys/firmware/devicetree/base
mount --bind $S/interrupts $R/proc/interrupts
exec chroot $R /bin/sh /root/az01-inner.sh $PRODUCT
" > $R/root/engine.log 2>&1 &
echo "Engine started, log: $R/root/engine.log"
