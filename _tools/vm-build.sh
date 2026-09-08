#!/bin/bash
# Builds an armhf QEMU VM that boots the Engine OS rootfs.
#
# Run as root in WSL2 or an x86 Linux VM:
#     apt-get install -y qemu-system-arm cpio xz-utils device-tree-compiler curl
#     bash vm-build.sh
#     bash vm-run.sh
#
# The original kernel (6.6.119-az01, Rockchip only, zero virtio) is unusable
# under QEMU: it gets replaced with the Debian armhf kernel, which has
# CONFIG_ARCH_VIRT=y and the PL011 serial built in. There virtio and ext4 are
# modules, so a minimal initramfs is needed to load them before switch_root.
#
# What it produces in _vm/:
#     rootfs-vm.img        writable copy of the rootfs, 2 GiB, patched
#     data.img             1 GiB ext4 for /data (etc and var are overlays on /data)
#     initrd.img           initramfs with static armhf busybox + virtio modules
#     virt-inmusic.dtb     QEMU virt device tree + the inmusic,* properties
#     id_vm / id_vm.pub    SSH key to get into the VM

set -e

BASE="$(cd "$(dirname "$0")/.." && pwd)"
VM="$BASE/_vm"
SRC="$BASE/_extracted/rootfs.img"
KV=6.1.0-50-armmp
KDEB=linux-image-${KV}_6.1.176-1_armhf.deb
BBDEB=busybox-static_1.35.0-4+deb12u1+b1_armhf.deb
MIRROR=http://deb.debian.org/debian/pool/main

[ "$(id -u)" = 0 ] || { echo "Root required." >&2; exit 1; }
[ -f "$SRC" ] || { echo "Missing $SRC (extract the rootfs first)." >&2; exit 1; }
mkdir -p "$VM"; cd "$VM"

echo "== 1. armhf kernel and busybox from Debian =="
[ -f "$KDEB" ]  || curl -sL -o "$KDEB"  "$MIRROR/l/linux/$KDEB"
[ -f "$BBDEB" ] || curl -sL -o "$BBDEB" "$MIRROR/b/busybox/$BBDEB"
rm -rf kdeb bbdeb && mkdir kdeb bbdeb
dpkg-deb -x "$KDEB" kdeb
dpkg-deb -x "$BBDEB" bbdeb
depmod -b kdeb "$KV"

echo "== 2. disks =="
[ -f rootfs-vm.img ] || cp "$SRC" rootfs-vm.img
if [ "$(stat -c%s rootfs-vm.img)" -lt 2000000000 ]; then
    truncate -s 2G rootfs-vm.img
    e2fsck -fy rootfs-vm.img >/dev/null 2>&1 || true
    resize2fs rootfs-vm.img >/dev/null
fi
e2label rootfs-vm.img engineos
if [ ! -f data.img ]; then
    truncate -s 1G data.img
    mkfs.ext4 -q -L data data.img
fi

echo "== 3. initramfs =="
rm -rf initramfs && mkdir -p initramfs/{bin,dev,proc,sys,newroot,modules}
cp bbdeb/bin/busybox initramfs/bin/
for a in sh mount umount insmod switch_root mkdir sleep ls cat echo; do
    ln -sf busybox "initramfs/bin/$a"
done
: > modorder.txt
for M in ext4 virtio_mmio virtio_blk virtio_net virtio_input virtio_console; do
    modprobe -d kdeb -S "$KV" --show-depends --ignore-install "$M" 2>/dev/null \
        | sed -n 's/^insmod //p' | sed 's/[[:space:]]*$//' >> modorder.txt
done
awk '!seen[$0]++' modorder.txt > modorder.tmp && mv modorder.tmp modorder.txt
i=0
while IFS= read -r m; do
    [ -n "$m" ] || continue
    cp "$m" "$(printf 'initramfs/modules/%02d_%s' $i "$(basename "$m")")"
    i=$((i+1))
done < modorder.txt

