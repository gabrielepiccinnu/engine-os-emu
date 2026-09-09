#!/usr/bin/env bash
# Drives the whole Engine OS emulation from macOS (or any Docker host) through
# a privileged Linux container.
#
#     bash docker/eos.sh all        everything: firmware, image, VM, Engine
#
# or one step at a time:
#
#     fetch     download MIXSTREAMPRO-5.0.4-Update.img from inMusic and verify it
#     image     build the Linux toolchain container image
#     up        start the container (privileged, ports 6080 and 5902)
#     extract   unpack the AZ01 container and decompress the rootfs
#     build     build the armhf VM (kernel, initrd, disks, DTB, SSH key)
#     mesa      sideload the Mesa 24 drivers (llvmpipe: ~5x the frame rate)
#     boot      boot the VM and wait for the guest to answer over SSH
#     export    copy the built artifacts out of the volumes into _vm, so QEMU
#               can run on the host (see _tools/vm-run-macos.sh)
#     engine    start the Engine DJ application inside the VM
#     view      open the browser on noVNC
#     shot [f]  capture the screen to a PNG on the host
#     log       follow the guest boot log
#     applog    follow the Engine application log
#     vssh ...  run a command inside the guest (no args: interactive shell)
#     shell     shell inside the container
#     stop      stop the VM, leaving the container up
#     down      remove the container (the disk volumes survive)
#     clean     remove the container AND the disk volumes
#     status    what is running
#
# The heavy files (_extracted, _vm) live in Docker volumes rather than on the
# bind mount: QEMU does scattered small block I/O and every request would
# otherwise pay a VirtioFS round trip, the same problem vm-fastdisk.sh solves
# on WSL.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE=engine-os-emu:trixie
NAME=engine-os-emu
VOL_VM=engineos-vm
VOL_EX=engineos-extracted

FW=MIXSTREAMPRO-5.0.4-Update.img
FW_URL=https://public.inmusiccdn.com/Engine/5.0.4/RELEASE/48fd65b16041710b/MIXSTREAMPRO-5.0.4-Update.img
FW_SHA=e642aaa686138d25a4e192b4afcdb51f1730d601ef8807bd4dfafadc40d6e995

NOVNC_URL="http://localhost:6080/vnc.html?autoconnect=true&resize=scale"
VNC_URL="vnc://localhost:5902"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

running() { [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true ]; }
dex()     { docker exec "$NAME" "$@"; }
dexi()    { docker exec -i "$NAME" "$@"; }

need_up() { running || die "the container is not running: bash docker/eos.sh up"; }

sha256() {
    if command -v shasum > /dev/null; then shasum -a 256 "$1" | cut -d' ' -f1
    else sha256sum "$1" | cut -d' ' -f1; fi
}

cmd_fetch() {
    say "firmware"
    if [ -f "$REPO/$FW" ] && [ "$(sha256 "$REPO/$FW")" = "$FW_SHA" ]; then
        echo "already present and verified: $FW"
        return
    fi
    echo "downloading from inMusic (174 MiB)..."
    curl -# -L --retry 3 -o "$REPO/$FW.part" "$FW_URL"
    got="$(sha256 "$REPO/$FW.part")"
    [ "$got" = "$FW_SHA" ] || die "SHA-256 mismatch: $got"
    mv -f "$REPO/$FW.part" "$REPO/$FW"
    echo "verified: $FW"
}

cmd_image() {
    say "container image"
    docker build -t "$IMAGE" "$REPO/docker"
}

cmd_up() {
    say "container"
    if running; then echo "already running"; return; fi
    docker rm -f "$NAME" > /dev/null 2>&1 || true
    docker volume create "$VOL_VM" > /dev/null
    docker volume create "$VOL_EX" > /dev/null
    # --privileged: vm-build.sh needs loop devices to mount the rootfs image.
    docker run -d --name "$NAME" --privileged \
        -v "$REPO":/work \
        -v "$VOL_VM":/work/_vm \
        -v "$VOL_EX":/work/_extracted \
        -p 127.0.0.1:6080:6080 \
        -p 127.0.0.1:5902:5902 \
        "$IMAGE" > /dev/null
    echo "started: $NAME"
}

cmd_extract() {
    need_up
    say "unpacking the AZ01 container"
    dex test -f "/work/$FW" || die "missing $FW: bash docker/eos.sh fetch"
    dex python3 /work/_tools/az01-extract.py "/work/$FW" /work/_extracted
    say "decompressing the rootfs (xz, a few minutes)"
    dex bash -c 'xz -dc /work/_extracted/02_rootfs.bin > /work/_extracted/rootfs.img'
    dex ls -lh /work/_extracted
}

cmd_build() {
    need_up
    say "building the armhf VM"
    dex bash /work/_tools/vm-build.sh
}

