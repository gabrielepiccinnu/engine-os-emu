#!/bin/bash
# Measures how long Engine takes to draw, to compare the variants.
#
#     bash engine-bench.sh            rootfs drivers (softpipe)
#     MESA24=1 bash engine-bench.sh   drivers from mesa-upgrade.sh
#
# Metric: the page flips counted by the drmspy shim. Those are the frames
# actually delivered to the scanout, so they measure real drawing rather than
# CPU time. Reported values are the time to the first frame and the steady rate.
set -e
BASE="$(cd "$(dirname "$0")/.." && pwd)"
VM="$BASE/_vm"

cp -f "$VM/id_vm" /tmp/id_vm; chmod 600 /tmp/id_vm
g() { ssh -p 2222 -i /tmp/id_vm -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 \
      -o LogLevel=ERROR root@127.0.0.1 "$@"; }

MESA24="${MESA24:-}" bash "$BASE/_tools/engine-run.sh" > /tmp/bench-launch.log 2>&1
T0=$(date +%s)

# grep -c exits with 1 when it finds nothing: with "|| echo 0" that would end
# up printing two lines. awk always returns exactly one number.
flips() { g 'awk "/PageFlip.*ok/{n++} END{print n+0}" /tmp/drmspy.log 2>/dev/null'; }

FIRST=""
LAST=0
echo "t(s)  frames"
for i in $(seq 1 36); do
    sleep 10
    N=$(flips | tr -d '\r')
    T=$(( $(date +%s) - T0 ))
    printf "%4d  %5s\n" "$T" "$N"
    if [ -z "$FIRST" ] && [ "$N" -gt 0 ] 2>/dev/null; then
        FIRST=$T
        F0=$N
        TF=$T
    fi
    LAST=$N
    # steady state: 60 s after the first frame is enough
    if [ -n "$FIRST" ] && [ $T -ge $((FIRST + 60)) ]; then break; fi
done

echo
echo "first frame after: ${FIRST:-never} s"
if [ -n "$FIRST" ]; then
    D=$(( $(date +%s) - T0 - TF ))
    [ "$D" -gt 0 ] && echo "frames in the following $D s: $((LAST - F0))"
fi
echo "renderer: $(g 'grep -a -m1 -E "MESA-LOADER|GL_RENDERER|llvmpipe|softpipe|virgl" /tmp/engine.log 2>/dev/null || echo "(no matching line)"')"
echo "Engine: $(g 'pidof Engine || echo dead')"
