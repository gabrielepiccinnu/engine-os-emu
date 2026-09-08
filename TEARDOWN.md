# Teardown: Numark Mixstream Pro 5.0.4 (Engine OS / inMusic "AZ0x")

Analysis of `MIXSTREAMPRO-5.0.4-Update.img` and a feasibility study of running the operating
system locally.

**Verdict in one line:** the system is **32-bit ARM (armhf) on a Rockchip RK3288 SoC**;
**VMware Workstation cannot run it** (it virtualizes x86/x86-64 only, it does not emulate ARM).
The workable path is QEMU, and the system **has been booted in full**, all the way to a root shell
on the emulated device (section 9).

**Verified status:**

| Goal | Result |
|---|---|
| Extracting the firmware from the AZ01 container | ✅ complete, SHA-1 verified |
| Running ARM binaries on x86 (qemu-user chroot) | ✅ |
| Full Engine OS boot under QEMU (systemd, network, SSH) | ✅ |
| Device console visible and interactive in a window | ✅ WSLg/GTK |
| Product identification (injected device tree) | ✅ NH08 / AZ05rA |
| virtio GPU plus DRM/KMS inside the VM | ✅ |
| Engine application startup (Qt, QML, SceneGraph, MIDI) | ✅ |
| **Engine DJ graphical interface on screen** | ✅ **working** (section 9-E) |
| "Incompatible Format" dialog at startup | ✅ removed with a udev rule |
| **Interface navigable with mouse and touch** | ✅ **working** (section 9-F) |
| Audio, control surface, jog wheels | ❌ the physical hardware is absent |

---

## 1. Starting material

| File | Size | Type |
|---|---|---|
| `MIXSTREAMPRO-5.0.4-Update.img` | 182,367,344 B | Proprietary **AZ01** container |
| `Mixstream Pro 5.0.4 Updater.exe` | 175,729,032 B | Windows executable (PE/MZ), installer wrapper |

The `.img` is **not** a disk image: it is a custom inMusic container. It has no partition table
and cannot be mounted directly.

---

## 2. The "AZ01" container format

The format was reconstructed entirely by reverse engineering. All integers are **little-endian**.

### 2.1 Base types

```
string  := u32 len, len bytes of text, 1 NUL byte, padding to a 4-byte boundary
blob    := u32 len, len raw bytes (no padding)
```

Alignment is `align4(offset + 4 + len + 1)`. Getting this detail wrong (forgetting the NUL, for
instance) desynchronizes the entire parse.

### 2.2 Header (offset 0x00, 160 bytes)

| Offset | Field | Value in this file |
|---|---|---|
| 0x00 | magic `char[4]` | `AZ01` |
| 0x04 | version `u32` | `1` |
| 0x08 | header_size `u32` | `160` (0xA0) |
| 0x0C | build name `string` | `SNAPSHOT-20260724110618` |
| 0x28 | n_compatible `u32` + n × `string` | `inmusic,jc11`, `inmusic,jc16`, `inmusic,nh08` |
| 0x64 | n_ids `u32` + n × `u32` | `0x15E4D008`, `0x15E4D00B`, `0x15E4203F` |
| 0x74 | description `string` | `Planck AZ01 Console upgrade Image` |

Notes:

- **A single update file covers three different machines.** The `compatible` strings are matched
  against the device's `/sys/firmware/devicetree/base/compatible`.
- The IDs all start with `0x15E4`, which is the **Numark/inMusic USB Vendor ID**: almost certainly
  VID/PID pairs of the supported products.
- `Planck` is the code name of the software platform, `AZ01` that of the hardware board.

### 2.3 Partition records (repeated)

```
0x00  magic        char[4]   "PART"
0x04  header_size  u32       (varies: 0x50, 0x58 and so on; data starts at entry+header_size)
0x08  data_size    u64       payload bytes
0x10  name         string    "splash" | "recoverysplash" | "rootfs"
      compression  string    "none" | "xz"
      flags        u32       1
      hash_algo    string    "sha1"
      hash         blob      20 bytes
```

The payload follows immediately at `entry_offset + header_size`; the next record starts at
`align4(data_offset + data_size)`.

### 2.4 Trailer

At `0x0ADEB460`: `"EOF\0"` + `u32 0x10` + 8 zero bytes (a 16-byte record).

### 2.5 Actual contents

| # | Name | Compression | Size | Data offset | SHA-1 (from header) |
|---|---|---|---|---|---|
| 0 | `splash` | none | 4,096,000 B | `0x0000F0` | `cebb789d…` |
| 1 | `recoverysplash` | none | 4,096,000 B | `0x3E8148` | `a312316e…` |
| 2 | `rootfs` | **xz** | 174,174,920 B | `0x7D0194` | `5c066be0…` |

SHA-1 of the rootfs blob **verified**: `5c066be040febe8ef75be1a68cf0101ef1d3355d`, matching the
value in the header, so the parse is correct and the image is intact. Decompressed:
**516,031,488 B** (492 MiB).

> The update **contains no separate bootloader or kernel**: the kernel travels inside the rootfs
> (`/boot`). U-Boot is not updated by this file.

---

## 3. The splash screens

They are not PNG or JPEG but **raw 32 bpp BGRA framebuffers**, 4,096,000 bytes = **800 × 1280 × 4**.

