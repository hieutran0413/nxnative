---
doc_type: architecture
project: "NX Native"
project_type: "desktop-app"
status: in-progress
owner: NX Native runtime maintainers (individual owner not recorded)
last_updated: 2026-10-26
---

# Architecture

## Constraints

Supported platforms: iOS/iPadOS app; macOS development and test host. README currently claims iPhone 15 Pro/A17 Pro or later and iPad M1 or later; lower tiers are experimental pending title-specific evidence.

Distribution/deployment: unsigned IPA built from user-owned NSP inputs; user sideloads. Never sign or install a build on the user's device on their behalf.

Data ownership: user-supplied game content, keys, and saves; extraction/build work stays in the NSP folder. Saves follow AGENTS.md.

Offline/lifecycle: game execution is local; app and host lifecycle/recovery are implemented in native runtime layers.

Privacy/security: keys are not printed; game files and extracted contents stay outside the repository and home folder.

Scale/performance: per-game profiles, native guest execution and NVN/graphics translation; prefer general Horizon/NVN fixes before game-specific behavior.

Team/maintenance:

Interaction-critical path: guest CPU execution, command submission/replay, Metal render passes, texture upload/decode, and frame presentation.

Lifecycle/recovery: Mac diagnostics in run logs; iOS diagnostics in `Documents/log.txt`; process failure and save/load correctness need per-game evidence.

## Decision

Stack: ARM64 rewriter and runtime, C/C++/Objective-C host, Metal graphics layer, Swift/Objective-C iOS shell; see [development guide](../development.md).

System boundaries: game and SDK code run in guest process model; host services implement Horizon/NVN behavior and bridge graphics to Metal; iOS shell packages user-provided game data.

Dependency direction: per-game profile and rewriter feed host runtime; graphics tools produce versioned shader libraries consumed by the host.

State/persistence: profile-scoped config and user save data; no game save is stored in the repository.

External services: none required for local gameplay; iCloud save sync is optional and user-managed.

## Performance budget

Use this section only when performance is material. Define representative workload, measured target, prohibited critical-path work, resource bounds, and degradation order.

| Budget | Target | Evidence owner |
| --- | --- | --- |
| Critical interaction or request | TOTK frame time <=16.67 ms target, report p50/p95/p99 | TOTK feature packet |
| Representative maximum workload | same save and route on BC and no-BC, then worst region stress | TOTK feature packet |
| Memory/storage/network bound | Mac simulation footprint <3072 MiB; physical A16 requires separate device logs | TOTK feature packet |
| Degradation order | lower render scale first; preserve texture fidelity and correctness; then reduce bandwidth/clears or CPU submission by measured bottleneck | TOTK feature packet |

## Runtime ownership and update contract

Authoritative state:

Projection/cache lifetime:

Allowed critical-path mutations:

Work that must be prepared before interaction:

Cancellation/interruption recovery:

## Alternatives

| Option | Benefit | Cost | Decision |
| --- | --- | --- | --- |
|  |  |  |  |

## Quality gates

Build: `make -C dm/host GAME=<base title ID> dmhost`; IPA build instructions in README/development guide.

Tests: `make -C dm/gfx/tests GAME=<base title ID> run` for graphics tests; scope tests to changed paths and acceptance risk.

Lint/typecheck: No project-wide lint/typecheck gate documented.

Accessibility: App shell checks apply to UI changes; not applicable to the current graphics-only TOTK work item.

Security/privacy: Preserve game-data/key handling constraints in AGENTS.md.

Performance: follow per-game evidence gates in feature packets; Mac simulation does not prove device thermals or battery.

Deployment/rollback: unsigned IPA only; user performs sideload and device testing.
