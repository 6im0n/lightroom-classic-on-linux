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
 * Build: gcc -shared -fPIC -O2 -o resources/stubs/binaries/wlstack.so \
 *            resources/stubs/sources/wlstack.c -lwayland-client -lpthread
 * Use:   LD_PRELOAD=.../wlstack.so wine ...   (only with the Wayland driver)
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client-core.h>
#include <wayland-util.h>

#define WL_SUBCOMPOSITOR_GET_SUBSURFACE 1
#define WL_SUBSURFACE_DESTROY           0
#define WL_SUBSURFACE_PLACE_ABOVE       2
#define MAX_ARGS                        20
#define MAX_SUBSURFACES                 1024

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
    va_list ap;
    int n;

    if (!iface || opcode >= (uint32_t)iface->method_count) abort();

    va_start(ap, flags);
    n = parse_args(iface->methods[opcode].signature, ap, args);
    va_end(ap);
    if (n < 0) abort();

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

    if (ret && opcode == WL_SUBCOMPOSITOR_GET_SUBSURFACE && !strcmp(iface->name, "wl_subcompositor"))
        remember(ret, (struct wl_proxy *)args[2].o);   /* args: new_id, surface, parent */
    return ret;
}
