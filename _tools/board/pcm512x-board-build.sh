#!/bin/bash
# Cross builds the PCM512x codec driver (HiFiBerry DAC+, PCM5122 over I2C)
# for the Tinker Board's Armbian kernel, which does not ship it.
#
#     docker exec engine-os-emu bash /work/_tools/board/pcm512x-board-build.sh
#
# The sources are the kernel's own, from the 6.18 stable branch. The codec
# and its I2C glue are two modules upstream, one exporting to the other;
# with no real modpost here (see board-kbuild.sh) a second module could not
# resolve the first's symbols, so both go into one, snd-soc-pcm512x-i2c.ko.
set -e
BASE="$(cd "$(dirname "$0")/../.." && pwd)"
SRC=/opt/pcm512x-board
GIT="${GIT:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/sound/soc/codecs}"
BRANCH="${BRANCH:-linux-6.18.y}"
rm -rf "$SRC" && mkdir -p "$SRC"
for f in pcm512x.c pcm512x.h pcm512x-i2c.c; do
    curl -sfL -o "$SRC/$f" "$GIT/$f?h=$BRANCH" || { echo "cannot fetch $f" >&2; exit 1; }
done
cat > "$SRC/Makefile" <<'MK'
obj-m := snd-soc-pcm512x-i2c.o
snd-soc-pcm512x-i2c-y := pcm512x.o pcm512x-i2c.o
MK
bash "$BASE/_tools/board/board-kbuild.sh" "$SRC" "$BASE/_vm/snd-soc-pcm512x-i2c-board.ko" "snd-soc-core,snd-pcm,snd"
