#!/bin/bash
# Waits until the guest answers over SSH, meaning the boot has reached the end.
# Under TCG emulation that takes 4 to 5 minutes.
#
#     bash vm-wait.sh [minutes]     default 10
#
# The wait lives here rather than in PowerShell because ssh writes to stderr
# until sshd is ready ("kex_exchange_identification: Connection reset by
# peer"): harmless, but in PowerShell with ErrorActionPreference=Stop it turns
# fatal.
BASE="$(cd "$(dirname "$0")/.." && pwd)"
VM="$BASE/_vm"
MAXMIN="${1:-10}"

cp -f "$VM/id_vm" /tmp/id_vm; chmod 600 /tmp/id_vm

i=0
n=$((MAXMIN * 6))
while [ $i -lt $n ]; do
    if ssh -p 2222 -i /tmp/id_vm -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
           -o LogLevel=ERROR root@127.0.0.1 'echo ready' 2>/dev/null \
       | grep -q ready; then
        echo "guest ready after $((i * 10))s"
        exit 0
    fi
    if ! pgrep -x qemu-system-arm > /dev/null; then
        echo "the VM is not running"
        exit 1
    fi
    i=$((i + 1))
    [ $((i % 6)) -eq 0 ] && echo "  ...$((i / 6)) min"
    sleep 10
done
echo "timed out after $MAXMIN minutes: check $VM/boot.log"
exit 1
