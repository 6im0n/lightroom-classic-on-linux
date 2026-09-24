/* x11cursor.c — LD_PRELOAD shim: keep the mouse pointer visible over the
 * Creative Cloud installer / sign-in windows under wine + Xwayland.
 *
 * The sign-in page is an Edge WebView2 child window owned by a different
 * process (msedgewebview2.exe) than its top-level window (the Adobe
 * bootstrapper). When WebView2 sets a cursor, wine asks the top-level window's
 * process to apply it, and that process can't use a cursor handle from another
 * process ("get_icon_ptr icon handle ... from other process"), so nothing
 * valid is ever defined. On top of that wine hides the pointer by defining a
 * blank 1x1 pixmap cursor, including on the root window (the desktop window
 * when there is no virtual desktop). Result: the pointer vanishes.
 *
 * The shim:
 *   - remembers every 1x1 pixmap cursor (wine's "empty cursor") and swaps it
 *     for the left_ptr arrow whenever wine defines it on a window;
 *   - gives top-level windows created without a cursor the arrow, so a window
 *     whose cursor could never be set still shows one.
 * Real cursors wine manages to create are left alone. Shapes WebView2 picks
 * (I-beam, hand) still come out as arrows.
 *
 * X11CURSOR_LOG=/path appends one line per XDefineCursor call (debugging).
 *
 * Build: gcc -shared -fPIC -O2 -o resources/stubs/binaries/x11cursor.so \
 *            resources/stubs/sources/x11cursor.c -ldl -lX11
 * Use:   LD_PRELOAD=.../x11cursor.so wine Creative_Cloud_Set-Up.exe
 */
#define _GNU_SOURCE
#include <X11/Xlib.h>
#include <X11/cursorfont.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define MAX_EMPTY 16

typedef Window (*create_window_fn)(Display *, Window, int, int, unsigned int,
        unsigned int, unsigned int, int, unsigned int, Visual *,
        unsigned long, XSetWindowAttributes *);
typedef Cursor (*create_pixmap_cursor_fn)(Display *, Pixmap, Pixmap, XColor *,
        XColor *, unsigned int, unsigned int);
typedef int (*define_cursor_fn)(Display *, Window, Cursor);

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static Cursor arrow;
static Cursor empty[MAX_EMPTY];
static int empty_count;

static void log_line(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void log_line(const char *fmt, ...)
{
    const char *path = getenv("X11CURSOR_LOG");
    FILE *f;
    va_list ap;

    if (!path || !(f = fopen(path, "a"))) return;
    fprintf(f, "%d ", (int)getpid());
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

/* Cursor XIDs are server-wide, so one created on any of wine's (long-lived)
 * connections works on the others. */
static Cursor get_arrow(Display *display)
{
    Cursor ret;

    pthread_mutex_lock(&lock);
    if (!arrow) arrow = XCreateFontCursor(display, XC_left_ptr);
    ret = arrow;
    pthread_mutex_unlock(&lock);
    return ret;
}

static int is_empty(Cursor cursor)
{
    int i, ret = 0;

    pthread_mutex_lock(&lock);
    for (i = 0; i < empty_count; i++) if (empty[i] == cursor) ret = 1;
    pthread_mutex_unlock(&lock);
    return ret;
}

Cursor XCreatePixmapCursor(Display *display, Pixmap source, Pixmap mask,
        XColor *fg, XColor *bg, unsigned int x, unsigned int y)
{
    static create_pixmap_cursor_fn real;
    unsigned int w = 0, h = 0, border, depth;
    int px, py;
    Window root;
    Cursor cursor;

    if (!real) real = (create_pixmap_cursor_fn)dlsym(RTLD_NEXT, "XCreatePixmapCursor");
    cursor = real(display, source, mask, fg, bg, x, y);

    if (cursor && XGetGeometry(display, source, &root, &px, &py, &w, &h, &border, &depth)
            && w == 1 && h == 1)
    {
        pthread_mutex_lock(&lock);
        if (empty_count < MAX_EMPTY) empty[empty_count++] = cursor;
        pthread_mutex_unlock(&lock);
        log_line("empty cursor %lx", cursor);
    }
    return cursor;
}

int XDefineCursor(Display *display, Window window, Cursor cursor)
{
    static define_cursor_fn real;
    int blank = is_empty(cursor);

    if (!real) real = (define_cursor_fn)dlsym(RTLD_NEXT, "XDefineCursor");
    log_line("define win %lx%s cursor %lx%s", window,
             window == DefaultRootWindow(display) ? " (root)" : "", cursor,
             blank ? " (empty -> arrow)" : "");
    if (blank) cursor = get_arrow(display);
    return real(display, window, cursor);
}

Window XCreateWindow(Display *display, Window parent, int x, int y,
        unsigned int width, unsigned int height, unsigned int border_width,
        int depth, unsigned int class, Visual *visual, unsigned long valuemask,
        XSetWindowAttributes *attributes)
{
    static create_window_fn real;
    XSetWindowAttributes attr = {0};

    if (!real) real = (create_window_fn)dlsym(RTLD_NEXT, "XCreateWindow");

    if (class != InputOnly && !(valuemask & CWCursor)
            && parent == DefaultRootWindow(display))
    {
        if (attributes) attr = *attributes;
        attr.cursor = get_arrow(display);
        attributes = &attr;
        valuemask |= CWCursor;
    }
    else if ((valuemask & CWCursor) && attributes && is_empty(attributes->cursor))
    {
        attr = *attributes;
        attr.cursor = get_arrow(display);
        attributes = &attr;
    }

    return real(display, parent, x, y, width, height, border_width, depth,
                class, visual, valuemask, attributes);
}
