---
doc_type: documentation-index
project: "NX Native"
project_type: "desktop-app"
status: discovery
last_updated: 2026-10-26
---

# NX Native Documentation

## Start here

Open [Feature Status](engineering/IMPLEMENTATION_STATUS.md) to see what works, what remains, and the next action for each feature. Follow its links for detailed decisions and evidence.

## Source-of-truth order

1. `../AGENTS.md` — repository safety, architecture notes and agent rules.
2. `product/PRODUCT_BRIEF.md` — product purpose and boundaries.
3. `engineering/ARCHITECTURE.md` — summarized runtime model and cross-cutting constraints; [development guide](development.md) remains the detailed architecture/build source.
4. `engineering/IMPLEMENTATION_STATUS.md` — verified progress overview.
5. `engineering/totk-a16-60fps.md` — active feature packet and acceptance evidence.
6. `engineering/IMPLEMENTATION_PLAN.md` — priority and dependency summary.
7. `operations/HANDOFF.md` — handoff; confirm current packet/status before relying on the template.

## Workflow

```text
discovery
→ design-ready
→ code-ready
→ in-progress
→ verification
→ accepted
→ released
```

## Folders

```text
docs/
├── product/
├── research/
├── design/
├── engineering/
├── operations/
├── decisions/
└── templates/
```

Raw evidence, exports, and scratch files belong in ignored `workbench/`.

Existing repository documents retain ownership when they predate this scaffold. Do not create duplicate architecture, work-item, or status records; add detail to the owning document and link here.

