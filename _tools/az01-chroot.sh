#!/bin/bash
# Runs the ARM Engine OS rootfs on x86 through qemu-user plus chroot.
#
# Run as root inside WSL2 or a Linux VM:
#     apt-get install -y qemu-user-static binfmt-support
#     bash az01-chroot.sh              # interactive shell in the ARM system
#     bash az01-chroot.sh az0x-info    # run one command and exit
#
# The original image stays untouched: it is mounted read-only and writes end
# up in a tmpfs overlay.
#
# The product code is read from the device tree, which does not exist on x86,
# so we mount a tmpfs over /sys inside the chroot namespace and recreate by
# hand the NUL-terminated files the application expects.

set -e

IMG="${IMG:-$(cd "$(dirname "$0")/.." && pwd)/_extracted/rootfs.img}"
PRODUCT="${PRODUCT:-NH08}"
COMPATIBLE="${COMPATIBLE:-inmusic,nh08}"

LOWER=/mnt/az01-lower
UPPER=/tmp/az01-ovl/upper
WORK=/tmp/az01-ovl/work
ROOT=/mnt/az01

if [ "$(id -u)" != "0" ]; then
    echo "Root required." >&2
    exit 1
fi
if [ ! -f "$IMG" ]; then
    echo "Image not found: $IMG" >&2
    echo "Extract it first with az01-extract.py + xz -dc." >&2
    exit 1
fi
if [ ! -x /usr/bin/qemu-arm-static ]; then
    echo "Missing /usr/bin/qemu-arm-static (apt-get install qemu-user-static)." >&2
    exit 1
fi

mkdir -p "$LOWER" "$UPPER" "$WORK" "$ROOT"
mountpoint -q "$LOWER" || mount -o loop,ro "$IMG" "$LOWER"
mountpoint -q "$ROOT" || mount -t overlay overlay \
    -o "lowerdir=$LOWER,upperdir=$UPPER,workdir=$WORK" "$ROOT"

cp -f /usr/bin/qemu-arm-static "$ROOT/usr/bin/"

# Everything else runs in a separate mount namespace, so it unmounts itself
# when the shell exits.
CMD=("$@")
export ROOT PRODUCT COMPATIBLE
unshare -m bash -c '
    set -e
    mount --bind /proc "$ROOT/proc"
    mount --bind /dev  "$ROOT/dev"
    mount --bind /dev/pts "$ROOT/dev/pts" 2>/dev/null || true
    mount -t tmpfs tmpfs "$ROOT/sys"

    DT="$ROOT/sys/firmware/devicetree/base"
    mkdir -p "$DT/chosen"
    printf "%s\0" "$PRODUCT"            > "$DT/inmusic,product-code"
    printf "%s\0" "$COMPATIBLE"         > "$DT/compatible"
    printf "%s\0" "0123456789ABCDEF"    > "$DT/serial-number"
    printf "%s\0" "A"                   > "$DT/inmusic,az01-pcb-rev"
    printf "%s\0" "1"                   > "$DT/chosen/inmusic,internal-sd-fitted"
    printf "%s\0" "2024.01"             > "$DT/chosen/u-boot,version"

    if [ "$#" -eq 0 ]; then
        exec chroot "$ROOT" /usr/bin/qemu-arm-static /bin/busybox.nosuid sh -l
    else
        exec chroot "$ROOT" /usr/bin/qemu-arm-static /bin/busybox.nosuid sh -c "$*"
    fi
' bash "${CMD[@]}"
