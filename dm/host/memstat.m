// Memory accounting: when DM_MEMSTAT=<tsv path> is set, one line is logged per second (common to Mac / iOS).
//   Totals: phys_footprint (task_info TASK_VM_INFO, which the iOS memory limit is based on), os_proc_available_memory (iOS only), Metal currentAllocatedSize
//   Breakdown: walk this process's VM regions (vm_region_recurse_64, VM_REGION_SUBMAP_INFO_64), classify by region, and for each class record
//         virtual = address space size (reserved-only counts too), resident = pages_resident, charged = dirty pages + compressed/swapped-out pages, deduplicated by VM object (≈ the part that goes into phys_footprint)
//         dedup key = (object id, offset within the object); reason for dedup: Metal wraps the guest memory pool with "no copy", so the same object is mapped in several places (share_mode TRUESHARED, ref_count>1), and summing region by region would double count;
// measured on Mac, after per-object dedup Σcharged is 2,139 MiB against phys_footprint 2,111 MiB (+1.3%)
//   Classes: guest (the whole guest address space block, including the SetHeapSize heap, alias, stacks; data read from RomFS through pread also lands here), code (embedded / loaded module images),
//         malloc (host heap), gpu (IOAccelerator / IOSurface / Metal tagged regions), stack, file (file mappings), other
//   The part where charged ≠ phys_footprint (GPU private memory accounted by IOKit is not in any VM region) is listed separately as "unattributed" = footprint − Σcharged.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <TargetConditionals.h>
#include <mach/mach.h>
#include <mach/vm_statistics.h>
#include <stdatomic.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif
#include "dm.h"

void svc_guest_range(uint8_t **base, size_t *size);
void svc_guest_ranges(uint8_t **heap, size_t *heap_size, uint8_t **alias, size_t *alias_size,
                      uint8_t **stack, size_t *stack_size);
enum { C_GUEST, C_GUEST_HEAP, C_GUEST_ALIAS, C_GUEST_STACK, C_GUEST_OTHER,
       C_CODE, C_MALLOC, C_GPU, C_STACK, C_FILE, C_OTHER, NC };
static const char *k_cls[NC] = {"guest", "guest_heap", "guest_alias", "guest_stack", "guest_other",
                                "code", "malloc", "gpu", "stack", "file", "other"};
static _Atomic int g_crossing_dump_active;

void dm_memstat_wait_for_crossing_dump(void) {
    uint64_t deadline = now_ns() + 2000000000ull;
    struct timespec pause = {.tv_sec = 0, .tv_nsec = 1000000};
    while (atomic_load(&g_crossing_dump_active) && now_ns() < deadline) nanosleep(&pause, NULL);
}

static int classify(vm_address_t a, const vm_region_submap_info_data_64_t *in) {
    uint8_t *gb; size_t gs; svc_guest_range(&gb, &gs);
    for (int i = 0; i < g_nmod; i++)
        if (a >= (vm_address_t)g_mod[i].base && a < (vm_address_t)g_mod[i].base + g_mod[i].size) return C_CODE;
    if (gb && a >= (vm_address_t)gb && a < (vm_address_t)gb + gs) {
        uint8_t *heap, *alias, *stack; size_t heap_size, alias_size, stack_size;
        svc_guest_ranges(&heap, &heap_size, &alias, &alias_size, &stack, &stack_size);
        if (heap && a >= (vm_address_t)heap && a < (vm_address_t)heap + heap_size) return C_GUEST_HEAP;
        if (alias && a >= (vm_address_t)alias && a < (vm_address_t)alias + alias_size) return C_GUEST_ALIAS;
        if (stack && a >= (vm_address_t)stack && a < (vm_address_t)stack + stack_size) return C_GUEST_STACK;
        return C_GUEST_OTHER;
    }
    switch (in->user_tag) {
        case VM_MEMORY_MALLOC: case VM_MEMORY_MALLOC_SMALL: case VM_MEMORY_MALLOC_LARGE: case VM_MEMORY_MALLOC_HUGE:
        case VM_MEMORY_MALLOC_TINY: case VM_MEMORY_MALLOC_LARGE_REUSABLE: case VM_MEMORY_MALLOC_LARGE_REUSED:
        case VM_MEMORY_MALLOC_NANO: case VM_MEMORY_MALLOC_MEDIUM: return C_MALLOC;
        case VM_MEMORY_IOACCELERATOR: case VM_MEMORY_IOSURFACE: case VM_MEMORY_IOKIT: return C_GPU;
        case VM_MEMORY_STACK: return C_STACK;
    }
    if (in->external_pager) return C_FILE;
    return C_OTHER;
}

