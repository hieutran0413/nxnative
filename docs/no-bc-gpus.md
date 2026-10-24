# GPUs without BC textures (A16 and older)

Switch games store most textures BC-compressed. Apple GPUs read BC only from the A17 Pro (iPhone 15 Pro) and the M1; on an A16 (iPhone 14 Pro / 14 Pro Max) and older, Metal rejects the format and the game stops at its first BC texture (`MTLTextureDescriptor has invalid pixelFormat (140)`, BC4 = 0x49; GitHub issue #4). This page records what the fix does and how to build a game with it.

## What the fix does

The decision is made at run time, so one IPA serves every device:

- `no_bc()` in `dm/gfx/nvn/nvn_mtl.m` asks `[g_dev supportsBCTextureCompression]` once. `DM_TEST_NO_BC=1` forces the same path on a Mac. On a GPU with BC nothing changes (no extra memory, no log line).
- Without BC, a BC texture is created in a decompressed format (`nvn_bc_unpacked` in `dm/gfx/tex/nvn_bcdec.c`): BC1–3 and BC7 become RGBA8 (sRGB variants likewise), BC4 R8, BC5 RG8, BC6H RGBA16F. `tex_desc` picks the format; BC4 / BC5 keep their signedness.
- Upload (`dm/gfx/nvn/nvn_mtl.m`, the texture upload function): BC1–5 are deswizzled on the GPU and decompressed by the `bcd` kernel (`bcd_pso`); BC6H, BC7 and 3D textures are decompressed on the CPU with `dm/third_party/bcdec` after the CPU deswizzle.
- Buffer → texture copies (`copy_b2t`) decompress the source blocks on the CPU into a temporary buffer; texture → texture copies from ASTC sources use `copy_t2t_astc`.
- Views of BC textures switch to the decompressed format, and a BC texture stored decompressed is never attached as a render target (`attach`, `rt_view_fmt`), as on GPUs with BC.

The code is the no-BC path removed in commit `14fbcf9` (it removed it because decompressed textures did not fit a 6 GB iPhone for Breath of the Wild), restored in `99ab322` and kept behind the device check.

## The cost

Decompressed textures take 2–8 times the memory. Breath of the Wild needed about 3.9 GB instead of 2.8 GB. Tears of the Kingdom (5 GB guest layout) is heavier still, and without the Increased Memory Limit entitlement an app gets about 3.4 GB (README). Expect the bigger games to be closed by iOS on an A16 unless it is signed with that entitlement. If a game does not fit, the next step is to re-encode BC as ASTC at load time (about the size of BC; costs CPU time and some quality); it is not implemented.

## Checking it

On the Mac: `make -C dm/host GAME=<id>`, then run the game with `DM_TEST_NO_BC=1`; the log must show `GPU has no BC texture formats (test switch DM_TEST_NO_BC)` and `no BC: BC1–5 are decompressed on the GPU`, and no `invalid pixelFormat`. On an iPhone, the same first line appears in `log.txt` (Files app) on an A16 and must not appear on an A17 Pro.

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