cat > initramfs/init <<'INIT'
#!/bin/sh
export PATH=/bin
mount -t proc     none /proc
mount -t sysfs    none /sys
mount -t devtmpfs none /dev
echo "[initramfs] loading the virtio/ext4 modules"
for m in /modules/*.ko*; do insmod "$m" 2>/dev/null; done
echo "[initramfs] looking for the rootfs among the virtio disks"
# virtio disk enumeration order is not guaranteed: identify the rootfs by its
# content rather than by device name
for dev in /dev/vda /dev/vdb /dev/vdc /dev/vdd; do
    [ -b "$dev" ] || continue
    if mount -t ext4 -o rw "$dev" /newroot 2>/dev/null; then
        if [ -e /newroot/lib/systemd/systemd ]; then
            echo "[initramfs] rootfs found on $dev"
            umount /proc /sys
            exec switch_root /newroot /sbin/init
        fi
        umount /newroot
    fi
done
echo "[initramfs] NO ROOTFS - emergency shell"
exec sh
INIT
chmod +x initramfs/init
( cd initramfs && find . | cpio -o -H newc --quiet ) | gzip -9 > initrd.img

echo "== 4. device tree carrying the inMusic identity =="
# 4 CPUs like the RK3288: Engine computes the CPU index for IRQ affinity
# assuming a quad core, and with 2 CPUs it asks for "CPU -2" and aborts.
# The DTB must be generated with the SAME options used to boot the VM.
qemu-system-arm -global virtio-mmio.force-legacy=false \
    -M virt -cpu cortex-a15 -smp 4 -m 2048 \
    -machine dumpdtb=virt.dtb -display none 2>/dev/null || true
dtc -I dtb -O dts virt.dtb -o virt.dts 2>/dev/null
# WARNING: do NOT add "rockchip,rk3288" to the root compatible. The kernel
# would select the Rockchip machine descriptor instead of the virt one and
# would hang before producing any serial output at all.
python3 - "$VM/virt.dts" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
if 'inmusic,product-code' not in s:
    s = s.replace('compatible = "linux,dummy-virt";',
        'compatible = "inmusic,nh08", "inmusic,az05", "linux,dummy-virt";\n'
        '\tmodel = "Numark MIXSTREAM PRO (QEMU)";\n'
        '\tinmusic,product-code = "NH08";\n'
        '\tinmusic,panel-rotation = <0x5a>;\n'
        '\tinmusic,az05-pcb-rev = "A";\n'
        '\tserial-number = "QEMU000000000000";', 1)
    open(p, 'w').write(s)
PY
dtc -I dts -O dtb virt.dts -o virt-inmusic.dtb 2>/dev/null

echo "== 5. SSH key =="
[ -f id_vm ] || ssh-keygen -q -t ed25519 -N '' -f id_vm -C engineos-vm

echo "== 6. patching the rootfs =="
R=/mnt/vmroot; mkdir -p $R
mountpoint -q $R || mount -o loop,rw rootfs-vm.img $R

cp -a "kdeb/lib/modules/$KV" "$R/lib/modules/"
rm -f "$R/lib/modules/$KV/build" "$R/lib/modules/$KV/source"
depmod -b "$R" "$KV"

# the root is mounted by the kernel; everything else stays as on the device
cat > "$R/etc/fstab" <<'FST'
proc     /proc         proc    defaults                                  0 0
devpts   /dev/pts      devpts  mode=0620,ptmxmode=0666,gid=5             0 0
tmpfs    /run          tmpfs   mode=0755,nodev,nosuid,strictatime        0 0
tmpfs    /var/volatile tmpfs   defaults                                  0 0
FST

# Hardware services must be replaced with stubs, NOT masked: data.mount has a
# Requires= on az0x-data-mkfs and systemd refuses to isolate the target if it
# is masked.
for s in engine touch-fw-update xmos-update az01-usbsata-fixer \
         az0x-data-mkfs az01-script-runner az01-power-button az01-machine-id; do
    rm -f "$R/etc/systemd/system/$s.service"
    cat > "$R/etc/systemd/system/$s.service" <<STUB
[Unit]
Description=STUB (disabled for emulation) $s

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
STUB
done

# /data as a bind of a directory on the rootfs.
# With What=/dev/disk/by-label/data systemd waits for a device unit that udev
# does not create in time (data.mount has DefaultDependencies=no and starts
# before udev): the boot ends in emergency mode. A bind has no external
# dependencies. /etc and /var are overlays with their upperdir inside /data,
# so it has to exist first.
mkdir -p "$R/data-store/system/etc/overlay" "$R/data-store/system/etc/.work" \
         "$R/data-store/system/var/overlay"  "$R/data-store/system/var/.work"
cat > "$R/etc/systemd/system/data.mount" <<'DM'
[Unit]
Description=/data as a bind on the rootfs (emulation)
DefaultDependencies=no
Conflicts=shutdown.target
Before=local-fs.target shutdown.target

[Mount]
What=/data-store
Where=/data
Type=none
Options=bind

[Install]
WantedBy=local-fs.target
DM

# serial console with autologin
mkdir -p "$R/etc/systemd/system/serial-getty@ttyAMA0.service.d"
cat > "$R/etc/systemd/system/serial-getty@ttyAMA0.service.d/autologin.conf" <<'AL'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 linux
AL
mkdir -p "$R/etc/systemd/system/getty.target.wants"
ln -sf /lib/systemd/system/serial-getty@.service \
       "$R/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service"
sed -i 's/^root:\*:/root::/' "$R/etc/shadow"

# SSH with a key
mkdir -p "$R/root/.ssh" && chmod 700 "$R/root/.ssh"
cp id_vm.pub "$R/root/.ssh/authorized_keys" && chmod 600 "$R/root/.ssh/authorized_keys"
mkdir -p "$R/etc/ssh/sshd_config.d"
printf 'PermitRootLogin prohibit-password\nPubkeyAuthentication yes\nUsePAM no\n' \
    > "$R/etc/ssh/sshd_config.d/10-vm.conf"
mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
ln -sf /lib/systemd/system/sshd.service \
       "$R/etc/systemd/system/multi-user.target.wants/sshd.service"

# virtio-gpu and virtio-input require VIRTIO_F_VERSION_1: on a legacy
# virtio-mmio transport the probe fails and the device stays in state FAILED
# (0x83), no longer recoverable at runtime. The real fix is
# -global virtio-mmio.force-legacy=false on the QEMU side (see vm-run.sh);
# here we load the modules at boot anyway.
mkdir -p "$R/etc/modules-load.d" "$R/etc/modprobe.d"
printf 'virtio_gpu\nvirtio_input\n'      > "$R/etc/modules-load.d/vm-gpu.conf"
printf 'options virtio_gpu modeset=1\n'  > "$R/etc/modprobe.d/vm-gpu.conf"

# Graphical console on tty1 with autologin: this is what shows up in the
# window. (To run Qt EGLFS the framebuffer has to be released instead, which
# engine-run.sh handles by stopping this getty and unbinding fbcon on the fly.)
rm -f "$R/etc/systemd/system/getty@tty1.service"
mkdir -p "$R/etc/systemd/system/getty.target.wants" \
         "$R/etc/systemd/system/getty@tty1.service.d"
ln -sf /lib/systemd/system/getty@.service \
       "$R/etc/systemd/system/getty.target.wants/getty@tty1.service"
cat > "$R/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<'AL'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
AL

# Engine enumerates block devices through libudev (a udev_monitor on SUBSYSTEM
# "block") and only accepts exfat / vfat / ntfs / hfsplus. The ext4 images the
# emulation needs (rootfs and /data) therefore trigger the "Incompatible
# Format" dialog when the application starts. Clearing the ID_FS_* properties
# of the ext4 devices stops Engine from recognizing them as music drives.
# The match is on the filesystem rather than the name: virtio disk ordering is
# not guaranteed. The FAT32 drive (label ENGINEOS) stays visible.
mkdir -p "$R/etc/udev/rules.d"
cat > "$R/etc/udev/rules.d/99-engine-hide-system-disks.rules" <<'UDEV'
SUBSYSTEM=="block", ENV{ID_FS_TYPE}=="ext4", ENV{ID_FS_TYPE}="", ENV{ID_FS_USAGE}="", ENV{ID_FS_LABEL}="", ENV{ID_FS_LABEL_ENC}="", ENV{ID_FS_UUID}="", ENV{ID_FS_UUID_ENC}=""
UDEV

# internal media drive in FAT32: the only one Engine is meant to see
if [ ! -f "$VM/media.img" ]; then
    truncate -s 2G "$VM/media.img"
    mkfs.vfat -F 32 -n ENGINEOS "$VM/media.img" > /dev/null
fi

cat > "$R/etc/motd" <<'MOTD'

  ============================================================
    Numark Mixstream Pro - Engine OS 5.0.4  (emulated in QEMU)
    ARM 32-bit / Rockchip RK3288 -> x86 via QEMU TCG
  ============================================================

  Useful commands:
    az0x-info                    device hardware info
    cat /etc/os-release          the distribution
    ls /usr/Engine               the DJ application
    systemctl list-units --failed
    journalctl -b | less

MOTD

sync; umount $R
echo
echo "Done. Boot it with: bash $(dirname "$0")/vm-run.sh"
