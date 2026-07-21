# v0.2 — moving the build to the author

**Status: design, not built.** v0.1 ships and works; nothing here is implemented. This
document records the constraint that shapes any redesign, the architecture chosen against
it, and the probe order that would validate it.

## The goal

Invert who runs the generator.

| | v0.1 (shipped) | v0.2 (this design) |
|---|---|---|
| Mod author ships | pak + `skin.json` | pak + `skin.json` |
| End user installs | every skin pak, + runs `cmsf.exe` | framework once, + skin paks |
| End user runs an exe | **yes, after every change** | no |
| Skins per character | unbounded | finite, growable pool |

v0.1's user-side build is not a UX choice anyone made — it falls out of a real constraint.
`DT_SkinUIData` and `BP_Player_*` are whole-asset pak overrides with exactly one owner
([04-authoring.md](04-authoring.md) §"Why you re-run the build"), so *someone* must merge
every installed skin into one artifact, and the user's machine is the only place the full
installed set is known.

v0.2 resolves that by assigning ownership instead of merging: the framework owns both
assets permanently, pre-provisions capacity, and authors claim into it.

## The constraint that kills the naive version

**`SkinChoices` is not only the selector roster. It is also the random respawn pool.**

> `SkinChoices` | `TArray<FSoftObjectPath>` | free pool — the random respawn roll.
> — [00-findings.md:255](00-findings.md#L255)

On tunnel death the game rolls a skin **directly from that array** ([:204-216](00-findings.md#L204),
[:297](00-findings.md#L297); `OnDeath` at [:344](00-findings.md#L344), [:357](00-findings.md#L357) — the
`OnDeath` linkage is **[INFERRED]**, the roll itself is **[VERIFIED]** by observed behaviour).
The roll does not consult `DT_SkinUIData` at all.

### Why that matters

The visibility rule in [00-findings.md](00-findings.md) §"what the selector checks" is a
**selector** rule: a roster entry with no table row never appears in the menu. It is easy to
read that as "unclaimed reserved capacity is harmless." It is not.

Reserve *M* mesh paths per character and the respawn roll draws from them at roughly
`M / (M + real)`. At M=64 against ScavGirl's ~5 base skins that is **~93% of tunnel respawns
landing on a reserved path**. If those paths resolve to nothing, the result is a broken or
invisible player model — triggered by the framework pak alone, with **zero skin mods
installed**, degrading vanilla behaviour for every user.

This is the [`2e0641c`](../../commit/2e0641c) selectable-trap relocated from the menu — where a
placeholder row name at least labelled it ([cmsf_build.py](../tools/cmsf_build.py) `--pool`
naming) — to the respawn roll, **where there is no mitigation surface at all.**

### Why it cannot be patched at runtime

Pruning the roster from Lua is documented-impossible. `SkinChoices` elements are opaque
`TSoftObjectPtrUserdata`; in-place writes silently no-op; `ret:set()` is banned
([probe/Scripts/main.lua](../probe/Scripts/main.lua)); passing a loaded asset to `SetNewSkin`
threw `EXCEPTION_ACCESS_VIOLATION` ([01-design.md](01-design.md) §runtime probes). `pcall`
does not protect against a C++ access violation — the process is gone before Lua sees it
([CMSFUnlock main.lua:23](../runtime/CMSFUnlock/Scripts/main.lua#L23)).

### The rule

> **Every reserved roster path must resolve to a real mesh.**
> Reserved capacity is never inert — it is always live in the respawn roll.

This constrains *any* pool-shaped design, including ones not proposed here. It is the
reason the pool was right to be rejected in v0.1 ([`465ba14`](../../commit/465ba14)) and the
reason it can be revived now.

## Why the pool works this time

v0.1's pool failed on two warts. Both now have mechanisms.

| Wart | v0.1 outcome | v0.2 mechanism |
|---|---|---|
| Unclaimed slots render and are selectable | pruning called mandatory, no safe pruning existed | **resolvable placeholders** — an unclaimed slot shows the character's default look; harmless in menu *and* in the respawn roll. Runtime pruning becomes cosmetic polish, not a correctness requirement |
| Names live inside the row | pool could only ever say `CMSF Slot 05` | **FText string-table reference** — the row points at a per-slot `ST_CMSF_<Char>_<NN>`; the author overrides *that asset*. The row never changes |

The string-table indirection is the crux. It is what lets a framework-owned row carry an
author-owned name, description, and portrait with **zero runtime text writes**.

## Architecture

### The framework release (user installs once)

Owns `DT_SkinUIData` and all six `BP_Player_*` outright. Per slot `<Char>/<NN>` it bakes:

- a row `CMSF.<Char>.<NN>` whose `SkinName`/`SkinDetails` are **string-table references** to
  `/Game/CMSF/<Char>/<NN>/ST_CMSF_<Char>_<NN>`, whose `SkinIcon` and `Skin` are soft paths to
  `T_CMSF_<Char>_<NN>` and `SK_CMSF_<Char>_<NN>`
- the matching `SkinChoices` append on `BP_Player_<Char>` (`skinpatch bpadd`, the proven 5→6
  primitive)
- **a CMSF-authored placeholder mesh, portrait, and sentinel string table at every reserved
  path** — this is what satisfies the resolvability rule

Plus `CMSFUnlock`, unchanged in its proven core.

### The author's pak (author runs the exe)

`cmsf.exe` takes their mesh + `skin.json` + a claimed slot, and emits an ordinary pak that
whole-asset-overrides exactly three packages at that slot's frozen paths: the mesh, the
portrait, and a generated string table carrying the real name and description. Higher load
order wins all three together, so a skin arrives coherently or not at all — never a
franken-skin.

Authors never ship `DT_SkinUIData` or `BP_Player_*`. That is the whole trick.

**`skin.json` is a build-time input and never ships.** `cmsf.exe` bakes its name and
description into the generated string table, so the author's pak is an ordinary pak trio.
The end user installs pak trios and nothing else — no manifest, no config, no exe.

### The runtime

**The runtime may hide, never create.** `CMSFUnlock` keeps its proven unlock (bool write +
no-arg `Init()`, game-thread wrapped) and *may* additionally collapse unclaimed slot tiles
using plain-type property writes only. Registration at runtime is dead — `RowMap` is a raw
`uint8*`, roster elements are opaque userdata. Every documented-dangerous operation class
stays banned: no hooks, no object/struct-parameter UFunction calls, no TArray construction.

**Claim detection is a pak-stem scan** — list `Content/Paks/Mods` from Lua and look for stems
matching the slot naming scheme, with the placeholder's sentinel string as a secondary
signal.

Deliberately *not* a sidecar manifest shipped beside the author's pak. A json in the user's
install is a file they can misplace, forget to remove when uninstalling, or lose to an
installer that only extracts `.pak`/`.utoc`/`.ucas` — and it buys nothing the stem scan does
not already give. Keeping the user's side to pak trios means a CMSF skin installs exactly
like every other TFW pak mod.

> **Baseline is a manual install**: the user drops the trio into `Content/Paks/Mods`, and the
> shipped filename tokens carry load order with no user action. Mod managers are an
> additional compatibility surface, not the assumed case — design and probe the plain path
> first.

Probes, in that order: (a) plain install — Lua can directory-list `Content/Paks/Mods` and the
shipped stems are readable; (b) mod-manager compat — the same scan still works when a manager
virtualises or renames the directory contents (for MO2 specifically: inside the USVFS-hooked
process, and stems surviving the mapper's number-token rewrite). A manager that breaks the
scan degrades to unpruned placeholder tiles — cosmetic, per the fail-open rule — so (b) is a
polish check, not a gate.

Because placeholders make unclaimed slots harmless, **pruning failing is cosmetic**, not a
correctness break. Fail open: if the claim signal is unreadable, do not prune — a visible
placeholder tile is always preferable to a hidden real skin.

### Patch day

Maintainer rebuilds the framework only, always from the fresh cook (the staleness inversion
in [04-authoring.md:138](04-authoring.md#L138) — a stale table deletes the developers' *new*
rows). **Slot paths under `/Game/CMSF/` are a permanent public ABI: append-only, never
renumbered.** That promise is what lets author paks survive every rebase untouched.

## The trade

v0.1 gave unbounded skins because the user regenerated. v0.2 gives a **finite, growable
namespace**: authors claim `<Char>/<NN>` from a public registry; pool size is raised on any
framework release without breaking existing claims.

Keep the pool **small**. Two independent reasons, and the second is the binding one:

1. Every baked slot is a respawn-roll participant even with placeholders absorbing it.
2. **Every baked slot costs ~9 MB.** A resolvable placeholder is a full clone of the
   character's base mesh — measured at 8.65 MB for ScavGirl (probe 2). Pool size is
   therefore a download-size decision, not just a namespace decision:

   | Pool | Slots | Framework pak |
   |---|---|---|
   | 2 per character | 12 | ~104 MB |
   | 4 per character | 24 | ~208 MB |
   | 8 per character | 48 | ~415 MB |

   All of it duplicating meshes the user already has on disk. Demand-size the pool (current
   claims + small headroom); do not reserve generously.

## What v0.1 keeps

v0.1 is **not** superseded and should not be deleted. It remains:

- **the rollback path** — if the string-table probes fail, v0.2's name channel dies and v0.1
  is the shipping design
- **the unbounded-skin mode** for users willing to run the generator — no slot claim, no
  registry, no cap
- **the private/local workflow** — a skin never published to Nexus needs no claimed slot
- **`CMSFUnlock`'s standalone value**, unchanged in both: it makes the game's *own* base
  skins selectable, which vanilla does not allow

Treat them as two distribution modes over one core, not two versions.

## Probe ladder

Cheapest and most decisive first. Each rung can kill the design before the next is paid for.

**Offline (no game launch, minutes):**

1. ~~**String-table authorability.**~~ **PASSED 2026-07-21** — cloned the game's own
   `ST_FW_UI_Skins`, rewrote it, and round-tripped it through `retoc to-zen` and back with
   the entries intact. See "Tooling" below, including the export-rename gotcha.
2. ~~**Placeholder mesh authorability.**~~ **PASSED 2026-07-21** — the mechanism works, and
   the template question answered itself: the character's own base mesh is the thing to
   clone. See "Tooling: probe 2" below. **The mechanism passing is not the headline — the
   size it costs is.**

**No offline rungs remain.** Everything below needs a launch.

**In-game, static name channel:**

3. **ST-ref renders, same pak.** One row whose `SkinName` references a CMSF string table in
   the same pak. PASS = real strings in the selector.
4. **ST-ref renders, cross-pak**, and **on the FIRST cold menu open** — string tables load on
   demand, so a name that only appears after reopening the menu is a partial failure needing
   an `Init()` retrigger.
5. **ST override by load order.** `AAA` at low order vs `BBB` at high order, same path.
   PASS = selector shows `BBB`. *This is the author channel itself.*

**In-game, the respawn constraint:**

6. **Placeholder absorbs the roll.** Bake N slots, die in the tunnels ~10×, confirm every
   placeholder spawn is the harmless default look. Then deliberately test **one unresolvable
   path** to observe the engine's real soft-path failure behaviour — currently **[INFERRED]**
   and worth converting to [VERIFIED] since the whole constraint rests on it.

**In-game, end to end:**

7. **Slot claim.** Author-style pak overriding one slot's three packages over the framework.
   Verify mesh, portrait, and name all switch, and revert cleanly when the pak is removed.
8. **Selection applies.** Selecting a claimed slot survives into a raid and across relaunch
   (`SaveGame`), with the pak present and absent.
9. **Prune mechanics** (optional polish): plain `Visibility` byte write on a trailing tile;
   confirm it collapses and survives a re-`Init()`.

**Promoted by probe 2 — run this before building placeholders:**

10. **Entitlement path.** If a local grant exists, pool slots could live in
    `LockedSkinChoices` instead — statically invisible when unclaimed **and out of the random
    roll entirely**, which would retire this whole document's central constraint. Chase the
    `Skin.Girl.MAY` loose end ([00-findings.md](00-findings.md) §the May anomaly) alongside it.

    Filed as a long shot until probe 2 measured what placeholders cost (~9 MB per slot).
    It is now the one probe that can *remove* the cost instead of managing it, and its
    decisive question — is ownership checked locally or against a backend — is cheap to ask.
    See "Why this promotes the entitlement path" below.

## Tooling: probe 1 is **PASSED** (2026-07-21)

The concern was that no from-scratch package authoring exists anywhere in the toolchain —
`skinpatch`, `tools/cmsf/Patcher.cs` and the skin-mods `fwrepath` all begin
`new UAsset(existingFile)` and edit in place, so synthesizing `UStringTable` packages looked
like a new tooling tier.

**It isn't, because the game ships a string table to clone.** `ST_FW_UI_Skins`
([00-findings.md:53](00-findings.md#L53)) is a real cooked `UStringTable`, and the base skin
rows already reference it in exactly the form v0.2 needs
([00-findings.md:86](00-findings.md#L86)). So the existing edit-in-place pattern covers it —
extract the game's table, clear it, write our own entries, save to a CMSF path.

Verified end to end, offline, on game build as of this date:

| Step | Result |
|---|---|
| `retoc to-legacy -f ST_FW_UI_Skins` from the live cook | 1 asset extracted (665 B `.uasset` + 2414 B `.uexp`) |
| UAssetAPI 1.1.0 load | resolved as `StringTableExport`, class `StringTable`, namespace `ST_FW_UI_Names`, **42 entries** |
| clear + set namespace + add entries + `asset.Write()` | wrote a 665 B `.uasset` + 113 B `.uexp` |
| reload the written asset | entries intact |
| `retoc to-zen` at `/Game/CMSF/Girl/05/` | **produced a valid pak trio** |
| `to-legacy` back, then reload | namespace `CMSF.Girl.05`, `Name` and `Desc` intact |

So the name/description channel is buildable with the tools already in the repo. What remains
unproven is whether the *game* resolves a cross-pak string-table reference and honours an
override — probes 3–5, which need a launch.

### Two findings from running it

**The export object is not renamed by renaming the file.** After saving the clone as
`ST_CMSF_Girl_05.uasset`, the export was still named `ST_FW_UI_Skins`. Since a `TableId` is
`/Package/Path.ObjectName`, a clone whose object keeps the template's name must either be
referenced as `/Game/CMSF/Girl/05/ST_CMSF_Girl_05.ST_FW_UI_Skins` or — better — have its
export renamed at generation time. This is the
[04-authoring.md](04-authoring.md) §Gotchas "object name after the dot" rule biting in a new
place. **The generator must rename the export, not just the file.**

**`to-legacy` on a mod pak needs the game's global container staged beside it.** Alone it
fails with `FIoChunkId ... ScriptObjects not found in any containers`. This is already
handled in [cmsf_build.py](../tools/cmsf_build.py) (it copies `global.utoc`/`global.ucas`
into the verify directory) — worth knowing before it looks like a corrupt pak.

## Tooling: probe 2 is **PASSED** (2026-07-21)

The worry was that a mesh, unlike a string table, carries hard imports — skeleton,
materials, physics asset — and that repathing it would null them, the way the
"unattended repathing" rejection below describes. It does not, **when the clone source is a
game asset extracted from the live cook** (the rejection is about third-party paks, where
the imports were never resolvable to begin with).

There is also no template problem. `SK_SCV_FL` — the character's own base mesh — is exactly
the right thing to clone, because "the placeholder shows the character's default look" and
"the placeholder *is* the default look" are the same asset.

Verified end to end, offline, via `tools/mshprobe`:

| Step | Result |
|---|---|
| `retoc to-legacy -f SK_SCV_FL` from the live cook | 14 assets; base mesh is 8,331 B `.uasset` + **8,637,458 B `.uexp`**, no `.ubulk` |
| UAssetAPI 1.1.0 load | 8 exports, **43 imports**, 212 names; `SkeletalMesh` export resolves |
| rename export `SK_SCV_FL` → `SK_CMSF_Girl_00`, `asset.Write()` | `.uexp` re-emitted byte-for-byte identical |
| `retoc to-zen` at `/Game/CMSF/Girl/00/` | valid pak trio — 347 B `.pak` + 2,066 B `.utoc` + **8,646,142 B `.ucas`** |
| `to-legacy` back, then reload | 8 exports, **43/43 imports preserved**, export carries the new name |

The imports that survive are the ones that matter: `Skeleton GenericHumanoid_Skeleton`,
`PhysicsAsset SK_SCV_FL_Slim_PhysicsAsset`, and 12 `MaterialInstanceConstant` refs — all
still pointing at their original `/Game/Character/...` packages, which the framework does
not ship and does not need to.

The probe-1 export-rename rule applies here too and is **load-bearing in a new way**: a
roster entry is a soft path `/Game/CMSF/Girl/00/SK_CMSF_Girl_00.SK_CMSF_Girl_00`, so an
unrenamed export makes the roster entry unresolvable — the precise failure the placeholder
exists to prevent.

### The finding that actually matters

**A placeholder costs a full mesh clone: ~8.65 MB per slot, per character.** Nothing in the
round-trip shrinks it — the `.uexp` is the render data, and it survives byte-identical
because it has to.

Incidental confirmation of scale from the same extract: `SK_SCV_FL_OCT` is 50.9 MB,
`SK_SCV_FL_DSQ` 15.3 MB, `SK_SCV_FL_SPT` 12.7 MB. Base meshes are the *cheap* end.

This does not kill v0.2. It does mean the pool must be demand-sized to single digits per
character (see "The trade"), and it materially raises the value of rung 10 — see below.

### Why this promotes the entitlement path

Rung 10 was filed as a long shot. The size finding makes it the **highest-expected-value
remaining probe**, because it removes the cost rather than managing it:

- `LockedSkinChoices` is out of the respawn roll entirely, so slots there **need no
  placeholder at all** — the framework pak collapses from hundreds of MB to a table patch.
- It is also what the selector shows by default
  ([00-findings.md:288](00-findings.md#L288)), so CMSF slots would not depend on
  `CMSFUnlock` to be visible.
- Both entitlement tables are ordinary DataTables
  ([00-findings.md:145](00-findings.md#L145)) — the exact asset class `skinpatch` already
  patches. Defining a CMSF tag and SKU row is existing capability, not new tooling.

The whole question is **where ownership is decided**: against those local tables, or against
a Steam/EOS backend call. That is open question 4 in
[00-findings.md](00-findings.md) §"what is still unknown" (does `GA_Player_ChangeSkin`
re-validate against an ownership list?) and it is what the `Skin.Girl.MAY` anomaly is
probably evidence about. **Answer that before building any placeholder.** A local check
retires the central constraint of this document; a backend check confirms the placeholder
design and caps the pool.

## Rejected

- **Runtime registration (the "Lua way").** Retired in [`3d9a0bc`](../../commit/3d9a0bc) on
  safety grounds and re-confirmed here. Its *distribution model* was never the problem and
  is what v0.2 recovers — by static means.
- **Composite DataTable registry.** `UCompositeDataTable.ParentTables` is
  `TArray<TObjectPtr<UDataTable>>` — **hard** object references, i.e. package imports
  resolved by `FPackageId`, re-entering the exact `FolderName`/`FPackageId` surgery CMSF
  exists to escape. Also serializes a combined `RowMap` at cook time, so it can appear to
  work while author overrides never take.
- **Per-author `DT_SkinUIData` edits.** The known-fatal baseline: last pak loaded silently
  erases every other author's skins.
- **Unattended repathing of third-party paks.** Not achievable today — `to-legacy` needs the
  full game mounted or skeleton/material imports become null, and the rename pass has
  non-fatal misses that stay silent until a T-pose in game. v0.2 avoids needing it: authors
  cook at the slot path from the start.
