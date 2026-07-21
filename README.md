# CMSF — Character Model Selection Framework

A framework for **appending** player-character skins to *The Forever Winter*'s
character-select screen, instead of overwriting the finite set of slots the game ships with.

**Status: v0.1 — working and verified in-game.** Custom skins appear in the character-select
screen with their own name, description and portrait, alongside the vanilla ones.

```bash
python tools/cmsf_build.py --list     # what is registered
python tools/cmsf_build.py            # -> dist/CMSF/CMSF_9_P.{pak,utoc,ucas}
```

Two pieces:

| | |
|---|---|
| **the generated pak** | appends each registered skin's mesh to the character's roster, and a row to `DT_SkinUIData` for its name/icon |
| **`CMSFUnlock`** (UE4SS Lua) | unfilters the selector, which vanilla restricts to entitlement-gated DLC skins |

Adding a skin: drop a folder under `skins/` and re-run the build — see
[docs/04-authoring.md](docs/04-authoring.md).

In v0.1 the **end user** runs the build, because one artifact must merge every installed
skin. [docs/05-v2-distribution.md](docs/05-v2-distribution.md) designs the inversion — author
runs the exe, user installs a framework once — and records the constraint any such design has
to survive: `SkinChoices` is also the random respawn pool, so reserved capacity is never
inert. v0.2 is design-only; v0.1 remains the shipping path and the unbounded-skin mode.

`CMSFUnlock` is worth having by itself: it makes the game's **own** base skins selectable,
which vanilla does not allow. Normally, picking a DLC skin strands you there until you die
in a raid and get randomly reassigned.

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
  02-poc.md         the experiments that located the real roster
  03-multiplayer.md what happens to mods in co-op — host authority, and skins as soft paths
  04-authoring.md   how to register a skin (mod-author facing)
  05-v2-distribution.md  design: move the build to the author, user installs once
```
```
skins/              registered skins, one folder each (skin.json)
tools/
  cmsf_build.py     the generator — extract, patch, repack, verify
  skinpatch/        UAssetAPI tool: DataTable rows + Blueprint roster arrays
runtime/CMSFUnlock/ UE4SS Lua mod that unfilters the selector
```

## Prior art in this workspace

- `forever-winter-datamine` — the CUE4Parse decoder + usmap used to produce every finding here
- `forever-winter-skin-mods` — the current overwrite pipeline this aims to replace
- `TFWQuestItemTag` — the proven UE4SS Lua polling pattern for live widget manipulation
- `FWBehaviorLab` — the static-pak vs UE4SS-runtime vector comparison
- `tfworkbench-compat-research` — the UE4SS `-894` ABI pin, and why it is load-bearing