// DM_MEMSTAT_DUMP=seconds: at that second, write large VM regions and full per-class VM totals to <tsv>.regions.
static void dump_regions(const char *path) {
    FILE *f = fopen(path, "w"); if (!f) return;
    static pthread_mutex_t dump_lock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&dump_lock);
    setvbuf(f, NULL, _IOLBF, 0);
    fprintf(f, "start	size MiB	class	user_tag	share_mode	obj_id	ref_count	resident MiB	dirty MiB	swapped MiB	file\n");
    uint64_t totals[NC][3] = {{0}}, private_charge[NC] = {0}; uint64_t regions = 0, written = 0;
    static uint32_t seen[1 << 16]; static uint64_t keys[1 << 16]; static uint32_t generation;
    generation++; if (!generation) { memset(seen, 0, sizeof seen); generation = 1; }
    vm_address_t a = 0; vm_size_t sz; natural_t depth = 0; vm_size_t pg = vm_page_size;
    for (;;) {
        vm_region_submap_info_data_64_t in; mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &a, &sz, &depth, (vm_region_recurse_info_t)&in, &cnt) != KERN_SUCCESS) break;
        if (in.is_submap) { depth++; continue; }
        int c = classify(a, &in); regions++;
        totals[c][0] += (uint64_t)in.pages_resident * pg;
        totals[c][1] += (uint64_t)in.pages_dirtied * pg;
        totals[c][2] += (uint64_t)in.pages_swapped_out * pg;
        if (!in.external_pager) {
            uint64_t k = ((uint64_t)in.object_id << 32) ^ (in.offset >> 14);
            uint32_t h = (uint32_t)((k * 0x9E3779B97F4A7C15ull) >> 48); int duplicate = 0;
            while (seen[h] == generation) { if (keys[h] == k) { duplicate = 1; break; } h = (h + 1) & 0xFFFF; }
            if (!duplicate) {
                seen[h] = generation; keys[h] = k;
                private_charge[c] += ((uint64_t)in.pages_dirtied + in.pages_swapped_out) * pg;
            }
        }
        if (((uint64_t)in.pages_resident * pg >> 20) >= 1 || sz >= (64ull << 20)) {
            fprintf(f, "%#lx\t%lu\t%s\t%u\t%u\t%#x\t%u\t%llu\t%llu\t%llu\t%d\n", a, sz >> 20, k_cls[c], in.user_tag, in.share_mode,
                    in.object_id, in.ref_count, (uint64_t)in.pages_resident * pg >> 20, (uint64_t)in.pages_dirtied * pg >> 20, (uint64_t)in.pages_swapped_out * pg >> 20, in.external_pager);
            written++;
        }
        a += sz;
    }
    fprintf(f, "# all-region totals include every mapped region; shared mappings may be counted in more than one class. Detail rows include %llu of %llu regions.\n", (unsigned long long)written, (unsigned long long)regions);
    for (int c = 0; c < NC; c++)
        fprintf(f, "# all-region-bytes\t%s\tresident=%llu\tdirty=%llu\tswapped=%llu\n", k_cls[c],
                (unsigned long long)totals[c][0], (unsigned long long)totals[c][1], (unsigned long long)totals[c][2]);
    fprintf(f, "# unique-private-charge excludes external-pager pages and deduplicates matching object-id/offset regions.\n");
    for (int c = 0; c < NC; c++)
        fprintf(f, "# unique-private-charge-bytes\t%s\tbytes=%llu\n", k_cls[c], (unsigned long long)private_charge[c]);
    fclose(f);
    pthread_mutex_unlock(&dump_lock);
}

static void sample(FILE *f, double t, id<MTLDevice> dev) {
    task_vm_info_data_t vi; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    uint64_t fp = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &n) == KERN_SUCCESS ? vi.phys_footprint : 0;
    uint64_t avail = 0;
#if TARGET_OS_IPHONE
    avail = os_proc_available_memory();
