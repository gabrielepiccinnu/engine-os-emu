#!/bin/bash
# Brings the Ubuntu 24.04 armhf Mesa drivers into the guest, alongside the
# original ones rather than replacing them.
#
#     bash mesa-upgrade.sh
#
# WHY
# The Engine OS rootfs has Mesa 24.0.7 but without libLLVM: kms_swrast_dri.so
# only contains softpipe, the reference rasterizer, running inside an emulated
# ARM CPU. The application log also shows:
#
#   MESA-LOADER: failed to open virtio_gpu: /usr/lib/dri/virtio_gpu_dri.so
#
# meaning Mesa looks for the virgl driver for QEMU's virtio-gpu, does not find
# it, and falls back to softpipe. With virgl the drawing would be executed by
# the x86 host.
#
# Ubuntu 24.04 has Mesa 24.0.x and glibc 2.39, the same versions as the rootfs
# (Yocto scarthgap), so the noble megadriver drops in without friction. It
# contains both llvmpipe and virtio_gpu (virgl) in the same file.
#
# The files go into /opt/mesa24 in the guest and are only activated through
# LIBGL_DRIVERS_PATH: the originals stay intact as a fallback.
set -e
BASE="$(cd "$(dirname "$0")/.." && pwd)"
VM="$BASE/_vm"
WORK=/opt/az01-mesa                     # on WSL's ext4, not on /mnt/d
PORTS=http://ports.ubuntu.com/ubuntu-ports
# The guest has glibc 2.39, which is exactly Ubuntu 24.04 "noble". The release
# index has to be used: the pool contains ALL releases together, and simply
# taking the highest version pulls in packages from later Ubuntu releases that
# demand GLIBC_2.42 and will not load.
#
# ONLY the release pocket, deliberately. noble shipped Mesa 24.0.5, the same
# series as the 24.0.7 in the rootfs, but noble-updates has since moved to the
# 25.x HWE stack. From 24.3 on, Mesa replaced the classic DRI megadriver
# (libgallium_dri.so) with libdril_dri.so, and the guest's own libEGL/libgbm
# cannot bind its entry points: Engine then dies at startup with
#   did not find extension DRI_Mesa version 1 / failed to bind extensions
#   Could not create GBM device / Could not open DRM device
SUITES="noble"

cp -f "$VM/id_vm" /tmp/id_vm; chmod 600 /tmp/id_vm
SSHOPT="-p 2222 -i /tmp/id_vm -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -o LogLevel=ERROR"

# .deb files downloaded earlier may come from the wrong release: start over,
# keeping only the index.
rm -rf "$WORK/deb" "$WORK/root" "$WORK/stage"
mkdir -p "$WORK/deb" "$WORK/root"
cd "$WORK/deb"

echo "== Ubuntu 24.04 armhf package index =="
INDEX="$WORK/Packages.$(echo $SUITES | tr ' ' '-')"
if [ ! -s "$INDEX" ]; then
    : > "$INDEX"
    for su in $SUITES; do
        echo "  $su"
        curl -sL "$PORTS/dists/$su/main/binary-armhf/Packages.gz" | gunzip >> "$INDEX" || true
    done
fi
echo "  records: $(grep -c '^Package: ' "$INDEX")"

