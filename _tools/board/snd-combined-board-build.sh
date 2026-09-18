#!/bin/bash
# Cross builds snd-combined.ko for the Tinker Board's Armbian kernel, in the
# container; board-kbuild.sh does the work.
#
#     docker exec engine-os-emu bash /work/_tools/board/snd-combined-board-build.sh
set -e
BASE="$(cd "$(dirname "$0")/../.." && pwd)"
rm -rf /opt/snd-combined-board && mkdir -p /opt/snd-combined-board
cp "$BASE/_tools/snd-combined.c" /opt/snd-combined-board/
echo 'obj-m := snd-combined.o' > /opt/snd-combined-board/Makefile
bash "$BASE/_tools/board/board-kbuild.sh" /opt/snd-combined-board "$BASE/_vm/snd-combined-board.ko"
