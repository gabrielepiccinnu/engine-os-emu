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
# fps, half that size at more. It is a mirror, not a remote desktop: input
# comes from the mouse on the board or from the web surface.
# 5 fps at 800 px: the JPEG encoding runs on the CPU, and together with
# Engine it is enough heat to take an uncooled board to thermal shutdown at
# 8 fps and 960 px. Raise both on a board with a heatsink.
FPS="${FPS:-5}"
SCALE="${SCALE:-800:-1}"
PORT="${PORT:-8090}"
ADDR="${ADDR:-169.254.41.200}"

if [ "${1:-}" = "stop" ]; then pkill -f "ffmpeg -loglevel error -f kmsgrab" ; echo stopped; exit 0; fi

# an IPv4 the Mac can reach over the cable, link-local like its own
ip addr show dev end0 | grep -q "$ADDR" || ip addr add "$ADDR/16" dev end0
pkill -f "ffmpeg -loglevel error -f kmsgrab" 2>/dev/null; sleep 0.5

nohup sh -c "while true; do
  ffmpeg -loglevel error -f kmsgrab -device /dev/dri/card0 -format bgra -framerate $FPS -i - \
    -vf 'hwdownload,format=bgra,scale=$SCALE' -c:v mjpeg -q:v 6 -f mpjpeg -listen 1 \
    'http://0.0.0.0:$PORT/'
  sleep 1
done" > /root/mirror.log 2>&1 &
echo "mirror: http://$ADDR:$PORT/   ($FPS fps, scale $SCALE)"
