/* wlstack.c — LD_PRELOAD shim: keep wine's Wayland popups (menus) on top of
 * GPU-drawn child windows.
 *
 * Under winewayland, Lightroom's GPU-drawn areas (the photo, the histogram:
 * child windows with their own Vulkan surface) and its menus (popup windows)
 * are all wl_subsurfaces of the main window. When wine places a popup it calls
 * wl_subsurface_place_above(popup, parent) whenever the owner window has no
 * client surface of its own, which is the case for Lightroom (the GPU surfaces
 * belong to child windows). "Place above the parent" means directly above it,
 * i.e. at the BOTTOM of the sibling stack, so the menu ends up under the GPU
 * surfaces and the photo paints over it
 * (dlls/winewayland.drv/wayland_surface.c, wayland_surface_reconfigure_subsurface).
 *
 * The Wayland spec puts a new sub-surface at the top of its siblings' stack,
 * and wine creates a new one each time a popup is shown. So dropping only the
 * place_above(subsurface, its own parent) requests leaves every surface in
 * creation order: GPU surfaces (created with their windows) below, menus
 * (created when opened) on top. Placement relative to a sibling is untouched.
 *
 * Implementation: interpose wl_proxy_marshal_flags (what the protocol's inline
 * wrappers call), remember each wl_subsurface's parent from
 * wl_subcompositor.get_subsurface, drop the matching place_above, and forward
 * everything else through wl_proxy_marshal_array_flags.
 *
 * WLSTACK_LOG=/path appends one line per dropped request (debugging).
 *
 * Build: gcc -shared -fPIC -O3 -o resources/stubs/binaries/wlstack.so \
 *            resources/stubs/sources/wlstack.c -lwayland-client -lpthread
 * Use:   LD_PRELOAD=.../wlstack.so wine ...   (only with the Wayland driver)
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client-core.h>
#include <wayland-util.h>
#include <sys/mman.h>

#define WL_SUBCOMPOSITOR_GET_SUBSURFACE 1
#define WL_SUBSURFACE_DESTROY           0
#define WL_SUBSURFACE_PLACE_ABOVE       2
#define MAX_ARGS                        20
#define MAX_SUBSURFACES                 1024

/* XRGB fix: on KDE Plasma 6.8 with NVIDIA (GLES compositing), the unused X byte
 * of XRGB8888 wl_shm buffers is treated as alpha, although the format says to
 * ignore it. GDI leaves that byte at 0, so white comes out as transparent black:
 * dark, unreadable panels. A native Wayland client shows the same thing, so wine
 * is not the cause. Setting X = 0xff when a buffer is attached avoids it and is
 * harmless on compositors without the problem. LR_WL_NO_XFIX=1 turns it off. */
#define WL_SHM_CREATE_POOL              0
#define WL_SHM_POOL_CREATE_BUFFER       0
#define WL_SHM_POOL_DESTROY             1
#define WL_SURFACE_ATTACH               1
#define WL_BUFFER_DESTROY               0
#define SHM_FORMAT_XRGB8888             1
#define MAX_POOLS                       256
#define MAX_BUFFERS                     1024

struct pool { struct wl_proxy *proxy; int fd; int32_t size; };
struct buf { struct wl_proxy *proxy; void *map; size_t map_size; uint32_t *px; int w, h, stride; };
static struct pool pools[MAX_POOLS];
static struct buf bufs[MAX_BUFFERS];
static int pool_count, buf_count;

struct sub { struct wl_proxy *subsurface, *parent; };

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct sub subs[MAX_SUBSURFACES];
static int sub_count;

static void log_drop(struct wl_proxy *sub)
{
    const char *path = getenv("WLSTACK_LOG");
    FILE *f;

    if (!path || !(f = fopen(path, "a"))) return;
    fprintf(f, "%d dropped place_above(subsurface %u, parent)\n", (int)getpid(), wl_proxy_get_id(sub));
    fclose(f);
}

static void remember(struct wl_proxy *subsurface, struct wl_proxy *parent)
{
    pthread_mutex_lock(&lock);
    if (sub_count < MAX_SUBSURFACES)
        subs[sub_count++] = (struct sub){ subsurface, parent };
    pthread_mutex_unlock(&lock);
}

static void forget(struct wl_proxy *subsurface)
{
    int i;

    pthread_mutex_lock(&lock);
    for (i = 0; i < sub_count; i++)
        if (subs[i].subsurface == subsurface) { subs[i] = subs[--sub_count]; break; }
    pthread_mutex_unlock(&lock);
}

static int is_parent(struct wl_proxy *subsurface, struct wl_proxy *ref)
{
    int i, ret = 0;

    pthread_mutex_lock(&lock);
    for (i = 0; i < sub_count; i++)
        if (subs[i].subsurface == subsurface) { ret = subs[i].parent == ref; break; }
    pthread_mutex_unlock(&lock);
    return ret;
}

static void pool_add(struct wl_proxy *proxy, int fd, int32_t size)
{
    int dup_fd = fcntl(fd, F_DUPFD_CLOEXEC, 3);

    if (dup_fd < 0) return;
    pthread_mutex_lock(&lock);
    if (pool_count < MAX_POOLS) pools[pool_count++] = (struct pool){ proxy, dup_fd, size };
    else close(dup_fd);
    pthread_mutex_unlock(&lock);
}

static void pool_del(struct wl_proxy *proxy)
{
    int i;

    pthread_mutex_lock(&lock);
    for (i = 0; i < pool_count; i++)
        if (pools[i].proxy == proxy)
        {
            close(pools[i].fd);
            pools[i] = pools[--pool_count];
            break;
        }
    pthread_mutex_unlock(&lock);
}

