/*
 * fix_ghost.c — fixes stale-paint "ghosting" / blank panels in Lightroom
 * Classic's dialogs under wine (Export preset tree, Copy Settings).
 *
 * TWO SEPARATE wine repaint bugs, both verified live by driving the dialogs
 * under automation (wine 11.10 staging):
 *
 *   1. EXPORT PRESET TREE — one owner-data SysListView32
 *      (LVS_OWNERDATA|LVS_OWNERDRAWFIXED). Collapsing a group shrinks the item
 *      count via LVM_SETITEMCOUNT; wine updates the count and repaints the
 *      surviving rows but NEVER erases the area the removed rows occupied (its
 *      item-geometry path is broken for this style: LVM_GETITEMRECT returns
 *      empty rects, so the computed erase region is empty and even a forced
 *      RDW_ERASE is a no-op). The old row pixels stay → "ghost" rows.
 *
 *   2. COPY SETTINGS CHECKBOXES — the left settings panel is built from Button
 *      checkbox controls whose Adobe subclass swallows WM_PAINT without
 *      BeginPaint/ValidateRect, so they never draw a pixel (their update region
 *      stays dirty forever; LR burns idle CPU on the ignored paint requests).
 *      Things that DON'T work, confirmed live: forcing WM_PAINT through wine's
 *      builtin Button proc (relies on BeginPaint, paints nothing);
 *      external-process GetDC (lands on a different surface than the composited
 *      window). What DOES reach the screen is an IN-PROCESS GDI draw.
 *
 * FIX (a WH_CALLWNDPROC hook on Lightroom's UI thread, acting ONLY inside
 * modal dialogs — see root_is_dialog: a top-level WS_POPUP MFC "Afx:*" window
 * or a "#32770", never the GPU-composited AgWinMainFrame or its child Afx
 * views, which must not be touched or they go black):
 *
 *   1. LVM_SETITEMCOUNT to a dialog SysListView32 → erase the listview's
 *      client area ourselves (FillRect with its LVM_GETBKCOLOR) and invalidate,
 *      so wine repaints the real rows over the fill. Coalesced and flushed once
 *      per burst by a low-priority WM_TIMER (fires only when the queue is idle).
 *
 *   2. Copy Settings checkboxes → we SUBCLASS each one and own its WM_PAINT:
 *      our proc draws the checkbox (DrawFrameControl with the real BM_GETCHECK
 *      state) + its label (DrawText, control's own font, parent's
 *      WM_CTLCOLORBTN background) and validates. Because we own every paint,
 *      the control stays drawn through hover/click repaints (an earlier
 *      approach that only repainted on observed messages blanked again on
 *      mouse-over). New controls are picked up by a light repeating sweep while
 *      the dialog is open; subclassing is restricted to checkbox-heavy dialogs
 *      (>=20 visible checkboxes) so it targets Copy Settings and nothing else.
 *
 *   No part of the fix ever does a broad RDW_ERASE on a parent/ancestor — an
 *   earlier build did (chasing a wrong "vacated child" theory) and blacked out
 *   GPU-composited windows that happened to share the generic "Afx:*" class.
 *
 *   A message hook is used rather than inline-patching user32: wine's user32
 *   geometry wrappers are thin jmp-thunks to win32u whose first bytes are not
 *   safely relocatable for a trampoline (that crashes). SetWindowsHookEx is a
 *   supported API and can't fault like a bad trampoline.
 *
 * INJECTION
 *   wine has no AppInit_DLLs support, so this ships as a proxy version.dll:
 *   Lightroom loads version.dll early; our build forwards version's 16 exports
 *   to version_orig.dll (a copy of wine's builtin PE version.dll, placed
 *   beside it) and runs this DllMain. Loading it process-wide via
 *   WINEDLLOVERRIDES=version=n broke the 32-bit Adobe helper processes, so
 *   install-lightroom-classic-fixes.sh scopes the override to Lightroom.exe
 *   alone (HKCU\Software\Wine\AppDefaults\Lightroom.exe\DllOverrides
 *   version=native,builtin) and drops both DLLs into Lightroom's install dir
 *   (first in the native search path; every exe there is 64-bit). version.dll
 *   loads on the UI thread during process init, so GetCurrentThreadId() in
 *   DllMain is the thread the dialogs live on.
 *
 * DEBUGGING
 *   FIXGHOST_LOG=<path>      append-mode trace of hook activity.
 *   FIXGHOST_DEBUGFILL=1     paint checkboxes bright red (prove the DC reaches
 *                            the screen) instead of drawing them normally.
 */
#include <windows.h>
#include <commctrl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

