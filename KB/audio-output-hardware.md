# Audio output hardware: what the firmware expects, and which HAT to put on the board

A note on choosing a DAC for the Tinker Board setup of the README's "On real hardware"
section. The short version: **the firmware expects no HAT at all**. The DAC is never seen by
Engine; it is the last link of a chain that starts at a virtual card, so the choice is
governed by what is wanted at the output, not by Engine.

## 1. What the firmware actually expects

On the Mixstream Pro the audio path is proprietary: the `snd-soc-inmusic-nh08` machine
driver with the `snd-soc-eta5805` codec on the RK3288's I2S, and a separate XMOS DSP
(TEARDOWN.md, section 4.1). No HAT replicates that, and none needs to.

Engine opens any ALSA card that has the right *shape* (TEARDOWN.md, section 12): one card
with a PCM playback substream, a PCM capture substream and a MIDI client, at 48 kHz, with at
least nine channels each way for the NH08 profile (eight for the Prime GO's JP07). That card
is the virtual `snd-combined`, on the board as under QEMU. Its playback carries 16 channels
of S32; of those, 0/1 are the master mix and 4/5 the same 10 dB down (booth or cue), the
rest silence.

The DAC comes in only at the end: `_tools/board/az01-audio.sh` reads the 16 channels back
off the `NH08 loop` card, keeps one pair with ffmpeg's `pan` filter and plays it with
`aplay` on whatever `hw:` it is given. So all the DAC is asked for is **stereo, 48 kHz,
preferably 32 bit**.

## 2. The HiFiBerry range, seen from this repo

| HAT | chip | status here | notes |
|---|---|---|---|
| **DAC+ Standard** | PCM5122, I2C | supported and tested, `az01-hifiberry-dtb.sh` | hardware volume and mute in `amixer`, 32 bit, RCA line out. **The one to get.** |
| DAC+ Pro | PCM5122 plus its own oscillators | should work as the Standard | the repo's device tree keeps the RK3288 as I2S master, so the oscillators go unused |
| DAC+ Zero, DAC+ Light, MiniAmp | PCM5102A, no I2C | supported, `az01-hifiberry-dtb.sh dac` | no hardware volume; the codec is the kernel's generic `spdif-dit` transmitter |
| Amp2 | TAS5756, pcm512x driver | probably fine in `plus` mode | a class D speaker amplifier, not a line output |
| DAC+ ADC, DAC+ ADC Pro | PCM5122 plus PCM1863 | the DAC yes, the ADC no | the input would need another driver and work on the chain; Engine's mic carries no real samples on the board today |
| DAC2 HD | PCM1796 plus external clocks | not supported | needs the `hifiberry-dachd` machine driver and the clock driver, built like the pcm512x one |
| Digi+, Digi2 | WM8804, S/PDIF | not supported | wm8804 driver to build, digital output only |
| DAC8x | 8 channels over four data lines | not applicable | made for the Pi 5's pins |

## 3. One data line: the limit of the RK3288 Tinker Board

The RK3288's I2S0 has four data outputs (SDO0-3), eight channels. They do not reach the
board. The Tinker Board S R2.0 schematic marks the balls `I2S_SDO1/GPIO6_A5`,
`I2S_SDO2/GPIO6_A6`, `I2S_SDO3/GPIO6_A7`, `I2S_LRCK_TX/GPIO6_A2` and `I2S_CLK/GPIO6_B0` (the
master clock) as `Is No Connect=True`: not on the header, not on a test point, not bonded to
anything. What the header carries is SCLK (pin 12), LRCK (35), SDI (38) and SDO0 (40). On
this board the I2S is stereo, and no soldering changes that.

So any HAT gives the master pair and nothing else. A second pair, channels 4/5 for a
headphone or booth feed, is a second card: a USB DAC and a second `az01-audio.sh` with
`PAIR=c4|c5`. The chain already sends to any `hw:`, so this works on the board as it is.

## 4. Boards with more data lines: the Tinker Board 2 / 2S

The Tinker Board 2 and 2S (RK3399) bring the whole of the RK3399's I2S0, an eight channel
controller, to the header (Tinker Board 2 / Tinker System 2 user manuals):

| pin | signal |
|---|---|
| 12 | I2S0_SCLK |
| 35 | I2S0_LRCK |
| 38 | I2S0_SDI0 |
| 40 | I2S0_SDO0 |
| 22 | GPIO3_D4 / I2S0_SDI1SDO3 |
| 31 | GPIO3_D5 / I2S0_SDI2SDO2 |
| 29 | GPIO3_D6 / I2S0_SDI3SDO1 |
| 37 | GPIO4_C5 / SPDIF_TX |

The three extra lines are bidirectional, each one SDO or SDI, so eight channels out, or four
out and four in, plus an S/PDIF. The `rockchip-i2s` driver already knows how:
`rockchip,playback-channels = <8>` in the device tree makes the card eight channels wide,
and the audio script could then send 0/1 and 4/5 straight through without the `pan`.

The Tinker Board 3N (RK3568) has no I2S on its header at all, per ASUS's GPIO table. The
Edge R was not checked.

Two things to weigh before ordering one:

1. **It is a port, not a swap.** Everything under `_tools/board/` is cut to the RK3288
   because it is the Mixstream Pro's own SoC: 32-bit kernel, Mali-T764, a VOP with no cursor
   plane, the stock device tree decompiled and recompiled. The Tinker Board 2 is arm64 with a
   Mali-T860. Engine (armhf) should run in compat on an arm64 kernel, but the display path,
   `snd-combined`, the DAC driver, the `kmsgrab` mirror and the thermal caps all have to be
   redone and retested.
2. **No HiFiBerry uses more than one data line**, the DAC8x apart, and that one is laid out
   for the Pi 5's pins, which are not the Tinker 2's 22/29/31. The realistic route on an
   RK3399 is two DAC+ Zero boards (PCM5102A, only BCLK, LRCK and DATA) wired by hand, one on
   pin 40 and one on pin 22.

## 5. Recommendation

DAC+ Standard (PCM5122) on the Tinker Board S: it is the one the repo already has a device
tree, a driver build and launcher support for. For a cue output, a USB DAC on channels 4/5,
before any thought of an RK3399 port.

## Sources

- [Tinker Board S R2.0 schematics](https://tinker-board.asus.com/download/TINKER_BOARD_S_R2.0_Schematics.pdf), the I2S ball connections
- [Tinker System 2 series user manual](https://tinker-board.asus.com/download/E22240_Tinker_System_2_EM_V2_WEB.pdf) and [Tinker Board 2 series user manual](https://download.discomp.cz/Asus/Tinker_Board_2_2S.pdf), the 40-pin header table
- [ASUS GPIO config table for the Tinker Board 3](https://www.asus.com/support/faq/1055442/)
- TEARDOWN.md sections 4.1 and 12, README.md "On real hardware", `_tools/board/az01-hifiberry-dtb.sh`, `_tools/board/az01-audio.sh`
