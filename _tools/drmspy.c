/*
 * drmspy - an LD_PRELOAD shim intercepting the DRM/KMS ABI of libdrm.
 *
 * The technique is taken from ep122_shim in nsaintot/cdj3k-emu: instead of
 * fighting the virtual GPU, intercept the DRM ABI at the library level.
 *
 * Purpose: work out exactly why Qt EGLFS cannot present a frame on
 * virtio-gpu. Intercepting ioctl() is not enough, since Qt fails BEFORE
 * reaching the kernel, so the libdrm functions Qt calls are hooked directly,
 * plus ioctl() for completeness. Logs to /tmp/drmspy.log.
 *
 * Cross-compiling for the armhf rootfs:
 *   arm-linux-gnueabihf-gcc -shared -fPIC -O2 -o drmspy.so drmspy.c -ldl
 *
 * Usage in the guest:
 *   LD_PRELOAD=/tmp/drmspy.so /usr/Engine/Engine -d0
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>
#include <dlfcn.h>
#include <unistd.h>
#include <stdint.h>

/* Subset of drmModeModeInfo: only needed to print the mode. */
typedef struct {
    uint32_t clock;
    uint16_t hdisplay, hsync_start, hsync_end, htotal, hskew;
    uint16_t vdisplay, vsync_start, vsync_end, vtotal, vscan;
    uint32_t vrefresh;
    uint32_t flags;
    uint32_t type;
    char     name[32];
} spy_modeinfo;

static FILE *logf;

static void spy_log_open(void)
{
    if (!logf) {
        logf = fopen("/tmp/drmspy.log", "a");
        if (logf) setvbuf(logf, NULL, _IOLBF, 0);
    }
}

__attribute__((constructor))
static void spy_ctor(void)
{
    spy_log_open();
    if (logf)
        fprintf(logf, "[pid %d] drmspy active\n", (int)getpid());
}

#define LOG(...) do { spy_log_open(); if (logf) { \
        fprintf(logf, "[pid %d] ", (int)getpid()); \
        fprintf(logf, __VA_ARGS__); } } while (0)

/*
 * THE FIX.
 *
 * Qt EGLFS creates the GBM surface as ARGB8888 (AR24). The virtio-gpu primary
 * plane only accepts XRGB8888 (XR24): with an AR24 framebuffer the kernel
 * refuses drmModeSetCrtc with EINVAL and the page flips fail with ENOSPC.
 * On the real device the Mali/rockchip accepts AR24, so the firmware has no
 * reason to pick anything else.
 *
 * Rewrite the format to XR24: the alpha channel is useless for a scanout.
 * Can be disabled with DRMSPY_NO_FORMAT_FIX=1.
 */
#define FMT_AR24 0x34325241u   /* DRM_FORMAT_ARGB8888 */
#define FMT_XR24 0x34325258u   /* DRM_FORMAT_XRGB8888 */

static int fix_enabled(void)
{
    static int cached = -1;
    if (cached < 0) {
        const char *s = getenv("DRMSPY_NO_FORMAT_FIX");
        cached = (s && *s == '1') ? 0 : 1;
    }
    return cached;
}

static uint32_t fix_format(uint32_t fmt, const char *where)
{
    if (fix_enabled() && fmt == FMT_AR24) {
        LOG("FIX %s: AR24 -> XR24\n", where);
        return FMT_XR24;
    }
    return fmt;
}

#define REAL(sym) do { if (!real_##sym) real_##sym = dlsym(RTLD_NEXT, #sym); } while (0)

/* ------------------------------------------------------------------ */

static int (*real_drmModeSetCrtc)(int, uint32_t, uint32_t, uint32_t, uint32_t,
                                  uint32_t *, int, spy_modeinfo *);

int drmModeSetCrtc(int fd, uint32_t crtcId, uint32_t bufferId,
                   uint32_t x, uint32_t y, uint32_t *connectors, int count,
                   spy_modeinfo *mode)
{
    int r, e;
    REAL(drmModeSetCrtc);
    r = real_drmModeSetCrtc(fd, crtcId, bufferId, x, y, connectors, count, mode);
    e = errno;
    LOG("SetCrtc fd=%d crtc=%u fb=%u x=%u y=%u nconn=%d conn0=%u mode=%s(%ux%u) -> %d %s\n",
        fd, crtcId, bufferId, x, y, count,
        (connectors && count > 0) ? connectors[0] : 0,
        mode ? mode->name : "(null)",
        mode ? mode->hdisplay : 0, mode ? mode->vdisplay : 0,
        r, r ? strerror(e) : "ok");
    errno = e;
    return r;
}

static int (*real_drmModePageFlip)(int, uint32_t, uint32_t, uint32_t, void *);

int drmModePageFlip(int fd, uint32_t crtc_id, uint32_t fb_id,
                    uint32_t flags, void *user_data)
{
    int r, e;
    REAL(drmModePageFlip);
    r = real_drmModePageFlip(fd, crtc_id, fb_id, flags, user_data);
    e = errno;
    LOG("PageFlip fd=%d crtc=%u fb=%u flags=0x%x -> %d %s\n",
        fd, crtc_id, fb_id, flags, r, r ? strerror(e) : "ok");
    errno = e;
    return r;
}

static int (*real_drmModeAddFB2)(int, uint32_t, uint32_t, uint32_t,
                                 const uint32_t *, const uint32_t *,
                                 const uint32_t *, uint32_t *, uint32_t);