static HHOOK g_hook;
static UINT_PTR g_lv_timer;
static UINT_PTR g_sweep_timer;
static HWND g_dialog;        /* dialog root currently being swept for checkboxes */
static int g_in_self;        /* re-entrancy guard around our own paints */
static FILE *g_dbg;

static void dbg(const char *fmt, ...)
{
    va_list ap;
    if (!g_dbg) return;
    va_start(ap, fmt);
    vfprintf(g_dbg, fmt, ap);
    va_end(ap);
    fflush(g_dbg);
}

/* A "dialog" we may touch is a MODAL POPUP: a top-level "#32770", or an MFC
 * "Afx:*" window that is WS_POPUP and not WS_CHILD. This deliberately excludes
 * the AgWinMainFrame main window AND the child "Afx:*" views inside it (which
 * are GPU-composited — drawing on them turns them black). */
static int root_is_dialog(HWND hwnd)
{
    WCHAR cls[64];
    HWND root = GetAncestor(hwnd, GA_ROOT);
    LONG style;
    if (!root || !GetClassNameW(root, cls, ARRAYSIZE(cls))) return 0;
    if (!wcscmp(cls, L"#32770")) return 1;
    if (wcsncmp(cls, L"Afx:", 4)) return 0;
    style = GetWindowLongW(root, GWL_STYLE);
    return (style & WS_POPUP) && !(style & WS_CHILD);
}

static int is_listview(HWND hwnd)
{
    WCHAR cls[32];
    if (!GetClassNameW(hwnd, cls, ARRAYSIZE(cls))) return 0;
    return !lstrcmpiW(cls, L"SysListView32");
}

static int is_check_control(HWND hwnd)
{
    WCHAR cls[32];
    LONG type;
    if (!GetClassNameW(hwnd, cls, ARRAYSIZE(cls)) || lstrcmpiW(cls, L"Button")) return 0;
    type = GetWindowLongW(hwnd, GWL_STYLE) & BS_TYPEMASK;
    return type == BS_CHECKBOX || type == BS_AUTOCHECKBOX
        || type == BS_3STATE || type == BS_AUTO3STATE
        || type == BS_RADIOBUTTON || type == BS_AUTORADIOBUTTON;
}

/* ---- bug 1: Export owner-data listview leaves removed rows painted -------- */

/* Erase the listview client with its own background colour, then invalidate so
 * wine repaints the surviving rows over the fill. (wine's RDW_ERASE is a no-op
 * for this owner-data control, so we erase explicitly.) */
static void erase_and_repaint_listview(HWND hwnd)
{
    RECT rc;
    HDC dc;
    HBRUSH br;
    COLORREF clr = (COLORREF)SendMessageW(hwnd, LVM_GETBKCOLOR, 0, 0);
    if (clr == CLR_NONE || clr == CLR_DEFAULT) clr = GetSysColor(COLOR_WINDOW);
    if (!GetClientRect(hwnd, &rc)) return;
    if ((dc = GetDC(hwnd))) {
        if ((br = CreateSolidBrush(clr))) {
            FillRect(dc, &rc, br);
            DeleteObject(br);
        }
        ReleaseDC(hwnd, dc);
    }
    RedrawWindow(hwnd, NULL, NULL, RDW_INVALIDATE | RDW_ALLCHILDREN);
}

#define MAX_LV 16
static HWND g_lv[MAX_LV];
static int g_lv_n;

static void CALLBACK lv_flush(HWND hwnd, UINT msg, UINT_PTR id, DWORD t)
{
    int i;
    (void)hwnd; (void)msg; (void)t;
    KillTimer(NULL, id);
    g_lv_timer = 0;
    g_in_self = 1;
    for (i = 0; i < g_lv_n; i++)
        if (IsWindow(g_lv[i])) {
            dbg("lv flush: %p\n", (void *)g_lv[i]);
            erase_and_repaint_listview(g_lv[i]);
        }
    g_lv_n = 0;
    g_in_self = 0;
}

static void queue_listview(HWND hwnd)
{
    int i;
    for (i = 0; i < g_lv_n; i++)
        if (g_lv[i] == hwnd) return;
    if (g_lv_n < MAX_LV) g_lv[g_lv_n++] = hwnd;
    if (!g_lv_timer) g_lv_timer = SetTimer(NULL, 0, 30, lv_flush);
}

/* ---- bug 2: Copy Settings checkboxes never paint (subclass + self-draw) --- */

#define MAX_SUB 256
static struct { HWND hwnd; WNDPROC orig; } g_sub[MAX_SUB];
static int g_sub_n;

static WNDPROC sub_orig(HWND hwnd)
{
    int i;
    for (i = 0; i < g_sub_n; i++)
        if (g_sub[i].hwnd == hwnd) return g_sub[i].orig;
    return NULL;
}

