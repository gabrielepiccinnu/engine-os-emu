#!/bin/bash
# Installs and starts the tablet -> touchscreen bridge (uinput-touch.c) in the
# guest.
#
#     bash touch-run.sh          start the bridge (tablet + touch together)
#     bash touch-run.sh -g       EVIOCGRAB: touch only, no mouse
#     bash touch-run.sh --tap X Y   synthetic tap at the given screen coordinates
#     bash touch-run.sh --log    show the guest's /tmp/uinput-touch.log
#
# Run this BEFORE engine-run.sh: Qt picks the touchscreen up at runtime through
# udev, but starting with the device already present removes any ambiguity.
set -e
BASE="$(cd "$(dirname "$0")/.." && pwd)"
VM="$BASE/_vm"
TOOLS="$BASE/_tools"

cp -f "$VM/id_vm" /tmp/id_vm; chmod 600 /tmp/id_vm
SSHOPT="-p 2222 -i /tmp/id_vm -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -o LogLevel=ERROR"

case "${1:-}" in
    --tap)
        ssh $SSHOPT root@127.0.0.1 "echo '$2 $3' > /tmp/tapfifo"
        echo "tap sent to $2,$3"; exit 0 ;;
    --log)
        ssh $SSHOPT root@127.0.0.1 'cat /tmp/uinput-touch.log'; exit 0 ;;
esac

arm-linux-gnueabihf-gcc -O2 -w -o /tmp/uinput-touch "$TOOLS/uinput-touch.c"
cp -f /tmp/uinput-touch "$VM/uinput-touch"
scp -P 2222 -i /tmp/id_vm -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR /tmp/uinput-touch root@127.0.0.1:/tmp/uinput-touch > /dev/null

GRAB="${1:-}"
ssh $SSHOPT root@127.0.0.1 GRAB="$GRAB" 'sh -s' <<'GUEST'
chmod +x /tmp/uinput-touch
killall uinput-touch 2>/dev/null
sleep 1

modprobe uinput 2>/dev/null
if [ ! -e /dev/uinput ]; then
    echo "ERROR: /dev/uinput missing, the kernel has no CONFIG_INPUT_UINPUT"
    exit 1
fi

# the Mixstream Pro screen is 800x1280 portrait
setsid /tmp/uinput-touch $GRAB -w 800 -h 1280 < /dev/null > /dev/null 2>&1 &
sleep 3

echo "--- input devices after the bridge ---"
awk '/^N: Name=/ { name=$0 } /^H: Handlers=/ { print "  " name " -> " $0 }' \
    /proc/bus/input/devices | sed 's/N: Name=//'

echo "--- how udev classifies them ---"
for e in /dev/input/event*; do
    t=$(udevadm info --query=property --name=$e 2>/dev/null \
        | grep -E '^ID_INPUT_(TOUCHSCREEN|MOUSE|TABLET|KEY)=' | tr '\n' ' ')
    n=$(udevadm info --query=property --name=$e 2>/dev/null \
        | sed -n 's/^NAME=//p')
    echo "  $e $n  $t"
done
GUEST

cat <<'MSG'

Bridge active. Now:
  bash engine-run.sh                 restart Engine with the touch device present
  bash touch-run.sh --tap 400 900    synthetic tap, to check it works
  bash touch-run.sh --log            events seen from the tablet and touches emitted
MSG
