#!/bin/bash
# Builds a Tinker Board S device tree with a HiFiBerry DAC+ (PCM5122) on the
# 40-pin header in place of the HDMI audio, and points Armbian's boot at it.
#
#     az01-hifiberry-dtb.sh          then reboot
#     az01-hifiberry-dtb.sh dac      the plain DAC (PCM5102A), no I2C
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
# result compiled next to the stock one. The DAC+'s PCM5122 is on I2C1, the
# header's pins 3/5, at 0x4d; its driver is not in Armbian's kernel, so
# pcm512x-board-build.sh builds it and az01-run.sh loads it. The plain DAC's
# PCM5102A needs no driver: there the codec is the kernel's generic
# "linux,spdif-dit" transmitter, a DAI that takes 16 to 32 bits at any rate.
set -e
CODEC="${1:-plus}"
BASE=/boot/dtb/rk3288-tinker-s.dtb
OUT=/boot/dtb/rk3288-tinker-s-hifiberry.dtb

if [ "$CODEC" = "off" ]; then
    sed -i '/^fdtfile=/d' /boot/armbianEnv.txt; echo "stock device tree at next boot"; exit 0
fi
dtc -I dtb -O dts "$BASE" 2>/dev/null > /tmp/tinker.dts
python3 - /tmp/tinker.dts "$CODEC" <<'PY'
import re, sys
p = sys.argv[1]; plus = sys.argv[2] != "dac"; s = open(p).read()
# the HDMI audio card: the root-level "sound {" node, named HDMI
# a root-level node ends at "\n\t};": its children close one tab deeper
i = s.index('\tsound {\n')
j = s.index('\n\t};\n', i) + len('\n\t};\n')
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
'''
if plus:
    # the PCM5122 on I2C1, fed by the header's 3.3 V; the DAC+ makes its own
    # from the 5 V pin, which is what the fixed regulator stands for
    add = '''
	hifiberry-3v3 {
		compatible = "regulator-fixed";
		regulator-name = "hifiberry-3v3";
		regulator-min-microvolt = <0x325aa0>;
		regulator-max-microvolt = <0x325aa0>;
		regulator-always-on;
		regulator-boot-on;
		phandle = <0x1e0>;
	};
'''
    i = s.index('\ti2c@ff140000 {\n')
    j = s.index('\n\t};\n', i) + 1
    node = s[i:j]
    node = node.replace('status = "disabled"', 'status = "okay"')
    node += '''
		hifiberry_dac: pcm5122@4d {
			compatible = "ti,pcm5122";
			reg = <0x4d>;
			#sound-dai-cells = <0x00>;
			AVDD-supply = <0x1e0>;
			DVDD-supply = <0x1e0>;
			CPVDD-supply = <0x1e0>;
		};
'''
    s = s[:i] + node + s[j:]
add += '''

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
if not plus:
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
