#!/bin/bash
# Keeps an uncooled Tinker Board from cooking itself while Engine runs.
#
#     az01-cool.sh          start the guard (the launcher does)
#     az01-cool.sh stop
#
# The RK3288 trips its critical point at 90 C and the kernel then powers the
# board off, no warning on the screen. Two things this does, every 5 s:
#  - the CPU is capped at 1.2 GHz instead of 1.5 while Engine runs: barely
#    noticeable in Engine, a few degrees on the die
#  - above WARM the mirror is stopped (JPEG encoding is the hungriest thing
#    on the CPU), above HOT Engine itself, and both are logged; the mirror
#    comes back once it has cooled below WARM again
WARM="${WARM:-80}"
HOT="${HOT:-87}"
CAP="${CAP:-1200000}"
LOG=/root/cool.log

if [ "${1:-}" = "stop" ]; then
    pkill -f "az01-cool.sh run"; echo 1512000 > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null
    echo stopped; exit 0
fi
if [ "${1:-}" != "run" ]; then
    pkill -f "az01-cool.sh run" 2>/dev/null
    setsid bash "$0" run < /dev/null > /dev/null 2>&1 &
    echo "cooling guard: cap $((CAP/1000)) MHz, mirror off above $WARM C, Engine off above $HOT C"
    exit 0
fi

echo "$CAP" > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null
mirror_stopped=0
while true; do
    t=0
    for z in /sys/class/thermal/thermal_zone*; do
        v=$(( $(cat $z/temp 2>/dev/null || echo 0) / 1000 )); [ $v -gt $t ] && t=$v
    done
    if [ $t -ge $HOT ]; then
        echo "$(date +%T) $t C: stopping Engine" >> $LOG
        bash /root/az01-run.sh stop > /dev/null 2>&1
        bash /root/az01-mirror.sh stop > /dev/null 2>&1; mirror_stopped=1
    elif [ $t -ge $WARM ] && [ $mirror_stopped = 0 ]; then
        echo "$(date +%T) $t C: stopping the mirror" >> $LOG
        bash /root/az01-mirror.sh stop > /dev/null 2>&1; mirror_stopped=1
    elif [ $t -lt $((WARM - 5)) ] && [ $mirror_stopped = 1 ] && pidof Engine > /dev/null; then
        echo "$(date +%T) $t C: mirror back" >> $LOG
        bash /root/az01-mirror.sh > /dev/null 2>&1; mirror_stopped=0
    fi
    sleep 5
done
