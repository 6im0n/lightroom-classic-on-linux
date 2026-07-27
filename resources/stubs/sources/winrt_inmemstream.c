#define INITGUID
/* winrt_inmemstream.c — pure-wine Windows.Storage.Streams.InMemoryRandomAccessStream
 *
 * In-process WinRT factory + object providing InMemoryRandomAccessStream, so
 * Adobe LrC's WML model loader (which builds the model through this class) works
 * under wine without the native Windows shcore.dll (which cascades/crashes).
 *
 * Implements IRandomAccessStream + IInputStream + IOutputStream + IClosable, a
 * backing growable buffer, an IBuffer (+ IBufferByteAccess) for read results,
 * and IAsyncOperationWithProgress / IAsyncOperation results that complete
 * synchronously.  WriteAsync ALSO dumps the bytes WML hands us to
 * /tmp/wml_model_dump_<n>.bin so we can tell encrypted-vs-plaintext-ONNX.
 *
 * Register:
 *   reg add "HKLM\Software\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Storage.Streams.InMemoryRandomAccessStream" \
 *       /v DllPath /t REG_SZ /d "C:\windows\system32\winrt_inmemstream.dll" /f
 * Build:
 *   x86_64-w64-mingw32-gcc -shared -O2 -o winrt_inmemstream.dll winrt_inmemstream.c \
 *       -lruntimeobject -lole32 -luuid
 */
#define COBJMACROS
#define CINTERFACE
#define WIDL_using_Windows_Foundation
#define WIDL_using_Windows_Storage_Streams
#include <windows.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <roapi.h>
#include <activation.h>
#include <robuffer.h>
#include <windows.foundation.h>
#include <windows.storage.streams.h>
#include <asyncinfo.h>
#include <winstring.h>
#include <wchar.h>

/* short aliases for the long C-ABI type names */
typedef __x_ABI_CWindows_CStorage_CStreams_CIRandomAccessStream IRAS;
typedef __x_ABI_CWindows_CStorage_CStreams_CIRandomAccessStreamVtbl IRASVtbl;
typedef __x_ABI_CWindows_CStorage_CStreams_CIInputStream IIn;
typedef __x_ABI_CWindows_CStorage_CStreams_CIInputStreamVtbl IInVtbl;
typedef __x_ABI_CWindows_CStorage_CStreams_CIOutputStream IOut;
typedef __x_ABI_CWindows_CStorage_CStreams_CIOutputStreamVtbl IOutVtbl;
typedef __x_ABI_CWindows_CStorage_CStreams_CIBuffer IBuf;
typedef __x_ABI_CWindows_CStorage_CStreams_CIBufferVtbl IBufVtbl;
typedef __x_ABI_CWindows_CFoundation_CIClosable IClose;
typedef __x_ABI_CWindows_CFoundation_CIClosableVtbl ICloseVtbl;
typedef __FIAsyncOperationWithProgress_2_Windows__CStorage__CStreams__CIBuffer_UINT32 IReadOp;
typedef __FIAsyncOperationWithProgress_2_Windows__CStorage__CStreams__CIBuffer_UINT32Vtbl IReadOpVtbl;
typedef __FIAsyncOperationWithProgress_2_UINT32_UINT32 IWriteOp;
typedef __FIAsyncOperationWithProgress_2_UINT32_UINT32Vtbl IWriteOpVtbl;
typedef __FIAsyncOperation_1_boolean IFlushOp;
typedef __FIAsyncOperation_1_booleanVtbl IFlushOpVtbl;

static LONG g_dump = 0;

/* trace which methods WML actually calls (find why no bytes reach the stream) */
static void logmsg(const char *fmt, ...){
    FILE *f = fopen("Z:\\tmp\\inmem_call.log","a"); if(!f) return;
    va_list ap; va_start(ap,fmt); vfprintf(f,fmt,ap); va_end(ap); fputc('\n',f); fclose(f);
}

/* log every QueryInterface so we see which IID WML asks for that we reject */
static void logqi(const char *who, REFIID riid, HRESULT hr){
    FILE *f = fopen("Z:\\tmp\\inmem_qi.log","a"); if(!f) return;
    fprintf(f,"%s {%08lx-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x} %s\n", who,
        riid->Data1, riid->Data2, riid->Data3,
        riid->Data4[0],riid->Data4[1],riid->Data4[2],riid->Data4[3],
        riid->Data4[4],riid->Data4[5],riid->Data4[6],riid->Data4[7],
        hr==S_OK?"OK":"E_NOINTERFACE");
    fclose(f);
}

/* ============================ IBuffer ============================ */
typedef struct {
    IBufVtbl *vtbl_buf;
    IBufferByteAccessVtbl *vtbl_bba;
    LONG ref;
    BYTE *data; UINT32 cap; UINT32 len;
} Buffer;

static Buffer *buf_from_buf(IBuf *i){ return (Buffer*)((char*)i - offsetof(Buffer,vtbl_buf)); }
static Buffer *buf_from_bba(IBufferByteAccess *i){ return (Buffer*)((char*)i - offsetof(Buffer,vtbl_bba)); }

