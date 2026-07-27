/* fakeram.c — LD_PRELOAD shim that caps the total RAM the process sees.
 *
 * Lightroom's WML / onnxruntime sizes its CPU inference memory arena to the
 * machine's *total* RAM (logs "ML inference: CPU memory (15.305GB)"). On a
 * 15GB box that makes it try to use everything -> OOM/freeze. Capping the
 * reported total to e.g. 9GB makes onnxruntime size a smaller arena so CPU
 * inference can fit alongside the desktop.
 *
 * wine's ntdll reads host memory via sysinfo() (GlobalMemoryStatusEx ->
 * NtQuerySystemInformation -> sysinfo) and, on some paths, /proc/meminfo.
 * We intercept sysinfo() here and also redirect reads of /proc/meminfo to a
 * generated file with clamped MemTotal.
 *
 * Build: gcc -shared -fPIC -O2 -o stubs/binaries/fakeram.so stubs/sources/fakeram.c -ldl
 * Use:   LD_PRELOAD=.../fakeram.so FAKERAM_GB=9 wine ...
 */
#define _GNU_SOURCE
#include <sys/sysinfo.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <fcntl.h>
#include <unistd.h>

static unsigned long cap_bytes(void){
    const char *g = getenv("FAKERAM_GB");
    double gb = g ? atof(g) : 9.0;
    if(gb <= 0) gb = 9.0;
    return (unsigned long)(gb * 1024.0 * 1024.0 * 1024.0);
}

/* ---- sysinfo() ---- */
int sysinfo(struct sysinfo *info){
    static int (*real)(struct sysinfo*) = NULL;
    if(!real) real = dlsym(RTLD_NEXT, "sysinfo");
    int r = real(info);
    if(r == 0 && info){
        unsigned long unit = info->mem_unit ? info->mem_unit : 1;
        unsigned long cap = cap_bytes() / unit;
        if(info->totalram > cap)  info->totalram  = cap;
        if(info->freeram  > cap)  info->freeram   = cap/2;   /* keep free < total */
        if(info->totalhigh> cap)  info->totalhigh = 0;
    }
    return r;
}

/* ---- /proc/meminfo redirect (some wine paths read it directly) ---- */
static const char *fake_meminfo_path(void){
    static char path[256] = "";
    if(path[0]) return path;
    unsigned long kb = cap_bytes() / 1024;
    snprintf(path, sizeof path, "/tmp/.fakeram_meminfo_%d", getpid());
    FILE *f = fopen(path, "w");
    if(f){
        fprintf(f,
            "MemTotal:       %lu kB\n"
            "MemFree:        %lu kB\n"
            "MemAvailable:   %lu kB\n"
            "Buffers:        0 kB\n"
            "Cached:         0 kB\n"
            "SwapTotal:      0 kB\n"
            "SwapFree:       0 kB\n",
            kb, kb/2, kb/2);
        fclose(f);
    }
    return path;
}
static int is_meminfo(const char *p){ return p && strcmp(p, "/proc/meminfo") == 0; }

FILE *fopen(const char *path, const char *mode){
    static FILE *(*real)(const char*,const char*) = NULL;
    if(!real) real = dlsym(RTLD_NEXT, "fopen");
    if(is_meminfo(path)) path = fake_meminfo_path();
    return real(path, mode);
}
FILE *fopen64(const char *path, const char *mode){
    static FILE *(*real)(const char*,const char*) = NULL;
    if(!real) real = dlsym(RTLD_NEXT, "fopen64");
    if(is_meminfo(path)) path = fake_meminfo_path();
    return real(path, mode);
}
int open(const char *path, int flags, ...){
    static int (*real)(const char*,int,...) = NULL;
    if(!real) real = dlsym(RTLD_NEXT, "open");
    mode_t m = 0;
    if(flags & O_CREAT){ va_list ap; va_start(ap,flags); m = va_arg(ap, int); va_end(ap); }
    if(is_meminfo(path)) path = fake_meminfo_path();
    return real(path, flags, m);
}
int open64(const char *path, int flags, ...){
    static int (*real)(const char*,int,...) = NULL;
    if(!real) real = dlsym(RTLD_NEXT, "open64");
    mode_t m = 0;
    if(flags & O_CREAT){ va_list ap; va_start(ap,flags); m = va_arg(ap, int); va_end(ap); }
    if(is_meminfo(path)) path = fake_meminfo_path();
    return real(path, flags, m);
}