The panel is **portrait 800×1280** mounted rotated: getting a readable 1280×800 image requires a
90 degree rotation. The correct transform (verified visually):

```
dst(x, y) = src(sx = 799 - y, sy = x)     # plus a B<->R swap
```

`_tools/splash2png.py` performs the conversion. The boot splash carries the *engine dj* logo and
the version number **5.0.4**; there is a second one for recovery. Run it against the extracted
blobs to regenerate both:

```bash
python3 _tools/splash2png.py _extracted/00_splash.bin splash.png
```

This also confirms the display resolution of the device.

---

## 4. The operating system

```
ID=az01
NAME="az0x (inMusic Brands AZ0x base distribution)"
VERSION="5.0.14 (scarthgap)"
CPE_NAME="cpe:/o:openembedded:az01:5.0.14"
```

- A custom **Yocto/OpenEmbedded distribution**, *scarthgap* release (Yocto 5.0).
- **ext4** filesystem, 492 MiB (459 MiB usable, 99% full), mounted **read-only**
  (`/dev/root / auto ro` in `/etc/fstab`).
- Init: **systemd** (`/sbin/init -> ../lib/systemd/systemd`), `multi-user` target.
- Toolchain: `arm-poky-linux-gnueabi-gcc 13.4.0`, **glibc 2.39**.
- **busybox** userland (`busybox.nosuid` / `busybox.suid`) plus selected coreutils.

### 4.1 Kernel

```
Linux version 6.6.119-az01-2025-12-17-rt67 (oe-user@oe-host)
#1 SMP PREEMPT_RT Wed Dec 17 11:04:42 UTC 2025
```

- A **real-time kernel** (`PREEMPT_RT` patch, `rt67`), a coherent choice for a low latency audio
  device.
- A 5.9 MB `zImage` in `/boot`, with 76 modules in `/lib/modules/6.6.119-az01-…` (nearly all of
  them USB ethernet, HID, Bluetooth, Broadcom WiFi and the custom audio codecs
  `snd-soc-inmusic-nh08`, `snd-soc-eta5805`, `snd-soc-rockchip-i2s`).
- **Zero references to `virtio` in the decompressed kernel.** It is a Rockchip-only kernel. This
  is the central technical constraint (section 8).

### 4.2 Device tree and boot

`/boot` contains:

```
boot.scr.uimg                 U-Boot script
zImage -> zImage-6.6.119-az01-2025-12-17-rt67
rk3288-az01-jc11.dtb   rk3288-az01-jc11-c.dtb
rk3288-az01-jc16.dtb   rk3288-az01-jc16-c.dtb
rk3288-az05-nh08.dtb
```

The boot script (U-Boot distroboot):

```
load ${devtype} ${devnum}:${distro_bootpart} ${kernel_addr_r} ${prefix}zImage || exit
load ${devtype} ${devnum}:${distro_bootpart} ${fdt_addr_r} ${prefix}${fdtfile} || exit
if test "${board_name}" = "az01b"    # applies the rk3288-az01b.dtbo overlay
setenv bootargs "${bootargs} fsck.repair=yes"
bootz ${kernel_addr_r} - ${fdt_addr_r}
```

The **device tree is the source of product identity**. Custom properties read at runtime:

```
/sys/firmware/devicetree/base/inmusic,product-code       e.g. "NH08"
/sys/firmware/devicetree/base/compatible                 e.g. "inmusic,nh08"
/sys/firmware/devicetree/base/serial-number
/sys/firmware/devicetree/base/inmusic,az01-pcb-rev
/sys/firmware/devicetree/base/inmusic,az05-pcb-rev
/sys/firmware/devicetree/base/chosen/u-boot,version
/sys/firmware/devicetree/base/chosen/inmusic,internal-sd-fitted
/sys/firmware/devicetree/base/mipi@ff960000/panel@0/rotation
```

The `rk3288-az05-nh08.dtb` device tree **explicitly confirms** the device:

```
model = "Numark MIXSTREAM PRO";
compatible = "inmusic,nh08", "inmusic,az05", "rockchip,rk3288";
inmusic,product-code = "NH08";
inmusic,panel-rotation = <0x5a>;          /* 90 degrees */
```

Other hardware details from the DTB:

| Node | Value |
|---|---|
| `gpu@ffa30000` | `rockchip,rk3288-mali` / **`arm,mali-t760`** |
| `mipi@ff960000/panel@0` | **`urt,umo-p076md-t`** (7.6 inch MIPI DSI panel) |
| `i2c@ff660000/eta5805@2f` | **ETA5805** amplifier with `eta,dsp-config-name = "nh08"` |
| `serial@ff190000` | control surface UART |

### 4.3 Addressed hardware

The startup scripts (`setup-prerequisites.sh`) yield the address map:

| Address | Block | Note |
|---|---|---|
| `ffa30000` | Mali GPU | governor forced to `performance`, IRQ on CPU 1 |
| `ffb20000` | I2S audio | IRQ at RT priority `chrt -f 99`, on CPU 3 |
| `ff540000` | USB EHCI | IRQ on CPU 1 |
| `ff190000` | control surface UART | MIDI towards the control surface |
| `sd-mux` | SD switch | `echo external > /sys/bus/platform/devices/sd-mux/state` |

