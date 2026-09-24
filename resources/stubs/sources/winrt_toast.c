/* winrt_toast.c — minimal Windows.UI.Notifications.ToastNotificationManager.
 *
 * The Creative Cloud desktop app (6.10) asks for the ToastNotificationManager
 * activation factory while it starts. wine has no implementation, so
 * RoGetActivationFactory fails with REGDB_E_CLASSNOTREG and Creative
 * Cloud.exe dereferences the NULL factory (access violation at
 * Creative Cloud.exe+0x65f9e): the window sits on "Initializing Creative
 * Cloud..." and then dies.
 *
 * This DLL provides the factory (IToastNotificationManagerStatics and
 * Statics2). Its toast notifier reports notifications as disabled for the app
 * and silently accepts Show/Hide; its history has nothing to remove. CC
 * carries on without desktop notifications.
 *
 * Registered under
 *   HKLM\Software\Microsoft\WindowsRuntime\ActivatableClassId\
 *        Windows.UI.Notifications.ToastNotificationManager  DllPath=...
 * by resources/scripts/creative-cloud/install-winrt-toast.sh.
 *
 * WINRT_TOAST_LOG=Z:\path\file.log logs every call (debugging).
 *
 * Build: x86_64-w64-mingw32-gcc -shared -O2 -o winrt_toast.dll winrt_toast.c \
 *            -s -lole32 -luuid -lwindowsapp
 */
#define COBJMACROS
#include <windows.h>
#include <stdio.h>
#include <stdarg.h>
#include <roapi.h>
#include <activation.h>
#include <winstring.h>

static const IID IID_IInspectable_ =
    {0xaf86e2e0, 0xb12d, 0x4c6a, {0x9c,0x5a,0xd7,0xaa,0x65,0x10,0x1e,0x90}};
static const IID IID_IActivationFactory_ =
    {0x00000035, 0x0000, 0x0000, {0xc0,0x00,0x00,0x00,0x00,0x00,0x00,0x46}};
static const IID IID_IToastNotificationManagerStatics =
    {0x50ac103f, 0xd235, 0x4598, {0xbb,0xef,0x98,0xfe,0x4d,0x1a,0x3a,0xd4}};
static const IID IID_IToastNotificationManagerStatics2 =
    {0x7ab93c52, 0x0e48, 0x4750, {0xba,0x9d,0x1a,0x41,0x13,0x98,0x18,0x47}};
static const IID IID_IToastNotificationHistory =
    {0x5caddc63, 0x01d3, 0x4c97, {0x98,0x6f,0x05,0x33,0x48,0x3f,0xee,0x14}};
static const IID IID_IToastNotifier =
    {0x75927b93, 0x03f3, 0x41ec, {0x91,0xd3,0x6e,0x5b,0xac,0x1b,0x38,0xe7}};

enum { NotificationSetting_DisabledForApplication = 1 };

