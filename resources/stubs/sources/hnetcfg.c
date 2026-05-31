/*
 * Stub hnetcfg.dll for Wine — replaces Wine's hnetcfg.dll just for
 * Adobe Lightroom Classic / CC, which calls
 *
 *   CoCreateInstance(CLSID_NetFwPolicy2, IID_INetFwPolicy2)
 *     -> INetFwPolicy2::get_Rules
 *     -> INetFwRules::get__NewEnum
 *     -> IUnknown::QueryInterface(IID_IEnumVARIANT)
 *     -> IEnumVARIANT::Next   (until S_FALSE)
 *
 * Wine's hnetcfg returns S_OK with NULL out-pointers on get__NewEnum
 * and Lightroom is missing a null check, so it segfaults at +0x28231C.
 *
 * This stub returns a real (but empty) enumerator so LR sees "no rules"
 * and continues startup cleanly.
 *
 * Vtable layouts follow netfw.h:
 *   INetFwPolicy2 : IDispatch         (get_Rules at slot 18 = 0x90)
 *   INetFwRules   : IDispatch         (get__NewEnum at slot 11 = 0x58)
 *   IEnumVARIANT  : IUnknown          (Next at slot 3)
 *   made by sander110419
 */

#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <objbase.h>
#include <oaidl.h>
#include <unknwn.h>

// ===== GUIDs we care about =====
static const GUID CLSID_NetFwPolicy2_local =
    {0xE2B3C97F,0x6AE1,0x41AC,{0x81,0x7A,0xF6,0xF9,0x21,0x66,0xD7,0xDD}};
static const GUID IID_INetFwPolicy2_local =
    {0x98325047,0xC671,0x4174,{0x8D,0x81,0xDE,0xFC,0xD3,0xF0,0x31,0x86}};
static const GUID IID_INetFwRules_local =
    {0x9c4c6277,0x5027,0x441e,{0xAF,0xAE,0xCA,0x1F,0x54,0x2D,0xA0,0x09}};
// IID_IEnumVARIANT
static const GUID IID_IEnumVARIANT_local =
    {0x00020404,0x0000,0x0000,{0xC0,0x00,0x00,0x00,0x00,0x00,0x00,0x46}};

// IDispatch and IEnumVARIANT IIDs already exposed by SDK as IID_IDispatch.

// =====================================================================
// IEnumVARIANT (empty enumerator)
// vtable: QI, AddRef, Release, Next, Skip, Reset, Clone
// =====================================================================
typedef struct EmptyEnumVARIANT EmptyEnumVARIANT;
typedef struct EmptyEnumVARIANTVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(EmptyEnumVARIANT*, REFIID, void**);
    ULONG   (STDMETHODCALLTYPE *AddRef)(EmptyEnumVARIANT*);
    ULONG   (STDMETHODCALLTYPE *Release)(EmptyEnumVARIANT*);
    HRESULT (STDMETHODCALLTYPE *Next)(EmptyEnumVARIANT*, ULONG, VARIANT*, ULONG*);
    HRESULT (STDMETHODCALLTYPE *Skip)(EmptyEnumVARIANT*, ULONG);
    HRESULT (STDMETHODCALLTYPE *Reset)(EmptyEnumVARIANT*);
    HRESULT (STDMETHODCALLTYPE *Clone)(EmptyEnumVARIANT*, EmptyEnumVARIANT**);
} EmptyEnumVARIANTVtbl;
struct EmptyEnumVARIANT {
    const EmptyEnumVARIANTVtbl *lpVtbl;
    LONG ref;
};

