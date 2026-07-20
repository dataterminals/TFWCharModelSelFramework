# CMSF — Character Model Selection Framework

A framework for **appending** player-character skins to *The Forever Winter*'s
character-select screen, instead of overwriting the finite set of slots the game ships with.

**Status: research complete, PoC not yet built.** The feasibility question is settled far
enough to build on — see [docs/00-findings.md](docs/00-findings.md) for the evidence. What
is *not* yet settled is the injection mechanism; see [docs/01-design.md](docs/01-design.md).

> Public-facing copy (Nexus page, release notes, announcement) is deliberately not drafted
> here. This README is the technical record.

## The problem

Every existing TFW skin mod is a **package-identity overwrite**. You take your mesh, rewrite
its package name and header `FolderName` so its `FPackageId` collides with a skin the game
already ships, and the loader serves yours instead. That approach has hard limits:

- **Capped at slot count.** Shaman has 4 DLC slots. Four mods, then you're out.
- **Mods clobber each other.** Two mods targeting the same slot: one wins, silently.
- **Requires owning the DLC** whose slot you borrow — the mod swaps the model, it can't
  unlock the slot.
- **The portrait lies.** Character-select thumbnails live outside the mesh folder, so a
  retargeted slot still shows the vanilla DLC portrait.
- **Fragile build pipeline.** `retoc to-legacy` → repath → `retoc to-zen`, plus the
  `FolderName`/`FPackageId` workaround, plus re-fixing external skeleton/material refs.

## Why appending is strictly better

The game's skin registry turns out to be a plain DataTable whose rows are fully
self-contained, and **both asset references in a row are soft object paths** — resolved by
string at load time. So a new row can point at a modder's own assets, at their own paths.

| | Overwrite (today) | Append (CMSF) |
|---|---|---|
| Skins per character | capped at slot count | unbounded |
| Two mods coexist | no — last one wins | yes — separate rows |
| Needs the DLC | yes | no |
| Custom portrait | no | yes (`SkinIcon` is per-row) |
| `FPackageId` surgery | required | not required |
| Custom name/description | no | yes (inline `FText`) |

That last column is the whole point: a modder ships a normal pak containing their own mesh
and icon at their own paths, plus a small manifest. No identity games, no collisions.

## Repo layout

```
docs/
  00-findings.md    what the datamine proves — the registry, the row struct, entitlements
  01-design.md      injection vectors, the composability constraint, open questions
  02-poc.md         the one-variable experiment that settles the last unknown
```

## Prior art in this workspace

- `forever-winter-datamine` — the CUE4Parse decoder + usmap used to produce every finding here
- `forever-winter-skin-mods` — the current overwrite pipeline this aims to replace
- `TFWQuestItemTag` — the proven UE4SS Lua polling pattern for live widget manipulation
- `FWBehaviorLab` — the static-pak vs UE4SS-runtime vector comparison
- `tfworkbench-compat-research` — the UE4SS `-894` ABI pin, and why it is load-bearing
