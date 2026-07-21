# CMSF — Character Model Selection Framework

A framework for **appending** player-character skins to *The Forever Winter*'s
character-select screen, instead of overwriting the finite set of slots the game ships with.

**Status: v0.1 ships. v0.2 is validated in-game but not yet built.**

v0.1 works today: custom skins appear in the character-select screen with their own name,
description and portrait, alongside the vanilla ones. The end user runs the generator.

v0.2 inverts that — the user installs a ~1 MB framework once, and each skin is an ordinary
pak trio. Every mechanism it needs was proven in-game on 2026-07-21 (probes 1–8, see
[docs/05-v2-distribution.md](docs/05-v2-distribution.md)); what remains is writing the
generator. See [docs/06-next-session.md](docs/06-next-session.md) for the handoff.

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
skin. [docs/05-v2-distribution.md](docs/05-v2-distribution.md) inverts that: the framework
permanently owns `DT_SkinUIData` and `BP_Player_*`, pre-provisions numbered slots, and an
author claims one by shipping three packages at its frozen paths — a mesh, a portrait and a
string table. Higher load order wins all three, so a skin arrives coherently or not at all.

Authors never ship `DT_SkinUIData` or `BP_Player_*`. That is the whole trick, and it is why
two CMSF skins cannot clobber each other.

v0.1 is **not** superseded: it remains the rollback path, the unbounded-skin mode for users
willing to run the generator, and the private/local workflow that needs no slot claim.

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
  05-v2-distribution.md  v0.2: move the build to the author — design + probe results
  06-next-session.md     handoff: what is proven, what to build, gotchas, machine setup
```
```
skins/              registered skins, one folder each (skin.json)
tools/
  cmsf_build.py     the v0.1 generator — extract, patch, repack, verify
  skinpatch/        UAssetAPI: DataTable rows (add / addst) + Blueprint roster (bpadd/bpset)
  stgen/            generate a CMSF string table — the v0.2 name channel
  mshgen/           clone any cooked package to a slot path with a NEW package identity
  stprobe/          probe 1 harness (string table round-trip)
  mshprobe/         probe 2 harness (mesh round-trip). Does NOT rewrite identity — use mshgen
  build_probe345.py the name-channel probes
  build_probe6.py   unresolvable-path behaviour;  build_probe6b.py forces the respawn roll
  build_probe7.py   end-to-end slot claim, in the shipping shape
runtime/CMSFUnlock/ UE4SS Lua mod that unfilters the selector
```

> **The identity rule.** Any tool that clones a cooked package must rewrite its package
> identity — *both* the name-map entry and `FolderName`. A clone that keeps its template's
> package name collides by `FPackageId` and the loader serves it in the template's place.
> See [docs/05-v2-distribution.md](docs/05-v2-distribution.md) §"The identity rule".

## Prior art in this workspace

- `forever-winter-datamine` — the CUE4Parse decoder + usmap used to produce every finding here
- `forever-winter-skin-mods` — the current overwrite pipeline this aims to replace
- `TFWQuestItemTag` — the proven UE4SS Lua polling pattern for live widget manipulation
- `FWBehaviorLab` — the static-pak vs UE4SS-runtime vector comparison
- `tfworkbench-compat-research` — the UE4SS `-894` ABI pin, and why it is load-bearing
