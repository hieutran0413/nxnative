# GPUs without BC textures (A16 and older)

Switch games store most textures BC-compressed. Apple GPUs read BC only from the A17 Pro (iPhone 15 Pro) and the M1; on an A16 (iPhone 14 Pro / 14 Pro Max) and older, Metal rejects the format and the game stops at its first BC texture (`MTLTextureDescriptor has invalid pixelFormat (140)`, BC4 = 0x49; GitHub issue #4). This page records what the fix does and how to build a game with it.

## What the fix does

The decision is made at run time, so one IPA serves every device:

- `no_bc()` in `dm/gfx/nvn/nvn_mtl.m` asks `[g_dev supportsBCTextureCompression]` once. `DM_TEST_NO_BC=1` forces the same path on a Mac. On a GPU with BC nothing changes (no extra memory, no log line).
- **Runtime BC1 / BC3 → ASTC 4×4 transcoding (`dm/gfx/tex/nvn_bcastc.*`)**:
  - 2D / 2D-array / cube BC1 (`RGB_DXT1`, `RGBA_DXT1` + sRGB) and BC3 (`RGBA_DXT5` + sRGB) textures are transcoded at upload time into `MTLPixelFormatASTC_4x4_LDR` / `MTLPixelFormatASTC_4x4_sRGB` (1 byte/pixel — 4× smaller than `RGBA8`, matching BC3's exact byte size).
  - GPU upload batches run the `bc1a` / `bc3a` compute kernels (`dm/gfx/tex/nvn_bcastc_msl.h`) right after GPU deswizzling and before the texture blit; CPU paths (`copy_b2t` fallback, sparse sub-tile uploads) use `nvn_bc_astc_encode` (`dm/gfx/tex/nvn_bcastc.c`).
  - Set `DM_NO_BC_ASTC=0` to disable ASTC transcoding completely, or `DM_NO_BC3_ASTC=0` to transcode only BC1 and decode BC3 to `RGBA8`.
- **Remaining BC formats (`dm/gfx/tex/nvn_bcdec.c` & `bcd` compute kernel)**:
  - BC2, BC7 and 3D BC1/BC3 become `RGBA8` (or `RGBA8_sRGB`), BC4 becomes `R8` (1 byte/pixel), BC5 becomes `RG8` (2 bytes/pixel), and BC6H becomes `RGBA16F`.
  - `tex_desc` preserves Apple GPU hardware lossless compression on `no_bc()` textures by omitting `MTLTextureUsagePixelFormatView` unless an unpacked sRGB BC texture requires an `RGBA8Unorm` compute-write view for `bcd`, and omitting `MTLTextureUsageShaderWrite` on ASTC-transcoded and CPU-decoded textures.
  - Both CPU (`nvn_bcdec.c`) and GPU (`k_bcd_msl`, `fmt == 8`) distinguish `NVN_FORMAT_RGB_DXT1` (`0x41` / `0x45`, opaque black `(0,0,0,1)` on selector 3 when `c0 <= c1`) from `NVN_FORMAT_RGBA_DXT1` (`0x42` / `0x46`, transparent `(0,0,0,0)`).
- **Buffer → texture (`copy_b2t`) and texture → texture (`copy_t2t`) copies**:
  - `copy_b2t` into an ASTC-transcoded BC1/BC3 texture dispatches `bc1a` / `bc3a` on the GPU into the frame arena and blits the ASTC blocks; `copy_b2t` into an unpacked 2D BC1–BC5 texture at `(0,0)` dispatches `bcd` directly from the source buffer without allocating a temporary `Shared` buffer.
  - `copy_t2t` between `ASTC_4x4_LDR` and `ASTC_4x4_sRGB` uses a format view + blit, and `copy_t2t` from `ASTC_4x4` into an `RGBA8` destination upgrades the destination with `MTLTextureUsageShaderWrite` if needed before running `copy_t2t_astc`.
- **Placement-sparse BC textures (`sparse_make`, `sparse_sync`)**:
  - On `no_bc()`, placement-sparse 2D/array BC textures are backed by sparse `ASTC_4x4` or unpacked Metal textures using `sub_x × sub_y` Metal sparse tiles per 64 KB NVN tile when the expanded format exceeds 64 KB per NVN tile, and transcode/decode each mapped tile on upload.
- **iOS Memory Pressure Watcher & LRU Eviction (`mtl_memory_pressure`, `mtl_trim_memory`)**:
  - `front_ios.m` monitors `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` (`WARN` / `CRITICAL`), `UIApplicationDidReceiveMemoryWarningNotification`, and `os_proc_available_memory()` every 32 submissions in `mtl_sub_begin` (plus app suspend in `dm_gfx_suspend`).
  - Under memory pressure, `mtl_trim_memory` reclaims completed `NvPkg->spare` textures, shrinks oversized upload staging buffers (`g_up_slot_blk`, `g_up_slot_over`), drops unreferenced `g_alias` textures, and evicts cold `no_bc()` `NvPkg` textures backed by live guest memory (`pk->evicted = 1`), re-hydrating them automatically in `tex_mtl_` only when a shader or draw actually samples them again.

## Checking it

On the Mac:
- Run `make -C dm/gfx/tex/tests` and `make -C dm/gfx/tests GAME=<id> t_nobc_mem && DM_TEST_NO_BC=1 MTL_DEBUG_LAYER=1 ./dm/gfx/tests/t_nobc_mem`.
- Or build `make -C dm/host GAME=<id>` and run the game with `DM_TEST_NO_BC=1`; the log shows `GPU has no BC texture formats (test switch DM_TEST_NO_BC): BC1/BC3 2D textures are transcoded to ASTC 4x4; remaining BC formats are stored decompressed`.

## Building a game with the fix (for example Tears of the Kingdom)

Nothing is needed in the game's profile; the fix is in the host that every build compiles.

```
python3 scripts/build_ipa_from_nsp.py "<NSP folder>" -k "<prod.keys>" -o "<new IPA path>"
```

- Give a new `-o` so the previous IPA is not overwritten until the new one is checked.
- The IPA is unsigned: sign and install it with the sideloading tool. Without a paid account's Increased Memory Limit, expect about 3.4 GB.
- The extracted game files under `<NSP folder>/<id>_build/extract/<version>` are reused, including any translation already written into them. A mod folder is applied with `--mods <folder with romfs/>` only when its files are not in the extraction yet.
- The script still needs the base game (an NSP or an XCI) in the NSP folder next to the update, even when `extract/` is complete: it stops with `no base game NSP found` otherwise.
- Never put `prod.keys`, `title.keys` or any game file in this repository.
