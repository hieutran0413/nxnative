---
doc_type: implementation-plan
project: "NX Native"
status: draft
last_updated: 2026-10-26
---

# Implementation Plan

## Execution priorities

| Priority | User or system proof | Admitted tasks | Exit condition |
| --- | --- | --- | --- |
| P0 | Reduce or safely reclaim at least 0.6–1.0 GiB during TOTK save loading while avoiding `MSF` | T3 | Same-save load stays below 3072 MiB and allocation/charge ownership is attributed. Current state: failed; latest 3072 MiB pressure-target probe reached 4109 MiB before gameplay, with a 4096 MiB diagnostic watchdog. Rendering work is deferred until this gap is materially smaller. |
| P1 | Validate representative gameplay and restore rendering acceptance | T1, then T2 | Reviewed gameplay, save/region path, no missing draws or `MSF`, peak below 3072 MiB. Current render defects remain known but are not the active workstream. |
| P2 | Meet the 60 fps target on the same representative route and verify device/save coverage | gated by P0/P1 | Frame p50/p95/p99 and CPU/GPU breakdown against 16.67 ms; seven named saves; 30-minute worst-area stress; user A16 thermal/battery logs. |

## Tasks

| Task | Outcome | Dependencies | Risk | Acceptance | Status |
| --- | --- | --- | --- | --- | --- |
| T1 | Preserve raw BC4 target blocks on no-BC GPUs and decode the result after draws | deferred until P0 RAM feasibility | high | upload/copy/clear/draw synchronization works and image parity is checked against BC path; current host/fixture evidence is partial and magenta remains | gated |
| T2 | Reach a repeatable save-load and gameplay route | T1 render correctness; strict 3072 MiB gate also fails before gameplay | high | reviewed matched gameplay capture and measured load boundary for BC and no-BC below the strict cap | gated |
| T3 | Attribute and reduce the save-load physical-memory burst | current confirmed 3072 MiB pressure simulation and failed 4109 MiB diagnostic | high | ownership/lifetime ledger for guest heap, alias, Metal, staging/cache and unattributed charges; demonstrate a safe reduction toward <=3072 MiB without `MSF` | active |
| T4 | Run seven-save matrix, worst-area stress and device follow-up | T1-T3 | high | all simulation gates pass; A16 thermals/battery are explicitly user-device evidence | gated |

Rules:

- Deliver vertical user outcomes, not disconnected layers.
- Keep only prerequisite-satisfied tasks active; mark the rest gated with the exact prerequisite.
- Define measurable exit conditions before implementation starts.
- Treat scaffolding and premature code as prototype evidence, not verified task progress.
- Keep refactor, feature behavior, and tests reviewable.
- Do not count placeholders or legacy code as completion.
- Name required build, test, accessibility, security, and release checks.

The current feature packet in [totk-a16-60fps.md](totk-a16-60fps.md) owns detailed acceptance and evidence. This plan summarizes admission and dependencies; it does not replace those gates.