cmd_boot() {
    need_up
    say "booting the VM"
    dex bash /work/_tools/vm-run.sh --web
    # Raw VNC relay, so a native client (macOS Screen Sharing) can be used
    # instead of the browser: QEMU binds VNC to 127.0.0.1 inside the container.
    dex pkill -f 'TCP-LISTEN:5902' 2> /dev/null || true
    dex sh -c 'setsid socat TCP-LISTEN:5902,fork,reuseaddr TCP:127.0.0.1:5901 > /dev/null 2>&1 < /dev/null &' || true
    echo "  browser:  $NOVNC_URL"
    echo "  VNC:      $VNC_URL"
    say "waiting for the guest (4-5 minutes under TCG)"
    dex bash /work/_tools/vm-wait.sh 15
}

cmd_mesa() {
    need_up
    say "sideloading the Mesa 24 drivers"
    dex bash /work/_tools/mesa-upgrade.sh
}

cmd_engine() {
    need_up
    # llvmpipe once mesa-upgrade.sh has run, the rootfs softpipe otherwise
    if dex test -d /work/_vm > /dev/null 2>&1 && \
       dex bash /work/_tools/vm-run.sh --ssh 'test -d /opt/mesa24' > /dev/null 2>&1; then
        say "starting Engine DJ (llvmpipe)"
        dex bash -c 'MESA24=1 bash /work/_tools/engine-run.sh'
    else
        say "starting Engine DJ (softpipe; run 'mesa' first for llvmpipe)"
        dex bash /work/_tools/engine-run.sh
    fi
}

cmd_export() {
    need_up
    say "copying the artifacts into $REPO/_vm"
    dex pgrep -x qemu-system-arm > /dev/null 2>&1 && \
        die "stop the VM first, or the disk images are copied mid-write: bash docker/eos.sh stop"
    # tar -S keeps the holes: the three images are 5 GiB apparent, about 1 GiB real
    dex tar -cS -C /work/_vm -f - \
        rootfs-vm.img data.img media.img initrd.img virt-inmusic.dtb \
        id_vm id_vm.pub drmspy.so uinput-touch | tar -x -C "$REPO/_vm"
    docker cp "$NAME:/work/_vm/kdeb/boot/vmlinuz-6.1.0-50-armmp" "$REPO/_vm/"
    du -sh "$REPO/_vm" | sed 's/^/  /'
    echo "now: bash _tools/vm-run-macos.sh"
}

cmd_view()  { command -v open > /dev/null && open "$NOVNC_URL" || echo "$NOVNC_URL"; }
cmd_log()   { need_up; dex tail -f /work/_vm/boot.log; }
cmd_applog(){ need_up; dex bash /work/_tools/vm-run.sh --ssh tail -f /tmp/engine.log; }
cmd_shell() { need_up; docker exec -it "$NAME" bash; }

cmd_vssh() {
    need_up
    if [ $# -eq 0 ]; then docker exec -it "$NAME" bash /work/_tools/vm-run.sh --ssh
    else dex bash /work/_tools/vm-run.sh --ssh "$@"; fi
}

cmd_shot() {
    need_up
    local out="${1:-$REPO/screen.png}"
    dex bash /work/_tools/vm-run.sh --shot /tmp/screen.ppm
    dex python3 /work/_tools/ppm2png.py /tmp/screen.ppm /tmp/screen.png
    docker cp "$NAME:/tmp/screen.png" "$out"
    echo "saved: $out"
}

cmd_stop()  { running && dex bash /work/_tools/vm-run.sh --stop || echo "container not running"; }
cmd_down()  { docker rm -f "$NAME" > /dev/null 2>&1 && echo "container removed" || echo "no container"; }
cmd_clean() { cmd_down; docker volume rm "$VOL_VM" "$VOL_EX" > /dev/null 2>&1 && echo "volumes removed" || true; }

cmd_status() {
    say "status"
    if running; then
        echo "container: up"
        dex pgrep -x qemu-system-arm > /dev/null 2>&1 \
            && echo "VM:        running   -> $NOVNC_URL" || echo "VM:        stopped"
        dex bash /work/_tools/vm-run.sh --ssh 'pidof Engine > /dev/null && echo "Engine:    running" || echo "Engine:    not running"' 2>/dev/null || true
    else
        echo "container: down"
    fi
    [ -f "$REPO/$FW" ] && echo "firmware:  present" || echo "firmware:  missing"
}

cmd_all() {
    cmd_fetch; cmd_image; cmd_up; cmd_extract; cmd_build; cmd_boot; cmd_mesa; cmd_engine
    cat <<MSG

Everything is up. Engine takes another 1-2 minutes to draw its first frame.

  Watch:   $NOVNC_URL
  or:      open $VNC_URL
  App log: bash docker/eos.sh applog
  Capture: bash docker/eos.sh shot engine.png

MSG
}

case "${1:-help}" in
    fetch|image|up|extract|build|mesa|boot|engine|export|view|log|applog|shell|shot|stop|down|clean|status|all)
        c="$1"; shift; "cmd_$c" "$@" ;;
    vssh) shift; cmd_vssh "$@" ;;
    *)    sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d' ;;
esac
