---
doc_type: product-brief
project: "NX Native"
status: discovery
owner: project maintainer (name not recorded)
last_updated: 2026-10-26
---

# NX Native Product Brief

## Product sentence

For players who own Nintendo Switch game files, NX Native is an Apple-platform native runtime that runs the game's own code with a host layer translating Horizon/NVN services to Apple systems.

## User and problem

Primary user: A player with legally obtained Switch game files and the required console keys who wants to run supported titles on iPhone or iPad.

Primary job: Build an unsigned app package from the user's NSP files and sideload it onto a supported Apple device.

Problem: Apple platforms do not provide the Switch Horizon and NVIDIA NVN runtime expected by those games.

Current workaround: Play on the Switch or use another compatible execution environment.

Evidence: Repository README documents the product, input files, packaging flow, and supported-game list. This is product documentation, not independent user research.

## Outcome

Successful user outcome: A supported game builds from the user's files, starts, loads its save, and remains playable with correct visuals and input.

Product success measure: Per-game verified build, gameplay, save, image, performance, and stability gates; no aggregate pass claim without evidence.

Failure condition: Game does not boot or play correctly, loses user data, exceeds its applicable resource budget, or silently reports success without gameplay evidence.

## Scope

In scope:

- Native Apple runtime and per-game profiles for Switch software.
- For current TOTK work: no-BC rendering and memory/performance behavior, with 16.67 ms target and 3072 MiB Mac simulation limit; see the owning feature packet.

Non-goals:

- Supplying or distributing Nintendo game files, keys, firmware, or user saves.
- Claiming that Mac simulation proves physical-device thermals, battery, or sustained frame pacing.

## Constraints

Platform/distribution: iOS/iPadOS and macOS development host; unsigned IPA is sideloaded by the user. README currently lists iOS/iPadOS 26 and A17 Pro-or-newer iPhone / M1-or-newer iPad as supported; A16 work is experimental.

Data ownership: User-provided NSPs, keys and saves; game data stays outside this repository. See AGENTS.md save/data rules.

Privacy/security: Do not print key values or copy game data into the repository or home directory.

Safety/compliance: User supplies game content and keys; project is unaffiliated with publishers (README). No legal conclusion recorded.

Entitlements/business model: Not applicable; no account or purchase flow documented.

Accessibility: Native shell should retain platform accessibility; per-game controls are evaluated as part of game compatibility. No accessibility audit is recorded here.

Time/budget/team: No schedule or team allocation recorded.

## Experience strategy

- UI strategy: native-first for the Apple app shell; game UI is rendered from the game's own code.
- Existing design system: Xcode project and app shell under `dm/ios`; no separate design-system source of truth identified.
- Design-system owner: not recorded.
- Presentation posture: preserve the existing app shell; evolve only with scoped evidence.
- System chrome: Apple-native/framework-standard.
- Product-content surfaces: game-rendered content and existing app shell.
- Revisit trigger: scoped UI work or an accessibility/compatibility issue supported by evidence.

## Assumptions and open decisions

| Item | Type | Owner | Due |
| --- | --- | --- | --- |
| Which lower Apple GPU/RAM tiers can meet each game's acceptance gates? | evidence gap | runtime owner | Before support claim |
| Physical A16 sustained frame pacing, heat and battery | evidence gap | user/device test | After unsigned IPA is supplied |