On-board firmware lives in `/usr/Engine/Firmware/` for **21 subsystems** (JC11 Mixer, JC11
Left/Right Display MCU, NH08 Controller, JP08 Motor, RMZ2 Controller and more): the system
updates the microcontrollers of the individual modules at startup (`touch-fw-update.service`,
`xmos-update.service`).

---

## 5. The application: Engine DJ

```
/usr/Engine/Engine              44.6 MB   ELF 32-bit ARM EABI5, PIE, stripped
/usr/Engine/FirmwareUpdater     1.5 MB
/usr/Engine/OfflineAnalyzer     1.3 MB
/usr/Engine/MidiDeviceScanner   100 KB
/usr/Engine/Reporter            206 KB    crash and coredump submission
/usr/Engine/qml/airQuick.1/     custom QML modules
/usr/Engine/Content/DemoDevice/ 5 demo .m4a tracks (~50 MB)
```

Stack: **Qt 6.7.2** (Core, Gui, Quick, Qml, Widgets, Network, DBus, OpenGL, Core5Compat, Xml)
plus **gRPC/protobuf**, **Boost 1.84**, **FFmpeg 58**, **OpenSSL 3**, **ALSA**, **KF6BluezQt**,
**KF5ThreadWeaver**, **libcurl**.

Startup (`engine.service` -> `/usr/Engine/Scripts/runengine`):

```sh
APPNAME=$(cat /sys/firmware/devicetree/base/inmusic,product-code)
/usr/Engine/Scripts/setup-prerequisites.sh $APPNAME
LD_LIBRARY_PATH=/usr/qt/lib /usr/Engine/Scripts/engine $APPNAME &
```

The `engine` script is a supervisor: it restarts the app in a loop and interprets the
`/tmp/engine-quit-reason` file written by the application to handle `Poweroff`, `Reboot`,
`UpdateFromLoader`, `UpdateFromFile`, `UpdateFromUrl`, `TestApp`, `ControllerMode`,
`UpdateFirmware` and `FactoryReset`.

Details worth noting:

- `ControllerMode` starts `planck-remote-screen` (12 MB), the mode in which the device acts as a
  controller for a computer.
- `TestApp` starts `test-app-launcher` (6 MB), factory diagnostics.
- Graphics go through **Qt EGLFS on KMS/GBM**: only the `libqeglfs.so` and `libqoffscreen.so`
  plugins are present. **There is no `libqlinuxfb.so`.**
- Mesa is present with 35 DRI drivers, including **`swrast_dri.so`, `kms_swrast_dri.so` and
  `panfrost_dri.so`**, so software rendering is technically possible.

---

## 6. Security and access

- **Local password login is impossible**: in `/etc/shadow` root has `*` (no valid password). A
  `getty@tty1` does exist.
- **Certificate-based SSH**: `sshd` is present, but `/usr/bin/az01-ssh-login` is a `ForceCommand`
  that validates constraints embedded in an **SSH certificate** (`--product` compared against the
  device tree, `--serial` against `fw_printenv serial#`). Without inMusic's CA there is no way in.
  Copyright inside the file: *Akai Professional, 2017*.
- **User data encryption**: `encrypt-fs.sh` uses `fscryptctl` to generate a random key from
  `/dev/urandom` on every boot and apply it to `/data` (**fscrypt**, ephemeral key).
- `az01-signed-fs` and `az01-bootloader-sig` suggest signature verification on the filesystem and
  the bootloader.
- A configurable OTG serial console (`az01-setup-otg-console.sh`), the most plausible hardware
  access route.

---

## 7. Services running at boot

```
engine.service                 the DJ application
az01-script-runner.service     arbitrary script execution (dev hook)
az01-usbsata-fixer.service     USB-SATA bridge workaround (JMS578)
az0x-info.service              hardware info logging
az0x-setup-hostname.service
touch-fw-update.service        updates the touchscreen firmware
xmos-update.service            updates the XMOS DSP
connman.service + wpa_supplicant + avahi-daemon
systemd-networkd, iptables/ip6tables
```

---

## 8. Why VMware Workstation cannot work

Three independent blockers, each sufficient on its own:

1. **Architecture.** Every binary is `ELF 32-bit LSB, ARM, EABI5`, interpreter
   `/usr/lib/ld-linux-armhf.so.3`. VMware Workstation is a type 2 **x86/x86-64** hypervisor: it
   virtualizes, it does not emulate. It will not execute ARM code. (Only VMware Fusion on Apple
   Silicon runs ARM guests, and that is a different platform.)
2. **SoC-bound kernel.** The 6.6.119 kernel contains **zero virtio symbols** and is compiled for
   the Rockchip RK3288. Even under QEMU it would find neither a disk nor a console: QEMU's `virt`
   machine exposes virtio peripherals exclusively.
3. **No board model.** QEMU has no RK3288 model, so the original `zImage` has no machine to run
   on.

The most VMware Workstation can do is host an x86 Linux VM that runs QEMU inside it, which is
exactly what WSL2 already does on this machine, without the extra layer.

---

## 9. What actually works: experimental results

### Option A: ARM chroot with qemu-user ✅ verified

This is the approach that **worked**. It emulates the binaries only (user mode), using the host
kernel: no drivers, no boot.