# The package record carries a Filename field giving the exact path in the
# pool: no more guessing at file names.
grab_pkg() {
    local pkg="$1" fn base
    fn=$(awk -v p="$pkg" '
        $1 == "Package:" { cur = $2 }
        $1 == "Filename:" && cur == p { print $2 }
    ' "$INDEX" | sort -u | tail -n 1)
    if [ -z "$fn" ]; then echo "  NOT FOUND: $pkg" >&2; return 1; fi
    base=$(basename "$fn")
    if [ ! -f "$base" ]; then
        echo "  $base"
        curl -sL -o "$base" "$PORTS/$fn" || return 1
    fi
    dpkg-deb -x "$base" "$WORK/root"
}

echo "== downloading the packages =="
PKGS="libgl1-mesa-dri libglapi-mesa libllvm17t64 libelf1t64
      libdrm2 libdrm-radeon1 libdrm-nouveau2 libdrm-amdgpu1 libdrm-etnaviv1
      libdrm-exynos1 libdrm-freedreno1 libdrm-omap1 libdrm-tegra0
      libxcb1 libxcb-dri2-0 libxcb-dri3-0 libxcb-present0 libxcb-sync1
      libxcb-randr0 libxcb-shm0 libxcb-xfixes0 libxcb-glx0
      libx11-6 libx11-xcb1 libxshmfence1 libxext6 libxfixes3 libxau6 libxdmcp6
      libsensors5 libedit2 libtinfo6 libffi8 liblzma5 libzstd1 libbsd0 libmd0"
for p in $PKGS; do grab_pkg "$p" || true; done

DRI=$(find "$WORK/root" -name 'virtio_gpu_dri.so' -o -name 'kms_swrast_dri.so' | head -n 1)
if [ -z "$DRI" ]; then echo "extraction failed: no DRI driver"; exit 1; fi
DRIDIR=$(dirname "$DRI")
# Mesa >= 24.3 points every *_dri.so at libdril_dri.so, whose ABI the guest's
# libEGL cannot bind. Stop here rather than let Engine fail at startup.
if [ "$(basename "$(readlink -f "$DRI")")" = "libdril_dri.so" ]; then
    echo "the index yielded Mesa >= 24.3 (libdril_dri.so): incompatible with" >&2
    echo "the guest's Mesa 24.0. Keep SUITES on the release pocket only." >&2
    exit 1
fi
LIBDIR=$(dirname "$(find "$WORK/root" -name 'libLLVM*.so*' | head -n 1)")
echo "  drivers in $DRIDIR"
echo "  libraries in ${LIBDIR:-none}"
ls -la "$DRIDIR" | grep -E 'virtio_gpu|kms_swrast|libgallium' | sed 's/^/    /'

echo "== preparing the tree to copy =="
# The Mesa 24 DRI drivers are 49 hard links to the same 20 MB megadriver: only
# three are taken, to avoid multiplying them during the copy.
STAGE="$WORK/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE/dri" "$STAGE/lib"
for d in virtio_gpu kms_swrast swrast; do
    [ -f "$DRIDIR/${d}_dri.so" ] && cp -f "$DRIDIR/${d}_dri.so" "$STAGE/dri/"
done
# every extracted library, symlinks included
find "$WORK/root" -path '*/lib/*' \( -type f -o -type l \) -name '*.so*' \
    -not -path '*/dri/*' -exec cp -a {} "$STAGE/lib/" \; 2>/dev/null
du -sh "$STAGE" | sed 's/^/  /'
ls "$STAGE/lib" | wc -l | sed 's/^/  libraries: /'

echo "== aligning the Mesa build string with the guest =="
# The guest's libEGL refuses any driver whose Mesa build string is not byte for
# byte its own:
#   DRI driver not from this Mesa build ('24.0.5-1ubuntu1' vs '24.0.7')
#   failed to bind extensions / Could not create GBM device
# (the __DRI_MESA extension, added in Mesa 24.0, is compared with strcmp). The
# distributions stamp the full package version into that string, so an archive
# build can never match a Yocto one: noble carries "24.0.5-1ubuntu1" against
# the rootfs's plain "24.0.7", and no Ubuntu release ever shipped 24.0.7.
#
# The string is rewritten in place instead, same length, NUL padded. What the
# check really guards is the DRI interface, and that does not change between
# maintenance releases of one stable series: only the last digit differs here.
GUESTVER=$(ssh $SSHOPT root@127.0.0.1 \
    'strings /usr/lib/libEGL.so.1 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | sort -u | head -n 1' \
    | tr -d '\r')
# the build string occurs several times: take the most frequent match, not the
# first, so an unrelated version-looking string cannot be picked up
DRIVERVER=$(strings "$STAGE/dri/virtio_gpu_dri.so" \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | sort | uniq -c | sort -rn \
    | head -n 1 | sed 's/^ *[0-9]* //')
echo "  guest libEGL: ${GUESTVER:-?}    sideloaded driver: ${DRIVERVER:-?}"
if [ -n "$GUESTVER" ] && [ -n "$DRIVERVER" ] && [ "$GUESTVER" != "$DRIVERVER" ]; then
    python3 - "$STAGE/dri" "$DRIVERVER" "$GUESTVER" <<'MESAVER'
import glob, os, sys
d, old, new = sys.argv[1], sys.argv[2].encode(), sys.argv[3].encode()
if len(new) > len(old):
    sys.exit("  the guest string is the longer one: cannot rewrite in place")
new += b"\0" * (len(old) - len(new))
for f in sorted(glob.glob(os.path.join(d, "*.so"))):
    blob = open(f, "rb").read()
    print("  %s: %d occurrences" % (os.path.basename(f), blob.count(old)))
    open(f, "wb").write(blob.replace(old, new))
MESAVER
fi

echo "== copying into the guest under /opt/mesa24 =="
tar -C "$STAGE" -czf /tmp/mesa24.tgz .

scp -P 2222 -i /tmp/id_vm -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR /tmp/mesa24.tgz root@127.0.0.1:/tmp/ > /dev/null

ssh $SSHOPT root@127.0.0.1 'sh -s' <<'GUEST'
rm -rf /opt/mesa24; mkdir -p /opt/mesa24
tar -C /opt/mesa24 -xzf /tmp/mesa24.tgz
rm -f /tmp/mesa24.tgz

echo "--- contents ---"
echo "  drivers: $(ls /opt/mesa24/dri/ | tr '\n' ' ')"
echo "  libraries: $(ls /opt/mesa24/lib/ | wc -l)"
du -sh /opt/mesa24 | sed 's/^/  space: /'

# busybox has no ldd: query the dynamic loader instead. The check has to cover
# ALL the copied libraries, not just the driver: libLLVM is opened with dlopen,
# so its dependencies do not show up when starting from the driver.
echo "--- dependencies still missing (recursive check) ---"
LOADER=$(ls /lib/ld-linux-armhf.so.* /lib/ld-linux.so.* 2>/dev/null | head -n 1)
MISS=$(for f in /opt/mesa24/dri/*.so /opt/mesa24/lib/*.so*; do
           [ -f "$f" ] || continue
           LD_LIBRARY_PATH=/opt/mesa24/lib "$LOADER" --list "$f" 2>&1 | grep 'not found'
       done | sed 's|^/opt/mesa24/[a-z]*/[^:]*: ||' | sort -u)
if [ -n "$MISS" ]; then
    echo "$MISS" | sed 's/^/  MISSING /'
else
    echo "  none: everything resolved"
fi

# dlopen dependencies do not appear above: extract them from the binary's
# strings and check by hand that they exist.
echo "--- libraries opened with dlopen ---"
strings /opt/mesa24/dri/virtio_gpu_dri.so 2>/dev/null \
    | grep -E '^lib(drm_|udev|sensors|LLVM|elf)[A-Za-z0-9_.-]*\.so' | sort -u \
    | while read -r l; do
        if [ -e "/opt/mesa24/lib/$l" ] || [ -e "/usr/lib/$l" ]; then
            echo "  ok      $l"
        else
            echo "  MISSING $l"
        fi
      done
GUEST

cat <<'MSG'

To use them, Engine has to be launched with:
  LIBGL_DRIVERS_PATH=/opt/mesa24/dri
  LD_LIBRARY_PATH=...:/opt/mesa24/lib
engine-run.sh does that when MESA24=1 is passed.
MSG
