/* uinput-touch.c - bridge from the virtio tablet to a multitouch touchscreen.
 *
 * WHY IT IS NEEDED
 * The Mixstream Pro is a touch device: Engine builds its UI on QTouchEvent.
 * QEMU offers virtio-tablet, which exposes only ABS_X/ABS_Y and BTN_LEFT: no
 * BTN_TOUCH, no ABS_MT_*. udev therefore labels it ID_INPUT_MOUSE and Qt's
 * evdevtouch plugin never takes it on ("Found matching devices QList()" in the
 * qt.qpa.input logs).
 *
 * This program reads the tablet and republishes its events through
 * /dev/uinput as a real touchscreen (INPUT_PROP_DIRECT plus the type B
 * multitouch protocol), in the coordinate space of the 800x1280 panel. udev
 * marks it ID_INPUT_TOUCHSCREEN and Qt picks it up at runtime.
 *
 *   uinput-touch [-g] [-d /dev/input/eventN] [-w 800] [-h 1280]
 *       -g   EVIOCGRAB on the tablet: events arrive ONLY as touch, avoiding
 *            the double mouse plus touch delivery.
 *
 * Logs to /tmp/uinput-touch.log, which also serves to tell whether mouse
 * movements from the browser (noVNC) really reach the guest kernel.
 *
 * Synthetic taps, for testing without a mouse: write "x y" into the
 * /tmp/tapfifo fifo, coordinates in screen pixels.
 *
 *   echo "400 900" > /tmp/tapfifo
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define TABLET_RANGE 32768      /* virtio-tablet reports 0..32767 */

static FILE *lg;

static void logp(const char *fmt, ...)
{
    va_list ap;
    struct timespec ts;
    if (!lg) return;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    fprintf(lg, "[%5ld.%03ld] ", (long)ts.tv_sec, ts.tv_nsec / 1000000);
    va_start(ap, fmt);
    vfprintf(lg, fmt, ap);
    va_end(ap);
    fflush(lg);
}

static int ufd;
static int scr_w = 800, scr_h = 1280;

static void emit(int type, int code, int val)
{
    struct input_event e;
    memset(&e, 0, sizeof e);
    e.type = type; e.code = code; e.value = val;
    write(ufd, &e, sizeof e);
}

static void sync_report(void) { emit(EV_SYN, SYN_REPORT, 0); }

/* Type B multitouch protocol, a single finger (slot 0). */
static int tracking_id = 0;
static int touching = 0;

static void touch_down(int x, int y)
{
    emit(EV_ABS, ABS_MT_SLOT, 0);
    emit(EV_ABS, ABS_MT_TRACKING_ID, ++tracking_id);
    emit(EV_ABS, ABS_MT_POSITION_X, x);
    emit(EV_ABS, ABS_MT_POSITION_Y, y);
    emit(EV_KEY, BTN_TOUCH, 1);
    emit(EV_ABS, ABS_X, x);
    emit(EV_ABS, ABS_Y, y);
    sync_report();
    touching = 1;
    logp("touch DOWN %d,%d (id %d)\n", x, y, tracking_id);
}

static void touch_move(int x, int y)
{
    emit(EV_ABS, ABS_MT_SLOT, 0);
    emit(EV_ABS, ABS_MT_POSITION_X, x);
    emit(EV_ABS, ABS_MT_POSITION_Y, y);
    emit(EV_ABS, ABS_X, x);
    emit(EV_ABS, ABS_Y, y);
    sync_report();
}

static void touch_up(void)
{
    emit(EV_ABS, ABS_MT_SLOT, 0);
    emit(EV_ABS, ABS_MT_TRACKING_ID, -1);
    emit(EV_KEY, BTN_TOUCH, 0);
    sync_report();
    touching = 0;
    logp("touch UP\n");
}

static int create_uinput(void)
{
    struct uinput_user_dev d;
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) { perror("open /dev/uinput"); return -1; }

    ioctl(fd, UI_SET_EVBIT, EV_SYN);
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_EVBIT, EV_ABS);
    ioctl(fd, UI_SET_KEYBIT, BTN_TOUCH);
    /* INPUT_PROP_DIRECT is what separates a touchscreen from a touchpad:
     * without it udev sets ID_INPUT_TOUCHPAD and Qt treats it as a mouse. */
    ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT);
    ioctl(fd, UI_SET_ABSBIT, ABS_X);
    ioctl(fd, UI_SET_ABSBIT, ABS_Y);
    ioctl(fd, UI_SET_ABSBIT, ABS_MT_SLOT);
    ioctl(fd, UI_SET_ABSBIT, ABS_MT_TRACKING_ID);
    ioctl(fd, UI_SET_ABSBIT, ABS_MT_POSITION_X);
    ioctl(fd, UI_SET_ABSBIT, ABS_MT_POSITION_Y);

    memset(&d, 0, sizeof d);
    snprintf(d.name, UINPUT_MAX_NAME_SIZE, "az01-touchscreen");
    d.id.bustype = BUS_VIRTUAL;
    d.id.vendor = 0x1d6b; d.id.product = 0x0104; d.id.version = 1;
    d.absmax[ABS_X] = scr_w - 1;
    d.absmax[ABS_Y] = scr_h - 1;
    d.absmax[ABS_MT_POSITION_X] = scr_w - 1;
    d.absmax[ABS_MT_POSITION_Y] = scr_h - 1;
    d.absmax[ABS_MT_SLOT] = 9;
    d.absmax[ABS_MT_TRACKING_ID] = 65535;
    if (write(fd, &d, sizeof d) != sizeof d) { perror("write uidev"); return -1; }
    if (ioctl(fd, UI_DEV_CREATE) < 0) { perror("UI_DEV_CREATE"); return -1; }
    return fd;
}