```bash
# in WSL2 Ubuntu, as root
apt-get update && apt-get install -y qemu-user-static binfmt-support
bash _tools/az01-chroot.sh          # mounts ro + overlay, enters the chroot
```

Results obtained:

```
$ uname -a
Linux … armv7l GNU/Linux                    <- ARM binaries executing on x86

$ az0x-info
hardware
  product-code:      NH08
  serial-sanitized:  0123456789Axxxxx
software
  bootloader:        2024.01
  buildroot:         5.0.14 (scarthgap)
  az01:              b0cd31c0
```

And the real application **does start**:

```
[I] ============================================================
[I] Engine  -  5.0.4
[I] ============================================================
[I] Command Line Arguments:  -d0
… registration of ~100 QML types (QmlRefHolder, SweepEffect, QuadPadsMode,
   StemsDialogActions, BrowserSourceRoles, WifiModelRoles …)
[I] Analytics: true
terminate called after throwing an instance of 'std::runtime_error'
  what():  Command execution timed out or failed to start!
```

Engine 5.0.4 initializes Qt, loads the screen configuration (`ScreenConfiguration.json`),
registers the entire QML tree, then stops on an external command that cannot find the hardware
(the candidates in the binary's strings are `mount`, `umount`, `systemctl`, `timedatectl`,
`az01-signed-fs`, `az01-update`).

**Required trick:** the app reads the product code from the device tree, which does not exist on
x86. The script mounts a `tmpfs` over `/sys` inside the chroot namespace and creates the
NUL-terminated files by hand:

```
/sys/firmware/devicetree/base/inmusic,product-code   ->  "NH08\0"
/sys/firmware/devicetree/base/compatible             ->  "inmusic,nh08\0"
```

Without this the error is `air.planck.config: Unable to find product "" in config map!`.

Valid product codes present in the binary: `JC11`, `JC11S`, `JC16`, `JP07`, `JP21`, `JP21X`,
`NH08`, `NH08S`, alongside the commercial names *PRIME 4*, *PRIME 4 PLUS*, *PRIME 2*, *PRIME GO*,
*SC5000*, *SC5000M*.

What this approach makes possible: inspecting the app, extracting QML and assets, running CLI
tools (`az0x-info`, `MidiDeviceScanner`, `OfflineAnalyzer`), analyzing the gRPC protocol,
debugging and tracing.
What it **cannot** do: show the GUI, produce audio, exercise the hardware.

### Option B: QEMU full-system ✅ verified, with a window on the desktop

**The system boots completely and can be watched running.** The original kernel has to be
discarded (Rockchip only, zero virtio) and replaced with the Debian armhf kernel, which has
`CONFIG_ARCH_VIRT=y` and PL011 built in.

```bash
bash _tools/vm-build.sh     # builds everything into _vm/
bash _tools/vm-run.sh       # boots it: a GTK window on the desktop
bash _tools/vm-run.sh --ssh # shell inside the emulated device
```

On **WSL2 with WSLg** the QEMU window appears directly on the Windows desktop and the device
console is interactive (`_vm/boot-live.png`, `_vm/console-live.png`):

```
az0x (inMusic Brands AZ0x base distribution) 5.0.14 mixstreampro tty1
mixstreampro login: root (automatic login)
root@mixstreampro:~# _
```

Two details make that window useful rather than black:

- the cmdline uses `console=ttyAMA0 console=tty1`. The last one wins as `/dev/console`, so systemd
  output goes to the framebuffer and **the entire boot** is visible in the window;
- `getty@tty1` with root autologin provides the shell. It has to be stopped before launching
  Engine, which needs the framebuffer free; `engine-run.sh` takes care of that.

Result:

```
OF: fdt: Machine model: Numark MIXSTREAM PRO (QEMU)
...
Welcome to az0x (inMusic Brands AZ0x base distribution) 5.0.14 (scarthgap)!
systemd 255.21 running in system mode
Detected virtualization qemu. Detected architecture arm.
...
az0x (inMusic Brands AZ0x base distribution) 5.0.14 mixstreampro ttyAMA0
mixstreampro login: root (automatic login)
root@mixstreampro:~#
```

The hostname becomes `mixstreampro` because `az0x-setup-hostname` derives it from the device tree
`model`. And `az0x-info` recognizes the hardware:

```
hardware
  product-code:      NH08
  board:             AZ05rA
  serial-sanitized:  QEMU0000000xxxxx
software
  linux:             6.1.0-50-armmp
  buildroot:         5.0.14 (scarthgap)
```

Working: full systemd, networking, D-Bus, avahi, connman, wpa_supplicant, **sshd**, and the
**virtio GPU** (`/dev/dri/card0` plus `renderD128`, connector `Virtual-1`).

#### The six real obstacles and how they are solved

