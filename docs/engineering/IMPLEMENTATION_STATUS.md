---
doc_type: verified-status
project: NX Native
status: active
last_updated: 2026-10-25
update_rule: verified evidence only
---

# Feature Status

Start here to see what each feature does today and what happens next. A blank or unknown item is not complete.

## At a glance

| Feature | Current status | What works now | What remains | Next action | Evidence / detail | Checked |
| --- | --- | --- | --- | --- | --- | --- |
| TOTK 3GB RAM Ceiling (Apple A16 Bionic) | accepted | 7/7 maps PASS (Peak RSS 1974-2140 MB, Headroom 930-1098 MB, 0% magenta error) | Long-duration stress test (>1h play) | Prepare unsigned iOS IPA package for device testing | [totk_a16_3gb_optimization_ledger.md](../../../Users/hieutran/.gemini/antigravity/brain/8ebf2e72-1cbf-4df8-a450-c96c881f0fb4/totk_a16_3gb_optimization_ledger.md) | 2026-10-25 |
| XNU Physical Footprint Reclaim (`mmap MAP_FIXED`) | accepted | Instant memory return to XNU kernel on Unmap & SetHeapSize | None (verified with Darwin vm_stat / phys_footprint) | Standardized in `dm/host/hle_svc.c` | [hle_svc.c](../../dm/host/hle_svc.c#L168-L285) | 2026-10-25 |
| Mipmap Clamping 2K/1K (`DM_CLAMP_2K`) | accepted | Textures >= 2048 clamped to level 1+, saves ~1.0 GB VRAM | Evaluate adaptive 1K clamping if memory < 200 MB | Keep enabled for A16/tight profiles | [nvn_mtl.m](../../dm/gfx/nvn/nvn_mtl.m#L1528-L1536) | 2026-10-25 |
| Eviction Thrashing Prevention & Tuned Thresholds | accepted | 280 MB critical trigger + 500 MB spare pruning + pool residency unpinning | None | Integrated in `mtl_check_memory_pressure` | [nvn_mtl.m](../../dm/gfx/nvn/nvn_mtl.m#L2500-L2515) | 2026-10-25 |
| Non-BC GPU Emulation (`DM_TEST_NO_BC=1`) | accepted | ASTC stand-ins + BC decompression pipeline | None | Integrated in shader pipeline | [no-bc-gpus.md](../no-bc-gpus.md) | 2026-10-25 |

## Overall

| Area | Current state | Evidence or open decision |
| --- | --- | --- |
| Architecture | verified | Native Darwin/XNU execution model with ARM64 JIT/rewriter |
| Graphics | verified | Metal 4 modern submission pipeline, residency sets, ASTC stand-ins |
| Memory Management | verified | Strict 3072 MB ceiling enforcement with MAP_FIXED instant reclamation |
| Stability | verified | Zero Jetsam kills, zero magenta texture corruption across all 7 test maps |

## Prototype and technical debt

| Area | Current fact | Why not accepted | Owning feature or gate |
| --- | --- | --- | --- |
| None recorded | Clean passing state across 7/7 maps | N/A | Memory headroom >= 600 MB maintained |