static HRESULT STDMETHODCALLTYPE EV_QI(EmptyEnumVARIANT *This, REFIID riid, void **ppv);
static ULONG   STDMETHODCALLTYPE EV_AddRef(EmptyEnumVARIANT *This) {
    return InterlockedIncrement(&This->ref);
}
static ULONG   STDMETHODCALLTYPE EV_Release(EmptyEnumVARIANT *This) {
    LONG r = InterlockedDecrement(&This->ref);
    if (r == 0) HeapFree(GetProcessHeap(), 0, This);
    return r;
}
static HRESULT STDMETHODCALLTYPE EV_Next(EmptyEnumVARIANT *This, ULONG celt, VARIANT *rgVar, ULONG *pCeltFetched) {
    (void)This; (void)celt; (void)rgVar;
    if (pCeltFetched) *pCeltFetched = 0;
    return S_FALSE; // end of enumeration, no rules
}
static HRESULT STDMETHODCALLTYPE EV_Skip(EmptyEnumVARIANT *This, ULONG celt) {
    (void)This; (void)celt;
    return S_FALSE;
}
static HRESULT STDMETHODCALLTYPE EV_Reset(EmptyEnumVARIANT *This) {
    (void)This;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE EV_Clone(EmptyEnumVARIANT *This, EmptyEnumVARIANT **ppv);

static const EmptyEnumVARIANTVtbl g_EV_vtbl = {
    EV_QI, EV_AddRef, EV_Release,
    EV_Next, EV_Skip, EV_Reset, EV_Clone
};

static EmptyEnumVARIANT* create_empty_enum(void) {
    EmptyEnumVARIANT *e = HeapAlloc(GetProcessHeap(), 0, sizeof(*e));
    if (!e) return NULL;
    e->lpVtbl = &g_EV_vtbl;
    e->ref = 1;
    return e;
}

static HRESULT STDMETHODCALLTYPE EV_QI(EmptyEnumVARIANT *This, REFIID riid, void **ppv) {
    if (!ppv) return E_POINTER;
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IEnumVARIANT_local)) {
        *ppv = This;
        This->lpVtbl->AddRef(This);
        return S_OK;
    }
    *ppv = NULL;
    return E_NOINTERFACE;
}
static HRESULT STDMETHODCALLTYPE EV_Clone(EmptyEnumVARIANT *This, EmptyEnumVARIANT **ppv) {
    (void)This;
    if (!ppv) return E_POINTER;
    *ppv = create_empty_enum();
    return *ppv ? S_OK : E_OUTOFMEMORY;
}

// =====================================================================
// INetFwRules (empty rules collection)
// vtable indices: 0 QI, 1 AddRef, 2 Release,
//                 3 GetTypeInfoCount, 4 GetTypeInfo,
//                 5 GetIDsOfNames, 6 Invoke,
//                 7 get_Count, 8 Add, 9 Remove, 10 Item, 11 get__NewEnum
// =====================================================================
typedef struct FwRules FwRules;
typedef struct FwRulesVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(FwRules*, REFIID, void**);
    ULONG   (STDMETHODCALLTYPE *AddRef)(FwRules*);
    ULONG   (STDMETHODCALLTYPE *Release)(FwRules*);
    HRESULT (STDMETHODCALLTYPE *GetTypeInfoCount)(FwRules*, UINT*);
    HRESULT (STDMETHODCALLTYPE *GetTypeInfo)(FwRules*, UINT, LCID, ITypeInfo**);
    HRESULT (STDMETHODCALLTYPE *GetIDsOfNames)(FwRules*, REFIID, LPOLESTR*, UINT, LCID, DISPID*);
    HRESULT (STDMETHODCALLTYPE *Invoke)(FwRules*, DISPID, REFIID, LCID, WORD, DISPPARAMS*, VARIANT*, EXCEPINFO*, UINT*);
    HRESULT (STDMETHODCALLTYPE *get_Count)(FwRules*, LONG*);
    HRESULT (STDMETHODCALLTYPE *Add)(FwRules*, void*);
    HRESULT (STDMETHODCALLTYPE *Remove)(FwRules*, BSTR);
    HRESULT (STDMETHODCALLTYPE *Item)(FwRules*, BSTR, void**);
    HRESULT (STDMETHODCALLTYPE *get__NewEnum)(FwRules*, IUnknown**);
} FwRulesVtbl;
struct FwRules {
    const FwRulesVtbl *lpVtbl;
    LONG ref;
};