#endif
    uint64_t virt[NC] = {0}, res[NC] = {0}, bill[NC] = {0};
    static uint32_t seen[1 << 16]; static uint32_t gen; gen++; if (!gen) { memset(seen, 0, sizeof seen); gen = 1; }   // Objects already counted in this sample (open addressing)
    vm_address_t a = 0; vm_size_t sz; natural_t depth = 0; vm_size_t pg = vm_page_size;
    for (;;) {
        vm_region_submap_info_data_64_t in; mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &a, &sz, &depth, (vm_region_recurse_info_t)&in, &cnt) != KERN_SUCCESS) break;
        if (in.is_submap) { depth++; continue; }
        int c = classify(a, &in);
        virt[c] += sz; res[c] += (uint64_t)in.pages_resident * pg;
        if (c >= C_GUEST_HEAP && c <= C_GUEST_OTHER) {
            virt[C_GUEST] += sz; res[C_GUEST] += (uint64_t)in.pages_resident * pg;
        }
        if (!in.external_pager) {                             // File pages are reclaimable and do not count toward footprint
            static uint64_t key[1 << 16];                     // Key = (object id, offset within the object): the pieces of one object split apart by mprotect cover different pages and must not be merged
            uint64_t k = (uint64_t)in.object_id << 32 ^ (in.offset >> 14);
            uint32_t h = (uint32_t)((k * 0x9E3779B97F4A7C15ull) >> 48), dup = 0;
            while (seen[h] == gen) { if (key[h] == k) { dup = 1; break; } h = (h + 1) & 0xFFFF; }
            if (!dup) {
                seen[h] = gen; key[h] = k;
                uint64_t charged = ((uint64_t)in.pages_dirtied + in.pages_swapped_out) * pg;
                bill[c] += charged;
                if (c >= C_GUEST_HEAP && c <= C_GUEST_OTHER) bill[C_GUEST] += charged;
            }
        }
        a += sz; continue;
    }
    uint64_t sum = 0; for (int c = 1; c < NC; c++) sum += bill[c]; // C_GUEST is a summary column for its four subranges.
    fprintf(f, "%.0f\t%llu\t%llu\t%llu\t%llu\t%llu\t%lld\t%lld", t, fp >> 20, avail >> 20, (unsigned long long)(dev.currentAllocatedSize >> 20),
            vi.internal >> 20, vi.compressed >> 20, (vi.ledger_tag_graphics_footprint + vi.ledger_tag_graphics_footprint_compressed) >> 20,
            (long long)(vi.limit_bytes_remaining >> 20));
    for (int c = 0; c < NC; c++) fprintf(f, "\t%llu/%llu/%llu", virt[c] >> 20, res[c] >> 20, bill[c] >> 20);
    fprintf(f, "\t%llu\t%lld\n", sum >> 20, ((int64_t)fp - (int64_t)sum) >> 20);
    fflush(f);
}

// DM_MEMSTAT_FAST_HZ=<1..60> writes lightweight kernel totals more often than
// the VM-region walk above. Large upload bursts can briefly cross a simulated
// limit between the one-second category samples; keep this path to task_info
// and Metal's allocation counter so the higher sampling rate stays cheap.
static void *memstat_fast_thread(void *p) {
    const char *path = p; char out[1100]; snprintf(out, sizeof out, "%s.fast.tsv", path);
    FILE *f = fopen(out, "w"); if (!f) { LOG("memstat: cannot open %s", out); return NULL; }
    fprintf(f, "monotonic_ns\tseconds\tphys_footprint\tmetal_alloc\tinternal\tgraphics\theadroom\n"); fflush(f);
    int hz = atoi(getenv("DM_MEMSTAT_FAST_HZ")); if (hz < 1) hz = 1; if (hz > 60) hz = 60;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); uint64_t t0 = now_ns();
    uint64_t step_ns = 1000000000ull / (unsigned)hz, next = now_ns(); unsigned batch = 0;
    for (;;) {
        task_vm_info_data_t vi; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &n) == KERN_SUCCESS)
            fprintf(f, "%llu\t%.3f\t%llu\t%llu\t%llu\t%llu\t%lld\n", (unsigned long long)now_ns(), (now_ns() - t0) / 1e9,
                    (unsigned long long)(vi.phys_footprint >> 20), (unsigned long long)(dev.currentAllocatedSize >> 20),
                    (unsigned long long)(vi.internal >> 20),
                    (unsigned long long)((vi.ledger_tag_graphics_footprint + vi.ledger_tag_graphics_footprint_compressed) >> 20),
                    (long long)(vi.limit_bytes_remaining >> 20));
        if (++batch >= (unsigned)MAX(hz / 4, 1)) { fflush(f); batch = 0; }
        next += step_ns; uint64_t now = now_ns();
        if (next <= now) next = now + step_ns;   // do not issue a burst of stale samples after an OS scheduling delay
        struct timespec delay = { .tv_sec = (time_t)((next - now) / 1000000000ull), .tv_nsec = (long)((next - now) % 1000000000ull) };
        nanosleep(&delay, NULL);
    }
    return NULL;
}