Each of these needed a specific diagnosis; all of them are already handled in the scripts.

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | No serial output, VM apparently dead | Adding `rockchip,rk3288` to the root `compatible` makes the kernel select the **Rockchip machine descriptor** instead of `virt` | Keep only `inmusic,*` + `linux,dummy-virt` in the DTB |
| 2 | `Failed to isolate default target: az0x-data-mkfs.service is masked` | `data.mount` has a `Requires=` on that service: masking it makes the target impossible to isolate | Replace the hardware services with **stubs** (`ExecStart=/bin/true`), do not mask them |
| 3 | Boot into emergency mode, `Expecting device /dev/disk/by-label/data` | `data.mount` has `DefaultDependencies=no` and starts before udev: the by-label link does not exist yet | Make `/data` a **bind** of a directory on the rootfs |
| 4 | `switch_root: can't execute /sbin/init` | virtio disk enumeration order is not guaranteed: the initramfs was mounting the data disk | The init identifies the rootfs **by its content**, not by device name |
| 5 | Boot stalls for minutes on "Load/Save Random Seed" | No entropy source | `-device virtio-rng-device` |
| 6 | `/dev/dri` missing, virtio3 in state `0x83` (FAILED) | The virtio-mmio transports come up in **legacy mode** (`0x07`, without FEATURES_OK) and `virtio-gpu`/`virtio-input` require `VIRTIO_F_VERSION_1`. The probe exits with `-EINVAL` **printing nothing at all** and the device stays FAILED, unrecoverable at runtime | `-global virtio-mmio.force-legacy=false`, after which every device moves to `0x0f` |

#### The Engine application under emulation

`bash _tools/engine-run.sh` starts it. Engine 5.0.4 gets **very** far:

- initializes Qt EGLFS on KMS/GBM and enumerates inputs through udev
  (`Found matching devices ("/dev/input/event1")`, `Adding mouse`)
- registers the whole QML tree (~100 types)
- detects the timezone, opens BluezQt, contacts the analytics service
- starts the **SceneGraph** and takes over the display (the console disappears)
- enumerates **MIDI** devices (`Device: "Midi::Out::Midi Through Port-0" in use by /usr/Engine/Engine`)

Two hardware checks have to be worked around, both automated in `engine-run.sh`:

- the **product code** from the device tree, injected into the DTB
- **IRQ affinity**: Engine looks up the control surface UART IRQ in `/proc/interrupts` and sets its
  CPU. A file in which the real PL011 IRQ is renamed to `ttyS0` is bind-mounted over
  `/proc/interrupts`. It has to be a genuine **SPI** IRQ (the `arch_timer` is per-CPU and the write
  fails with `EIO`). `-smp 4` is also required: with 2 CPUs the app computes "CPU -2" and aborts.
- The `getty@tty1` console has to be disabled and `fbcon` unbound, otherwise they hold the
  framebuffer and Qt cannot perform the KMS mode-set.

**The GUI works**: see section 9-E for how it was unblocked.

### Option E: the Engine DJ graphical interface ✅ solved

For months the wall appeared to be Mesa: the firmware has no `virgl` driver, therefore no 3D on
the emulated GPU. **That was the wrong track.**

