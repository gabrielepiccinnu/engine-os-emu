#!/bin/bash
# Moves the VM disk images from the Windows filesystem to the Linux one, and
# brings them back when needed.
#
#     bash vm-fastdisk.sh on     copy into /opt/az01-vm (ext4) and use those
#     bash vm-fastdisk.sh off    copy back into _vm and use those again
#     bash vm-fastdisk.sh status
#
# WHY
# _vm lives on /mnt/d, that is drvfs: a 9p filesystem between the WSL2 VM and
# Windows. Sequential throughput holds up (~90 MB/s), but every request pays a
# round-trip latency, and QEMU does scattered block I/O: loading the Qt
# libraries and the QML files means thousands of small requests.
#
# vm-run.sh automatically prefers /opt/az01-vm when it exists.
#
# WARNING: with "on" the guest writes go to the copies in /opt. To bring the
# changes back to D: (Engine settings, loaded music) use "off", which copies
# them back. Stop the VM before either operation.
set -e
BASE="$(cd "$(dirname "$0")/.." && pwd)"
VM="$BASE/_vm"
FAST=/opt/az01-vm
IMGS="rootfs-vm.img data.img media.img"

running() { pgrep -x qemu-system-arm > /dev/null; }

case "${1:-status}" in
on)
    running && { echo "stop the VM first: bash vm-run.sh --stop"; exit 1; }
    mkdir -p "$FAST"
    for i in $IMGS; do
        if [ -f "$VM/$i" ]; then
            echo "  copying $i ($(du -h "$VM/$i" | cut -f1))..."
            cp -f "$VM/$i" "$FAST/$i"
        fi
    done
    echo "done: the VM will use $FAST"
    df -hT "$FAST" | tail -n 1 | sed 's/^/  /'
    ;;
off)
    running && { echo "stop the VM first: bash vm-run.sh --stop"; exit 1; }
    for i in $IMGS; do
        if [ -f "$FAST/$i" ]; then
            echo "  copying $i back to D:..."
            cp -f "$FAST/$i" "$VM/$i"
        fi
    done
    rm -rf "$FAST"
    echo "done: the VM goes back to using $VM"
    ;;
status)
    if [ -d "$FAST" ]; then
        echo "fast disks ACTIVE in $FAST"
        ls -lh "$FAST" | tail -n +2 | awk '{print "  " $9 " " $5}'
    else
        echo "disks on $VM (9p, slower)"
    fi
    ;;
*)
    echo "usage: $0 on|off|status"; exit 1 ;;
esac