/* Find the tablet by name, so the event number does not matter. */
static int find_tablet(void)
{
    char path[64], name[256];
    int i, fd;
    for (i = 0; i < 32; i++) {
        snprintf(path, sizeof path, "/dev/input/event%d", i);
        fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;
        name[0] = 0;
        ioctl(fd, EVIOCGNAME(sizeof name), name);
        if (strstr(name, "Tablet") || strstr(name, "tablet")) {
            logp("tablet: %s (%s)\n", path, name);
            return fd;
        }
        close(fd);
    }
    return -1;
}

int main(int argc, char **argv)
{
    int tfd = -1, ffd = -1, grab = 0, c;
    int cur_x = 0, cur_y = 0, have_x = 0, have_y = 0, nev = 0;
    const char *dev = NULL;

    lg = fopen("/tmp/uinput-touch.log", "w");

    while ((c = getopt(argc, argv, "gd:w:h:")) != -1) {
        switch (c) {
        case 'g': grab = 1; break;
        case 'd': dev = optarg; break;
        case 'w': scr_w = atoi(optarg); break;
        case 'h': scr_h = atoi(optarg); break;
        }
    }

    ufd = create_uinput();
    if (ufd < 0) return 1;
    logp("virtual touchscreen created: %dx%d\n", scr_w, scr_h);

    tfd = dev ? open(dev, O_RDONLY | O_NONBLOCK) : find_tablet();
    if (tfd < 0) logp("WARNING: tablet not found, fifo taps only\n");
    else if (grab && ioctl(tfd, EVIOCGRAB, 1) == 0) logp("tablet under EVIOCGRAB\n");

    unlink("/tmp/tapfifo");
    if (mkfifo("/tmp/tapfifo", 0666) == 0)
        ffd = open("/tmp/tapfifo", O_RDONLY | O_NONBLOCK);

    for (;;) {
        fd_set rf;
        int mx = -1;
        struct timeval tv;
        tv.tv_sec = 5; tv.tv_usec = 0;
        FD_ZERO(&rf);
        if (tfd >= 0) { FD_SET(tfd, &rf); if (tfd > mx) mx = tfd; }
        if (ffd >= 0) { FD_SET(ffd, &rf); if (ffd > mx) mx = ffd; }
        if (mx < 0) { sleep(1); continue; }
        if (select(mx + 1, &rf, NULL, NULL, &tv) <= 0) continue;

        if (tfd >= 0 && FD_ISSET(tfd, &rf)) {
            struct input_event e;
            while (read(tfd, &e, sizeof e) == (ssize_t)sizeof e) {
                if (e.type == EV_ABS && e.code == ABS_X) {
                    cur_x = (int)((long long)e.value * scr_w / TABLET_RANGE);
                    have_x = 1;
                } else if (e.type == EV_ABS && e.code == ABS_Y) {
                    cur_y = (int)((long long)e.value * scr_h / TABLET_RANGE);
                    have_y = 1;
                } else if (e.type == EV_KEY && e.code == BTN_LEFT) {
                    if (e.value) touch_down(cur_x, cur_y);
                    else touch_up();
                } else if (e.type == EV_SYN && e.code == SYN_REPORT) {
                    if (touching && have_x && have_y) touch_move(cur_x, cur_y);
                    /* trace the first few movements: confirms the browser's
                     * mouse reaches the guest kernel */
                    if (nev++ < 20) logp("tablet sync -> %d,%d\n", cur_x, cur_y);
                }
            }
        }

        if (ffd >= 0 && FD_ISSET(ffd, &rf)) {
            char buf[128];
            ssize_t n = read(ffd, buf, sizeof buf - 1);
            if (n > 0) {
                int x, y;
                buf[n] = 0;
                if (sscanf(buf, "%d %d", &x, &y) == 2) {
                    logp("synthetic tap %d,%d\n", x, y);
                    touch_down(x, y);
                    usleep(120000);
                    touch_up();
                }
            }
            /* the fifo closes with every writer: reopen it */
            close(ffd);
            ffd = open("/tmp/tapfifo", O_RDONLY | O_NONBLOCK);
        }
    }
    return 0;
}