static void sub_remove(HWND hwnd)
{
    int i;
    for (i = 0; i < g_sub_n; i++)
        if (g_sub[i].hwnd == hwnd) { g_sub[i] = g_sub[--g_sub_n]; return; }
}

/* Draw a checkbox/radio control into dc: parent-coloured background, the box
 * (with real check state), and the label in the control's font. */
static void draw_check(HWND hwnd, HDC dc)
{
    RECT rc, box, txt;
    HFONT font;
    HGDIOBJ old_font = NULL;
    HBRUSH bg;
    LONG style, type;
    int side, top, checked, radio;
    UINT dfcs;
    WCHAR text[256];

    if (!GetClientRect(hwnd, &rc) || IsRectEmpty(&rc)) return;

    if (getenv("FIXGHOST_DEBUGFILL")) {
        HBRUSH rb = CreateSolidBrush(RGB(255, 0, 0));
        FillRect(dc, &rc, rb);
        DeleteObject(rb);
        return;
    }

    /* Background matching the panel (the control area must be cleared each
     * paint or hover-state redraws would smear over old text). */
    bg = (HBRUSH)SendMessageW(GetParent(hwnd), WM_CTLCOLORBTN, (WPARAM)dc, (LPARAM)hwnd);
    if (!bg) bg = GetSysColorBrush(COLOR_3DFACE);
    FillRect(dc, &rc, bg);

    style = GetWindowLongW(hwnd, GWL_STYLE);
    type = style & BS_TYPEMASK;
    radio = (type == BS_RADIOBUTTON || type == BS_AUTORADIOBUTTON);
    checked = (int)SendMessageW(hwnd, BM_GETCHECK, 0, 0);

    side = rc.bottom - rc.top;
    if (side > 13) side = 13;
    top = (rc.bottom - rc.top - side) / 2;
    box = rc;
    if (style & BS_LEFTTEXT) {           /* box on the right, text left of it */
        box.left = rc.right - side;
        txt = rc; txt.right = box.left - 4;
    } else {                             /* box on the left, text right of it */
        box.right = rc.left + side;
        txt = rc; txt.left = rc.left + side + 4;
    }
    box.top = top;
    box.bottom = top + side;

    dfcs = (radio ? DFCS_BUTTONRADIO : DFCS_BUTTONCHECK);
    if (checked == BST_CHECKED) dfcs |= DFCS_CHECKED;
    else if (checked == BST_INDETERMINATE) dfcs |= DFCS_CHECKED | DFCS_BUTTON3STATE;
    DrawFrameControl(dc, &box, DFC_BUTTON, dfcs);

    if (GetWindowTextW(hwnd, text, ARRAYSIZE(text)) > 0) {
        font = (HFONT)SendMessageW(hwnd, WM_GETFONT, 0, 0);
        if (font) old_font = SelectObject(dc, font);
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, GetSysColor(IsWindowEnabled(hwnd) ? COLOR_BTNTEXT : COLOR_GRAYTEXT));
        DrawTextW(dc, text, -1, &txt,
                  DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX | DT_END_ELLIPSIS);
        if (old_font) SelectObject(dc, old_font);
    }
}

static LRESULT CALLBACK check_subproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    WNDPROC orig = sub_orig(hwnd);
    if (!orig) return DefWindowProcW(hwnd, msg, wp, lp);
    switch (msg) {
    case WM_ERASEBKGND:
        return 1;                        /* we clear the client in WM_PAINT */
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        if (dc) draw_check(hwnd, dc);
        EndPaint(hwnd, &ps);
        return 0;
    }
    case BM_SETCHECK: {
        LRESULT r = CallWindowProcW(orig, hwnd, msg, wp, lp);
        InvalidateRect(hwnd, NULL, FALSE);   /* redraw new state via our WM_PAINT */
        return r;
    }
    case WM_DESTROY: {
        LRESULT r = CallWindowProcW(orig, hwnd, msg, wp, lp);
        SetWindowLongPtrW(hwnd, GWLP_WNDPROC, (LONG_PTR)orig);
        sub_remove(hwnd);
        return r;
    }
    }
    return CallWindowProcW(orig, hwnd, msg, wp, lp);
}

static void subclass_check(HWND hwnd)
{
    WNDPROC orig;
    if (sub_orig(hwnd) || g_sub_n >= MAX_SUB) return;
    orig = (WNDPROC)GetWindowLongPtrW(hwnd, GWLP_WNDPROC);
    if (orig == check_subproc) return;
    g_sub[g_sub_n].hwnd = hwnd;
    g_sub[g_sub_n].orig = orig;
    g_sub_n++;
    SetWindowLongPtrW(hwnd, GWLP_WNDPROC, (LONG_PTR)check_subproc);
    InvalidateRect(hwnd, NULL, TRUE);
    dbg("subclassed checkbox %p\n", (void *)hwnd);
}

