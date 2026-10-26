// What the tests that link hle_nvn.c and hle_bigstack.c without the host need of it: weak definitions, so a test that defines its own keeps it
#include <stdint.h>
__attribute__((weak)) uint64_t g_t0_ns;   // process start time (host main.c), read by hle_nvn's per-frame timing
__attribute__((weak)) int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }   // no guest address space (hle_bigstack.c)
// The isolated graphics tests do not run memstat or create guest alias mappings.
__attribute__((weak)) void dm_memstat_wait_for_crossing_dump(void) {}
__attribute__((weak)) void svc_alias_map_stats(uint64_t *mapped, uint64_t *peak, uint64_t *map_calls, uint64_t *unmap_calls, uint64_t *map_bytes, uint64_t *unmap_bytes) {
    if (mapped) *mapped = 0; if (peak) *peak = 0; if (map_calls) *map_calls = 0;
    if (unmap_calls) *unmap_calls = 0; if (map_bytes) *map_bytes = 0; if (unmap_bytes) *unmap_bytes = 0;
}
