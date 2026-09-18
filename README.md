# engine-os-emu

Reverse engineering of inMusic's **AZ01** firmware container, and booting **Engine OS** (the
system that runs on the Numark Mixstream Pro) end to end under QEMU on an x86 machine.

The container format was decoded from scratch, the ARM rootfs extracted, and the whole system
brought up under emulation until the Engine DJ interface rendered on screen and responded to
touch input. [TEARDOWN.md](TEARDOWN.md) is the full write-up: container layout, kernel, device
tree, boot chain, and every obstacle that had to be diagnosed along the way.

No firmware is included in this repository. See [Obtaining the firmware](#obtaining-the-firmware).

## Status

| Goal | Result |
|---|---|
| Extracting the firmware from the AZ01 container | done, SHA-1 verified |
| Running ARM binaries on x86 (qemu-user chroot) | done |
| Full Engine OS boot under QEMU (systemd, network, SSH) | done |
| Device console visible and interactive in a window | done, WSLg/GTK |
| Product identification (injected device tree) | done, NH08 / AZ05rA |
| virtio GPU plus DRM/KMS inside the VM | done |
| Engine application startup (Qt, QML, SceneGraph, MIDI) | done |
| **Engine DJ graphical interface on screen** | **working** |
| "Incompatible Format" dialog at startup | removed with a udev rule |
| **Interface navigable with mouse and touch** | **working** |
| Audio, jog wheels | not possible, the physical hardware is absent |
| **Loading and playing a track** | **working**, through a virtual control surface |

![Engine DJ running in a native window](_vm/window-native.png)

## Obtaining the firmware

The update image is proprietary inMusic material and is **not** distributed here. You have to
download it yourself from the manufacturer:

1. Get the Mixstream Pro updater for Engine DJ OS 5.0.4 from the official Numark support site:
   [Engine DJ Updates and Releases](https://support.numark.com/en/support/solutions/folders/69000636315),
   see also [How to Update Engine DJ OS](https://support.numark.com/en/support/solutions/articles/69000833677-numark-how-to-update-engine-dj-os).
2. The download is a Windows updater executable. The `.img` container is embedded in it and is
   written out when the updater runs.
3. Place `MIXSTREAMPRO-5.0.4-Update.img` in the root of this repository.

Confirm you have the same input this teardown was written against:

```
MIXSTREAMPRO-5.0.4-Update.img    182367344 bytes
  SHA-256  e642aaa686138d25a4e192b4afcdb51f1730d601ef8807bd4dfafadc40d6e995

Mixstream Pro 5.0.4 Updater.exe  175729032 bytes
  SHA-256  86e375d555b862b375577fcb1b45e5310b34740af60265a0aa45f85723ad8998
```

A different firmware version will still extract, since the container parser is generic, but the
offsets, hashes and log excerpts quoted in the teardown refer to 5.0.4.

## Quickstart

Everything runs on an x86 Linux host. WSL2 on Windows is what this was developed on. The steps
below need root, because they mount images and use loop devices.

```bash
apt-get install -y qemu-system-arm qemu-user-static binfmt-support \
                   cpio xz-utils device-tree-compiler curl gcc-arm-linux-gnueabihf

# 1. Unpack the AZ01 container and decompress the rootfs
python3 _tools/az01-extract.py MIXSTREAMPRO-5.0.4-Update.img _extracted
xz -dc _extracted/02_rootfs.bin > _extracted/rootfs.img

# 2. Build the VM. Downloads the Debian armhf kernel and busybox, builds the
#    disks and the patched device tree, generates the guest SSH key.
bash _tools/vm-build.sh

# 3. Boot it, then start the Engine application inside it
bash _tools/vm-run.sh
bash _tools/engine-run.sh
```

Then watch it, either in the browser at `http://localhost:6080/vnc.html?autoconnect=true&resize=scale`,
or in a native window on the Windows desktop:

```powershell
powershell -File _tools\vm-window.ps1
```

The native window is considerably more responsive than noVNC, because it skips the encode,
websocket and canvas redraw round trip on every frame.

## Running it on macOS, or on any non-Linux host

The steps above need a Linux host: loop devices to patch the rootfs image, an armhf cross
compiler for the shims, and root. `docker/` packages all of that in a privileged Debian
container, so the host only has to run Docker. Any daemon that allows privileged containers will
do; `brew install colima docker && colima start --cpu 4 --memory 8` is enough and needs no
administrator password. On Apple Silicon the container itself is native arm64 and only the armhf
guest is emulated.

```bash
bash docker/eos.sh all
```

That downloads and verifies the firmware, builds the container image, unpacks the container,
builds the VM, boots it, and starts Engine. Individual steps (`fetch`, `image`, `up`, `extract`,
`build`, `boot`, `engine`, `shot`, `vssh`, `status`, `stop`, `clean`) can be run on their own;
`bash docker/eos.sh` with no argument lists them.

There is no X11 in the container, so the display is VNC: the browser at
`http://localhost:6080/vnc.html?autoconnect=true&resize=scale`, or a native client at
`vnc://localhost:5902` (on macOS, Screen Sharing), which is the more responsive of the two.

### Running QEMU on the host instead

The container is only needed to *build*. Running the VM wants nothing from it, so QEMU can go on
the host and the browser out of the loop entirely:

```bash
brew install qemu
bash docker/eos.sh export        # copies the artifacts out of the Docker volumes
bash _tools/vm-run-macos.sh          # VNC on 127.0.0.1:5903
open vnc://:engineos@localhost:5903  # Screen Sharing
bash _tools/engine-run.sh            # as usual, over SSH
```

The VNC server has a password, and it is in that URL. QEMU with no password
offers exactly one security type, "None", and Apple's Screen Sharing will not use it: it asks for
a password for "localhost" that nothing can satisfy, on every connection. Offering VNC
authentication instead is what makes that client work. It guards a socket bound to 127.0.0.1, so
it is there to satisfy the client rather than to protect anything, and VNC authentication is DES
based and takes 8 characters at most. `VNC_PASSWORD` overrides it. The same is true of the
container's `vnc://localhost:5902`, which has no password set: there the browser is the viewer.

`engine-run.sh` reuses the armhf shims the build left in `_vm` when there is no cross compiler,
so it works unchanged on the host.

For something to double click, `bash _tools/mac-app.sh` builds `Engine OS.app` around exactly
those scripts, with no logic of its own. It starts the VM, waits for the guest, opens the viewer
and starts Engine, reporting each step as a notification because an app launched from Finder has
nowhere to print. Launching it again is safe: it checks whether the VM is up and whether Engine
is still alive, and does only what is missing.

### Sharing a folder from the Mac

Music otherwise has to be copied into `media.img`, the FAT32 image Engine sees as its
`ENGINEOS` drive. A folder on the host can be handed to the guest instead, live:

```bash
SHARE=~/Music/DJ bash _tools/vm-run-macos.sh      # virtio-9p, mount tag "share"
MESA24=1 SHARE_NAME=Music bash _tools/engine-run.sh
SHARE=~/Music/DJ bash _tools/mac-app.sh           # or bake it into the app
```

The folder appears in Engine's **Folder** view as `ENGINEOS > Music`, and files added on the
Mac while Engine runs show up on the next visit to the folder, since 9p reads through to the
host on every access. Engine keeps its database on `media.img`, as before.

It is a folder inside the ENGINEOS drive rather than a source of its own, and that is not a
shortcut. Engine does not look at the filesystem for its sources: it asks `edisksd` over
D-Bus, and `edisksd` enumerates block devices that udev has labelled with a filesystem, so a
9p mount is invisible to it. `engine-run.sh` therefore bind-mounts the share into
`/media/ENGINEOS` once `edisksd` has mounted that drive. QEMU's `vvfat` driver, which exposes a
folder *as* a block device, does make a second source appear, but its FAT32 support is untested
by its own admission and in practice the volume was corrupt within seconds of Engine writing
its library to it (`fat_get_cluster: invalid start cluster`), and one file on the host came
back modified. Do not use it in write mode.

This is not faster. Measured at the device resolution it lands on 193 frames against the
container's 191 to 209, so the Docker VM layer costs nothing worth measuring; what it removes is
the encode, websocket and canvas redraw on every frame, which is the part that actually feels
slow at 3 fps.

`--cocoa` runs QEMU's own window instead, and is the obvious thing to want, but on a Retina
screen the guest comes up at 640x400 whatever mode is asked for. The virtio-gpu driver takes its
preferred mode from the size the host reports for the display, Qt EGLFS picks the preferred one,
and QEMU's Cocoa UI reports the window in points rather than pixels, so a 2x screen halves it.
The framebuffer console still shows the full size, which makes it easy to miss. `edid=off` does
not help, and neither does asking for a doubled mode. Over VNC nothing reports a display size,
the guest keeps 1280x800, and the interface is whole.

`_extracted` and `_vm` are kept in Docker volumes rather than on the bind mount. QEMU does
scattered small block I/O and every request would otherwise pay a VirtioFS round trip: the same
problem `vm-fastdisk.sh` solves on WSL.

To inspect the ARM userland without booting anything, there is also a qemu-user chroot:

```bash
bash _tools/az01-chroot.sh            # interactive shell in the ARM system
bash _tools/az01-chroot.sh az0x-info  # or run a single command
```

## Rendering performance (optional)

Drawing is done entirely in software on an emulated ARM CPU, so it is slow. Two things help, and
neither is obvious from the file names alone:

```bash
bash _tools/vm-fastdisk.sh on       # move the disk images onto ext4
bash _tools/mesa-upgrade.sh         # sideload a Mesa build that has llvmpipe and virgl
MESA24=1 bash _tools/engine-run.sh  # run Engine against it
bash _tools/engine-bench.sh         # compare, by counting DRM page flips
```

`vm-fastdisk.sh` exists because `_vm` normally sits on drvfs, the 9p bridge between WSL2 and
Windows. Sequential throughput is fine there, but every request pays a round trip, and QEMU does
scattered small block I/O: loading the Qt libraries and the QML files means thousands of small
requests.

**Caveat:** while fast disks are active, guest writes go to the copies under `/opt/az01-vm`. Run
`bash _tools/vm-fastdisk.sh off` to copy them back to `_vm`. Stop the VM before either operation.

`mesa-upgrade.sh` exists because the rootfs ships Mesa 24.0.7 without libLLVM, so
`kms_swrast_dri.so` only contains softpipe, the reference rasterizer. Mesa also looks for a virgl
driver for QEMU's virtio-gpu, fails to find it, and falls back. The script installs the Ubuntu
24.04 armhf drivers under `/opt/mesa24` and leaves the originals untouched as a fallback.

It is worth the trouble, and it is the only thing that is. Measured with `engine-bench.sh`, in
the container on an M-series Mac:

| configuration | first frame | frames in the next 60 s |
|---|---|---|
| softpipe (rootfs drivers) | 42 s | 29 |
| **llvmpipe** (`/opt/mesa24`) | 31 s | 165 - 209 |
| llvmpipe, 8 vCPUs | 71 s | 86 |
| llvmpipe, `tb-size=1024`, `cache=unsafe` | 31 s | 205 |
| llvmpipe, `LP_NATIVE_VECTOR_WIDTH=256` | 31 s | 188 |
| llvmpipe, scanout at 640x400 | 31 s | 636 - 764 |

Read that table with the spread in mind: repeated runs of the *same* configuration land anywhere
between 165 and 209 frames, so anything inside ~25% is noise.

Where the time actually goes settles which knobs can matter at all. Summing the per-thread CPU
time of the Engine process:

| thread | share |
|---|---|
| `llvmpipe-0..3` | ~95% |
| `SceneGraph` | 3% |
| `EMain` and everything else | 2% |

Rasterisation is the whole cost, and the four rasterizer threads are evenly loaded, so only two
things can move the number: fewer pixels, or moving the rasterising off the emulated CPU.

- **llvmpipe instead of softpipe: about 6x.** The one change worth making.
- **Fewer pixels scale almost exactly.** A 640x400 scanout is a quarter of the pixels and gives
  3.3x to 3.8x the frames. It is *not* offered as a default: Engine lays its interface out in
  fixed pixels for the 800x1280 panel, so a smaller scanout clips the interface rather than
  scaling it, and the sidebar loses entries. `XRES`/`YRES` are there for when responsiveness
  matters more than seeing all of it.
- **More vCPUs make it worse.** llvmpipe runs one rasterizer thread per guest CPU, so 8 looks
  like the obvious next step. It halves the frame rate and doubles the time to first frame: QEMU's
  multi-threaded TCG pays more in cross-CPU synchronisation than the extra threads bring in. The
  host is not the constraint either, 4 vCPUs already leave it 70% idle.
- `tb-size`, `cache=unsafe` and a 256-bit llvmpipe vector width all come out inside the noise.

`vm-run.sh` takes `SMP`, `MEM`, `TB`, `CACHE`, `XRES` and `YRES` from the environment, and
`engine-run.sh` takes `EXTRA_ENV`, so the same comparison can be repeated on other hardware
without editing anything.

## Why this cannot be made fast

The structural fix would be **virgl**, which hands the guest's OpenGL to the host GPU
(`vm-run.sh --gl`). It needs a DRM render node, so it wants real Linux with a GPU. In a container
on macOS the hypervisor's kernel carries no GPU driver at all, `/dev/dri` does not exist and
neither `vgem` nor `vkms` can be loaded, so QEMU's `egl-headless` refuses to start with *"no drm
render node available"*.

The other half of the answer is the CPU. [cdj3k-emu](https://github.com/nsaintot/cdj3k-emu),
which emulates a comparable device, runs at native speed on Apple Silicon because its target is
an **aarch64** SoC: it can use Hypervisor.framework and never enters TCG. The Mixstream Pro is a
32-bit ARMv7 device, and Apple Silicon cores do not execute AArch32 at all, not even in userspace.
There is no hardware virtualisation path for this firmware on that host, so the emulated CPU is a
floor rather than a tuning problem, and software rasterising a 1 megapixel Qt scene on top of it
is what the frame rate reflects.

Two things about that sideload are less obvious than they look, and both are handled by the
script:

- **Only the `noble` release pocket.** noble shipped Mesa 24.0.5, the same series as the rootfs,
  but `noble-updates` has since moved to the 25.x HWE stack. From 24.3 on, Mesa replaced the
  classic DRI megadriver with `libdril_dri.so`, whose entry points the guest's own libEGL cannot
  bind: Engine dies at startup on *"did not find extension DRI_Mesa version 1"*.
- **The build string is rewritten.** Since 24.0, libEGL compares the driver's Mesa version with
  its own using `strcmp`, and the distributions stamp the full package version into it. Ubuntu's
  `24.0.5-1ubuntu1` can therefore never satisfy a Yocto `24.0.7`, and no Ubuntu release ever
  shipped 24.0.7 to begin with. The script rewrites the string in the staged drivers in place,
  same length, NUL padded. The check guards the DRI interface, which does not change between
  maintenance releases of one stable series.

## Loading a track: the virtual control surface

Engine's touchscreen has no gesture that loads a track into a deck. On the device that is a
button, LOAD is MIDI from the control surface's microcontroller, and so are PLAY, CUE and the
browse encoder. Without a surface the library can be browsed and previewed and nothing else,
and a touch on a track that Engine's own database still lists but that no longer exists gives
the `FILE_DOES_NOT_EXIST` in the log, not a loading bug.

`_tools/snd-combined.c` provides the surface. It is the virtual sound card of section 12 of
the teardown with a second card added, called `Control Surface` like the real UART port, and
that card is a crossover: whatever is written to its second MIDI device arrives as input on the
first, the one Engine opens. Three things had to be learnt from Engine before it would bind its
assignment file to that port, and the module handles all three:

- Engine sends a MIDI Identity Request to every port and binds nothing until one answers with
  the reply its `KnownDevices.xml` expects, `7E ?? 06 02 00 01 3F 3F ...`: inMusic's
  manufacturer id and family `3F`. It asks three times in the first half minute and then stops.
  The module answers on the spot.
- The last four free bytes of that reply are read as the surface's firmware version, and it has
  to be **equal** to the one shipped in `/usr/Engine/Firmware/NH08 Controller/firmware.json`,
  1.0.0.49. Newer is as bad as older: `version mismatch; starting updater`, and Engine quits into
  the firmware updater. `identity=` on the module changes the bytes for another image.
- Engine pairs an output port with whichever input answers first. If the inject device had an
  input side it would get the request echoed into it and win that race, so it has none.

```bash
docker exec engine-os-emu bash /work/_tools/snd-combined-build.sh   # once, in the container
docker cp engine-os-emu:/work/_vm/snd-combined.ko _vm/
MESA24=1 bash _tools/engine-run.sh      # loads the card before Engine when the .ko is in _vm
bash _tools/surface.sh browse 2         # the browse encoder, two steps down
bash _tools/surface.sh push             # enter the folder
bash _tools/surface.sh load 1           # LOAD deck 1: analysis, waveform, beatgrid
bash _tools/surface.sh play 1
```

`surface.sh` takes its note and channel numbers from the product's own assignment file in the
rootfs, and `raw`, `note` and `cc` send anything else.

The whole surface is also a web page, `python3 _tools/surface-web.py`, which opens
`http://127.0.0.1:8808/`: two decks with jog wheel, pitch slider, pads and transport, the mixer
with EQ, faders, crossfader, FX and the browse encoder, every control sending what the real
surface's microcontroller sends. The server keeps one ssh session open with `cat` writing to the
inject device, and the bytes go down that pipe raw: no process per message on either side, which
matters when a knob turn is a few hundred CCs a second under emulation. `HOST=0.0.0.0` makes it
reachable from a phone or tablet on the LAN, which is the closest thing to the device itself.

It lights up too. Everything Engine writes to the surface, the LED notes and the VU meter CCs,
can be read from `/proc/asound/Surface/monitor`, a blocking stream the module keeps for exactly
this: a MIDI port would be one more thing for Engine to open and pair, a proc file is invisible to
it. The server reads it over a second ssh session and pushes each change to the page as a
server-sent event, so PLAY glows while the deck runs, CUE blinks in time, the pads and pad modes
take the colours Engine gives them, and the two VU meters bounce with the track. There is still no audio: the card's PCM
carries no samples, so the deck plays into nothing, but everything Engine does around a playing
track, analysis, waveform, beatgrid, key, time, is there to see.

## On real hardware: an ASUS Tinker Board

The Mixstream Pro is an RK3288, and so is the Tinker Board. With the rootfs unpacked into
`/opt/az01` on an Armbian SD card, Engine runs there **natively**, on Armbian's kernel, with the
Mali T760 driven by mainline panfrost, which is the driver the rootfs's own Mesa carries
(`panfrost_dri.so` sits in `/usr/lib/dri`, virtio-gpu never did). No drmspy, no llvmpipe: the GPU
draws, and at whatever the HDMI display offers, 1920x1080 included.

```bash
bash _tools/board/board.sh install    # az01-run.sh and az01-mirror.sh to /root on the board
bash _tools/board/board.sh start      # Engine on the HDMI, mirror at http://169.254.41.200:8090/
bash _tools/board/board.sh shot x.png # the HDMI output, from the DRM scanout buffer
```

`az01-run.sh` is `runengine` from the rootfs, done from a chroot in its own mount namespace,
with what the board lacks stood in for: the product identity is a copy of the live device tree
with `inmusic,product-code` and its neighbours added, bind-mounted over the real one; the control
surface UART that Engine pins to a CPU is the console UART renamed in a copy of
`/proc/interrupts`; the framebuffer console is unbound so Engine can become DRM master; a system
D-Bus runs inside the chroot so `edisksd` and the rest are reachable. One thing was not
obvious: Armbian's kernel has `RT_GROUP_SCHED`, and under cgroup v2 an ssh session's scope is
refused `SCHED_FIFO`, which Engine treats as fatal for its audio thread. The launcher moves
itself into the root cgroup first.

The surface is there too: `_tools/board/snd-combined-board-build.sh` builds the same module
against Armbian's kernel (its headers are one patch level ahead of the board and the package
ships no host tools, both dealt with in the script), the launcher loads it, and Engine
identifies the surface and takes the audio card exactly as it does under QEMU. With
`BOARD=1 python3 _tools/surface-web.py` the web surface points at the board and carries the
board's display on top, with touch: one page for the screen, the buttons and the LEDs.
`_tools/board/remote-web.py` is the display alone.

A USB stick is a source as on the device: `edisksd` runs in the chroot too, its D-Bus service
file being systemd-only (`Exec=/bin/false`). What it must not see is Armbian's own ext4 SD card,
or Engine puts up "Incompatible Format"; the udev database it reads is Armbian's and its
`ID_FS_*` properties are what mounts Armbian's root at boot, so it is not edited: the chroot
gets an overlay of it in which the ext4 and swap entries carry no filesystem, and a stick plugged
in later shows through from below.

And it has sound. The virtual card's playback comes out again on a third card, `NH08 loop`,
a capture returning the sixteen S32 channels Engine writes, clocked by the same hrtimer (the
period in nanoseconds: truncated to microseconds it ran 0.006% fast, an underrun every five
minutes). `_tools/board/az01-audio.sh` reads it, keeps channels 0/1, which carry the master
mix (4/5 are the same 10 dB down, the rest silence), and plays them through `aplay` on the HDMI
or a USB card with an 85 ms buffer. Three things had to be found out the hard way: Engine opens
every PCM of a card as `hw:<card>`, so the loop must be a card of its own or Engine reopens its
own device and gives up; a late writer must still get its period interrupt, or Engine, which
paces itself on it, waits for the clock and the clock for Engine; and whatever carries the
audio out must run below Engine's own SCHED_RR 45-49 audio threads, or it starves them.

A HiFiBerry DAC+ on the 40-pin header is the better output: a PCM5122, 32 bits, line level,
no USB in the way. Its pins are the Raspberry Pi's, and on the Tinker Board those carry I2S0,
the same controller that feeds the HDMI audio; one controller, one card, so the HDMI card has
to make way. An overlay cannot say so: the HDMI card's node is `/sound`, which libfdt resolves
to `sound@ff8b0000` (the SPDIF) first, and the node has no label to target instead.
`_tools/board/az01-hifiberry-dtb.sh` decompiles the stock device tree, disables the HDMI card,
enables I2C1 (header pins 3/5) with the PCM5122 at `0x4d` on it and a `simple-audio-card` of
its own on the I2S, compiles the result next to the stock DTB and sets `fdtfile` in
`armbianEnv.txt`. Armbian's kernel does not carry the codec driver, so
`_tools/board/pcm512x-board-build.sh` builds it from the kernel's own sources, the two upstream
modules folded into one (`board-kbuild.sh` has no real modpost, so one module could not
resolve another's exports), and the launcher loads it when the DAC is in the device tree. After
a reboot the card is `hw:HiFiBerry`, with the chip's own volume and mute in `amixer`, and
`AUDIO_OUT=hw:HiFiBerry board.sh start` sends the master there as S32. For the plain DAC
(PCM5102A, no I2C) `az01-hifiberry-dtb.sh dac` uses the kernel's generic transmitter instead.

For what it is worth, the device's own device tree says how fast the real unit runs: the CPU up
to 1608 MHz on demand, the GPU pinned at 400 MHz (its table ends there), and no passive thermal
trip at all, only a critical one at 113 C. The launcher tops the GPU at 400 like the device; the
CPU cap is the bare board's problem, not Engine's.

Two things the board taught: Wi-Fi works only with ConnMan and wpa_supplicant started in the
chroot (Engine talks to `net.connman`, nothing else), and an RK3288 with no heatsink powers
itself off on temperature within the hour if the GPU is pinned to `performance` as the real
unit does, so the launcher does not, and `board.sh temp` is worth a look.

`az01-mirror.sh` is the remote view: ffmpeg's `kmsgrab` reads the buffer the display is
scanning out and serves it as MJPEG over HTTP, 8 fps at 960 px wide on this CPU, to any browser
on the cable. The board has no DHCP on that link, so the Mac reaches it by IPv6 link-local for
ssh and the script gives it an IPv4 link-local address for the browser.

## What will never work under emulation

Audio (a custom I2S codec plus a separate XMOS DSP), jog wheels, motors, pads, and the ilitek
touch panel are physical circuits of the device, not software. The control surface is too, but
its MIDI side can be stood in for, see above. The update image also contains only the splash screens and
the rootfs: no bootloader, no `/data` partition, no user content.

Section 10 of [TEARDOWN.md](TEARDOWN.md) lists these in detail.

## Tools

| File | Purpose |
|---|---|
| `_tools/az01-extract.py` | parser and extractor for the AZ01 container |
| `_tools/splash2png.py` | converts the raw BGRA splash screens to rotated PNG |
| `_tools/az01-chroot.sh` | mounts the rootfs as an overlay and enters the ARM chroot |
| `_tools/vm-build.sh` | builds the whole armhf QEMU VM: kernel, initramfs, disks, DTB, patches |
| `_tools/vm-run.sh` | starts and stops the VM, opens an SSH shell, captures the screen |
| `_tools/vm-wait.sh` | waits until the guest answers over SSH, meaning the boot is finished |
| `_tools/vm-window.ps1` | runs the whole thing in a native QEMU window on the Windows desktop |
| `_tools/vm-fit.sh` | sizes and focuses the QEMU window, acting on the X window |
| `_tools/engine-run.sh` | starts Engine inside the VM, with all the shims it needs |
| `_tools/drmspy.c` | LD_PRELOAD shim that intercepts the DRM ABI and rewrites the pixel format |
| `_tools/uinput-touch.c` | bridge from the virtio tablet to a real multitouch device via `/dev/uinput` |
| `_tools/touch-run.sh` | installs the bridge in the guest, sends synthetic taps, shows its log |
| `_tools/mesa-upgrade.sh` | sideloads the Ubuntu 24.04 armhf Mesa drivers into the guest |
| `_tools/engine-bench.sh` | measures how fast Engine draws, by counting page flips |
| `_tools/vm-fastdisk.sh` | moves the disk images between the Windows and Linux filesystems |
| `_tools/ppm2png.py` | converts QEMU monitor screendumps to PNG |
| `docker/Dockerfile` | Linux toolchain image: QEMU, armhf cross compiler, noVNC |
| `docker/eos.sh` | drives the whole pipeline inside that container, from a non-Linux host |
| `_tools/vm-run-macos.sh` | runs the VM with QEMU on a macOS host, no container in the loop |
| `_tools/mac-app.sh` | builds a double-clickable Engine OS.app around those scripts |
| `_tools/snd-combined.c` | virtual ALSA card with playback, capture and MIDI, plus a `Control Surface` MIDI card Engine binds its assignment to |
| `_tools/snd-combined-build.sh` | cross builds that module against the guest kernel |
| `_tools/surface.sh` | presses the surface's buttons: load, play, cue, browse, or any note or CC |
| `_tools/board/` | Engine natively on an ASUS Tinker Board: launcher, HDMI mirror, and the Mac-side helper |
| `_tools/surface-web.py`, `_tools/surface.html` | the surface as a web page, every control sending the real MIDI, LEDs and VU driven back by Engine |

## Credits

The breakthrough on the graphical interface came from
[nsaintot/cdj3k-emu](https://github.com/nsaintot/cdj3k-emu), which boots the firmware of another
Rockchip based, Qt based DJ player under QEMU. Its `ep122_shim` established the approach used
here: do not fight the virtual GPU, intercept the DRM/KMS ABI with an LD_PRELOAD instead.
`_tools/drmspy.c` is a direct application of that idea.

## License and disclaimer

The original work in this repository is MIT licensed. See [LICENSE](LICENSE).

This project is **unofficial**. It is not affiliated with, authorized by, or endorsed by inMusic
Brands, Numark or Engine DJ. It documents interoperability and security research carried out on
publicly distributed firmware for a device owned by the author.

No vendor code, firmware or asset is redistributed here. The Engine application, its QML, and the
module firmware remain proprietary.