static BOOL CALLBACK count_checks_cb(HWND hwnd, LPARAM lp)
{
    int *count = (int *)lp;
    if (IsWindowVisible(hwnd) && is_check_control(hwnd) && ++*count >= 20)
        return FALSE;
    return TRUE;
}

/* Copy Settings, identified structurally (not by localised title): an MFC
 * dialog with many visible standard checkbox controls. */
static int is_copy_settings_dialog(HWND root)
{
    int count = 0;
    if (!root || !root_is_dialog(root)) return 0;
    EnumChildWindows(root, count_checks_cb, (LPARAM)&count);
    return count >= 20;
}

static BOOL CALLBACK subclass_cb(HWND hwnd, LPARAM lp)
{
    if (IsWindowVisible(hwnd) && is_check_control(hwnd)) {
        subclass_check(hwnd);
        (*(int *)lp)++;
    }
    return TRUE;
}

/* Repeating while the dialog is open: subclass any not-yet-handled checkbox
 * (controls can be created after the dialog first appears). Cheap, and stops
 * itself once the dialog is gone. */
static void CALLBACK sweep_timer(HWND hwnd, UINT msg, UINT_PTR id, DWORD t)
{
    int n = 0;
    (void)hwnd; (void)msg; (void)t;
    if (!IsWindow(g_dialog) || !IsWindowVisible(g_dialog) || !is_copy_settings_dialog(g_dialog)) {
        KillTimer(NULL, id);
        g_sweep_timer = 0;
        g_dialog = NULL;
        return;
    }
    g_in_self = 1;
    EnumChildWindows(g_dialog, subclass_cb, (LPARAM)&n);
    g_in_self = 0;
}

static void arm_sweep(HWND root)
{
    g_dialog = root;
    if (!g_sweep_timer) g_sweep_timer = SetTimer(NULL, 0, 200, sweep_timer);
}

static LRESULT CALLBACK call_wnd_proc(int code, WPARAM wParam, LPARAM lParam)
{
    if (code == HC_ACTION && !g_in_self) {
        const CWPSTRUCT *p = (const CWPSTRUCT *)lParam;
        HWND root = GetAncestor(p->hwnd, GA_ROOT);
        switch (p->message) {
        case LVM_SETITEMCOUNT:
            if (is_listview(p->hwnd) && root_is_dialog(p->hwnd))
                queue_listview(p->hwnd);
            break;
        /* Arm the checkbox sweep on common paint/activation traffic to any
         * dialog popup; the sweep's own is_copy_settings_dialog gate decides
         * whether to act and self-kills otherwise. (WM_INITDIALOG isn't sent
         * for this MFC window, and at WM_SHOWWINDOW the checkboxes don't exist
         * yet — so gating the trigger on the checkbox count missed it.) */
        case WM_PAINT:
        case WM_ACTIVATE:
        case WM_SHOWWINDOW:
        case WM_COMMAND:
            if (root && root_is_dialog(root)) arm_sweep(root);
            break;
        }
    }
    return CallNextHookEx(g_hook, code, wParam, lParam);
}

/* Only act inside Lightroom.exe — defence in depth on top of the per-app
 * DllOverride. Inline ASCII lowercase (no CRT locale dep). */
static int is_lightroom(void)
{
    wchar_t path[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, path, MAX_PATH);
    if (!n) return 0;
    for (DWORD i = 0; i < n; i++)
        if (path[i] >= L'A' && path[i] <= L'Z') path[i] += 32;
    return wcsstr(path, L"lightroom.exe") != NULL;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID resv)
{
    if (reason == DLL_PROCESS_ATTACH) {
        const char *log = getenv("FIXGHOST_LOG");
        DisableThreadLibraryCalls(inst);
        if (log) g_dbg = fopen(log, "a");
        if (is_lightroom()) {
            g_hook = SetWindowsHookExW(WH_CALLWNDPROC, call_wnd_proc, inst, GetCurrentThreadId());
            dbg("attach: tid=%lu hook=%p\n", (unsigned long)GetCurrentThreadId(), (void *)g_hook);
        } else {
            dbg("attach: not Lightroom.exe, hook skipped\n");
        }
    } else if (reason == DLL_PROCESS_DETACH) {
        if (!resv) {
            if (g_lv_timer) KillTimer(NULL, g_lv_timer);
            if (g_sweep_timer) KillTimer(NULL, g_sweep_timer);
            if (g_hook) UnhookWindowsHookEx(g_hook);
        }
        if (g_dbg) fclose(g_dbg);
    }
    return TRUE;
}
