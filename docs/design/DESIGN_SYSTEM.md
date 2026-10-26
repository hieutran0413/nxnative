---
doc_type: design-system
project: "NX Native"
status: not-applicable-to-current-work-item
owner: App shell design owner not recorded
last_updated: 2026-10-26
---

# Design System

## Scope

The active TOTK A16 work is graphics/runtime performance and correctness. It changes no user-facing app-shell UI, so screen design, bespoke controls, and responsive UI states are not applicable to this work item. The runtime renders the game's UI from game code. For future app-shell changes, follow the native Xcode app shell and preserve existing behavior.

## Principles

- Prefer platform-native or framework-standard behavior.
- Preserve accepted bespoke components that carry the product identity; evolve them deliberately rather than normalizing them by default.
- Use semantic color, typography, spacing, and component roles.
- Design all material states and recovery paths.
- Treat accessibility and responsive/adaptive behavior as acceptance criteria.
- Record intentional differences from references.

## Existing system and presentation boundary

- UI strategy: native-first app shell; game-rendered surfaces.
- Design-system source of truth: Xcode project under `dm/ios`; no standalone token/component system identified.
- Owner: not recorded.
- Posture: preserve existing shell unless scoped evidence authorizes change.

| Surface | Presentation rule | Evidence / owner |
| --- | --- | --- |
| System chrome | Apple-native/framework-standard | Existing app shell |
| Product content | Game-rendered UI; out of scope for this optimization packet | TOTK feature packet |

## Bespoke exceptions

Record `None` or relevant custom-control tradeoffs. Ordinary branding does not require a formal exception. Link the owning decision instead of duplicating it.

| Component/surface | User outcome | Why standard control is insufficient | Owner | Accessibility route | Adaptive/platform fallback | Performance budget | Validation |
| --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | |

## Foundations

Color:

Typography:

Spacing/layout:

Icons:

Imagery:

Motion:

Content voice:

## Component map

| Product intent | Design component | Implementation primitive | States | Accessibility |
| --- | --- | --- | --- | --- |
|  |  |  |  |  |

## Responsive/adaptive matrix

| Context | Navigation | Layout/density | Input | Validation |
| --- | --- | --- | --- | --- |
|  |  |  |  |  |

## Prohibited patterns

- Custom controls with unresolved behavior or accessibility tradeoffs.
- Replacing accepted bespoke identity with native defaults without product/design authority.
- Gesture-, color-, animation-, hover-, or sound-only meaning.
- Fixed layouts inferred from one screenshot.
- Tokens or components without an implementation owner.
