#!/bin/bash
# Real audio out of Engine on the board: the master pair, off the loop
# capture of the virtual card, into a card that has a connector.
#
#     az01-audio.sh               master to the HDMI (the TV's speakers)
#     OUT=hw:OnBoard az01-audio.sh   or to the USB audio dongle
#     az01-audio.sh stop
#
# Engine plays 16 channels of S32 at 48 kHz into the virtual card; device 1
# "NH08 loop", a card of its own, gives them back as a capture. Measured with a
# track playing, channels 0/1 carry the master mix and 4/5 the same 10 dB
# down (booth or cue), the rest is silence. ffmpeg keeps 0/1 and writes
# them to aplay, which writes them to the output card. Two processes rather
# than ffmpeg alone because ffmpeg's ALSA output takes a two second buffer
# and offers no way to shrink it; aplay's is set here, 4096 frames, 85 ms.
# Both run real-time, but below Engine's own audio threads (SCHED_RR 45-49,
# pinned to cores): above them they starved them and Engine's stream died.
OUT="${OUT:-hw:HDMI}"
PAIR="${PAIR:-c0=c0|c1=c1}"
BUFFER="${BUFFER:-4096}"
LOG=/root/audio.log

if [ "${1:-}" = "stop" ]; then pkill -f "az01-audio-loop"; pkill -f "ffmpeg -loglevel warning -f alsa"; pkill -x aplay; echo stopped; exit 0; fi
pkill -f "az01-audio-loop" 2>/dev/null; pkill -f "ffmpeg -loglevel warning -f alsa" 2>/dev/null; pkill -x aplay 2>/dev/null; sleep 0.3

cat > /root/az01-audio-loop.sh <<EOF
echo \$\$ > /sys/fs/cgroup/cgroup.procs
while true; do
  chrt -r 30 ffmpeg -loglevel warning -f alsa -acodec pcm_s32le -channels 16 -sample_rate 48000 -i hw:Loop \\
    -af "pan=stereo|$PAIR" -f s16le -ar 48000 - \\
  | chrt -r 30 aplay -q -D $OUT -f S16_LE -c 2 -r 48000 --buffer-size=$BUFFER --period-size=$((BUFFER/4))
  sleep 2
done
EOF
nohup bash /root/az01-audio-loop.sh > $LOG 2>&1 &
echo "audio: NH08 loop channels ($PAIR) -> $OUT, buffer $BUFFER frames"
