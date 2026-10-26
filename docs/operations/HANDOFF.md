---
doc_type: handoff
project: "NX Native"
status: active
last_updated: 2026-10-26
---

# Session Handoff

## Read first

1. `AGENTS.md`
2. `docs/README.md`
3. active feature packet
4. linked product/design/engineering context

## Current state

Status: TOTK 60 fps / 3072 MiB work remains in progress at P0 correctness/memory qualification. The narrow no-BC BC4 render-target backing is implemented and host-builds, but fresh no-BC gameplay still has severe magenta corruption and diagnostic memory/performance failure. Init Product Project is integrated by reusing existing status, feature-packet and handoff ownership; no parallel scaffold was created.

Last verified result: host build `GAME=0100F2C0115B6000 make -C dm/host` succeeds (44 compiler warnings). Matched serial-filtered gameplay captures `01_Great_Sky_Island_20261026T065417_cf4d9f59` (no-BC) and `01_Great_Sky_Island_20261026T065850_055cb893` (BC) used the same save, 0.5 scale, 60 fps target, and 6144 MiB diagnostic watchdog. Frame 136/pass 973 uses shader `1e79317965315de3_b` to write cube `ser=2916`; face-0 snapshots show 726/4096 magenta-threshold pixels no-BC and 0/4096 BC. The shader, target, slot 12 and sampler match; slot 17 was reported as BC1 sRGB/Metal 131 versus ASTC sRGB/Metal 186 in that gameplay pair. This localizes an observed image divergence to that draw while slot 17 changes representation, but does not establish the sole cause. Both runs exceed 3072 MiB (3980/3566 MiB). Their p95 frame times are 35.15/35.80 ms under PASSDUMP/TEXDUMP instrumentation, so not a performance comparison. An ASTC-disabled no-BC probe `01_Great_Sky_Island_20261026T070959_6c1f151b` reached the Vietnamese title menu with the green/magenta color issue while ASTC stand-ins were 0 MiB; it stopped before gameplay and peaked at 2440 MiB under a 4096 MiB diagnostic watchdog. Follow-up frame-300 snapshots in `01_Great_Sky_Island_20261026T071326_3146b9c6` show main target `ser=2642` black after clear, then already carrying the corrupted background before the final blit; the presented drawable matches it. The final shader `dd3d1e0ebf732428_b` samples that target and writes RGBA unchanged. The trace also finds the 800×448 RG11B10Float scene target sampled by the background composite; its first bad writer/input remains to be captured. The strict-watchdog snapshot run peaked at 2566 MiB but did not enter gameplay. Capture implementation preserves cube slices and the serial-filtered dump avoids unrelated end-of-frame texture views.

Current work item: [TOTK A16 60 fps feature packet](../engineering/totk-a16-60fps.md).

## Next gate

Outcome: P0 remains failed. The final presentation blit and ASTC conversion are not required for the general title corruption: with ASTC disabled, the main 1920×1080 render target is already corrupted before the final blit. Next capture the 800×448 RG11B10Float scene target after each writer and identify its first bad input, then compare with BC mode. Preserve pass 973 as a separate gameplay divergence: slot 17's representation changes there, but byte-exact BC1 checks and close center-sample BC/ASTC sRGB comparisons weaken it as a sole cause. The same-run capture shows slot 12 and sampler match. Qualify the separate texture-dimension `[RED]` binding and BC4 shadow/decode, then attribute alias ownership/lifetimes before reclamation. Repeat the save/route under strict limits. Do not begin seven-save or 30-minute acceptance until P0 and then P1 pass.

Checks: Targeted BC4/BC texture fixtures and host build; same-save gameplay with BC and `DM_TEST_NO_BC=1`; verify save/region transitions, frame-time percentiles and memory categories under 3072 MiB. Keep synthetic fixture success separate from runtime acceptance.

