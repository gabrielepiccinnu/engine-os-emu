#!/bin/bash
# Cross builds a kernel module for the Tinker Board's Armbian kernel, in the
# container, from the Armbian headers package.
#
#     board-kbuild.sh SRCDIR OUT.ko [DEPENDS]
#
# SRCDIR holds the sources and a Makefile (obj-m); OUT.ko is where the
# stripped module goes; DEPENDS is the "depends" line of the module info,
# comma separated, which is what modprobe reads to load what it needs first.
#
# The board runs 6.18.43 (Armbian 26.8.1) and the repository only keeps
# 26.8.3 (6.18.44): the headers are one patch level ahead. That kernel has
# no MODVERSIONS, so vermagic is all it checks, and the utsrelease in the
# headers is rewritten to the board's; nothing in ALSA's module ABI moves
# between two patch levels. Three host tools the package does not ship
# prebuilt are dealt with: recordmcount is compiled from its source,
# modpost's sources want generated files that are not there, so a stand-in
# writes the .mod.c the way 6.18's modpost does for a module exporting
# nothing, and devicetable-offsets is not needed for that.
set -e
SRC="$1"; OUT="$2"; export MODPOST_DEPENDS="${3:-snd-pcm,snd-rawmidi,snd}"
[ -d "$SRC" ] && [ -n "$OUT" ] || { echo "usage: board-kbuild.sh SRCDIR OUT.ko [DEPENDS]" >&2; exit 1; }
KVER="${KVER:-6.18.43-current-rockchip}"
DEB_URL="${DEB_URL:-https://apt.armbian.com/pool/main/l/linux-headers-current-rockchip/linux-headers-current-rockchip_26.8.3_armhf__6.18.44-S1efe-D5397-Pcd24-C3e9a-H8422-HK01ba-V014b-B4990-R448a.deb}"
WORK=/opt/armbian-headers

command -v arm-linux-gnueabihf-gcc > /dev/null || { echo "cross compiler missing" >&2; exit 1; }
which bison flex bc > /dev/null 2>&1 || { apt-get -qq update && apt-get -qq install -y bison flex bc libssl-dev > /dev/null; }

if [ ! -d "$WORK/usr/src" ]; then
    echo "== Armbian headers =="
    mkdir -p "$WORK" && curl -sL -o /tmp/armbian-headers.deb "$DEB_URL"
    dpkg-deb -x /tmp/armbian-headers.deb "$WORK"
fi
K=$(ls -d "$WORK"/usr/src/linux-headers-*)
sed -i "s/\"[^\"]*\"/\"$KVER\"/" "$K/include/generated/utsrelease.h"

echo "== host tools =="
cd "$K"
[ -x scripts/recordmcount ] || gcc -O2 -o scripts/recordmcount scripts/recordmcount.c
cat > scripts/mod/modpost <<'STANDIN'
#!/bin/sh
# Stand-in for modpost: an empty Module.symvers and the .mod.c 6.18's modpost
# would write (add_header, add_depends) for a module that exports nothing.
out=Module.symvers; order=modules.order
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift;; -T) order=$2; shift;; esac; shift; done
: > "$out"
for o in $(cat "$order"); do
  cat > "${o%.o}.mod.c" <<MODC
#include <linux/module.h>
#include <linux/export-internal.h>
#include <linux/compiler.h>

MODULE_INFO(name, KBUILD_MODNAME);

__visible struct module __this_module
__section(".gnu.linkonce.this_module") = {
	.name = KBUILD_MODNAME,
	.init = init_module,
#ifdef CONFIG_MODULE_UNLOAD
	.exit = cleanup_module,
#endif
	.arch = MODULE_ARCH_INIT,
};

MODULE_INFO(depends, "${MODPOST_DEPENDS:-snd-pcm,snd-rawmidi,snd}");
MODC
done
STANDIN
chmod +x scripts/mod/modpost

echo "== building =="
make -s -C "$K" M="$SRC" ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- modules
KO=$(ls "$SRC"/*.ko)
arm-linux-gnueabihf-strip --strip-debug "$KO"
cp -f "$KO" "$OUT"
echo "built: $OUT"
strings "$OUT" | grep -E "^(vermagic|depends)"