The key came from the [nsaintot/cdj3k-emu](https://github.com/nsaintot/cdj3k-emu) project, which
boots the firmware of another DJ player (also Rockchip, also Qt) under QEMU. Its technique: **do
not fight the virtual GPU, intercept the DRM/KMS ABI with an LD_PRELOAD** (`ep122_shim`).

Applying the same method, through `_tools/drmspy.c` cross-compiled for armhf, the cause surfaced
in two minutes:

```
gbm_surface_create 800x1280 fmt=AR24  ->  ok
AddFB2Mod         800x1280 fmt=AR24  ->  fb=37 ok
SetCrtc  crtc=33 fb=37 mode=800x1280 ->  -22 Invalid argument
PageFlip crtc=33 fb=37               ->  -28 No space left on device
```

**Qt EGLFS creates the GBM surface as ARGB8888 (AR24). The virtio-gpu primary plane only accepts
XRGB8888 (XR24).** The kernel refuses the mode-set because the framebuffer format is not supported
by the scanout. On the real device the Mali accepts AR24, so the firmware has no reason to choose
anything else: this is an incompatibility that exists **only** under emulation.

The shim rewrites the format on the fly:

```c
#define FMT_AR24 0x34325241u   /* DRM_FORMAT_ARGB8888 */
#define FMT_XR24 0x34325258u   /* DRM_FORMAT_XRGB8888 */
/* in gbm_surface_create, gbm_surface_create_with_modifiers,
   drmModeAddFB2, drmModeAddFB2WithModifiers */
if (fmt == FMT_AR24) fmt = FMT_XR24;
```

With the fix in place the error changed from `EINVAL` to `EACCES`: the **DRM master** was missing,
because `getty@tty1` has `Restart=always` and kept reclaiming the framebuffer. Masking it
(stopping it is not enough) and unbinding `fbcon` makes the mode-set succeed.

Result, measured by the same shim:

```
getty@tty1: inactive
frame buffer device: bind=0
FIX gbm_surface_create: AR24 -> XR24
SetCrtc fd=8 crtc=33 fb=40 mode=800x1280(800x1280) -> 0 ok
page flip OK: 32     page flip KO: 0
```

From **6 failures out of 6** to **32 successful page flips, zero failed**. The framebuffer goes
from 1024×768 (console) to **800×1280**, the native panel geometry, and the percentage of lit
pixels rises from 1.56% (splash) to 29.69% (setup interface).

```bash
bash _tools/engine-run.sh    # compiles the shim, prepares the guest, starts Engine
```

Screenshots: `_vm/engine-splash.png` (the app's own Qt splash) and `_vm/engine-ui.png` (the setup
screen with the Wi-Fi toggle and the *Incompatible Format* dialog, complaining that `/data` is
ext4 rather than exFAT, exactly as the real device would).

Rendering is software (`kms_swrast` on an emulated ARM CPU): several seconds per frame. Enough to
explore the interface, not to use it.

#### The "Incompatible Format" dialog ✅ solved

At startup the app used to show *"… has an incompatible format. Please reformat the drive to exFAT
or FAT32"*. The diagnosis took three steps, each one changing the message: it named `engineos`,
which was the label given to the rootfs; renamed to `az01-root`, the dialog followed it; with the
labels removed it became `NO NAME 2`. So Engine was looking at the **disks**, not at mount points.

The binary's strings settled the question:

```
udev_monitor_new_from_netlink        SUBSYSTEM / block
udev_monitor_filter_add_match_subsystem_devtype
udev_device_get_property_value
exfat  vfat  ntfs  hfsplus          <- the accepted filesystems (no ext4)
```

Engine listens on **libudev** for the `block` subsystem and reads `ID_FS_TYPE`. The two ext4
images used by the emulation (rootfs and `/data`) cannot be eliminated: `/etc` and `/var` are
overlays, and overlayfs requires extended attributes, which FAT does not provide. On the real
device the eMMC is not exposed as a music drive, so the case never arises.

The solution is a udev rule that clears the filesystem properties **only on ext4 devices**, so
that Engine does not see them as drives:

```
# /etc/udev/rules.d/99-engine-hide-system-disks.rules
SUBSYSTEM=="block", ENV{ID_FS_TYPE}=="ext4", ENV{ID_FS_TYPE}="", ENV{ID_FS_USAGE}="",     ENV{ID_FS_LABEL}="", ENV{ID_FS_LABEL_ENC}="", ENV{ID_FS_UUID}="", ENV{ID_FS_UUID_ENC}=""
```

The match is on the filesystem rather than the name, because virtio disk ordering is not
guaranteed. Verification inside the guest:

```
vda -> ID_FS_TYPE=vfat        (ENGINEOS, the music drive: stays visible)
vdb -> ID_FS_TYPE=(none)      (ext4, hidden)
vdc -> ID_FS_TYPE=(none)      (rootfs ext4, hidden)
```

The dialog is gone: the app goes straight to the Wi-Fi setup screen with the *Next* button active
(`_vm/engine-setup.png`). `_vm/media.img` (2 GB, FAT32, label `ENGINEOS`) is mounted at
`/media/az01-internal`: that is where test music goes.

### Option F: making the interface navigable ✅ solved

With the GUI on screen one problem remained: **the UI responded to neither mouse nor keyboard**.

Two distinct causes, and they are worth keeping separate because the first one masks the second.

**Apparent cause.** Engine had already exited (see *Remaining limitation*): what was visible in
the browser was the last frame left in the framebuffer, with no process behind it listening. On
its own this explains the entire symptom.

**Structural cause.** The Mixstream Pro is a **touch** device: the Engine UI is built on
`QTouchEvent`. QEMU offers `virtio-tablet`, which declares only `ABS_X`/`ABS_Y` and `BTN_LEFT`:

```
event1: QEMU Virtio Tablet
  EV:  f
  ABS: 3          <- only ABS_X and ABS_Y, no ABS_MT_*, no BTN_TOUCH
```

`udev` therefore classifies it as `ID_INPUT_MOUSE=1`, and Qt's `evdevtouch` plugin discards it:

```
qt.qpa.input: Adding mouse at /dev/input/event1
qt.qpa.input: evdevtouch: udev device discovery for type Device_Touchpad|Device_Touchscreen
qt.qpa.input: Found matching devices QList()          <- no touchscreen
```

The solution is a userspace bridge, `_tools/uinput-touch.c`: it reads the virtio tablet and
**republishes its events through `/dev/uinput` as a real touchscreen**, with `INPUT_PROP_DIRECT`
and the type B multitouch protocol, in the coordinate space of the 800×1280 panel.

`INPUT_PROP_DIRECT` is not a detail: without that bit `udev` sets `ID_INPUT_TOUCHPAD` and Qt goes
back to treating it as a mouse. With the correct bit:

```
/dev/input/event3   az01-touchscreen   ID_INPUT=1 ID_INPUT_TOUCHSCREEN=1
```

and Qt picks it up at runtime:

```
qt.qpa.input: evdevtouch: Adding device at /dev/input/event3
qt.qpa.input: evdevtouch: /dev/input/event3: Protocol type B (multi), filtered=no
qt.qpa.input: evdevtouch: min X: 0 max X: 799 / min Y: 0 max Y: 1279
[ ] evdevtouch: Updating QInputDeviceManager device count: 1 touch devices
```

The bridge is started automatically by `engine-run.sh` **before** Engine, to give udev time to
label the device. It also exposes a `/tmp/tapfifo` fifo for synthetic taps, useful for driving the
UI without a mouse:

```bash
bash _tools/touch-run.sh --tap 650 68     # touch the "Next" button
bash _tools/touch-run.sh --log            # events read from the tablet, touches emitted
```

**End-to-end verification.** A click injected into the virtio tablet from the QEMU monitor travels
the whole chain:

```
[1705.354] touch DOWN 0,0 (id 2)      <- the bridge receives BTN_LEFT from the tablet
[1705.354] tablet sync -> 0,0            and re-emits it as a touch
```

The tablet stays attached as a mouse as well, so EGLFS keeps drawing the cursor and the pointer
position is visible in the browser. Should the double mouse plus touch delivery cause trouble,
`touch-run.sh -g` does an `EVIOCGRAB` on the tablet and lets only the touch through.

Result: the first-run procedure completes and the real application is reached.

| Screen | File |
|---|---|
| Wi-Fi setup, checkbox ticked with a tap | `_vm/tap-checkbox.png` |
| Engine DJ Profiles screen | `_vm/tap-next.png` |
| **library browser, Deck 1 and Deck 2** | `_vm/engine-main.png` |

#### How to watch it: a native window, not a browser

noVNC in the browser works but is slow: every frame is encoded by QEMU's VNC server, pushed over a
websocket and repainted into a JavaScript canvas, and every click makes the reverse trip.

QEMU's GTK window skips all of that. In early attempts it seemed not to open at all: the taskbar
showed `[WARN:COPY MODE] QEMU` but no window. In reality **the window was being created
correctly**: WSLg projects it through `msrdc` and simply leaves it in the background. Verified by
launching an empty QEMU and photographing the desktop:

```
msrdc   [WARN:COPY MODE] QEMU (PROVAFIN) [Paused] (Ubuntu-22.04)
```

`[WARN:COPY MODE]` only signals that WSLg has no GPU acceleration and composites in software,
which makes asking QEMU for OpenGL pointless.

`_tools/vm-window.ps1` starts the VM with `-display gtk,gl=off,zoom-to-fit=on`, waits for the
boot, launches Engine and brings the window to the front with `ShowWindow`/`SetForegroundWindow`.
`zoom-to-fit` is needed because the panel is 800×1280 portrait and does not fit a 1080 desktop.

```powershell
powershell -File _tools\vm-window.ps1
```

Closing the window shuts the VM down. The mouse acts as a finger on the touchscreen through the
bridge described above; verified by reading `/tmp/uinput-touch.log` while clicking in the window:

```
touch DOWN 81,346 (id 16)
touch DOWN 584,901 (id 17)
touch DOWN 568,119 (id 18)
```

Resizing has to be applied to the **X window** (`_tools/vm-fit.sh`, which uses `xdotool`): what is
visible on Windows is an `msrdc` proxy, and `MoveWindow` on the proxy does not propagate to QEMU.
GTK enforces a minimum width of 640, which together with a height of 1024 gives exactly the 800:1280
ratio of the panel.

The cost of TCG emulation remains: Engine draws slowly regardless of the video transport, but the
input latency disappears.

#### Remaining limitation

**Engine does not stay running.** After drawing the interface the process exits, with no crash and
no `engine-quit-reason`, after a few minutes. Plausibly an internal watchdog waiting on absent
hardware (the control surface or the audio DSP). Restarting `engine-run.sh` is enough.

When it happens the image stays on screen but stops responding: it is the frozen frame, not an
input problem. `bash vm-run.sh --ssh pidof Engine` distinguishes the two cases.

### Option C: VMware Workstation

Useful only as an **x86 host**: an Ubuntu VM inside VMware Workstation running option A or B
within it. It adds nothing over the WSL2 already present on this machine, apart from isolation.

### Option D: equivalent real hardware

Here the question "Raspberry Pi or something else?" has a clear answer, and the Pi is **not** the
better choice.

#### The right choice: an RK3288 board

The rootfs is compiled for the **same SoC** as the following boards, all of which have complete
mainline support:

| Board | SoC | GPU | Notes |
|---|---|---|---|
| **ASUS Tinker Board / Tinker Board S** | RK3288 | Mali-T764 | The closest match: same SoC, 2 GB, mature mainline support |
| Firefly-RK3288 | RK3288 | Mali-T764 | |
| Radxa Rock 2 Square | RK3288 | Mali-T764 | |
| "veyron" Chromebooks (ASUS C201, Chromebit CS10) | RK3288 | Mali-T764 | Cheap on the used market |

Why they matter: the rootfs includes **open source Mesa 24.0.7** with `panfrost_dri.so` and
`rockchip_dri.so`. On a Mali T7xx those drivers genuinely work, so the GPU would be
**accelerated**, not emulated.

Procedure (same logic as the VM):

1. kernel plus DTB for the board (Armbian or mainline 6.6), modules copied into the rootfs
   `/lib/modules`;
2. add `inmusic,product-code = "NH08"` to the board's DTB (it is already a device tree platform,
   so an overlay is enough);