static void buf_add(struct wl_proxy *pool, struct wl_proxy *proxy, const union wl_argument *a)
{
    int32_t offset = a[1].i, w = a[2].i, h = a[3].i, stride = a[4].i;
    int i;

    if (a[5].u != SHM_FORMAT_XRGB8888 || offset < 0 || w <= 0 || h <= 0 || stride < w * 4) return;
    pthread_mutex_lock(&lock);
    for (i = 0; i < pool_count; i++)
    {
        void *map;

        if (pools[i].proxy != pool) continue;
        if (buf_count == MAX_BUFFERS || (int64_t)offset + (int64_t)stride * h > pools[i].size) break;
        map = mmap(NULL, pools[i].size, PROT_READ | PROT_WRITE, MAP_SHARED, pools[i].fd, 0);
        if (map == MAP_FAILED) break;
        bufs[buf_count++] = (struct buf){ proxy, map, pools[i].size,
                                          (uint32_t *)((char *)map + offset), w, h, stride };
        break;
    }
    pthread_mutex_unlock(&lock);
}

static void buf_del(struct wl_proxy *proxy)
{
    int i;

    pthread_mutex_lock(&lock);
    for (i = 0; i < buf_count; i++)
        if (bufs[i].proxy == proxy)
        {
            munmap(bufs[i].map, bufs[i].map_size);
            bufs[i] = bufs[--buf_count];
            break;
        }
    pthread_mutex_unlock(&lock);
}

static void buf_fix(struct wl_proxy *proxy)
{
    int i, x, y;

    if (!proxy) return;
    pthread_mutex_lock(&lock);
    for (i = 0; i < buf_count; i++)
    {
        if (bufs[i].proxy != proxy) continue;
        for (y = 0; y < bufs[i].h; y++)
        {
            uint32_t *row = (uint32_t *)((char *)bufs[i].px + (size_t)y * bufs[i].stride);
            for (x = 0; x < bufs[i].w; x++) row[x] |= 0xff000000u;
        }
        break;
    }
    pthread_mutex_unlock(&lock);
}

/* Read the variadic request arguments the way libwayland does, following the
 * request's signature (e.g. "2?oiu": version prefix, '?' = nullable). */
static int parse_args(const char *sig, va_list ap, union wl_argument *args)
{
    int n = 0;

    for (; *sig; sig++)
    {
        if ((*sig >= '0' && *sig <= '9') || *sig == '?') continue;
        if (n == MAX_ARGS) return -1;
        switch (*sig)
        {
        case 'i': args[n].i = va_arg(ap, int32_t); break;
        case 'u': args[n].u = va_arg(ap, uint32_t); break;
        case 'f': args[n].f = va_arg(ap, wl_fixed_t); break;
        case 's': args[n].s = va_arg(ap, const char *); break;
        case 'o': args[n].o = va_arg(ap, struct wl_object *); break;
        case 'n': args[n].o = va_arg(ap, struct wl_object *); break;
        case 'a': args[n].a = va_arg(ap, struct wl_array *); break;
        case 'h': args[n].h = va_arg(ap, int32_t); break;
        default:  return -1;
        }
        n++;
    }
    return n;
}

struct wl_proxy *wl_proxy_marshal_flags(struct wl_proxy *proxy, uint32_t opcode,
                                        const struct wl_interface *interface,
                                        uint32_t version, uint32_t flags, ...)
{
    const struct wl_interface *iface = wl_proxy_get_interface(proxy);
    union wl_argument args[MAX_ARGS];
    struct wl_proxy *ret;
    static int xfix = -1;
    va_list ap;
    int n;

    if (!iface || opcode >= (uint32_t)iface->method_count) abort();

    va_start(ap, flags);
    n = parse_args(iface->methods[opcode].signature, ap, args);
    va_end(ap);
    if (n < 0) abort();

    if (xfix < 0) xfix = !getenv("LR_WL_NO_XFIX");
    if (xfix)
    {
        if (opcode == WL_SURFACE_ATTACH && !strcmp(iface->name, "wl_surface"))
            buf_fix((struct wl_proxy *)args[0].o);
        else if (opcode == WL_SHM_POOL_DESTROY && !strcmp(iface->name, "wl_shm_pool"))
            pool_del(proxy);
        else if (opcode == WL_BUFFER_DESTROY && !strcmp(iface->name, "wl_buffer"))
            buf_del(proxy);
    }

    if (!strcmp(iface->name, "wl_subsurface"))
    {
        if (opcode == WL_SUBSURFACE_PLACE_ABOVE && is_parent(proxy, (struct wl_proxy *)args[0].o))
        {
            log_drop(proxy);
            return NULL;
        }
        if (opcode == WL_SUBSURFACE_DESTROY) forget(proxy);
    }

    ret = wl_proxy_marshal_array_flags(proxy, opcode, interface, version, flags, args);

    if (xfix && ret)
    {
        if (opcode == WL_SHM_CREATE_POOL && !strcmp(iface->name, "wl_shm"))
            pool_add(ret, args[1].h, args[2].i);
        else if (opcode == WL_SHM_POOL_CREATE_BUFFER && !strcmp(iface->name, "wl_shm_pool"))
            buf_add(proxy, ret, args);
    }

    if (ret && opcode == WL_SUBCOMPOSITOR_GET_SUBSURFACE && !strcmp(iface->name, "wl_subcompositor"))
        remember(ret, (struct wl_proxy *)args[2].o);   /* args: new_id, surface, parent */
    return ret;
}
