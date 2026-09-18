#!/bin/bash
# Real audio out of Engine on the board: the master pair, off the loop
# capture of the virtual card, into a card that has a connector.
#
#     az01-audio.sh               master to the HDMI (the TV's speakers)
#     OUT=hw:OnBoard az01-audio.sh   or to the USB audio dongle
#     az01-audio.sh cue hw:Device    the headphones, on another card
#     az01-audio.sh stop [cue]    everything, or one chain
#
# Engine plays 16 channels of S32 at 48 kHz into the virtual card; device 1
# "NH08 loop", a card of its own, gives them back as a capture. Measured with a
# track playing and PFL and faders moved from the surface: channels 0/1
# carry the master mix, 2/3 the headphones (what PFL selects, silent with
# PFL off), 4/5 the booth (master 10 dB down), the rest is silence. One
# chain per output, each a process group of its own: "master" and "cue" run
# side by side, the loop card having four capture substreams. ffmpeg keeps
# the pair and writes it to aplay, which writes to the output card. Three processes
# rather than ffmpeg alone: ffmpeg's ALSA input reads 2048-frame chunks and
# its ALSA output takes a two second buffer, neither adjustable, so arecord
# reads the loop in 512-frame periods and aplay writes with the buffer set
# here, 8192 frames, 170 ms, of which the jitter of a throttled CPU eats a
# good part; ffmpeg in between only mixes the pair down.
# Both run real-time, but below Engine's own audio threads (SCHED_RR 45-49,
# pinned to cores): above them they starved them and Engine's stream died.
NAME=master
if [ "${1:-}" = "cue" ]; then NAME=cue; OUT="${2:-${OUT:-hw:Device}}"; PAIR="${PAIR:-c0=c2|c1=c3}"; fi
OUT="${OUT:-hw:HDMI}"
PAIR="${PAIR:-c0=c0|c1=c1}"
BUFFER="${BUFFER:-8192}"
# the sample format handed to the card: 16 bits is what the HDMI and the USB
# dongles take; the HiFiBerry DAC+ takes Engine's 32 as they are
case "$OUT" in *HiFiBerry*) FORMAT="${FORMAT:-s32le}" ;; *) FORMAT="${FORMAT:-s16le}" ;; esac
AFORMAT=$(echo "${FORMAT/le/_le}" | tr a-z A-Z)
LOG=/root/audio-$NAME.log

# a chain is a process group, its leader's pid in /run/az01-audio-NAME.pgid
stop_chain() { [ -f /run/az01-audio-$1.pgid ] && { kill -- -$(cat /run/az01-audio-$1.pgid) 2>/dev/null; rm -f /run/az01-audio-$1.pgid; echo "$1 stopped"; }; }
if [ "${1:-}" = "stop" ]; then
    if [ -n "${2:-}" ]; then stop_chain "$2"; else stop_chain master; stop_chain cue; fi
    # chains from before the process groups
    pkill -f "az01-audio-loop.sh" 2>/dev/null; exit 0
fi
stop_chain $NAME > /dev/null; sleep 0.3

cat > /root/az01-audio-loop-$NAME.sh <<EOF
echo \$\$ > /sys/fs/cgroup/cgroup.procs
while true; do
  chrt -r 30 arecord -q -D hw:Loop -f S32_LE -c 16 -r 48000 --period-size=512 --buffer-size=4096 -t raw \\
  | chrt -r 30 ffmpeg -loglevel warning -probesize 32 -analyzeduration 0 -blocksize 32768 \\
      -f s32le -ar 48000 -ac 16 -i - -af "pan=stereo|$PAIR" -f $FORMAT -ar 48000 - \\
  | chrt -r 30 aplay -D $OUT -f $AFORMAT -c 2 -r 48000 --buffer-size=$BUFFER --period-size=$((BUFFER/8))
  sleep 2
done
EOF
setsid bash /root/az01-audio-loop-$NAME.sh > $LOG 2>&1 < /dev/null &
echo $! > /run/az01-audio-$NAME.pgid
echo "audio $NAME: NH08 loop channels ($PAIR) -> $OUT, $AFORMAT, buffer $BUFFER frames"
