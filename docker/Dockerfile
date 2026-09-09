# Linux toolchain for the Engine OS emulation, so the whole thing runs on a
# host that is neither x86 nor Linux (macOS on Apple Silicon, for instance).
#
# The container is native arm64 on Apple Silicon: only the armhf GUEST is
# emulated by QEMU TCG, the container itself runs at full speed.
#
# It must be run privileged: vm-build.sh mounts the rootfs image through a
# loop device to patch it.
FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        qemu-system-arm qemu-utils ipxe-qemu \
        gcc-arm-linux-gnueabihf libc6-dev-armhf-cross \
        python3 curl ca-certificates \
        cpio xz-utils gzip \
        device-tree-compiler \
        dpkg-dev kmod \
        e2fsprogs dosfstools util-linux \
        openssh-client \
        novnc websockify socat \
        procps psmisc iproute2 \
        less file \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work

# Nothing to run by itself: the container stays up and eos.sh drives the
# _tools scripts inside it with docker exec.
CMD ["sleep", "infinity"]