// DM_MEMSTAT_WATCH_MB=<MiB>: record every threshold crossing from the
// background task_info sampler, independent of presents. Do not terminate
// here: the per-frame renderer pressure handler must get its reclaim window
// and emit its detailed accounting before its own simulated-Jetsam decision.
static void *memstat_watch_thread(void *p) {
    long cap = atol(getenv("DM_MEMSTAT_WATCH_MB"));
    if (cap <= 0) return NULL;
    char path[1100]; snprintf(path, sizeof path, "%s.watch.tsv", (const char *)p);
    FILE *f = fopen(path, "w");
    if (f) { fprintf(f, "seconds\tphys_footprint\tlimit_mib\tover_limit\n"); fflush(f); }
    int hz = 60; uint64_t t0 = now_ns(), next = t0;
    int logged_crossing = 0;
    const char *dump_crossing = getenv("DM_MEMSTAT_DUMP_ON_CROSS");
    int dump_on_crossing = dump_crossing && *dump_crossing && strcmp(dump_crossing, "0");
    for (;;) {
        task_vm_info_data_t vi; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &n) == KERN_SUCCESS) {
            uint64_t mb = (vi.phys_footprint + ((1ull << 20) - 1)) >> 20; // Round up so the report cannot hide a fractional MiB over the ceiling.
            int over = vi.phys_footprint >= ((uint64_t)cap << 20);
            if (f) { fprintf(f, "%.3f\t%llu\t%ld\t%d\n", (now_ns() - t0) / 1e9, (unsigned long long)mb, cap, over); fflush(f); }
            if (over && !logged_crossing) {
                LOG("[RED] memory watchdog: phys_footprint %llu MiB reached or exceeded %ld MiB simulation limit; renderer pressure handler still active", (unsigned long long)mb, cap);
                logged_crossing = 1;
                if (dump_on_crossing) {
                    char regions[1200]; snprintf(regions, sizeof regions, "%s.crossing.regions", (const char *)p);
                    atomic_store(&g_crossing_dump_active, 1);
                    dump_regions(regions);
                    atomic_store(&g_crossing_dump_active, 0);
                    LOG("[memstat] crossing VM-region snapshot written to %s", regions);
                }
            }
        }
        next += 1000000000ull / hz;
        uint64_t now = now_ns(); if (next <= now) next = now + 1000000000ull / hz;
        struct timespec delay = { .tv_sec = (time_t)((next - now) / 1000000000ull), .tv_nsec = (long)((next - now) % 1000000000ull) };
        nanosleep(&delay, NULL);
    }
    return NULL;
}

static void *memstat_thread(void *p) {
    FILE *f = fopen((const char *)p, "w");
    if (!f) { LOG("memstat: cannot open %s", (const char *)p); return NULL; }
    fprintf(f, "# unit MiB; kernel accounting internal / compressed / graphics ledger / headroom to the limit; class columns = virtual/resident/charged (deduplicated per object); charged total = Σ private charged; unattributed = phys_footprint − charged total\nseconds\tphys_footprint\tavailable\tmetal_alloc\tinternal\tcompressed\tgraphics\theadroom");
    for (int c = 0; c < NC; c++) fprintf(f, "\t%s", k_cls[c]);
    fprintf(f, "\tcharged total\tunattributed\n");
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();   // The same device object as the graphics backend (the system default device singleton)
    const char *fast_hz = getenv("DM_MEMSTAT_FAST_HZ");
    if (fast_hz && *fast_hz && atoi(fast_hz) > 0) { pthread_t ft; if (!pthread_create(&ft, NULL, memstat_fast_thread, strdup((const char *)p))) pthread_detach(ft); }
    const char *watch_mb = getenv("DM_MEMSTAT_WATCH_MB");
    if (watch_mb && *watch_mb && atoi(watch_mb) > 0) { pthread_t wt; if (!pthread_create(&wt, NULL, memstat_watch_thread, strdup((const char *)p))) pthread_detach(wt); }
    uint64_t t0 = now_ns();
    const char *ds = getenv("DM_MEMSTAT_DUMP"); int dump_at = ds ? atoi(ds) : -1;
    char dp[1100]; snprintf(dp, sizeof dp, "%s.regions", (const char *)p);
    for (int sec = 0;; sec++) { sample(f, (now_ns() - t0) / 1e9, dev); if (sec == dump_at) dump_regions(dp); sleep(1); }
    return NULL;
}