Blockers: No-BC gameplay remains visibly magenta and BC-native is clean; ASTC-disabled no-BC also shows corruption at the title menu, before any save load. The main presentation target is already corrupted before the final blit, and the 800×448 scene target's first bad writer remains unknown. For the matched first face-0 gameplay draw, slot 17's representation differs while slot 12 and sampler match; the independent sRGB sample comparator covers texel centers, not the game's trilinear/filter path. The 72 snapshots are in the external work folder `benchmark/cube-snap-serial-20261026/`, paired as `no_bc_fixed_0_sNNN_2916_m.png` and `bc_fixed_0_sNNN_2916_m.png`; use the same NNN/mip to compare subsequent writes. Both instrumented gameplay runs fail memory and timing gates. The separate RG11B10Float 3D-to-2D `[RED]` bind remains unqualified. Safe alias ownership/lifetime is unresolved; former 7/7 claim remains withdrawn. Physical A16 thermals/battery/frame-pacing still require user sideload and device logs.

## Preserve

Uncommitted work: Preserve all existing dirty work. Review `git status` before edits and do not revert unrelated in-progress files.

External state: Game NSP/build/run data stays in its external NSP work folder. Do not sign/install IPA or move extracted game data into this repository/home directory.

## Latest diagnostic evidence — 2026-10-26

The earlier size-selected BC1 upload diagnostic `01_Great_Sky_Island_20261026T062011_45743d18` reached gameplay with magenta; its apparent four-mip limit came from the verifier's filter and result cap. The corrected run `01_Great_Sky_Island_20261026T062946_6f1f7fff` verified all 11 mips and tied the source to slot 17. Follow-up `01_Great_Sky_Island_20261026T063532_0b4e0550` captured that slot's source and ASTC output for every mip, then compared actual Metal sRGB samples: maximum 1.37/255 error, zero alpha mismatches, levels 4–10 exact. Gameplay remains corrupted; this reduces confidence in that source as the root cause, not proof of full image parity. It peaked at 3953 MiB and frame p95 34.24 ms. See feature packet for measurements and instrumentation caveats.

Scale 0.35 no-BC diagnostic `01_Great_Sky_Island_20261026T060201_14935b83` reached token-reviewed gameplay and completed a 5 s route, but remained visibly magenta. At 60 fps target with `DM_FPS_HOLD=off`, peak footprint was 4210 MiB, frame p50/p95/p99 16.52/20.18/23.70 ms, GPU 10.93/16.70/20.50 ms, and region load 146.17 s. This diagnostic used the 6144 MiB watchdog override; it fails image, RAM and p95 gates. Render scale range is now 0.35–1.0 and the host was rebuilt; 0.5 remains the comparison baseline. See feature packet for categories and detailed limits.

Follow-up scale 0.30 route `01_Great_Sky_Island_20261026T060821_e91718fe` also reached reviewed gameplay but stayed magenta and peaked at 3950 MiB. Frame p50/p95/p99 was 16.61/20.98/24.58 ms and GPU p95 16.52 ms; compared with 0.35, render-target traffic decreased about 13% in a representative slow frame, but frame p95 worsened 0.80 ms and GPU p95 improved just 0.18 ms. Keep the lower setting floor at 0.35; prioritize CPU replay and image correctness. A non-TTY run ended at the title gate and is discarded.

Strict-limit same-save attempts now reproduce the load-time memory stop without diagnostic watchdog overrides. `01_Great_Sky_Island_20261026T054501_9fe41229` (no-BC) and `01_Great_Sky_Island_20261026T054606_0eaecf6b` (BC-capable) both ran at 0.5 scale / 60 fps target / 3072 MiB, reached the save-reload confirmation, and were killed before gameplay at 3089 / 3087 MiB (frames 3275 / 3810). Gameplay, route timing and region-load boundary are therefore unavailable. No-BC frame p50/p95/p99 was 16.64/19.76/22.21 ms; BC-capable 16.64/19.86/23.26 ms. At kill the no-BC guest/Metal/alias ledgers were 1427/1834/495 MiB; BC-capable 2076/1757/854 MiB. These pre-gameplay attempts are not an apples-to-apples performance comparison. Both contain the 8×8×8 RG11B10Float versus 2D shader type `[RED]`; neither log contains `MSF` or an explicit lost-draw marker. Investigate guest/alias ownership and the draw mismatch before pursuing speed changes. Run details are in the engineering packet.