3. `ScreenConfiguration.json`: change `"name": "MIPI"` to the real connector (`HDMI-A-1`);
4. the systemd stubs and the IRQ shim, as in the VM.

Expectation: **the GUI should genuinely appear**. Audio, control surface, jog wheels and
touchscreen remain out of reach.

#### Raspberry Pi: possible but worse

A Pi 4 or 5 running **32-bit Raspberry Pi OS** (armhf) executes the binaries, and since it also
has a device tree the product code can be injected with an overlay. However:

- the rootfs **contains neither `vc4_dri.so` nor `v3d_dri.so`**, so there is no Mesa driver for the
  Broadcom GPU. It would fall back to `kms_swrast` (software), the same wall as the VM, only
  faster.
- SoC, clocks, regulators and peripherals are completely different: none of the device's 76 kernel
  modules is reusable.
- The Pi 4 has a DSI connector, so an 800×1280 panel is theoretically connectable, but the
  Mixstream panel is a `urt,umo-p076md-t` with its own driver.

In short: the Pi is fine for **studying the userland**; a Tinker Board is the only realistic route
to **seeing the interface**.

#### What will not work on any generic hardware

Audio (custom I2S codec plus XMOS DSP), the control surface (MCUs over UART), jog wheels and
motors, the ilitek touchscreen: these are physical circuits of the Mixstream Pro, not software.