__attribute__((constructor)) static void memstat_start(void) {
    const char *p = getenv("DM_MEMSTAT");
    if (!p || !*p) return;
    char *path = strdup(p);
#if TARGET_OS_IPHONE
    if (*p != '/') { size_t n = strlen(getenv("HOME")) + strlen(p) + 16; path = malloc(n); snprintf(path, n, "%s/Documents/%s", getenv("HOME"), p); }   // Relative name → the container's Documents (the container path is not known before launch)
#endif
    pthread_t th; pthread_create(&th, NULL, memstat_thread, path); pthread_detach(th);
}

// ---------- Per-thread CPU: DM_THRCPU=<tsv path>[,interval in seconds (default 10)] (common to Mac / iOS; on iOS a relative name → the container's Documents) ----------
// Every interval, walk all threads of this process (task_threads), take the thread name and user + system CPU time (ns) from THREAD_EXTENDED_INFO, and difference them by thread id:
// each line is "seconds, thread id, thread name, CPU% (100 = one core)"; the last line is "seconds, -, total, CPU%". Used for heat attribution (which thread eats CPU); enable together with DM_HEAT to compare against thermal state.
#include <mach/thread_info.h>
#define THR_MAX 512
static void *thrcpu_thread(void *p) {
    char path[1024]; int iv = 10; { const char *c = strchr((const char *)p, ','); snprintf(path, sizeof path, "%.*s", c ? (int)(c - (const char *)p) : (int)strlen(p), (const char *)p); if (c) iv = atoi(c + 1); }
    FILE *f = fopen(path, "w"); if (!f) return NULL;
    fprintf(f, "seconds\tthread ID\tthread name\tCPU%%\n"); fflush(f);
    static uint64_t ids[THR_MAX], last[THR_MAX]; int n = 0; uint64_t t0 = now_ns(), tl = t0;
    for (;;) {
        sleep(iv); uint64_t t = now_ns(); double dt = (t - tl) / 1e9, tot = 0; tl = t;
        thread_act_array_t th; mach_msg_type_number_t nt = 0;
        if (task_threads(mach_task_self(), &th, &nt) != KERN_SUCCESS) continue;
        for (mach_msg_type_number_t i = 0; i < nt; i++) {
            thread_extended_info_data_t ei; mach_msg_type_number_t c1 = THREAD_EXTENDED_INFO_COUNT;
            thread_identifier_info_data_t ii; mach_msg_type_number_t c2 = THREAD_IDENTIFIER_INFO_COUNT;
            if (thread_info(th[i], THREAD_EXTENDED_INFO, (thread_info_t)&ei, &c1) == KERN_SUCCESS && thread_info(th[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ii, &c2) == KERN_SUCCESS) {
                uint64_t cpu = ei.pth_user_time + ei.pth_system_time; int k = 0; while (k < n && ids[k] != ii.thread_id) k++;
                if (k == n && n < THR_MAX) { ids[n] = ii.thread_id; last[n] = cpu; n++; }   // New thread: only record the baseline this round
                else if (k < n) { double pct = (cpu - last[k]) / 1e9 / dt * 100; last[k] = cpu; tot += pct;
                    if (pct >= 0.5) { char gn[96]; int thr_name_of(pthread_t, char *, size_t); pthread_t pt = pthread_from_mach_thread_np(th[i]);
                        const char *nm = pt && thr_name_of(pt, gn, sizeof gn) ? gn : ei.pth_name[0] ? ei.pth_name : "-";   // Guest thread: handle + guest name; host thread: pthread name
                        fprintf(f, "%.0f\t%llu\t%s\t%.1f\n", (t - t0) / 1e9, ii.thread_id, nm, pct); } }
            }
            mach_port_deallocate(mach_task_self(), th[i]);
        }
        vm_deallocate(mach_task_self(), (vm_address_t)th, nt * sizeof *th);
        fprintf(f, "%.0f\t-\ttotal\t%.1f\n", (t - t0) / 1e9, tot); fflush(f);
    }
    return NULL;
}
__attribute__((constructor)) static void thrcpu_start(void) {
    const char *p = getenv("DM_THRCPU");
    if (!p || !*p) return;
    char *spec = strdup(p);
#if TARGET_OS_IPHONE
    if (*p != '/') { size_t n = strlen(getenv("HOME")) + strlen(p) + 16; spec = malloc(n); snprintf(spec, n, "%s/Documents/%s", getenv("HOME"), p); }
#endif
    pthread_t th; pthread_create(&th, NULL, thrcpu_thread, spec); pthread_detach(th);
}