Run `01_Great_Sky_Island_20261026T051106_5e7c0fd7` confirmed gameplay but still shows severe magenta; peak footprint is 3944 MiB and frame p95 35.65 ms. A bounded no-BC passdump first observes cube `ser=2917` as an attachment at frame 137 / pass 1295 with fragment shader `1e79317965315de3_b`; later gameplay use includes `1fbafa5693b5d675_b`. This is only the first observation in frames 0–300, not a process-lifetime first-writer proof or cause. Run details and next comparison are in the engineering packet. Compare the same attachment/input/output against BC-native and no-BC to locate first divergence; passdump timing is invalid for performance claims.

Matched follow-up: BC-native `01_Great_Sky_Island_20261026T051626_672f111e` and no-BC `01_Great_Sky_Island_20261026T052322_9635c7bb` screenshots both show live gameplay at the same viewpoint; BC is clean, no-BC is magenta. The same first observed shader `1e79317965315de3_b` writes cube face 0 in both runs; slot 17 is BC1 sRGB (`ser=3935`, MTL 131) vs ASTC sRGB (`ser=3938`, MTL 186), with slot 12 shared. Readback threshold counts are 0/4096 vs 124/4096 magenta-like pixels in the cube target. This locates divergence to the target pass but does not prove slot 17 is causal. Targeted `DM_BC1A_VERIFY_SERIAL=3938` emitted no verifier result even with a fresh external cache root; inspect/log the actual object upload route and compare decoded source values before altering the encoder. Benchmark telemetry now follows the optional `DM_TEXTURE_CACHE` root.

Do not reset, overwrite, deploy, or perform destructive operations without scope and authority.



### Descriptor-correlated trace — 2026-10-26

Run `01_Great_Sky_Island_20261026T053917_f1d3c8c3` confirms live gameplay and magenta in token-reviewed gate 5. In frame 136 / pass 973, shader `1e79317965315de3_b` writes 64×64 RG11B10Float cube target `ser=2916`; slot 17 is BC1 RGBA sRGB `ser=3938` (1024², 11 mips), represented as ASTC sRGB. GPU deswizzle/transcode match CPU bytes for mips 0–3. An external native-Metal sample comparator tested those captured levels as BC1 sRGB and ASTC sRGB: max channel error by mip was 1.37/255, 0.75/255, 0.68/255 and 0/255; mean at most 0.000042, zero samples over 3/255 and zero alpha mismatches. Mips 4–10, inter-texel/mip filtering, shader sample behavior, slot 12 and the target/render path remain unproven. The comparison narrows but does not resolve the magenta cause.

This verifier/passdump/TEXINFO diagnostic used a 6144 MiB watchdog override and is not acceptance or performance evidence. Peak footprint was 3972 MiB, frame p50/p95/p99 18.28/35.46/39.84 ms, GPU 11.88/18.68/19.84 ms, guest peak 2492 MiB (heap 1424, alias 1054, stack 13), Metal allocation 2371 MiB, upload staging 32/44 MiB and region load 126.29 s. It reproduced the separate `[RED]` texture-type mismatch for an 8×8×8 RG11B10Float object bound to a 2D shader declaration; no `MSF` was found. Runner empty-verifier-variable handling is fixed. Next correlate slot 12 and the first differing target output against BC-native, inspect the dimension mismatch, then capture clean matched gameplay runs. Seven-save, 30-minute and physical A16 checks remain outstanding. Details are appended to the TOTK feature packet.