int drmModeAddFB2(int fd, uint32_t width, uint32_t height, uint32_t pixel_format,
                  const uint32_t bo_handles[4], const uint32_t pitches[4],
                  const uint32_t offsets[4], uint32_t *buf_id, uint32_t flags)
{
    int r, e;
    REAL(drmModeAddFB2);
    pixel_format = fix_format(pixel_format, "AddFB2");
    r = real_drmModeAddFB2(fd, width, height, pixel_format, bo_handles,
                           pitches, offsets, buf_id, flags);
    e = errno;
    LOG("AddFB2 %ux%u fmt=%.4s pitch=%u handle=%u -> fb=%u %d %s\n",
        width, height, (const char *)&pixel_format,
        pitches ? pitches[0] : 0, bo_handles ? bo_handles[0] : 0,
        buf_id ? *buf_id : 0, r, r ? strerror(e) : "ok");
    errno = e;
    return r;
}

static int (*real_drmModeAddFB2WithModifiers)(int, uint32_t, uint32_t, uint32_t,
                                              const uint32_t *, const uint32_t *,
                                              const uint32_t *, const uint64_t *,
                                              uint32_t *, uint32_t);

int drmModeAddFB2WithModifiers(int fd, uint32_t width, uint32_t height,
                               uint32_t pixel_format, const uint32_t bo_handles[4],
                               const uint32_t pitches[4], const uint32_t offsets[4],
                               const uint64_t modifier[4], uint32_t *buf_id,
                               uint32_t flags)
{
    int r, e;
    REAL(drmModeAddFB2WithModifiers);
    pixel_format = fix_format(pixel_format, "AddFB2Mod");
    r = real_drmModeAddFB2WithModifiers(fd, width, height, pixel_format,
                                        bo_handles, pitches, offsets, modifier,
                                        buf_id, flags);
    e = errno;
    LOG("AddFB2Mod %ux%u fmt=%.4s pitch=%u mod=0x%llx flags=0x%x -> fb=%u %d %s\n",
        width, height, (const char *)&pixel_format,
        pitches ? pitches[0] : 0,
        modifier ? (unsigned long long)modifier[0] : 0ULL, flags,
        buf_id ? *buf_id : 0, r, r ? strerror(e) : "ok");
    errno = e;
    return r;
}

/* Qt picks between atomic and legacy: record what is available too. */
static int (*real_drmSetClientCap)(int, uint64_t, uint64_t);

int drmSetClientCap(int fd, uint64_t capability, uint64_t value)
{
    int r, e;
    REAL(drmSetClientCap);
    r = real_drmSetClientCap(fd, capability, value);
    e = errno;
    LOG("SetClientCap cap=%llu val=%llu -> %d %s\n",
        (unsigned long long)capability, (unsigned long long)value,
        r, r ? strerror(e) : "ok");
    errno = e;
    return r;
}

static int (*real_drmModeSetPlane)(int, uint32_t, uint32_t, uint32_t, uint32_t,
                                   int32_t, int32_t, uint32_t, uint32_t,
                                   uint32_t, uint32_t, uint32_t, uint32_t);

int drmModeSetPlane(int fd, uint32_t plane_id, uint32_t crtc_id, uint32_t fb_id,
                    uint32_t flags, int32_t crtc_x, int32_t crtc_y,
                    uint32_t crtc_w, uint32_t crtc_h, uint32_t src_x,
                    uint32_t src_y, uint32_t src_w, uint32_t src_h)
{
    int r, e;
    REAL(drmModeSetPlane);
    r = real_drmModeSetPlane(fd, plane_id, crtc_id, fb_id, flags, crtc_x, crtc_y,
                             crtc_w, crtc_h, src_x, src_y, src_w, src_h);
    e = errno;
    LOG("SetPlane plane=%u crtc=%u fb=%u %ux%u -> %d %s\n",
        plane_id, crtc_id, fb_id, crtc_w, crtc_h, r, r ? strerror(e) : "ok");
    errno = e;
    return r;
}

/* GBM: if surface creation fails, Qt never even reaches KMS. */
static void *(*real_gbm_surface_create)(void *, uint32_t, uint32_t, uint32_t, uint32_t);

void *gbm_surface_create(void *gbm, uint32_t w, uint32_t h,
                         uint32_t format, uint32_t flags)
{
    void *r;
    REAL(gbm_surface_create);
    format = fix_format(format, "gbm_surface_create");
    r = real_gbm_surface_create(gbm, w, h, format, flags);
    LOG("gbm_surface_create %ux%u fmt=%.4s flags=0x%x -> %p\n",
        w, h, (const char *)&format, flags, r);
    return r;
}

static void *(*real_gbm_surface_create_with_modifiers)(void *, uint32_t, uint32_t,
                                                       uint32_t, const uint64_t *,
                                                       unsigned int);

void *gbm_surface_create_with_modifiers(void *gbm, uint32_t w, uint32_t h,
                                        uint32_t format, const uint64_t *mods,
                                        unsigned int count)
{
    void *r;
    REAL(gbm_surface_create_with_modifiers);
    format = fix_format(format, "gbm_surface_create_with_modifiers");
    r = real_gbm_surface_create_with_modifiers(gbm, w, h, format, mods, count);
    LOG("gbm_surface_create_with_modifiers %ux%u fmt=%.4s nmods=%u -> %p\n",
        w, h, (const char *)&format, count, r);
    return r;
}
