# CMSF — Character Model Selection Framework

A framework for **appending** player-character skins to *The Forever Winter*'s
character-select screen, instead of overwriting the finite set of slots the game ships with.

**Status: v0.2 is built, validated in-game, and packaged. Not yet released.**

Probes 1–9 all pass, and on 2026-07-22 **all six characters** were opened in-game against the
real 192-slot framework: every menu populates and prunes, and an author's claim renders with
its own name, portrait and mesh. See [docs/05-v2-distribution.md](docs/05-v2-distribution.md)
for the design and probe results, [docs/06-next-session.md](docs/06-next-session.md) for the
current handoff.

```bash
python tools/cmsf_framework.py --slots 32       # the framework users install once
cmsf-author.exe <skin-dir>                      # one skin -> one pak trio (authors)
pwsh tools/package-release.ps1                  # the author bundle, guarded
```

**What remains before release:**

1. **Make this repo public.** `cmsf-author` fetches the slot registry from the repo's raw URL,
   so while it is private the collision check degrades to "cannot check" for every author. It
   fails soft by design, but it is inert until the flip.
2. Ship it — the Nexus page and release notes are drafted in
   [docs/08-public-copy.md](docs/08-public-copy.md).

Untested and documented as such: **multiplayer**, and behaviour **across a game patch**.

## The two distribution models

**v0.2 — the shipping design.** The user installs a **0.57 MB framework once**, and each skin
is an ordinary pak trio. No exe on the user's side, no manifest, no re-running a generator when
skins are added. The framework permanently owns `DT_SkinUIData` and `BP_Player_*` and
pre-provisions numbered slots; an author claims one by shipping three packages at its frozen
paths — a mesh, a portrait and a string table. Higher load order wins all three together, so a
skin arrives coherently or not at all.

Authors never ship `DT_SkinUIData` or `BP_Player_*`. That is the whole trick, and it is why two
CMSF skins cannot clobber each other. Authoring guide: [docs/07-authoring-v2.md](docs/07-authoring-v2.md).

**v0.1 — not superseded.** The END USER runs a generator that merges every installed skin into
one pak. It remains the rollback path, the unbounded-skin mode for users willing to run it, and
the private/local workflow that needs no slot claim.

```bash
python tools/cmsf_build.py --list     # v0.1 — what is registered
python tools/cmsf_build.py            # -> dist/CMSF/CMSF_9_P.{pak,utoc,ucas}
```

Both models share `CMSFUnlock`, which is worth having by itself: it makes the game's **own**
base skins selectable, which vanilla does not allow. Normally, picking a DLC skin strands you
there until you die in a raid and get randomly reassigned.

| | |
|---|---|
| **the pak** | v0.2 provisions 32 slots per character; v0.1 appends each registered skin's mesh to the roster and a row to `DT_SkinUIData` |
| **`CMSFUnlock`** (UE4SS Lua) | unfilters the selector, **and** hides CMSF slots no author has claimed |

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
string at load time. So a new row can point at assets that were never part of the game.

| | Overwrite (today) | Append (CMSF) |
|---|---|---|
| Skins per character | capped at slot count | 32 (v0.2 pool) / unbounded (v0.1) |
| Two mods coexist | no — last one wins | yes — separate rows |
| Needs the DLC | yes | no |
| Custom portrait | no | yes (`SkinIcon` is per-row) |
| Custom name/description | no | yes — string table (v0.2) or inline `FText` (v0.1) |

> **v0.2 still rewrites package identity, deliberately.** v0.1 let a modder keep their own
> package paths; v0.2 clones into the slot's frozen path *with* a rewritten identity, which is
> what lets the framework reference a path that exists before any author does. The identity
> rule below is therefore load-bearing, not avoided.

## Repo layout

```
docs/
  00-findings.md         what the datamine proves — the registry, the row struct, entitlements
  01-design.md           injection vectors, the composability constraint, open questions
  02-poc.md              the experiments that located the real roster
  03-multiplayer.md      what happens to mods in co-op — host authority, skins as soft paths
  04-authoring.md        v0.1 authoring. SUPERSEDED for v0.2 — see 07
  05-v2-distribution.md  v0.2 design + probe results. Contains a long argument for a
                         placeholder mechanism that probe 6 DISPROVED; marked, but do not skim
  06-next-session.md     handoff: what is proven, what remains, gotchas, machine setup
  07-authoring-v2.md     v0.2 authoring (mod-author facing) — the current guide
  08-public-copy.md      Nexus page, release notes, and what NOT to claim. Draft
  slots.md               the slot registry — who claimed which <Char>/<NN>
```
```
skins/                   v0.1 registered skins, one folder each (skin.json)
examples/example-skin/   a BUILDABLE example, on private slot 28 — doubles as a setup check
tools/
  cmsf_framework.py      v0.2 — emits the framework pak. Rebuild from every fresh cook
  cmsf_author.py         v0.2 — one skin -> one pak trio. Reference implementation
  cmsf-author/           the same tool in C#, published as cmsf-author.exe for authors
  cmsf_build.py          the v0.1 generator — extract, patch, repack, verify
  cmsf/                  the v0.1 end-user exe (C#)
  package-release.ps1    builds the author bundle; REFUSES to ship Oodle or a usmap
  skinpatch/             UAssetAPI: DataTable rows (add / addst) + roster (bpadd / bpset)
  stgen/  mshgen/        string-table and package cloning — absorbed into cmsf-author
  stprobe/  mshprobe/    historical probe harnesses. mshprobe does NOT rewrite identity
  build_probe*.py        the probe paks, 3-9
runtime/
  CMSFUnlock/            UE4SS Lua: unfilters the selector, prunes unclaimed slots
  CMSFTime/              `cmsftime` — times Init() over N reps, for pool-depth work
  CMSFProbe9/            the rung-9 probe. Superseded by CMSFUnlock; kept as evidence
```

> **The identity rule.** Any tool that clones a cooked package must rewrite its package
> identity — *both* the name-map entry and `FolderName`. A clone that keeps its template's
> package name collides by `FPackageId` and the loader serves it in the template's place.
> See [docs/05-v2-distribution.md](docs/05-v2-distribution.md) §"The identity rule".

> **What must never be redistributed.** `ForeverWinter-*.usmap` (decoded from the game's own
> type layout) and `oo2core_9_win64.dll` (proprietary Oodle — retoc provisions it itself, and
> it *will* appear in your build folder). `package-release.ps1` enforces this rather than
> trusting anyone to remember it.

## Prior art in this workspace

- `forever-winter-datamine` — the CUE4Parse decoder + usmap used to produce every finding here
- `forever-winter-skin-mods` — the current overwrite pipeline this aims to replace
- `TFWQuestItemTag` — the proven UE4SS Lua polling pattern for live widget manipulation
- `FWBehaviorLab` — the static-pak vs UE4SS-runtime vector comparison
- `tfworkbench-compat-research` — the UE4SS `-894` ABI pin, and why it is load-bearing
- `ForeverWinterMO2Support` — the MO2 plugin. Under MO2 it rewrites every pak's `_<N>_P`
  token from left-pane priority, so MO2 order decides load order, not the filename

## Licence

[MIT](LICENSE). Built with [retoc](https://github.com/trumank/retoc) (MIT, Truman Kilen and
Archengius) and [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS).