static void trace(const char *fmt, ...)
{
    char path[MAX_PATH];
    FILE *f;
    va_list ap;

    if (!GetEnvironmentVariableA("WINRT_TOAST_LOG", path, sizeof(path))) return;
    if (!(f = fopen(path, "a"))) return;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static void trace_iid(const char *what, REFIID iid)
{
    trace("%s {%08lx-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x}", what,
          iid->Data1, iid->Data2, iid->Data3, iid->Data4[0], iid->Data4[1],
          iid->Data4[2], iid->Data4[3], iid->Data4[4], iid->Data4[5],
          iid->Data4[6], iid->Data4[7]);
}

/* ---- IInspectable plumbing shared by both objects ------------------------ */

typedef struct {
    HRESULT (WINAPI *QueryInterface)(void *, REFIID, void **);
    ULONG   (WINAPI *AddRef)(void *);
    ULONG   (WINAPI *Release)(void *);
    HRESULT (WINAPI *GetIids)(void *, ULONG *, IID **);
    HRESULT (WINAPI *GetRuntimeClassName)(void *, HSTRING *);
    HRESULT (WINAPI *GetTrustLevel)(void *, TrustLevel *);
} inspectable_vtbl;

static HRESULT WINAPI insp_GetIids(void *iface, ULONG *count, IID **iids)
{
    *count = 0;
    *iids = NULL;
    return S_OK;
}

static HRESULT WINAPI insp_GetTrustLevel(void *iface, TrustLevel *level)
{
    *level = BaseTrust;
    return S_OK;
}

/* ---- IToastNotifier ----------------------------------------------------- */

typedef struct {
    inspectable_vtbl base;
    HRESULT (WINAPI *Show)(void *, void *);
    HRESULT (WINAPI *Hide)(void *, void *);
    HRESULT (WINAPI *get_Setting)(void *, INT32 *);
    HRESULT (WINAPI *AddToSchedule)(void *, void *);
    HRESULT (WINAPI *RemoveFromSchedule)(void *, void *);
    HRESULT (WINAPI *GetScheduledToastNotifications)(void *, void **);
} notifier_vtbl;

typedef struct { const notifier_vtbl *vtbl; LONG ref; } notifier;

static HRESULT WINAPI notifier_QueryInterface(void *iface, REFIID iid, void **out)
{
    notifier *self = iface;

    if (IsEqualIID(iid, &IID_IUnknown) || IsEqualIID(iid, &IID_IInspectable_)
            || IsEqualIID(iid, &IID_IToastNotifier))
    {
        InterlockedIncrement(&self->ref);
        *out = self;
        return S_OK;
    }
    trace_iid("notifier: no interface", iid);
    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG WINAPI notifier_AddRef(void *iface)
{
    return InterlockedIncrement(&((notifier *)iface)->ref);
}

static ULONG WINAPI notifier_Release(void *iface)
{
    notifier *self = iface;
    ULONG ref = InterlockedDecrement(&self->ref);
    if (!ref) HeapFree(GetProcessHeap(), 0, self);
    return ref;
}

static HRESULT WINAPI notifier_GetRuntimeClassName(void *iface, HSTRING *name)
{
    static const WCHAR cls[] = L"Windows.UI.Notifications.ToastNotifier";
    return WindowsCreateString(cls, ARRAYSIZE(cls) - 1, name);
}

static HRESULT WINAPI notifier_Show(void *iface, void *toast)
{
    trace("notifier: Show (dropped)");
    return S_OK;
}

static HRESULT WINAPI notifier_Hide(void *iface, void *toast)
{
    trace("notifier: Hide");
    return S_OK;
}

static HRESULT WINAPI notifier_get_Setting(void *iface, INT32 *setting)
{
    trace("notifier: get_Setting -> DisabledForApplication");
    *setting = NotificationSetting_DisabledForApplication;
    return S_OK;
}

static HRESULT WINAPI notifier_AddToSchedule(void *iface, void *toast)
{
    trace("notifier: AddToSchedule (dropped)");
    return S_OK;
}

static HRESULT WINAPI notifier_RemoveFromSchedule(void *iface, void *toast)
{
    trace("notifier: RemoveFromSchedule");
    return S_OK;
}

static HRESULT WINAPI notifier_GetScheduled(void *iface, void **list)
{
    trace("notifier: GetScheduledToastNotifications -> E_NOTIMPL");
    *list = NULL;
    return E_NOTIMPL;
}

static const notifier_vtbl notifier_vtable = {
    { notifier_QueryInterface, notifier_AddRef, notifier_Release,
      insp_GetIids, notifier_GetRuntimeClassName, insp_GetTrustLevel },
    notifier_Show, notifier_Hide, notifier_get_Setting,
    notifier_AddToSchedule, notifier_RemoveFromSchedule, notifier_GetScheduled,
};

static HRESULT create_notifier(void **out)
{
    notifier *self = HeapAlloc(GetProcessHeap(), 0, sizeof(*self));

    if (!self) return E_OUTOFMEMORY;
    self->vtbl = &notifier_vtable;
    self->ref = 1;
    *out = self;
    return S_OK;
}

/* ---- IToastNotificationHistory: nothing is ever shown, so nothing to remove */

typedef struct {
    inspectable_vtbl base;
    HRESULT (WINAPI *RemoveGroup)(void *, HSTRING);
    HRESULT (WINAPI *RemoveGroupWithId)(void *, HSTRING, HSTRING);
    HRESULT (WINAPI *RemoveGroupedTagWithId)(void *, HSTRING, HSTRING, HSTRING);
    HRESULT (WINAPI *RemoveGroupedTag)(void *, HSTRING, HSTRING);
    HRESULT (WINAPI *Remove)(void *, HSTRING);
    HRESULT (WINAPI *Clear)(void *);
    HRESULT (WINAPI *ClearWithId)(void *, HSTRING);
} history_vtbl;

static const history_vtbl *history;   /* static object, never freed */

static HRESULT WINAPI history_QueryInterface(void *iface, REFIID iid, void **out)
{
    if (IsEqualIID(iid, &IID_IUnknown) || IsEqualIID(iid, &IID_IInspectable_)
            || IsEqualIID(iid, &IID_IAgileObject)
            || IsEqualIID(iid, &IID_IToastNotificationHistory))
    {
        *out = &history;
        return S_OK;
    }
    trace_iid("history: no interface", iid);
    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG WINAPI static_AddRef(void *iface) { return 2; }
static ULONG WINAPI static_Release(void *iface) { return 1; }

static HRESULT WINAPI history_GetRuntimeClassName(void *iface, HSTRING *name)
{
    static const WCHAR cls[] = L"Windows.UI.Notifications.ToastNotificationHistory";
    return WindowsCreateString(cls, ARRAYSIZE(cls) - 1, name);
}

static HRESULT WINAPI history_1(void *iface, HSTRING a) { trace("history: remove/clear"); return S_OK; }
static HRESULT WINAPI history_2(void *iface, HSTRING a, HSTRING b) { trace("history: remove"); return S_OK; }
static HRESULT WINAPI history_3(void *iface, HSTRING a, HSTRING b, HSTRING c) { trace("history: remove"); return S_OK; }
static HRESULT WINAPI history_0(void *iface) { trace("history: clear"); return S_OK; }

static const history_vtbl history_vtable = {
    { history_QueryInterface, static_AddRef, static_Release,
      insp_GetIids, history_GetRuntimeClassName, insp_GetTrustLevel },
    history_1, history_2, history_3, history_2, history_1, history_0, history_1,
};

/* ---- factory: IActivationFactory + IToastNotificationManagerStatics(2) ---- */

typedef struct {
    inspectable_vtbl base;
    HRESULT (WINAPI *ActivateInstance)(void *, IInspectable **);
} activation_vtbl;

typedef struct {
    inspectable_vtbl base;
    HRESULT (WINAPI *CreateToastNotifier)(void *, void **);
    HRESULT (WINAPI *CreateToastNotifierWithId)(void *, HSTRING, void **);
    HRESULT (WINAPI *GetTemplateContent)(void *, INT32, void **);
} statics_vtbl;

typedef struct {
    inspectable_vtbl base;
    HRESULT (WINAPI *get_History)(void *, void **);
} statics2_vtbl;

/* One static object with two interface pointers; never freed. */
static struct {
    const activation_vtbl *activation;
    const statics_vtbl *statics;
    const statics2_vtbl *statics2;
} factory;

static HRESULT factory_qi(REFIID iid, void **out)
{
    if (IsEqualIID(iid, &IID_IUnknown) || IsEqualIID(iid, &IID_IInspectable_)
            || IsEqualIID(iid, &IID_IAgileObject)
            || IsEqualIID(iid, &IID_IActivationFactory_))
    {
        *out = &factory.activation;
        return S_OK;
    }
    if (IsEqualIID(iid, &IID_IToastNotificationManagerStatics))
    {
        *out = &factory.statics;
        return S_OK;
    }
    if (IsEqualIID(iid, &IID_IToastNotificationManagerStatics2))
    {
        *out = &factory.statics2;
        return S_OK;
    }
    trace_iid("factory: no interface", iid);
    *out = NULL;
    return E_NOINTERFACE;
}

static HRESULT WINAPI factory_QueryInterface(void *iface, REFIID iid, void **out)
{
    return factory_qi(iid, out);
}

static ULONG WINAPI factory_AddRef(void *iface) { return 2; }
static ULONG WINAPI factory_Release(void *iface) { return 1; }

static HRESULT WINAPI factory_GetRuntimeClassName(void *iface, HSTRING *name)
{
    static const WCHAR cls[] = L"Windows.UI.Notifications.ToastNotificationManager";
    return WindowsCreateString(cls, ARRAYSIZE(cls) - 1, name);
}

static HRESULT WINAPI factory_ActivateInstance(void *iface, IInspectable **out)
{
    trace("factory: ActivateInstance -> E_NOTIMPL (static class)");
    *out = NULL;
    return E_NOTIMPL;
}

static HRESULT WINAPI statics_CreateToastNotifier(void *iface, void **out)
{
    trace("statics: CreateToastNotifier");
    return create_notifier(out);
}

static HRESULT WINAPI statics_CreateToastNotifierWithId(void *iface, HSTRING id, void **out)
{
    trace("statics: CreateToastNotifierWithId(%ls)", WindowsGetStringRawBuffer(id, NULL));
    return create_notifier(out);
}

static HRESULT WINAPI statics_GetTemplateContent(void *iface, INT32 type, void **out)
{
    trace("statics: GetTemplateContent(%d) -> E_NOTIMPL", type);
    *out = NULL;
    return E_NOTIMPL;
}

static HRESULT WINAPI statics2_get_History(void *iface, void **out)
{
    trace("statics2: get_History");
    history = &history_vtable;
    *out = &history;
    return S_OK;
}

static const activation_vtbl activation_vtable = {
    { factory_QueryInterface, factory_AddRef, factory_Release,
      insp_GetIids, factory_GetRuntimeClassName, insp_GetTrustLevel },
    factory_ActivateInstance,
};

static const statics_vtbl statics_vtable = {
    { factory_QueryInterface, factory_AddRef, factory_Release,
      insp_GetIids, factory_GetRuntimeClassName, insp_GetTrustLevel },
    statics_CreateToastNotifier, statics_CreateToastNotifierWithId,
    statics_GetTemplateContent,
};

static const statics2_vtbl statics2_vtable = {
    { factory_QueryInterface, factory_AddRef, factory_Release,
      insp_GetIids, factory_GetRuntimeClassName, insp_GetTrustLevel },
    statics2_get_History,
};

HRESULT WINAPI DllGetActivationFactory(HSTRING name, IActivationFactory **out)
{
    const WCHAR *s = WindowsGetStringRawBuffer(name, NULL);

    trace("DllGetActivationFactory(%ls)", s);
    if (lstrcmpW(s, L"Windows.UI.Notifications.ToastNotificationManager"))
    {
        *out = NULL;
        return CLASS_E_CLASSNOTAVAILABLE;
    }
    factory.activation = &activation_vtable;
    factory.statics = &statics_vtable;
    factory.statics2 = &statics2_vtable;
    *out = (IActivationFactory *)&factory.activation;
    return S_OK;
}

HRESULT WINAPI DllCanUnloadNow(void)
{
    return S_FALSE;
}