static HRESULT STDMETHODCALLTYPE buf_QI(IBuf *This, REFIID riid, void **ppv){
    Buffer *b = buf_from_buf(This);
    if(IsEqualGUID(riid,&IID_IUnknown)||IsEqualGUID(riid,&IID_IInspectable)||
       IsEqualGUID(riid,&IID___x_ABI_CWindows_CStorage_CStreams_CIBuffer)){
        *ppv=&b->vtbl_buf; InterlockedIncrement(&b->ref); return S_OK; }
    if(IsEqualGUID(riid,&IID_IBufferByteAccess)){
        *ppv=&b->vtbl_bba; InterlockedIncrement(&b->ref); return S_OK; }
    *ppv=NULL; return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE buf_AddRef(IBuf *This){ return InterlockedIncrement(&buf_from_buf(This)->ref); }
static ULONG STDMETHODCALLTYPE buf_Release(IBuf *This){ Buffer*b=buf_from_buf(This);
    ULONG r=InterlockedDecrement(&b->ref); if(!r){ free(b->data); free(b);} return r; }
static HRESULT STDMETHODCALLTYPE buf_GetIids(IBuf*T,ULONG*n,IID**p){*n=0;*p=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE buf_GetRCN(IBuf*T,HSTRING*s){*s=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE buf_GetTL(IBuf*T,TrustLevel*t){*t=BaseTrust;return S_OK;}
static HRESULT STDMETHODCALLTYPE buf_get_Capacity(IBuf*This,UINT32*v){*v=buf_from_buf(This)->cap;return S_OK;}
static HRESULT STDMETHODCALLTYPE buf_get_Length(IBuf*This,UINT32*v){*v=buf_from_buf(This)->len;return S_OK;}
static HRESULT STDMETHODCALLTYPE buf_put_Length(IBuf*This,UINT32 v){Buffer*b=buf_from_buf(This); if(v>b->cap)return E_INVALIDARG; b->len=v; return S_OK;}
static IBufVtbl g_bufVtbl = { buf_QI,buf_AddRef,buf_Release,buf_GetIids,buf_GetRCN,buf_GetTL,
    buf_get_Capacity,buf_get_Length,buf_put_Length };

static HRESULT STDMETHODCALLTYPE bba_QI(IBufferByteAccess*This,REFIID riid,void**ppv){ return buf_QI((IBuf*)&buf_from_bba(This)->vtbl_buf,riid,ppv); }
static ULONG STDMETHODCALLTYPE bba_AddRef(IBufferByteAccess*This){ return InterlockedIncrement(&buf_from_bba(This)->ref); }
static ULONG STDMETHODCALLTYPE bba_Release(IBufferByteAccess*This){ return buf_Release((IBuf*)&buf_from_bba(This)->vtbl_buf); }
static HRESULT STDMETHODCALLTYPE bba_Buffer(IBufferByteAccess*This,byte**pp){ *pp=buf_from_bba(This)->data; return S_OK; }
static IBufferByteAccessVtbl g_bbaVtbl = { bba_QI,bba_AddRef,bba_Release,bba_Buffer };

static Buffer *new_buffer(UINT32 cap){
    Buffer *b=calloc(1,sizeof(Buffer)); b->vtbl_buf=&g_bufVtbl; b->vtbl_bba=&g_bbaVtbl;
    b->ref=1; b->cap=cap; b->len=0; b->data=calloc(1,cap?cap:1); return b;
}

/* ===================== IAsyncInfo (shared) =====================
 * Every WinRT IAsyncOperation<T>/IAsyncOperationWithProgress inherits
 * IAsyncInfo {00000036-...}. WinML's await does `.as<IAsyncInfo>()` then calls
 * get_Status (vtbl slot 7) — if the QI fails it derefs null and crashes
 * (the microsoft.ai.machinelearning.dll 0xc0000005). All our async ops complete
 * synchronously with success, so one static "already-completed" IAsyncInfo
 * answers for all of them. */
typedef struct { IAsyncInfoVtbl *vtbl; } AInfo;
static HRESULT STDMETHODCALLTYPE ai_QI(IAsyncInfo*T,REFIID r,void**p){
    if(IsEqualGUID(r,&IID_IUnknown)||IsEqualGUID(r,&IID_IInspectable)||IsEqualGUID(r,&IID_IAsyncInfo)){*p=T;return S_OK;}
    *p=NULL;return E_NOINTERFACE;}
static ULONG STDMETHODCALLTYPE ai_AddRef(IAsyncInfo*T){return 2;}
static ULONG STDMETHODCALLTYPE ai_Release(IAsyncInfo*T){return 1;}
static HRESULT STDMETHODCALLTYPE ai_GetIids(IAsyncInfo*T,ULONG*n,IID**p){*n=0;*p=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE ai_GetRCN(IAsyncInfo*T,HSTRING*s){*s=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE ai_GetTL(IAsyncInfo*T,TrustLevel*t){*t=BaseTrust;return S_OK;}
static HRESULT STDMETHODCALLTYPE ai_get_Id(IAsyncInfo*T,UINT32*v){*v=1;return S_OK;}
static HRESULT STDMETHODCALLTYPE ai_get_Status(IAsyncInfo*T,AsyncStatus*v){*v=Completed;return S_OK;}
static HRESULT STDMETHODCALLTYPE ai_get_ErrorCode(IAsyncInfo*T,HRESULT*v){*v=S_OK;return S_OK;}
static HRESULT STDMETHODCALLTYPE ai_Cancel(IAsyncInfo*T){return S_OK;}
static HRESULT STDMETHODCALLTYPE ai_Close(IAsyncInfo*T){return S_OK;}
static IAsyncInfoVtbl g_aiVtbl={ai_QI,ai_AddRef,ai_Release,ai_GetIids,ai_GetRCN,ai_GetTL,
    ai_get_Id,ai_get_Status,ai_get_ErrorCode,ai_Cancel,ai_Close};
static AInfo g_ainfo={&g_aiVtbl};

/* ===================== generic sync async op ===================== */
/* one struct serves IReadOp (result=IBuffer), IWriteOp/IFlushOp (result scalar).
   completed synchronously; put_Completed invokes the handler immediately. */
typedef struct {
    IReadOpVtbl *vtbl_read;     /* primary if read   */
    IWriteOpVtbl *vtbl_write;   /* primary if write  */
    IFlushOpVtbl *vtbl_flush;   /* primary if flush  */
    LONG ref; int kind;         /* 0=read 1=write 2=flush */
    IBuf *res_buf; UINT32 res_u32; boolean res_bool;
    IUnknown *handler;          /* completed delegate */
} AsyncOp;
/* recover from whichever vtbl */
static AsyncOp *op_from(void *i,int kind){
    if(kind==0) return (AsyncOp*)((char*)i-offsetof(AsyncOp,vtbl_read));
    if(kind==1) return (AsyncOp*)((char*)i-offsetof(AsyncOp,vtbl_write));
    return (AsyncOp*)((char*)i-offsetof(AsyncOp,vtbl_flush));
}
static ULONG op_addref(AsyncOp*o){return InterlockedIncrement(&o->ref);}
static ULONG op_release(AsyncOp*o){ULONG r=InterlockedDecrement(&o->ref);
    if(!r){ if(o->res_buf)o->res_buf->lpVtbl->Release(o->res_buf); if(o->handler)o->handler->lpVtbl->Release(o->handler); free(o);} return r;}

/* --- IReadOp (IAsyncOperationWithProgress<IBuffer,UINT32>) --- */
static HRESULT STDMETHODCALLTYPE rop_QI(IReadOp*This,REFIID riid,void**ppv){ AsyncOp*o=op_from(This,0);
    if(IsEqualGUID(riid,&IID_IUnknown)||IsEqualGUID(riid,&IID_IInspectable)||
       IsEqualGUID(riid,&IID___FIAsyncOperationWithProgress_2_Windows__CStorage__CStreams__CIBuffer_UINT32)){
        *ppv=&o->vtbl_read; op_addref(o); return S_OK;}
    if(IsEqualGUID(riid,&IID_IAsyncInfo)){*ppv=&g_ainfo; return S_OK;}
    *ppv=NULL; return E_NOINTERFACE;}
static ULONG STDMETHODCALLTYPE rop_AddRef(IReadOp*T){return op_addref(op_from(T,0));}
static ULONG STDMETHODCALLTYPE rop_Release(IReadOp*T){return op_release(op_from(T,0));}
static HRESULT STDMETHODCALLTYPE rop_GetIids(IReadOp*T,ULONG*n,IID**p){*n=0;*p=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE rop_GetRCN(IReadOp*T,HSTRING*s){*s=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE rop_GetTL(IReadOp*T,TrustLevel*t){*t=BaseTrust;return S_OK;}
static HRESULT STDMETHODCALLTYPE rop_put_Completed(IReadOp*This,void*h){ AsyncOp*o=op_from(This,0);
    if(h){ o->handler=(IUnknown*)h; o->handler->lpVtbl->AddRef(o->handler);
        /* already completed -> invoke now: handler signature Invoke(handler,asyncInfo,status) */
        typedef HRESULT(STDMETHODCALLTYPE *inv_t)(void*,void*,int);
        inv_t inv=((inv_t*)((IUnknown*)h)->lpVtbl)[3]; /* slot after QI/AddRef/Release */
        inv(h,&o->vtbl_read,1 /*Completed*/);} return S_OK;}
static HRESULT STDMETHODCALLTYPE rop_get_Completed(IReadOp*T,void**h){*h=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE rop_put_Progress(IReadOp*T,void*h){return S_OK;}
static HRESULT STDMETHODCALLTYPE rop_get_Progress(IReadOp*T,void**h){*h=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE rop_GetResults(IReadOp*This,IBuf**r){ AsyncOp*o=op_from(This,0);
    *r=o->res_buf; if(o->res_buf)o->res_buf->lpVtbl->AddRef(o->res_buf); return S_OK;}
static IReadOpVtbl g_ropVtbl={rop_QI,rop_AddRef,rop_Release,rop_GetIids,rop_GetRCN,rop_GetTL,
    rop_put_Progress,rop_get_Progress,rop_put_Completed,rop_get_Completed,rop_GetResults};

/* --- IWriteOp (IAsyncOperationWithProgress<UINT32,UINT32>) --- */
static HRESULT STDMETHODCALLTYPE wop_QI(IWriteOp*This,REFIID riid,void**ppv){ AsyncOp*o=op_from(This,1);
    if(IsEqualGUID(riid,&IID_IUnknown)||IsEqualGUID(riid,&IID_IInspectable)||
       IsEqualGUID(riid,&IID___FIAsyncOperationWithProgress_2_UINT32_UINT32)){
        *ppv=&o->vtbl_write; op_addref(o); return S_OK;}
    if(IsEqualGUID(riid,&IID_IAsyncInfo)){*ppv=&g_ainfo; return S_OK;}
    *ppv=NULL; return E_NOINTERFACE;}
static ULONG STDMETHODCALLTYPE wop_AddRef(IWriteOp*T){return op_addref(op_from(T,1));}
static ULONG STDMETHODCALLTYPE wop_Release(IWriteOp*T){return op_release(op_from(T,1));}
static HRESULT STDMETHODCALLTYPE wop_GetIids(IWriteOp*T,ULONG*n,IID**p){*n=0;*p=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE wop_GetRCN(IWriteOp*T,HSTRING*s){*s=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE wop_GetTL(IWriteOp*T,TrustLevel*t){*t=BaseTrust;return S_OK;}
static HRESULT STDMETHODCALLTYPE wop_put_Completed(IWriteOp*This,void*h){ AsyncOp*o=op_from(This,1);
    if(h){ o->handler=(IUnknown*)h; o->handler->lpVtbl->AddRef(o->handler);
        typedef HRESULT(STDMETHODCALLTYPE *inv_t)(void*,void*,int);
        inv_t inv=((inv_t*)((IUnknown*)h)->lpVtbl)[3]; inv(h,&o->vtbl_write,1);} return S_OK;}
static HRESULT STDMETHODCALLTYPE wop_get_Completed(IWriteOp*T,void**h){*h=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE wop_put_Progress(IWriteOp*T,void*h){return S_OK;}
static HRESULT STDMETHODCALLTYPE wop_get_Progress(IWriteOp*T,void**h){*h=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE wop_GetResults(IWriteOp*This,UINT32*r){*r=op_from(This,1)->res_u32;return S_OK;}
static IWriteOpVtbl g_wopVtbl={wop_QI,wop_AddRef,wop_Release,wop_GetIids,wop_GetRCN,wop_GetTL,
    wop_put_Progress,wop_get_Progress,wop_put_Completed,wop_get_Completed,wop_GetResults};

/* --- IFlushOp (IAsyncOperation<boolean>) --- */
static HRESULT STDMETHODCALLTYPE fop_QI(IFlushOp*This,REFIID riid,void**ppv){ AsyncOp*o=op_from(This,2);
    if(IsEqualGUID(riid,&IID_IUnknown)||IsEqualGUID(riid,&IID_IInspectable)||
       IsEqualGUID(riid,&IID___FIAsyncOperation_1_boolean)){
        *ppv=&o->vtbl_flush; op_addref(o); return S_OK;}
    if(IsEqualGUID(riid,&IID_IAsyncInfo)){*ppv=&g_ainfo; return S_OK;}
    *ppv=NULL; return E_NOINTERFACE;}
static ULONG STDMETHODCALLTYPE fop_AddRef(IFlushOp*T){return op_addref(op_from(T,2));}
static ULONG STDMETHODCALLTYPE fop_Release(IFlushOp*T){return op_release(op_from(T,2));}
static HRESULT STDMETHODCALLTYPE fop_GetIids(IFlushOp*T,ULONG*n,IID**p){*n=0;*p=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE fop_GetRCN(IFlushOp*T,HSTRING*s){*s=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE fop_GetTL(IFlushOp*T,TrustLevel*t){*t=BaseTrust;return S_OK;}
static HRESULT STDMETHODCALLTYPE fop_put_Completed(IFlushOp*This,void*h){ AsyncOp*o=op_from(This,2);
    if(h){ o->handler=(IUnknown*)h; o->handler->lpVtbl->AddRef(o->handler);
        typedef HRESULT(STDMETHODCALLTYPE *inv_t)(void*,void*,int);
        inv_t inv=((inv_t*)((IUnknown*)h)->lpVtbl)[3]; inv(h,&o->vtbl_flush,1);} return S_OK;}
static HRESULT STDMETHODCALLTYPE fop_get_Completed(IFlushOp*T,void**h){*h=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE fop_GetResults(IFlushOp*This,boolean*r){*r=op_from(This,2)->res_bool;return S_OK;}
static IFlushOpVtbl g_fopVtbl={fop_QI,fop_AddRef,fop_Release,fop_GetIids,fop_GetRCN,fop_GetTL,
    fop_put_Completed,fop_get_Completed,fop_GetResults};

static AsyncOp *new_readop(IBuf*b){AsyncOp*o=calloc(1,sizeof(AsyncOp));o->vtbl_read=&g_ropVtbl;o->ref=1;o->kind=0;o->res_buf=b;return o;}
static AsyncOp *new_writeop(UINT32 n){AsyncOp*o=calloc(1,sizeof(AsyncOp));o->vtbl_write=&g_wopVtbl;o->ref=1;o->kind=1;o->res_u32=n;return o;}
static AsyncOp *new_flushop(void){AsyncOp*o=calloc(1,sizeof(AsyncOp));o->vtbl_flush=&g_fopVtbl;o->ref=1;o->kind=2;o->res_bool=1;return o;}

/* ============================ Stream ============================ */
typedef struct __x_ABI_CWindows_CStorage_CStreams_CIRandomAccessStreamWithContentTypeVtbl IWCTVtbl;
typedef __x_ABI_CWindows_CStorage_CStreams_CIRandomAccessStreamWithContentType IWCT;
typedef struct __x_ABI_CWindows_CStorage_CStreams_CIContentTypeProviderVtbl ICTPVtbl;
typedef __x_ABI_CWindows_CStorage_CStreams_CIContentTypeProvider ICTP;
typedef struct {
    IRASVtbl *vtbl_ras;
    IInVtbl  *vtbl_in;
    IOutVtbl *vtbl_out;
    ICloseVtbl *vtbl_close;
    IWCTVtbl *vtbl_wct;     /* IRandomAccessStreamWithContentType (marker) */
    ICTPVtbl *vtbl_ctp;     /* IContentTypeProvider (get_ContentType)      */
    LONG ref;
    BYTE *data; UINT64 size, cap, pos;
} Stream;
static Stream *new_stream(void);
static Stream *s_from_ras(IRAS*i){return (Stream*)((char*)i-offsetof(Stream,vtbl_ras));}
static Stream *s_from_in(IIn*i){return (Stream*)((char*)i-offsetof(Stream,vtbl_in));}
static Stream *s_from_out(IOut*i){return (Stream*)((char*)i-offsetof(Stream,vtbl_out));}
static Stream *s_from_close(IClose*i){return (Stream*)((char*)i-offsetof(Stream,vtbl_close));}
static Stream *s_from_wct(IWCT*i){return (Stream*)((char*)i-offsetof(Stream,vtbl_wct));}
static Stream *s_from_ctp(ICTP*i){return (Stream*)((char*)i-offsetof(Stream,vtbl_ctp));}
/* grow to EXACT need for big writes (>1MB) so a 41MB model doesn't round up to
 * 64MB; keep geometric doubling only for small/incremental growth. */
static void s_ensure(Stream*s,UINT64 need){ if(need<=s->cap)return; UINT64 nc=(need>(1u<<20))?need:(s->cap?s->cap*2:4096); while(nc<need)nc*=2; s->data=realloc(s->data,nc); memset(s->data+s->cap,0,nc-s->cap); s->cap=nc;}

static HRESULT s_QI(Stream*s,REFIID riid,void**ppv){
    HRESULT hr=S_OK;
    if(IsEqualGUID(riid,&IID_IUnknown)||IsEqualGUID(riid,&IID_IInspectable)||
       IsEqualGUID(riid,&IID___x_ABI_CWindows_CStorage_CStreams_CIRandomAccessStream)){*ppv=&s->vtbl_ras;}
    else if(IsEqualGUID(riid,&IID___x_ABI_CWindows_CStorage_CStreams_CIInputStream)){*ppv=&s->vtbl_in;}
    else if(IsEqualGUID(riid,&IID___x_ABI_CWindows_CStorage_CStreams_CIOutputStream)){*ppv=&s->vtbl_out;}
    else if(IsEqualGUID(riid,&IID___x_ABI_CWindows_CFoundation_CIClosable)){*ppv=&s->vtbl_close;}
    else if(IsEqualGUID(riid,&IID___x_ABI_CWindows_CStorage_CStreams_CIRandomAccessStreamWithContentType)){*ppv=&s->vtbl_wct;}
    else if(IsEqualGUID(riid,&IID___x_ABI_CWindows_CStorage_CStreams_CIContentTypeProvider)){*ppv=&s->vtbl_ctp;}
    else {*ppv=NULL; hr=E_NOINTERFACE;}
    logqi("stream",riid,hr);
    if(hr==S_OK) InterlockedIncrement(&s->ref);
    return hr;
}
static ULONG s_addref(Stream*s){return InterlockedIncrement(&s->ref);}
static ULONG s_release(Stream*s){ULONG r=InterlockedDecrement(&s->ref); if(!r){free(s->data);free(s);} return r;}

/* IRandomAccessStream */
static HRESULT STDMETHODCALLTYPE ras_QI(IRAS*T,REFIID r,void**p){return s_QI(s_from_ras(T),r,p);}
static ULONG STDMETHODCALLTYPE ras_AddRef(IRAS*T){return s_addref(s_from_ras(T));}
static ULONG STDMETHODCALLTYPE ras_Release(IRAS*T){return s_release(s_from_ras(T));}
static HRESULT STDMETHODCALLTYPE ras_GetIids(IRAS*T,ULONG*n,IID**p){*n=0;*p=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE ras_GetRCN(IRAS*T,HSTRING*s){*s=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE ras_GetTL(IRAS*T,TrustLevel*t){*t=BaseTrust;return S_OK;}
static HRESULT STDMETHODCALLTYPE ras_get_Size(IRAS*T,UINT64*v){*v=s_from_ras(T)->size;logmsg("ras_get_Size -> %llu",(unsigned long long)*v);return S_OK;}
static HRESULT STDMETHODCALLTYPE ras_put_Size(IRAS*T,UINT64 v){Stream*s=s_from_ras(T);s_ensure(s,v);s->size=v;logmsg("ras_put_Size %llu",(unsigned long long)v);return S_OK;}
static HRESULT STDMETHODCALLTYPE ras_GetInputStreamAt(IRAS*T,UINT64 pos,IIn**o){Stream*s=s_from_ras(T);s->pos=pos;*o=(IIn*)&s->vtbl_in;s_addref(s);logmsg("ras_GetInputStreamAt %llu (size=%llu)",(unsigned long long)pos,(unsigned long long)s->size);return S_OK;}
static HRESULT STDMETHODCALLTYPE ras_GetOutputStreamAt(IRAS*T,UINT64 pos,IOut**o){Stream*s=s_from_ras(T);s->pos=pos;*o=(IOut*)&s->vtbl_out;s_addref(s);logmsg("ras_GetOutputStreamAt %llu",(unsigned long long)pos);return S_OK;}
static HRESULT STDMETHODCALLTYPE ras_get_Position(IRAS*T,UINT64*v){*v=s_from_ras(T)->pos;return S_OK;}
static HRESULT STDMETHODCALLTYPE ras_Seek(IRAS*T,UINT64 v){s_from_ras(T)->pos=v;return S_OK;}
static HRESULT STDMETHODCALLTYPE ras_CloneStream(IRAS*T,IRAS**o){Stream*s=s_from_ras(T);Stream*n=new_stream();
    if(s->size){s_ensure(n,s->size);memcpy(n->data,s->data,s->size);n->size=s->size;}n->pos=0;
    *o=(IRAS*)&n->vtbl_ras;logmsg("ras_CloneStream copied %llu bytes",(unsigned long long)s->size);return S_OK;}
static HRESULT STDMETHODCALLTYPE ras_get_CanRead(IRAS*T,boolean*v){*v=1;return S_OK;}
static HRESULT STDMETHODCALLTYPE ras_get_CanWrite(IRAS*T,boolean*v){*v=1;return S_OK;}
static IRASVtbl g_rasVtbl={ras_QI,ras_AddRef,ras_Release,ras_GetIids,ras_GetRCN,ras_GetTL,
    ras_get_Size,ras_put_Size,ras_GetInputStreamAt,ras_GetOutputStreamAt,ras_get_Position,
    ras_Seek,ras_CloneStream,ras_get_CanRead,ras_get_CanWrite};

/* IInputStream::ReadAsync(buffer,count,opt) */
static HRESULT STDMETHODCALLTYPE in_QI(IIn*T,REFIID r,void**p){return s_QI(s_from_in(T),r,p);}
static ULONG STDMETHODCALLTYPE in_AddRef(IIn*T){return s_addref(s_from_in(T));}
static ULONG STDMETHODCALLTYPE in_Release(IIn*T){return s_release(s_from_in(T));}
static HRESULT STDMETHODCALLTYPE in_GetIids(IIn*T,ULONG*n,IID**p){*n=0;*p=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE in_GetRCN(IIn*T,HSTRING*s){*s=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE in_GetTL(IIn*T,TrustLevel*t){*t=BaseTrust;return S_OK;}
static HRESULT STDMETHODCALLTYPE in_ReadAsync(IIn*T,IBuf*b,UINT32 count,int opt,IReadOp**op){
    Stream*s=s_from_in(T); UINT64 avail=(s->pos<s->size)?(s->size-s->pos):0; UINT32 n=(count<avail)?count:(UINT32)avail;
    logmsg("in_ReadAsync count=%u pos=%llu size=%llu -> n=%u",count,(unsigned long long)s->pos,(unsigned long long)s->size,n);
    byte*dst=NULL; b->lpVtbl->QueryInterface(b,&IID_IBufferByteAccess,(void**)&dst);
    IBufferByteAccess*bba=NULL; b->lpVtbl->QueryInterface(b,&IID_IBufferByteAccess,(void**)&bba);
    if(bba){ byte*raw=NULL; bba->lpVtbl->Buffer(bba,&raw); if(raw&&n)memcpy(raw,s->data+s->pos,n); bba->lpVtbl->Release(bba);}
    b->lpVtbl->put_Length(b,n); s->pos+=n; b->lpVtbl->AddRef(b);
    *op=(IReadOp*)&new_readop(b)->vtbl_read; return S_OK;
}
static IInVtbl g_inVtbl={in_QI,in_AddRef,in_Release,in_GetIids,in_GetRCN,in_GetTL,in_ReadAsync};

/* IOutputStream::WriteAsync(buffer) — DUMP the bytes */
static HRESULT STDMETHODCALLTYPE out_QI(IOut*T,REFIID r,void**p){return s_QI(s_from_out(T),r,p);}
static ULONG STDMETHODCALLTYPE out_AddRef(IOut*T){return s_addref(s_from_out(T));}
static ULONG STDMETHODCALLTYPE out_Release(IOut*T){return s_release(s_from_out(T));}
static HRESULT STDMETHODCALLTYPE out_GetIids(IOut*T,ULONG*n,IID**p){*n=0;*p=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE out_GetRCN(IOut*T,HSTRING*s){*s=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE out_GetTL(IOut*T,TrustLevel*t){*t=BaseTrust;return S_OK;}
static HRESULT STDMETHODCALLTYPE out_WriteAsync(IOut*T,IBuf*b,IWriteOp**op){
    Stream*s=s_from_out(T); UINT32 len=0; b->lpVtbl->get_Length(b,&len);
    logmsg("out_WriteAsync len=%u pos=%llu",len,(unsigned long long)s->pos);
    byte*raw=NULL; IBufferByteAccess*bba=NULL;
    b->lpVtbl->QueryInterface(b,&IID_IBufferByteAccess,(void**)&bba);
    if(bba){ bba->lpVtbl->Buffer(bba,&raw); bba->lpVtbl->Release(bba);}
    if(raw&&len){ s_ensure(s,s->pos+len); memcpy(s->data+s->pos,raw,len); s->pos+=len; if(s->pos>s->size)s->size=s->pos; }
    *op=(IWriteOp*)&new_writeop(len)->vtbl_write; return S_OK;
}
static HRESULT STDMETHODCALLTYPE out_FlushAsync(IOut*T,IFlushOp**op){*op=(IFlushOp*)&new_flushop()->vtbl_flush;return S_OK;}
static IOutVtbl g_outVtbl={out_QI,out_AddRef,out_Release,out_GetIids,out_GetRCN,out_GetTL,out_WriteAsync,out_FlushAsync};

/* IClosable */
static HRESULT STDMETHODCALLTYPE cl_QI(IClose*T,REFIID r,void**p){return s_QI(s_from_close(T),r,p);}
static ULONG STDMETHODCALLTYPE cl_AddRef(IClose*T){return s_addref(s_from_close(T));}
static ULONG STDMETHODCALLTYPE cl_Release(IClose*T){return s_release(s_from_close(T));}
static HRESULT STDMETHODCALLTYPE cl_GetIids(IClose*T,ULONG*n,IID**p){*n=0;*p=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE cl_GetRCN(IClose*T,HSTRING*s){*s=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE cl_GetTL(IClose*T,TrustLevel*t){*t=BaseTrust;return S_OK;}
static HRESULT STDMETHODCALLTYPE cl_Close(IClose*T){return S_OK;}
static ICloseVtbl g_clVtbl={cl_QI,cl_AddRef,cl_Release,cl_GetIids,cl_GetRCN,cl_GetTL,cl_Close};

/* IRandomAccessStreamWithContentType — marker interface, only IInspectable;
 * consumers QI it back for IRandomAccessStream/IInputStream/IContentTypeProvider */
static HRESULT STDMETHODCALLTYPE wct_QI(IWCT*T,REFIID r,void**p){return s_QI(s_from_wct(T),r,p);}
static ULONG STDMETHODCALLTYPE wct_AddRef(IWCT*T){return s_addref(s_from_wct(T));}
static ULONG STDMETHODCALLTYPE wct_Release(IWCT*T){return s_release(s_from_wct(T));}
static HRESULT STDMETHODCALLTYPE wct_GetIids(IWCT*T,ULONG*n,IID**p){*n=0;*p=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE wct_GetRCN(IWCT*T,HSTRING*s){*s=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE wct_GetTL(IWCT*T,TrustLevel*t){*t=BaseTrust;return S_OK;}
static IWCTVtbl g_wctVtbl={wct_QI,wct_AddRef,wct_Release,wct_GetIids,wct_GetRCN,wct_GetTL};

/* IContentTypeProvider::get_ContentType -> "application/octet-stream" */
static HRESULT STDMETHODCALLTYPE ctp_QI(ICTP*T,REFIID r,void**p){return s_QI(s_from_ctp(T),r,p);}
static ULONG STDMETHODCALLTYPE ctp_AddRef(ICTP*T){return s_addref(s_from_ctp(T));}
static ULONG STDMETHODCALLTYPE ctp_Release(ICTP*T){return s_release(s_from_ctp(T));}
static HRESULT STDMETHODCALLTYPE ctp_GetIids(ICTP*T,ULONG*n,IID**p){*n=0;*p=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE ctp_GetRCN(ICTP*T,HSTRING*s){*s=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE ctp_GetTL(ICTP*T,TrustLevel*t){*t=BaseTrust;return S_OK;}
static HRESULT STDMETHODCALLTYPE ctp_get_ContentType(ICTP*T,HSTRING*v){
    WindowsCreateString(L"application/octet-stream",24,v); return S_OK;}
static ICTPVtbl g_ctpVtbl={ctp_QI,ctp_AddRef,ctp_Release,ctp_GetIids,ctp_GetRCN,ctp_GetTL,ctp_get_ContentType};

static Stream *new_stream(void){
    Stream*s=calloc(1,sizeof(Stream)); s->vtbl_ras=&g_rasVtbl; s->vtbl_in=&g_inVtbl;
    s->vtbl_out=&g_outVtbl; s->vtbl_close=&g_clVtbl; s->vtbl_wct=&g_wctVtbl; s->vtbl_ctp=&g_ctpVtbl;
    s->ref=1; return s;
}

/* ====================== DataWriter ====================== */
/* WML writes the model: CreateDataWriter(ourOutputStream) -> WriteBuffer/Bytes
 * -> StoreAsync (flush to the output stream). wine's wintypes DataWriter is a
 * semi-stub that never forwards, so we provide a working one. */
typedef __x_ABI_CWindows_CStorage_CStreams_CIDataWriter IDW;
typedef __x_ABI_CWindows_CStorage_CStreams_CIDataWriterVtbl IDWVtbl;
typedef __x_ABI_CWindows_CStorage_CStreams_CIDataWriterFactory IDWF;
typedef __x_ABI_CWindows_CStorage_CStreams_CIDataWriterFactoryVtbl IDWFVtbl;
typedef __FIAsyncOperation_1_UINT32 IStoreOp;
typedef __FIAsyncOperation_1_UINT32Vtbl IStoreOpVtbl;

/* sync IAsyncOperation<UINT32> for StoreAsync */
typedef struct { IStoreOpVtbl *vtbl; LONG ref; UINT32 res; IUnknown*handler; } StoreOp;
static HRESULT STDMETHODCALLTYPE so_QI(IStoreOp*This,REFIID riid,void**ppv){ StoreOp*o=(StoreOp*)This;
    if(IsEqualGUID(riid,&IID_IUnknown)||IsEqualGUID(riid,&IID_IInspectable)||
       IsEqualGUID(riid,&IID___FIAsyncOperation_1_UINT32)){*ppv=o;InterlockedIncrement(&o->ref);return S_OK;}
    if(IsEqualGUID(riid,&IID_IAsyncInfo)){*ppv=&g_ainfo;return S_OK;}
    *ppv=NULL;return E_NOINTERFACE;}
static ULONG STDMETHODCALLTYPE so_AddRef(IStoreOp*T){return InterlockedIncrement(&((StoreOp*)T)->ref);}
static ULONG STDMETHODCALLTYPE so_Release(IStoreOp*T){StoreOp*o=(StoreOp*)T;ULONG r=InterlockedDecrement(&o->ref);if(!r){if(o->handler)o->handler->lpVtbl->Release(o->handler);free(o);}return r;}
static HRESULT STDMETHODCALLTYPE so_GetIids(IStoreOp*T,ULONG*n,IID**p){*n=0;*p=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE so_GetRCN(IStoreOp*T,HSTRING*s){*s=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE so_GetTL(IStoreOp*T,TrustLevel*t){*t=BaseTrust;return S_OK;}
static HRESULT STDMETHODCALLTYPE so_put_Completed(IStoreOp*This,void*h){StoreOp*o=(StoreOp*)This;
    if(h){o->handler=(IUnknown*)h;o->handler->lpVtbl->AddRef(o->handler);
        typedef HRESULT(STDMETHODCALLTYPE*inv_t)(void*,void*,int); inv_t inv=((inv_t*)((IUnknown*)h)->lpVtbl)[3]; inv(h,This,1);}return S_OK;}
static HRESULT STDMETHODCALLTYPE so_get_Completed(IStoreOp*T,void**h){*h=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE so_GetResults(IStoreOp*This,UINT32*r){*r=((StoreOp*)This)->res;return S_OK;}
static IStoreOpVtbl g_soVtbl={so_QI,so_AddRef,so_Release,so_GetIids,so_GetRCN,so_GetTL,so_put_Completed,so_get_Completed,so_GetResults};
static StoreOp* new_storeop(UINT32 n){StoreOp*o=calloc(1,sizeof(StoreOp));o->vtbl=&g_soVtbl;o->ref=1;o->res=n;return o;}

typedef struct { IDWVtbl *vtbl; LONG ref; IOut *out; BYTE *buf; UINT32 len, cap; } DataWriter;
static void dw_grow(DataWriter*d,UINT32 need){ if(need<=d->cap)return; UINT32 nc=(need>(1u<<20))?need:(d->cap?d->cap*2:4096); while(nc<need)nc*=2; d->buf=realloc(d->buf,nc); d->cap=nc; }
/* NOTE: once we own RandomAccessStreamReference, Adobe runs the full WinML
 * path and DOES call DataWriter.StoreAsync (which flushes buf -> stream via
 * out->WriteAsync). So NO flush-on-write here — doing both double-writes the
 * model into the stream and corrupts it. Buffer only; StoreAsync commits. */
static HRESULT STDMETHODCALLTYPE dw_QI(IDW*This,REFIID riid,void**ppv){ DataWriter*d=(DataWriter*)This;
    HRESULT hr=E_NOINTERFACE;
    if(IsEqualGUID(riid,&IID_IUnknown)||IsEqualGUID(riid,&IID_IInspectable)||
       IsEqualGUID(riid,&IID___x_ABI_CWindows_CStorage_CStreams_CIDataWriter)){*ppv=d;InterlockedIncrement(&d->ref);hr=S_OK;} else *ppv=NULL;
    logqi("datawriter",riid,hr); return hr;}
static ULONG STDMETHODCALLTYPE dw_AddRef(IDW*T){return InterlockedIncrement(&((DataWriter*)T)->ref);}
static ULONG STDMETHODCALLTYPE dw_Release(IDW*T){DataWriter*d=(DataWriter*)T;ULONG r=InterlockedDecrement(&d->ref);if(!r){if(d->out)d->out->lpVtbl->Release(d->out);free(d->buf);free(d);}return r;}
static HRESULT STDMETHODCALLTYPE dw_GetIids(IDW*T,ULONG*n,IID**p){*n=0;*p=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE dw_GetRCN(IDW*T,HSTRING*s){*s=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE dw_GetTL(IDW*T,TrustLevel*t){*t=BaseTrust;return S_OK;}
static HRESULT STDMETHODCALLTYPE dw_ni(void*This){logmsg("dw_ni (unimpl typed-write/prop)");return E_NOTIMPL;}       /* x64: ignores extra args */
static HRESULT STDMETHODCALLTYPE dw_get_unstored(IDW*This,UINT32*v){*v=((DataWriter*)This)->len;logmsg("dw_get_unstored -> %u",*v);return S_OK;}
static HRESULT STDMETHODCALLTYPE dw_ok(void*This){logmsg("dw_ok (put prop)");return S_OK;}            /* for put props */
static HRESULT STDMETHODCALLTYPE dw_WriteByte(IDW*This,BYTE b){DataWriter*d=(DataWriter*)This;dw_grow(d,d->len+1);d->buf[d->len++]=b;return S_OK;}
static HRESULT STDMETHODCALLTYPE dw_WriteBytes(IDW*This,UINT32 n,BYTE*v){DataWriter*d=(DataWriter*)This;dw_grow(d,d->len+n);memcpy(d->buf+d->len,v,n);d->len+=n;
    logmsg("dw_WriteBytes n=%u total=%u first8=%02x%02x%02x%02x%02x%02x%02x%02x",n,d->len,
        n>0?v[0]:0,n>1?v[1]:0,n>2?v[2]:0,n>3?v[3]:0,n>4?v[4]:0,n>5?v[5]:0,n>6?v[6]:0,n>7?v[7]:0);
    return S_OK;}
static HRESULT STDMETHODCALLTYPE dw_WriteBuffer(IDW*This,IBuf*b){DataWriter*d=(DataWriter*)This;UINT32 n=0;b->lpVtbl->get_Length(b,&n);
    IBufferByteAccess*bba=NULL;byte*raw=NULL;b->lpVtbl->QueryInterface(b,&IID_IBufferByteAccess,(void**)&bba);
    if(bba){bba->lpVtbl->Buffer(bba,&raw);bba->lpVtbl->Release(bba);} if(raw&&n){dw_grow(d,d->len+n);memcpy(d->buf+d->len,raw,n);d->len+=n;}logmsg("dw_WriteBuffer n=%u total=%u",n,d->len);return S_OK;}
static HRESULT STDMETHODCALLTYPE dw_WriteBufferRange(IDW*This,IBuf*b,UINT32 start,UINT32 count){DataWriter*d=(DataWriter*)This;
    IBufferByteAccess*bba=NULL;byte*raw=NULL;b->lpVtbl->QueryInterface(b,&IID_IBufferByteAccess,(void**)&bba);
    if(bba){bba->lpVtbl->Buffer(bba,&raw);bba->lpVtbl->Release(bba);} if(raw&&count){dw_grow(d,d->len+count);memcpy(d->buf+d->len,raw+start,count);d->len+=count;}return S_OK;}
static HRESULT STDMETHODCALLTYPE dw_StoreAsync(IDW*This,IStoreOp**op){ DataWriter*d=(DataWriter*)This;
    logmsg("dw_StoreAsync len=%u out=%p",d->len,(void*)d->out);
    if(d->out && d->len){ Buffer*b=new_buffer(d->len); memcpy(b->data,d->buf,d->len); b->len=d->len;
        IWriteOp*wop=NULL; d->out->lpVtbl->WriteAsync(d->out,(IBuf*)&b->vtbl_buf,&wop); if(wop)wop->lpVtbl->Release(wop);
        ((IBuf*)&b->vtbl_buf)->lpVtbl->Release((IBuf*)&b->vtbl_buf); }
    /* model now committed to the stream — drop the DataWriter's own copy so we
     * don't hold the (multi-MB) model twice per masking model. */
    UINT32 n=d->len; free(d->buf); d->buf=NULL; d->cap=0; d->len=0;
    *op=(IStoreOp*)new_storeop(n); return S_OK; }
static HRESULT STDMETHODCALLTYPE dw_FlushAsync(IDW*This,IFlushOp**op){logmsg("dw_FlushAsync");*op=(IFlushOp*)&new_flushop()->vtbl_flush;return S_OK;}
static HRESULT STDMETHODCALLTYPE dw_DetachBuffer(IDW*This,IBuf**b){DataWriter*d=(DataWriter*)This;logmsg("dw_DetachBuffer len=%u",d->len);Buffer*nb=new_buffer(d->len?d->len:1);memcpy(nb->data,d->buf,d->len);nb->len=d->len;*b=(IBuf*)&nb->vtbl_buf;d->len=0;return S_OK;}
static HRESULT STDMETHODCALLTYPE dw_DetachStream(IDW*This,IOut**o){DataWriter*d=(DataWriter*)This;logmsg("dw_DetachStream");*o=d->out;if(d->out){d->out->lpVtbl->AddRef(d->out);}return S_OK;}
/* positional vtbl (33 slots) — typed writes/props we don't need use dw_ni/dw_ok */
static IDWVtbl g_dwVtbl={
    dw_QI,dw_AddRef,dw_Release,dw_GetIids,dw_GetRCN,dw_GetTL,
    dw_get_unstored,(void*)dw_ni,(void*)dw_ok,(void*)dw_ni,(void*)dw_ok,  /* unstored, get/put unicode, get/put byteorder */
    dw_WriteByte,dw_WriteBytes,dw_WriteBuffer,dw_WriteBufferRange,
    (void*)dw_ni,(void*)dw_ni,(void*)dw_ni,(void*)dw_ni,(void*)dw_ni,(void*)dw_ni,(void*)dw_ni,(void*)dw_ni, /* Boolean,Guid,Int16,Int32,Int64,UInt16,UInt32,UInt64 */
    (void*)dw_ni,(void*)dw_ni,(void*)dw_ni,(void*)dw_ni,(void*)dw_ni,(void*)dw_ni, /* Single,Double,DateTime,TimeSpan,String,MeasureString */
    dw_StoreAsync,dw_FlushAsync,dw_DetachBuffer,dw_DetachStream };
static DataWriter* new_datawriter(IOut*out){DataWriter*d=calloc(1,sizeof(DataWriter));d->vtbl=&g_dwVtbl;d->ref=1;d->out=out;if(out)out->lpVtbl->AddRef(out);return d;}

/* IDataWriterFactory */
typedef struct { IDWFVtbl *vtbl; LONG ref; } DWFactory;
static HRESULT STDMETHODCALLTYPE dwf_QI(IDWF*This,REFIID riid,void**ppv){
    if(IsEqualGUID(riid,&IID_IUnknown)||IsEqualGUID(riid,&IID_IInspectable)||IsEqualGUID(riid,&IID_IActivationFactory)||
       IsEqualGUID(riid,&IID___x_ABI_CWindows_CStorage_CStreams_CIDataWriterFactory)){*ppv=This;((DWFactory*)This)->ref++;return S_OK;} *ppv=NULL;return E_NOINTERFACE;}
static ULONG STDMETHODCALLTYPE dwf_AddRef(IDWF*T){return ++((DWFactory*)T)->ref;}
static ULONG STDMETHODCALLTYPE dwf_Release(IDWF*T){return --((DWFactory*)T)->ref;}
static HRESULT STDMETHODCALLTYPE dwf_GetIids(IDWF*T,ULONG*n,IID**p){*n=0;*p=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE dwf_GetRCN(IDWF*T,HSTRING*s){*s=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE dwf_GetTL(IDWF*T,TrustLevel*t){*t=BaseTrust;return S_OK;}
static HRESULT STDMETHODCALLTYPE dwf_Create(IDWF*This,IOut*out,IDW**w){logmsg("dwf_Create out=%p",(void*)out);*w=(IDW*)new_datawriter(out);return S_OK;}
static IDWFVtbl g_dwfVtbl={dwf_QI,dwf_AddRef,dwf_Release,dwf_GetIids,dwf_GetRCN,dwf_GetTL,dwf_Create};
static DWFactory g_dwFactory={&g_dwfVtbl,1};

/* ============ RandomAccessStreamReference (read bridge for WinML) ============
 * wine's windows.storage RandomAccessStreamReference is a semi-stub that does
 * NOT feed our stream's bytes back to WinML's OpenReadAsync (verified: our
 * stream is never read). WinML's LearningModel.LoadFromStream goes:
 *   InMemoryRandomAccessStream (ours, holds the model) ->
 *   RandomAccessStreamReference.CreateFromStream(it) ->
 *   reference.OpenReadAsync() -> IRandomAccessStreamWithContentType -> read.
 * Own the reference so OpenReadAsync hands back OUR stream (which now has the
 * flushed model), and WinML actually reads the ONNX. */
typedef __x_ABI_CWindows_CStorage_CStreams_CIRandomAccessStreamReference IRASRef;
typedef __x_ABI_CWindows_CStorage_CStreams_CIRandomAccessStreamReferenceVtbl IRASRefVtbl;
typedef __x_ABI_CWindows_CStorage_CStreams_CIRandomAccessStreamReferenceStatics IRASRefStatics;
typedef __x_ABI_CWindows_CStorage_CStreams_CIRandomAccessStreamReferenceStaticsVtbl IRASRefStaticsVtbl;
typedef __FIAsyncOperation_1_Windows__CStorage__CStreams__CIRandomAccessStreamWithContentType IORAsyncOp;
typedef __FIAsyncOperation_1_Windows__CStorage__CStreams__CIRandomAccessStreamWithContentTypeVtbl IORAsyncOpVtbl;

/* sync IAsyncOperation<IRandomAccessStreamWithContentType*> for OpenReadAsync */
typedef struct { IORAsyncOpVtbl *vtbl; LONG ref; IWCT *res; IUnknown *handler; } ORAsyncOp;
static HRESULT STDMETHODCALLTYPE orop_QI(IORAsyncOp*T,REFIID riid,void**ppv){ ORAsyncOp*o=(ORAsyncOp*)T;
    if(IsEqualGUID(riid,&IID_IUnknown)||IsEqualGUID(riid,&IID_IInspectable)||
       IsEqualGUID(riid,&IID___FIAsyncOperation_1_Windows__CStorage__CStreams__CIRandomAccessStreamWithContentType)){
        *ppv=o;InterlockedIncrement(&o->ref);return S_OK;}
    if(IsEqualGUID(riid,&IID_IAsyncInfo)){*ppv=&g_ainfo;return S_OK;}
    *ppv=NULL;return E_NOINTERFACE;}
static ULONG STDMETHODCALLTYPE orop_AddRef(IORAsyncOp*T){return InterlockedIncrement(&((ORAsyncOp*)T)->ref);}
static ULONG STDMETHODCALLTYPE orop_Release(IORAsyncOp*T){ORAsyncOp*o=(ORAsyncOp*)T;ULONG r=InterlockedDecrement(&o->ref);
    if(!r){if(o->res)((IWCT*)o->res)->lpVtbl->Release(o->res);if(o->handler)o->handler->lpVtbl->Release(o->handler);free(o);}return r;}
static HRESULT STDMETHODCALLTYPE orop_GetIids(IORAsyncOp*T,ULONG*n,IID**p){*n=0;*p=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE orop_GetRCN(IORAsyncOp*T,HSTRING*s){*s=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE orop_GetTL(IORAsyncOp*T,TrustLevel*t){*t=BaseTrust;return S_OK;}
static HRESULT STDMETHODCALLTYPE orop_put_Completed(IORAsyncOp*This,void*h){ ORAsyncOp*o=(ORAsyncOp*)This;
    logmsg("orop_put_Completed (OpenReadAsync completing)");
    if(h){ o->handler=(IUnknown*)h; o->handler->lpVtbl->AddRef(o->handler);
        typedef HRESULT(STDMETHODCALLTYPE *inv_t)(void*,void*,int);
        inv_t inv=((inv_t*)((IUnknown*)h)->lpVtbl)[3]; inv(h,This,1 /*Completed*/);} return S_OK;}
static HRESULT STDMETHODCALLTYPE orop_get_Completed(IORAsyncOp*T,void**h){*h=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE orop_GetResults(IORAsyncOp*This,IWCT**r){ ORAsyncOp*o=(ORAsyncOp*)This;
    *r=o->res; if(o->res)((IWCT*)o->res)->lpVtbl->AddRef(o->res); logmsg("orop_GetResults -> %p",(void*)o->res); return S_OK;}
static IORAsyncOpVtbl g_oropVtbl={orop_QI,orop_AddRef,orop_Release,orop_GetIids,orop_GetRCN,orop_GetTL,
    orop_put_Completed,orop_get_Completed,orop_GetResults};
static ORAsyncOp* new_orop(IWCT*res){ORAsyncOp*o=calloc(1,sizeof(ORAsyncOp));o->vtbl=&g_oropVtbl;o->ref=1;o->res=res;
    if(res)res->lpVtbl->AddRef(res);return o;}

/* StreamRef: holds the wrapped IRandomAccessStream; OpenReadAsync returns it */
typedef struct { IRASRefVtbl *vtbl; LONG ref; IRAS *stream; } StreamRef;
static HRESULT STDMETHODCALLTYPE sr_QI(IRASRef*This,REFIID riid,void**ppv){ StreamRef*s=(StreamRef*)This;
    if(IsEqualGUID(riid,&IID_IUnknown)||IsEqualGUID(riid,&IID_IInspectable)||
       IsEqualGUID(riid,&IID___x_ABI_CWindows_CStorage_CStreams_CIRandomAccessStreamReference)){*ppv=s;InterlockedIncrement(&s->ref);return S_OK;}
    *ppv=NULL;return E_NOINTERFACE;}
static ULONG STDMETHODCALLTYPE sr_AddRef(IRASRef*T){return InterlockedIncrement(&((StreamRef*)T)->ref);}
static ULONG STDMETHODCALLTYPE sr_Release(IRASRef*T){StreamRef*s=(StreamRef*)T;ULONG r=InterlockedDecrement(&s->ref);
    if(!r){if(s->stream)s->stream->lpVtbl->Release(s->stream);free(s);}return r;}
static HRESULT STDMETHODCALLTYPE sr_GetIids(IRASRef*T,ULONG*n,IID**p){*n=0;*p=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE sr_GetRCN(IRASRef*T,HSTRING*s){*s=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE sr_GetTL(IRASRef*T,TrustLevel*t){*t=BaseTrust;return S_OK;}
static HRESULT STDMETHODCALLTYPE sr_OpenReadAsync(IRASRef*This,IORAsyncOp**op){ StreamRef*s=(StreamRef*)This;
    /* DataWriter.StoreAsync left the stream position at the END (= model size).
     * OpenReadAsync means "open for reading from the start", so rewind to 0 or
     * WinML reads 0 bytes -> empty model -> "ML model not loaded". */
    if(s->stream) s->stream->lpVtbl->Seek(s->stream, 0);
    IWCT *wct=NULL; if(s->stream) s->stream->lpVtbl->QueryInterface(s->stream,
        &IID___x_ABI_CWindows_CStorage_CStreams_CIRandomAccessStreamWithContentType,(void**)&wct);
    logmsg("sr_OpenReadAsync wct=%p",(void*)wct);
    *op=(IORAsyncOp*)new_orop(wct); if(wct)wct->lpVtbl->Release(wct); return S_OK;}
static IRASRefVtbl g_srVtbl={sr_QI,sr_AddRef,sr_Release,sr_GetIids,sr_GetRCN,sr_GetTL,sr_OpenReadAsync};
static StreamRef* new_streamref(IRAS*st){StreamRef*s=calloc(1,sizeof(StreamRef));s->vtbl=&g_srVtbl;s->ref=1;s->stream=st;
    if(st)st->lpVtbl->AddRef(st);return s;}

/* IRandomAccessStreamReferenceStatics */
typedef struct { IRASRefStaticsVtbl *vtbl; LONG ref; } RASRefStatics;
static HRESULT STDMETHODCALLTYPE srs_QI(IRASRefStatics*This,REFIID riid,void**ppv){
    if(IsEqualGUID(riid,&IID_IUnknown)||IsEqualGUID(riid,&IID_IInspectable)||IsEqualGUID(riid,&IID_IActivationFactory)||
       IsEqualGUID(riid,&IID___x_ABI_CWindows_CStorage_CStreams_CIRandomAccessStreamReferenceStatics)){
        *ppv=This;((RASRefStatics*)This)->ref++;return S_OK;} *ppv=NULL;return E_NOINTERFACE;}
static ULONG STDMETHODCALLTYPE srs_AddRef(IRASRefStatics*T){return ++((RASRefStatics*)T)->ref;}
static ULONG STDMETHODCALLTYPE srs_Release(IRASRefStatics*T){return --((RASRefStatics*)T)->ref;}
static HRESULT STDMETHODCALLTYPE srs_GetIids(IRASRefStatics*T,ULONG*n,IID**p){*n=0;*p=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE srs_GetRCN(IRASRefStatics*T,HSTRING*s){*s=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE srs_GetTL(IRASRefStatics*T,TrustLevel*t){*t=BaseTrust;return S_OK;}
static HRESULT STDMETHODCALLTYPE srs_CreateFromFile(IRASRefStatics*T,void*file,IRASRef**r){*r=NULL;return E_NOTIMPL;}
static HRESULT STDMETHODCALLTYPE srs_CreateFromUri(IRASRefStatics*T,void*uri,IRASRef**r){*r=NULL;return E_NOTIMPL;}
static HRESULT STDMETHODCALLTYPE srs_CreateFromStream(IRASRefStatics*T,IRAS*stream,IRASRef**r){
    logmsg("srs_CreateFromStream stream=%p",(void*)stream);
    *r=(IRASRef*)new_streamref(stream); return S_OK;}
static IRASRefStaticsVtbl g_srsVtbl={srs_QI,srs_AddRef,srs_Release,srs_GetIids,srs_GetRCN,srs_GetTL,
    srs_CreateFromFile,srs_CreateFromUri,srs_CreateFromStream};
static RASRefStatics g_srsFactory={&g_srsVtbl,1};

/* ====================== activation factory ====================== */
typedef struct { IActivationFactoryVtbl *vtbl; LONG ref; } Factory;
static HRESULT STDMETHODCALLTYPE f_QI(IActivationFactory*This,REFIID riid,void**ppv){
    if(IsEqualGUID(riid,&IID_IUnknown)||IsEqualGUID(riid,&IID_IInspectable)||IsEqualGUID(riid,&IID_IActivationFactory)){
        *ppv=This; ((Factory*)This)->ref++; return S_OK;} *ppv=NULL; return E_NOINTERFACE;}
static ULONG STDMETHODCALLTYPE f_AddRef(IActivationFactory*This){return ++((Factory*)This)->ref;}
static ULONG STDMETHODCALLTYPE f_Release(IActivationFactory*This){return --((Factory*)This)->ref;}
static HRESULT STDMETHODCALLTYPE f_GetIids(IActivationFactory*T,ULONG*n,IID**p){*n=0;*p=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE f_GetRCN(IActivationFactory*T,HSTRING*s){*s=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE f_GetTL(IActivationFactory*T,TrustLevel*t){*t=BaseTrust;return S_OK;}
static HRESULT STDMETHODCALLTYPE f_ActivateInstance(IActivationFactory*T,IInspectable**inst){
    Stream*s=new_stream(); *inst=(IInspectable*)&s->vtbl_ras; logmsg("f_ActivateInstance stream=%p",(void*)s); return S_OK;}
static IActivationFactoryVtbl g_fVtbl={f_QI,f_AddRef,f_Release,f_GetIids,f_GetRCN,f_GetTL,f_ActivateInstance};
static Factory g_factory={&g_fVtbl,1};

HRESULT WINAPI DllGetActivationFactory(HSTRING name, IActivationFactory **factory){
    UINT32 len=0; const WCHAR *s = WindowsGetStringRawBuffer(name,&len);
    if(s && len && wcsstr(s, L"DataWriter")){
        *factory=(IActivationFactory*)&g_dwFactory; g_dwFactory.ref++; return S_OK;
    }
    if(s && len && wcsstr(s, L"RandomAccessStreamReference")){
        *factory=(IActivationFactory*)&g_srsFactory; g_srsFactory.ref++; return S_OK;
    }
    *factory=(IActivationFactory*)&g_factory; g_factory.ref++; return S_OK;
}
HRESULT WINAPI DllCanUnloadNow(void){ return S_FALSE; }
BOOL WINAPI DllMain(HINSTANCE h,DWORD r,LPVOID v){ if(r==DLL_PROCESS_ATTACH)DisableThreadLibraryCalls(h); return TRUE; }
