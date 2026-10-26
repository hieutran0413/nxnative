---
doc_type: research-register
project: "NX Native"
status: active
last_updated: 2026-10-26
---

# Research Register

Evidence labels:

- Observed
- Primary source
- Secondary source
- Inference
- Evidence gap

| ID | Question | Evidence | Finding | Confidence | Product implication |
| --- | --- | --- | --- | --- | --- |
| R-001 | What does the product do and which platform owns game execution? | Primary source: repository README and `docs/development.md` | Native Apple runtime executes game code and implements Switch-facing services; shader/graphics work bridges NVN to Metal. | High for documented architecture | Preserve game-data ownership boundaries and prefer general Horizon/NVN/Metal behavior. |
| R-002 | Does current evidence support TOTK A16-class 60 fps and a 3072 MiB limit? | Observed local benchmark logs/screenshots summarized in [feature packet](../engineering/totk-a16-60fps.md) | No. Current attempts have not confirmed gameplay; a prior load exceeded 3072 MiB; no-BC logs show a dropped BC4 draw. | High for current recorded attempts; limited to tested Mac runs | Treat A16-class support as experimental; require same-route BC/no-BC gameplay and separate physical-device logs. |
| R-003 | Is the new BC4 decode kernel equivalent to the established decoder? | Observed: `make -C dm/gfx/tests GAME=0100F2C0115B6000 t_bcastc && ./dm/gfx/tests/t_bcastc` | Exact byte parity on odd-sized 3D fixture 19×17×3 on this Mac Metal device. The test does not exercise host target lifetime/synchronization. | High for fixture and device; narrow scope | Allows host integration work to proceed; not an end-to-end render-target claim. |

Raw recordings, frame dumps, and temporary screenshots stay in `workbench/evidence/`.

