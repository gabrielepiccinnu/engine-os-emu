#!/bin/bash
# Builds a Tinker Board S device tree with a HiFiBerry DAC (PCM5102A) on the
# 40-pin header in place of the HDMI audio, and points Armbian's boot at it.
#
#     az01-hifiberry-dtb.sh          then reboot
#     az01-hifiberry-dtb.sh off      back to the stock device tree
#
# WHY A WHOLE DTB AND NOT AN OVERLAY
# The board's I2S0 (i2s@ff890000) comes out on the header at the pins the
# HiFiBerry expects from a Raspberry Pi (12 BCLK, 35 LRCLK, 40 DOUT), and the
# same I2S feeds the HDMI audio card, node "/sound". One controller serves one
# card, so that card has to go. An overlay cannot say so: "/sound" is
# ambiguous to libfdt, which takes the first child whose name matches up to
# the unit address, and that is sound@ff8b0000, the SPDIF; and the HDMI card
# has no label in the stock DTB to target by phandle. So the stock DTB is
# decompiled, the HDMI card disabled, the DAC and its card added, and the
# result compiled next to the stock one. Armbian's kernel has no PCM5102A
# driver and that chip needs none: the codec is the generic "linux,spdif-dit"
# transmitter, a DAI that takes 16 to 32 bits at any usual rate.
set -e
BASE=/boot/dtb/rk3288-tinker-s.dtb
OUT=/boot/dtb/rk3288-tinker-s-hifiberry.dtb

if [ "${1:-}" = "off" ]; then
    sed -i '/^fdtfile=/d' /boot/armbianEnv.txt; echo "stock device tree at next boot"; exit 0
fi
dtc -I dtb -O dts "$BASE" 2>/dev/null > /tmp/tinker.dts
python3 - /tmp/tinker.dts <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
# the HDMI audio card: the root-level "sound {" node, named HDMI
i = s.index('\tsound {\n')
j = s.index('\t};\n', i) + len('\t};\n')
node = s[i:j]
assert 'simple-audio-card,name = "HDMI"' in node
node = node.replace('\tsound {\n', '\tsound {\n\t\tstatus = "disabled";\n', 1)
s = s[:i] + node + s[j:]
# the DAC and its card, on the same I2S
add = '''
	hifiberry-dac {
		compatible = "linux,spdif-dit";
		#sound-dai-cells = <0x00>;
	};

	sound-hifiberry {
		compatible = "simple-audio-card";
		simple-audio-card,name = "HiFiBerry";
		simple-audio-card,format = "i2s";
		simple-audio-card,mclk-fs = <0x100>;

		simple-audio-card,cpu {
			sound-dai = <&i2s>;
		};

		simple-audio-card,codec {
			sound-dai = <&hifiberry_dac>;
		};
	};
'''
add = add.replace('\thifiberry-dac {', '\thifiberry_dac: hifiberry-dac {')
# decompiling drops the labels; the I2S node keeps its phandle, use that
m = re.search(r'\ti2s@ff890000 \{.*?\n\t\tphandle = (<0x[0-9a-f]+>);', s, re.S)
assert m, "no phandle on i2s@ff890000"
add = add.replace('<&i2s>', m.group(1))
# insert before the closing of the root node (the __symbols__ block, if any, or the end)
k = s.rfind('\n\t__symbols__ {')
if k < 0:
    k = s.rfind('\n};')
s = s[:k] + add + s[k:]
open(p, 'w').write(s)
PY
dtc -I dts -O dtb -o "$OUT" /tmp/tinker.dts 2>&1 | grep -v Warning || true
[ -s "$OUT" ] || { echo "dtc failed" >&2; exit 1; }
grep -q '^fdtfile=' /boot/armbianEnv.txt && sed -i "s|^fdtfile=.*|fdtfile=$(basename $OUT)|" /boot/armbianEnv.txt || echo "fdtfile=$(basename $OUT)" >> /boot/armbianEnv.txt
sed -i '/^user_overlays=hifiberry-dac/d' /boot/armbianEnv.txt
echo "built $OUT; fdtfile set: reboot to use it"
