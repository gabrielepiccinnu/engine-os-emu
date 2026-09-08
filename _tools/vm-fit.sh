#!/bin/bash
# Sizes and focuses the QEMU window.
#
#     bash vm-fit.sh [width] [height]      default 640x1000
#
# It has to act on the X window: the one visible on Windows is an msrdc proxy,
# and resizing the proxy with MoveWindow does not propagate to QEMU.
# GTK enforces a minimum width of 640 (the menu bar), so the 800x1280 panel
# comes out slightly stretched: the View -> Zoom To Fit menu allows adjusting
# it to taste.
export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/mnt/wslg/runtime-dir}"

W="${1:-640}"
H="${2:-1000}"

command -v xdotool  > /dev/null 2>&1 || apt-get install -y -qq xdotool   > /dev/null 2>&1
command -v xwininfo > /dev/null 2>&1 || apt-get install -y -qq x11-utils > /dev/null 2>&1

# The search string must keep matching the QEMU window title set by vm-run.sh
# with -name.
ID=$(xdotool search --name "Numark Mixstream" 2>/dev/null | tail -n 1)
if [ -z "$ID" ]; then
    echo "QEMU window not found on display $DISPLAY"
    exit 1
fi

xdotool windowsize "$ID" "$W" "$H"
xdotool windowactivate "$ID" 2>/dev/null
sleep 1
echo "window: $(xwininfo -id "$ID" | awk '/Width|Height/{printf "%s ", $2}')"
