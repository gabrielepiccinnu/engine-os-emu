#!/bin/bash
# Mirrors the board's display to the LAN as an MJPEG stream, straight from the
# DRM scanout buffer, so whatever Engine draws on the HDMI is what you see.
#
#     az01-mirror.sh          serve on http://169.254.41.200:8090/
#     az01-mirror.sh stop
#
# ffmpeg's kmsgrab reads the framebuffer the display is scanning out (the
# same AR24 GBM buffer Engine flips), hwdownload copies it to the CPU, and
# the JPEG encoder is what limits the rate on the RK3288: 1920x1080 at ~6-8
# fps, half that size at more. Every frame is flushed as soon as it is
# encoded (nobuffer, flush_packets), or the muxer sits on a few of them and
# the picture trails the screen by a second. It is a mirror, not a remote
# desktop by itself: remote-web.py adds the touch.
# 640 px, asked at 8 fps and delivered at about 5: the JPEG encoding runs on
# the CPU, some 150 ms a frame with the CPU capped, and together with Engine
# it is enough heat to take an uncooled board to thermal shutdown at 960 px.
# Raise both on a board with a heatsink.
#
# On latency, measured: the touch reaches Engine in ~20 ms, the capture and
# encode cost ~150 ms, the network nothing; what is left of the 0.5-1 s a
# tab switch takes to show up is Engine itself, throttled to 816 MHz by the
# thermal trip at 75 C. The picture is only as quick as the board is cool.
#
# The capture costs a core: hwdownload copies each 1280x800 frame out of
# the scanout buffer, uncached memory, before the scale and the encode. At
# 8 fps that was 96% of one, and with Engine decoding a Bluetooth stream on
# top the audio chains, real-time or not, underran twenty times a minute;
# with the mirror off, never. So the mirror runs SCHED_IDLE, which is only
# what nothing else wants, and at 5 fps.
FPS="${FPS:-5}"
SCALE="${SCALE:-640:-1}"
PORT="${PORT:-8090}"
ADDR="${ADDR:-169.254.41.200}"

# the restart loop and ffmpeg both carry "kmsgrab" on their command lines
if [ "${1:-}" = "stop" ]; then pkill -f "kmsgrab"; echo stopped; exit 0; fi

# an IPv4 the Mac can reach over the cable, link-local like its own
ip addr show dev end0 | grep -q "$ADDR" || ip addr add "$ADDR/16" dev end0
pkill -f "kmsgrab" 2>/dev/null; sleep 0.5

nohup chrt -i 0 sh -c "while true; do
  ffmpeg -loglevel error -fflags nobuffer -flags low_delay -thread_queue_size 2 \
    -f kmsgrab -device /dev/dri/card0 -format bgra -framerate $FPS -i - \
    -vf 'hwdownload,format=bgra,scale=$SCALE' -c:v mjpeg -q:v 8 -threads 1 -fps_mode passthrough \
    -max_delay 0 -muxdelay 0 -max_interleave_delta 0 \
    -f mpjpeg -flush_packets 1 -listen 1 'http://0.0.0.0:$PORT/'
  sleep 1
done" > /root/mirror.log 2>&1 &
echo "mirror: http://$ADDR:$PORT/   ($FPS fps, scale $SCALE)"