---

## 10. What will never work under emulation

| Subsystem | Why |
|---|---|
| Audio | custom I2S codec `eta5805`/`inmusic-nh08` on a physical bus, separate XMOS DSP |
| Control surface | MIDI over UART `ff190000` to dedicated MCUs |
| Jog wheels, motors, pads | firmware on external microcontrollers |
| Touchscreen | MIPI panel plus ilitek controller, firmware updated at boot |
| GPU | Mali T760 (acceleration), replaceable only by swrast |
| `/data` encryption | `fscrypt` with an ephemeral key; no user data in the image |
| SSH | requires a certificate signed by the inMusic CA |

The update image contains **only the splash screens and the rootfs**: no U-Boot, no `/data`
partition, no user content and no factory state.

---

## 11. Tools produced

Everything under `_tools/` is part of this repository. Everything under `_extracted/` and `_vm/`
is **generated locally** by those tools and is not distributed here, with the exception of the
screenshots.

| File | Purpose |
|---|---|
| `_tools/az01-extract.py` | parser and extractor for the AZ01 container |
| `_tools/splash2png.py` | converts the BGRA 800×1280 splash screens to rotated PNG |
| `_tools/az01-chroot.sh` | mounts the rootfs as an overlay and enters the ARM chroot |
| `_tools/vm-build.sh` | builds the complete armhf QEMU VM (kernel, initramfs, disks, DTB, patches) |
| `_tools/vm-run.sh` | starts and stops the VM, opens the SSH shell, captures the screen |
| `_tools/vm-wait.sh` | waits until the guest answers over SSH, meaning the boot has finished |
| `_tools/engine-run.sh` | starts the Engine application inside the VM (IRQ shim plus display) |
| `_tools/drmspy.c` | LD_PRELOAD shim intercepting the DRM ABI and rewriting the pixel format |
| `_tools/uinput-touch.c` | bridge from the virtio tablet to a multitouch touchscreen via `/dev/uinput` |
| `_tools/touch-run.sh` | installs the bridge in the guest, sends synthetic taps, shows the log |
| `_tools/vm-window.ps1` | runs everything in a native QEMU window on the Windows desktop |
| `_tools/vm-fit.sh` | sizes and focuses the QEMU window (acting on the X window) |
| `_tools/mesa-upgrade.sh` | sideloads the Ubuntu 24.04 armhf Mesa drivers into `/opt/mesa24` |
| `_tools/engine-bench.sh` | measures how fast Engine draws, by counting DRM page flips |
| `_tools/vm-fastdisk.sh` | moves the disk images between the Windows and Linux filesystems |
| `_tools/ppm2png.py` | converts QEMU monitor screendumps to PNG |

Generated artifacts, for reference:

| File | Content |
|---|---|
| `_extracted/rootfs.img` | ext4 filesystem, 492 MiB, mountable on Linux |
| `_extracted/boot/` | the `zImage` kernel and the 5 device trees extracted from `/boot` |
| `_extracted/splash.png` | boot splash (engine dj 5.0.4), produced by `splash2png.py` |
| `_extracted/recoverysplash.png` | recovery splash |

Screenshots kept as documentation:

| File | Content |
|---|---|
| `_vm/boot-live.png` | Engine OS booting in the QEMU window |
| `_vm/console-live.png` | the interactive console of the emulated device |
| `_vm/engine-splash.png` | the Engine DJ splash drawn by the application |
| `_vm/engine-ui.png` | the Engine OS interface running |
| `_vm/engine-setup.png` | Wi-Fi setup without the dialog, after the udev rule |
| `_vm/tap-checkbox.png` | touch proof: a checkbox ticked by a synthetic tap |
| `_vm/tap-next.png` | the Engine DJ Profiles screen |
| `_vm/engine-main.png` | Engine DJ operational: library browser, Deck 1 and Deck 2 |
| `_vm/window-native.png` | Engine DJ in the native window on the desktop |

Usage:

```bash
python _tools/az01-extract.py MIXSTREAMPRO-5.0.4-Update.img            # list
python _tools/az01-extract.py MIXSTREAMPRO-5.0.4-Update.img _extracted # extract everything
python _tools/az01-extract.py MIXSTREAMPRO-5.0.4-Update.img _extracted rootfs
xz -dc _extracted/02_rootfs.bin > _extracted/rootfs.img

python _tools/splash2png.py _extracted/00_splash.bin _extracted/splash.png
```

---

## 12. Note

This analysis was carried out on firmware publicly distributed by inMusic, for a device owned by
the author, for study and interoperability purposes. The application code (`Engine`, the QML, the
module firmware) remains proprietary and is not redistributable.
