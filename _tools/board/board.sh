#!/bin/bash
# The Mac side of the Tinker Board: ssh, scp and the two scripts, over the
# Ethernet cable. The board has no DHCP on that link, so it is reached by its
# IPv6 link-local address (every Linux has one, and it answers ff02::1) and,
# for the browser, by the IPv4 link-local address az01-mirror.sh assigns.
#
#     bash board.sh                 ssh shell
#     bash board.sh CMD...          run a command
#     bash board.sh cp SRC DST      copy to the board
#     bash board.sh get SRC DST     copy from the board
#     bash board.sh install         copy az01-run.sh and az01-mirror.sh to /root
#     bash board.sh start           Engine on the HDMI, and the mirror
#     bash board.sh stop
#     bash board.sh shot FILE.png   grab the HDMI output
#
# BOARD_HOST overrides the address; BOARD_IF the Mac's interface (en0).
set -e
IF="${BOARD_IF:-en0}"
H="${BOARD_HOST:-fe80::8ad7:f6ff:fec2:c5c1%$IF}"
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
    "")      exec ssh $O "root@$H" ;;
    cp)      exec scp -q $O "$2" "root@[$H]:$3" ;;
    get)     exec scp -q $O "root@[$H]:$2" "$3" ;;
    install) scp -q $O "$D/az01-run.sh" "$D/az01-mirror.sh" "root@[$H]:/root/"
             # the touch bridge, built static in the container: docker exec engine-os-emu \
             #   arm-linux-gnueabihf-gcc -O2 -w -static -o /work/_vm/uinput-touch-static /work/_tools/uinput-touch.c
             # copied alongside and renamed: the running one is busy (ETXTBSY)
             [ -f "$D/../../_vm/uinput-touch-static" ] && scp -q $O "$D/../../_vm/uinput-touch-static" "root@[$H]:/root/uinput-touch.new"
             ssh $O "root@$H" '[ -f /root/uinput-touch.new ] && mv -f /root/uinput-touch.new /root/uinput-touch; chmod +x /root/az01-run.sh /root/az01-mirror.sh /root/uinput-touch 2>/dev/null'; echo installed ;;
    start)   ssh $O "root@$H" 'bash /root/az01-run.sh && bash /root/az01-mirror.sh' ;;
    stop)    ssh $O "root@$H" 'bash /root/az01-run.sh stop; bash /root/az01-mirror.sh stop' ;;
    shot)    ssh $O "root@$H" 'ffmpeg -loglevel error -y -f kmsgrab -device /dev/dri/card0 -format bgra -i - -frames:v 1 -update 1 -vf hwdownload,format=bgra -pix_fmt rgb24 /tmp/shot.png'
             scp -q $O "root@[$H]:/tmp/shot.png" "${2:-board-shot.png}"; echo "saved: ${2:-board-shot.png}" ;;
    *)       exec ssh $O "root@$H" "$@" ;;
esac
