#!/bin/bash
# Cross builds snd-combined.ko for the guest kernel and installs it in the VM.
#
# Run it where the cross compiler is, which on a macOS host means the container:
#     docker exec engine-os-emu bash /work/_tools/snd-combined-build.sh
#
# Three things about this build are not obvious:
#
#  - the module must match the Debian kernel the VM boots, so it is built
#    against that kernel's headers rather than anything in the rootfs
#  - linux-kbuild is a HOST package. The armhf one holds armhf binaries, which
#    an arm64 container cannot run at all, Apple Silicon having no AArch32. The
#    arm64 kbuild is fetched for the host side and the armmp headers for the
#    target side, which is the ordinary cross arrangement
#  - Debian's kernel Makefile asks for the exact compiler it was built with,
#    arm-linux-gnueabihf-gcc-12. Any recent cross gcc links a module fine, so
#    the name is provided as a symlink rather than pinning the version
set -e

BASE="$(cd "$(dirname "$0")/.." && pwd)"
KV=6.1.0-50-armmp
KVER=6.1.176-1
MIRROR=http://deb.debian.org/debian/pool/main/l/linux
WORK=/opt/kheaders

command -v arm-linux-gnueabihf-gcc > /dev/null || {
    echo "cross compiler missing: apt-get install -y gcc-arm-linux-gnueabihf" >&2; exit 1; }

echo "== kernel headers for $KV =="
mkdir -p "$WORK" && cd "$WORK"
for f in "linux-headers-${KV}_${KVER}_armhf.deb" \
         "linux-headers-6.1.0-50-common_${KVER}_all.deb" \
         "linux-kbuild-6.1_${KVER}_arm64.deb"; do
    [ -f "$f" ] || curl -sL -O "$MIRROR/$f"
done
rm -rf x && mkdir x
for f in *.deb; do dpkg-deb -x "$f" x; done
cp -a x/usr/src/linux-headers-* /usr/src/
cp -a x/usr/lib/linux-kbuild-6.1 /usr/lib/
ln -sf "$(command -v arm-linux-gnueabihf-gcc)" /usr/local/bin/arm-linux-gnueabihf-gcc-12

echo "== building =="
rm -rf /opt/snd-combined && mkdir -p /opt/snd-combined
cp "$BASE/_tools/snd-combined.c" /opt/snd-combined/
echo 'obj-m := snd-combined.o' > /opt/snd-combined/Makefile
make -C "/usr/src/linux-headers-$KV" M=/opt/snd-combined \
     ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- modules

cp -f /opt/snd-combined/snd-combined.ko "$BASE/_vm/"
echo
echo "built: $BASE/_vm/snd-combined.ko"
echo
echo "In the guest, with the ALSA core loaded first:"
echo "  modprobe snd-pcm; modprobe snd-rawmidi; modprobe snd-seq"
echo "  insmod snd-combined.ko id=NH08 name=NH08 channels=16 rate=48000"
