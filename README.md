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
| Audio, control surface, jog wheels | not possible, the physical hardware is absent |

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

## What will never work under emulation

Audio (a custom I2S codec plus a separate XMOS DSP), the control surface (MIDI over UART to
dedicated microcontrollers), jog wheels, motors, pads, and the ilitek touch panel are physical
circuits of the device, not software. The update image also contains only the splash screens and
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