static HRESULT STDMETHODCALLTYPE FR_QI(FwRules *This, REFIID riid, void **ppv) {
    if (!ppv) return E_POINTER;
    if (IsEqualIID(riid, &IID_IUnknown)
        || IsEqualIID(riid, &IID_IDispatch)
        || IsEqualIID(riid, &IID_INetFwRules_local)) {
        *ppv = This;
        This->lpVtbl->AddRef(This);
        return S_OK;
    }
    *ppv = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE FR_AddRef(FwRules *This) {
    return InterlockedIncrement(&This->ref);
}
static ULONG STDMETHODCALLTYPE FR_Release(FwRules *This) {
    LONG r = InterlockedDecrement(&This->ref);
    if (r == 0) HeapFree(GetProcessHeap(), 0, This);
    return r;
}
static HRESULT STDMETHODCALLTYPE FR_GetTypeInfoCount(FwRules *This, UINT *pctinfo) {
    (void)This;
    if (pctinfo) *pctinfo = 0;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE FR_GetTypeInfo(FwRules *This, UINT i, LCID l, ITypeInfo **pp) {
    (void)This; (void)i; (void)l;
    if (pp) *pp = NULL;
    return E_NOTIMPL;
}
static HRESULT STDMETHODCALLTYPE FR_GetIDsOfNames(FwRules *This, REFIID r, LPOLESTR *n, UINT c, LCID l, DISPID *d) {
    (void)This; (void)r; (void)n; (void)c; (void)l; (void)d;
    return DISP_E_UNKNOWNNAME;
}
static HRESULT STDMETHODCALLTYPE FR_Invoke(FwRules *This, DISPID id, REFIID r, LCID l, WORD w, DISPPARAMS *p, VARIANT *vr, EXCEPINFO *e, UINT *u) {
    (void)This; (void)id; (void)r; (void)l; (void)w; (void)p; (void)vr; (void)e; (void)u;
    return DISP_E_MEMBERNOTFOUND;
}
static HRESULT STDMETHODCALLTYPE FR_get_Count(FwRules *This, LONG *count) {
    (void)This;
    if (count) *count = 0;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE FR_Add(FwRules *This, void *rule) {
    (void)This; (void)rule;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE FR_Remove(FwRules *This, BSTR name) {
    (void)This; (void)name;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE FR_Item(FwRules *This, BSTR name, void **rule) {
    (void)This; (void)name;
    if (rule) *rule = NULL;
    return HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND);
}
static HRESULT STDMETHODCALLTYPE FR_get__NewEnum(FwRules *This, IUnknown **newEnum) {
    (void)This;
    if (!newEnum) return E_POINTER;
    EmptyEnumVARIANT *e = create_empty_enum();
    if (!e) { *newEnum = NULL; return E_OUTOFMEMORY; }
    *newEnum = (IUnknown*)e;
    return S_OK;
}

static const FwRulesVtbl g_FR_vtbl = {
    FR_QI, FR_AddRef, FR_Release,
    FR_GetTypeInfoCount, FR_GetTypeInfo, FR_GetIDsOfNames, FR_Invoke,
    FR_get_Count, FR_Add, FR_Remove, FR_Item, FR_get__NewEnum
};

static FwRules* create_fw_rules(void) {
    FwRules *r = HeapAlloc(GetProcessHeap(), 0, sizeof(*r));
    if (!r) return NULL;
    r->lpVtbl = &g_FR_vtbl;
    r->ref = 1;
    return r;
}

// =====================================================================
// INetFwPolicy2
// vtable indices: 0 QI, 1 AddRef, 2 Release,
//                 3 GetTypeInfoCount, 4 GetTypeInfo,
//                 5 GetIDsOfNames, 6 Invoke,
//                 7 get_CurrentProfileTypes
//                 8 get_FirewallEnabled
//                 9 put_FirewallEnabled
//                 10 get_ExcludedInterfaces
//                 11 put_ExcludedInterfaces
//                 12 get_BlockAllInboundTraffic
//                 13 put_BlockAllInboundTraffic
//                 14 get_NotificationsDisabled
//                 15 put_NotificationsDisabled
//                 16 get_UnicastResp...
//                 17 put_UnicastResp...
//                 18 get_Rules            <-- offset 0x90, the one we need
//                 19 get_ServiceRestriction
//                 20 EnableRuleGroup
//                 21 IsRuleGroupEnabled
//                 22 RestoreLocalFirewallDefaults
//                 23 get_DefaultInboundAction
//                 24 put_DefaultInboundAction
//                 25 get_DefaultOutboundAction
//                 26 put_DefaultOutboundAction
//                 27 get_IsRuleGroupCurrentlyEnabled
//                 28 get_LocalPolicyModifyState
// =====================================================================
typedef struct FwPolicy2 FwPolicy2;
typedef struct FwPolicy2Vtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(FwPolicy2*, REFIID, void**);
    ULONG   (STDMETHODCALLTYPE *AddRef)(FwPolicy2*);
    ULONG   (STDMETHODCALLTYPE *Release)(FwPolicy2*);
    HRESULT (STDMETHODCALLTYPE *GetTypeInfoCount)(FwPolicy2*, UINT*);
    HRESULT (STDMETHODCALLTYPE *GetTypeInfo)(FwPolicy2*, UINT, LCID, ITypeInfo**);
    HRESULT (STDMETHODCALLTYPE *GetIDsOfNames)(FwPolicy2*, REFIID, LPOLESTR*, UINT, LCID, DISPID*);
    HRESULT (STDMETHODCALLTYPE *Invoke)(FwPolicy2*, DISPID, REFIID, LCID, WORD, DISPPARAMS*, VARIANT*, EXCEPINFO*, UINT*);
    // 7
    HRESULT (STDMETHODCALLTYPE *get_CurrentProfileTypes)(FwPolicy2*, LONG*);
    HRESULT (STDMETHODCALLTYPE *get_FirewallEnabled)(FwPolicy2*, LONG, VARIANT_BOOL*);
    HRESULT (STDMETHODCALLTYPE *put_FirewallEnabled)(FwPolicy2*, LONG, VARIANT_BOOL);
    HRESULT (STDMETHODCALLTYPE *get_ExcludedInterfaces)(FwPolicy2*, LONG, VARIANT*);
    HRESULT (STDMETHODCALLTYPE *put_ExcludedInterfaces)(FwPolicy2*, LONG, VARIANT);
    HRESULT (STDMETHODCALLTYPE *get_BlockAllInboundTraffic)(FwPolicy2*, LONG, VARIANT_BOOL*);
    HRESULT (STDMETHODCALLTYPE *put_BlockAllInboundTraffic)(FwPolicy2*, LONG, VARIANT_BOOL);
    HRESULT (STDMETHODCALLTYPE *get_NotificationsDisabled)(FwPolicy2*, LONG, VARIANT_BOOL*);
    HRESULT (STDMETHODCALLTYPE *put_NotificationsDisabled)(FwPolicy2*, LONG, VARIANT_BOOL);
    HRESULT (STDMETHODCALLTYPE *get_UnicastResponsesToMulticastBroadcastDisabled)(FwPolicy2*, LONG, VARIANT_BOOL*);
    HRESULT (STDMETHODCALLTYPE *put_UnicastResponsesToMulticastBroadcastDisabled)(FwPolicy2*, LONG, VARIANT_BOOL);
    // 18 get_Rules
    HRESULT (STDMETHODCALLTYPE *get_Rules)(FwPolicy2*, FwRules**);
    HRESULT (STDMETHODCALLTYPE *get_ServiceRestriction)(FwPolicy2*, void**);
    HRESULT (STDMETHODCALLTYPE *EnableRuleGroup)(FwPolicy2*, LONG, BSTR, VARIANT_BOOL);
    HRESULT (STDMETHODCALLTYPE *IsRuleGroupEnabled)(FwPolicy2*, LONG, BSTR, VARIANT_BOOL*);
    HRESULT (STDMETHODCALLTYPE *RestoreLocalFirewallDefaults)(FwPolicy2*);
    HRESULT (STDMETHODCALLTYPE *get_DefaultInboundAction)(FwPolicy2*, LONG, LONG*);
    HRESULT (STDMETHODCALLTYPE *put_DefaultInboundAction)(FwPolicy2*, LONG, LONG);
    HRESULT (STDMETHODCALLTYPE *get_DefaultOutboundAction)(FwPolicy2*, LONG, LONG*);
    HRESULT (STDMETHODCALLTYPE *put_DefaultOutboundAction)(FwPolicy2*, LONG, LONG);
    HRESULT (STDMETHODCALLTYPE *get_IsRuleGroupCurrentlyEnabled)(FwPolicy2*, BSTR, VARIANT_BOOL*);
    HRESULT (STDMETHODCALLTYPE *get_LocalPolicyModifyState)(FwPolicy2*, LONG*);
} FwPolicy2Vtbl;
struct FwPolicy2 {
    const FwPolicy2Vtbl *lpVtbl;
    LONG ref;
};

static HRESULT STDMETHODCALLTYPE FP_QI(FwPolicy2 *This, REFIID riid, void **ppv) {
    if (!ppv) return E_POINTER;
    if (IsEqualIID(riid, &IID_IUnknown)
        || IsEqualIID(riid, &IID_IDispatch)
        || IsEqualIID(riid, &IID_INetFwPolicy2_local)) {
        *ppv = This;
        This->lpVtbl->AddRef(This);
        return S_OK;
    }
    *ppv = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE FP_AddRef(FwPolicy2 *This) {
    return InterlockedIncrement(&This->ref);
}
static ULONG STDMETHODCALLTYPE FP_Release(FwPolicy2 *This) {
    LONG r = InterlockedDecrement(&This->ref);
    if (r == 0) HeapFree(GetProcessHeap(), 0, This);
    return r;
}
static HRESULT STDMETHODCALLTYPE FP_GetTypeInfoCount(FwPolicy2 *This, UINT *p) {
    (void)This; if (p) *p = 0; return S_OK;
}
static HRESULT STDMETHODCALLTYPE FP_GetTypeInfo(FwPolicy2 *This, UINT i, LCID l, ITypeInfo **pp) {
    (void)This; (void)i; (void)l;
    if (pp) *pp = NULL;
    return E_NOTIMPL;
}
static HRESULT STDMETHODCALLTYPE FP_GetIDsOfNames(FwPolicy2 *This, REFIID r, LPOLESTR *n, UINT c, LCID l, DISPID *d) {
    (void)This;(void)r;(void)n;(void)c;(void)l;(void)d;
    return DISP_E_UNKNOWNNAME;
}
static HRESULT STDMETHODCALLTYPE FP_Invoke(FwPolicy2 *This, DISPID id, REFIID r, LCID l, WORD w, DISPPARAMS *p, VARIANT *vr, EXCEPINFO *e, UINT *u) {
    (void)This;(void)id;(void)r;(void)l;(void)w;(void)p;(void)vr;(void)e;(void)u;
    return DISP_E_MEMBERNOTFOUND;
}
static HRESULT STDMETHODCALLTYPE FP_get_CurrentProfileTypes(FwPolicy2 *This, LONG *pt) {
    (void)This; if (pt) *pt = 1 /* NET_FW_PROFILE2_DOMAIN */; return S_OK;
}
static HRESULT STDMETHODCALLTYPE FP_get_FirewallEnabled(FwPolicy2 *This, LONG t, VARIANT_BOOL *en) {
    (void)This;(void)t; if (en) *en = VARIANT_FALSE; return S_OK;
}
static HRESULT STDMETHODCALLTYPE FP_put_FirewallEnabled(FwPolicy2 *This, LONG t, VARIANT_BOOL en) {
    (void)This;(void)t;(void)en; return S_OK;
}
static HRESULT STDMETHODCALLTYPE FP_get_ExcludedInterfaces(FwPolicy2 *This, LONG t, VARIANT *v) {
    (void)This;(void)t;
    if (v) { VariantInit(v); V_VT(v) = VT_EMPTY; }
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE FP_put_ExcludedInterfaces(FwPolicy2 *This, LONG t, VARIANT v) {
    (void)This;(void)t;(void)v; return S_OK;
}
static HRESULT STDMETHODCALLTYPE FP_get_BlockAllInboundTraffic(FwPolicy2 *This, LONG t, VARIANT_BOOL *en) {
    (void)This;(void)t; if (en) *en = VARIANT_FALSE; return S_OK;
}
static HRESULT STDMETHODCALLTYPE FP_put_BlockAllInboundTraffic(FwPolicy2 *This, LONG t, VARIANT_BOOL en) {
    (void)This;(void)t;(void)en; return S_OK;
}
static HRESULT STDMETHODCALLTYPE FP_get_NotificationsDisabled(FwPolicy2 *This, LONG t, VARIANT_BOOL *en) {
    (void)This;(void)t; if (en) *en = VARIANT_TRUE; return S_OK;
}
static HRESULT STDMETHODCALLTYPE FP_put_NotificationsDisabled(FwPolicy2 *This, LONG t, VARIANT_BOOL en) {
    (void)This;(void)t;(void)en; return S_OK;
}
static HRESULT STDMETHODCALLTYPE FP_get_UnicastResp(FwPolicy2 *This, LONG t, VARIANT_BOOL *en) {
    (void)This;(void)t; if (en) *en = VARIANT_FALSE; return S_OK;
}
static HRESULT STDMETHODCALLTYPE FP_put_UnicastResp(FwPolicy2 *This, LONG t, VARIANT_BOOL en) {
    (void)This;(void)t;(void)en; return S_OK;
}
static HRESULT STDMETHODCALLTYPE FP_get_Rules(FwPolicy2 *This, FwRules **pp) {
    (void)This;
    if (!pp) return E_POINTER;
    *pp = create_fw_rules();
    return *pp ? S_OK : E_OUTOFMEMORY;
}
static HRESULT STDMETHODCALLTYPE FP_get_ServiceRestriction(FwPolicy2 *This, void **pp) {
    (void)This; if (pp) *pp = NULL; return E_NOTIMPL;
}
static HRESULT STDMETHODCALLTYPE FP_EnableRuleGroup(FwPolicy2 *This, LONG t, BSTR g, VARIANT_BOOL e) {
    (void)This;(void)t;(void)g;(void)e; return S_OK;
}
static HRESULT STDMETHODCALLTYPE FP_IsRuleGroupEnabled(FwPolicy2 *This, LONG t, BSTR g, VARIANT_BOOL *e) {
    (void)This;(void)t;(void)g; if (e) *e = VARIANT_FALSE; return S_OK;
}
static HRESULT STDMETHODCALLTYPE FP_RestoreLocalFirewallDefaults(FwPolicy2 *This) {
    (void)This; return S_OK;
}
static HRESULT STDMETHODCALLTYPE FP_get_DefaultInboundAction(FwPolicy2 *This, LONG t, LONG *a) {
    (void)This;(void)t; if (a) *a = 1 /* NET_FW_ACTION_ALLOW */; return S_OK;
}
static HRESULT STDMETHODCALLTYPE FP_put_DefaultInboundAction(FwPolicy2 *This, LONG t, LONG a) {
    (void)This;(void)t;(void)a; return S_OK;
}
static HRESULT STDMETHODCALLTYPE FP_get_DefaultOutboundAction(FwPolicy2 *This, LONG t, LONG *a) {
    (void)This;(void)t; if (a) *a = 1; return S_OK;
}
static HRESULT STDMETHODCALLTYPE FP_put_DefaultOutboundAction(FwPolicy2 *This, LONG t, LONG a) {
    (void)This;(void)t;(void)a; return S_OK;
}
static HRESULT STDMETHODCALLTYPE FP_get_IsRuleGroupCurrentlyEnabled(FwPolicy2 *This, BSTR g, VARIANT_BOOL *e) {
    (void)This;(void)g; if (e) *e = VARIANT_FALSE; return S_OK;
}
static HRESULT STDMETHODCALLTYPE FP_get_LocalPolicyModifyState(FwPolicy2 *This, LONG *s) {
    (void)This; if (s) *s = 0; return S_OK;
}

static const FwPolicy2Vtbl g_FP_vtbl = {
    FP_QI, FP_AddRef, FP_Release,
    FP_GetTypeInfoCount, FP_GetTypeInfo, FP_GetIDsOfNames, FP_Invoke,
    FP_get_CurrentProfileTypes,
    FP_get_FirewallEnabled, FP_put_FirewallEnabled,
    FP_get_ExcludedInterfaces, FP_put_ExcludedInterfaces,
    FP_get_BlockAllInboundTraffic, FP_put_BlockAllInboundTraffic,
    FP_get_NotificationsDisabled, FP_put_NotificationsDisabled,
    FP_get_UnicastResp, FP_put_UnicastResp,
    FP_get_Rules,
    FP_get_ServiceRestriction,
    FP_EnableRuleGroup, FP_IsRuleGroupEnabled,
    FP_RestoreLocalFirewallDefaults,
    FP_get_DefaultInboundAction, FP_put_DefaultInboundAction,
    FP_get_DefaultOutboundAction, FP_put_DefaultOutboundAction,
    FP_get_IsRuleGroupCurrentlyEnabled,
    FP_get_LocalPolicyModifyState
};

static FwPolicy2* create_fw_policy2(void) {
    FwPolicy2 *p = HeapAlloc(GetProcessHeap(), 0, sizeof(*p));
    if (!p) return NULL;
    p->lpVtbl = &g_FP_vtbl;
    p->ref = 1;
    return p;
}

// =====================================================================
// IClassFactory for CLSID_NetFwPolicy2
// =====================================================================
typedef struct HnetCF {
    const IClassFactoryVtbl *lpVtbl;
    LONG ref;
} HnetCF;

static HRESULT STDMETHODCALLTYPE CF_QI(IClassFactory *This, REFIID riid, void **ppv) {
    if (!ppv) return E_POINTER;
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IClassFactory)) {
        *ppv = This;
        This->lpVtbl->AddRef(This);
        return S_OK;
    }
    *ppv = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE CF_AddRef(IClassFactory *This) {
    return InterlockedIncrement(&((HnetCF*)This)->ref);
}
static ULONG STDMETHODCALLTYPE CF_Release(IClassFactory *This) {
    LONG r = InterlockedDecrement(&((HnetCF*)This)->ref);
    if (r < 1) ((HnetCF*)This)->ref = 1;
    return 1;
}
static HRESULT STDMETHODCALLTYPE CF_CreateInstance(IClassFactory *This, IUnknown *pUnkOuter, REFIID riid, void **ppv) {
    (void)This;
    if (!ppv) return E_POINTER;
    *ppv = NULL;
    if (pUnkOuter) return CLASS_E_NOAGGREGATION;
    FwPolicy2 *p = create_fw_policy2();
    if (!p) return E_OUTOFMEMORY;
    HRESULT hr = p->lpVtbl->QueryInterface(p, riid, ppv);
    p->lpVtbl->Release(p);
    return hr;
}
static HRESULT STDMETHODCALLTYPE CF_LockServer(IClassFactory *This, BOOL fLock) {
    (void)This;(void)fLock; return S_OK;
}

static const IClassFactoryVtbl g_CF_vtbl = {
    CF_QI, CF_AddRef, CF_Release,
    CF_CreateInstance, CF_LockServer
};
static HnetCF g_class_factory = { &g_CF_vtbl, 1 };

// =====================================================================
// DLL entry points
// =====================================================================
__declspec(dllexport) HRESULT WINAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, void **ppv) {
    if (!ppv) return E_POINTER;
    *ppv = NULL;
    if (IsEqualCLSID(rclsid, &CLSID_NetFwPolicy2_local)) {
        return g_class_factory.lpVtbl->QueryInterface((IClassFactory*)&g_class_factory, riid, ppv);
    }
    return CLASS_E_CLASSNOTAVAILABLE;
}

__declspec(dllexport) HRESULT WINAPI DllCanUnloadNow(void) {
    return S_FALSE;
}

__declspec(dllexport) HRESULT WINAPI DllRegisterServer(void) {
    return S_OK;
}
__declspec(dllexport) HRESULT WINAPI DllUnregisterServer(void) {
    return S_OK;
}

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(hinst);
    return TRUE;
}
