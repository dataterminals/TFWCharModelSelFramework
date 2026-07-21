# v0.2 — moving the build to the author

**Status: probes 1–6 pass; the framework is not built.** (2026-07-21)

Two results define the design:

1. **The name channel works.** A CMSF-authored string table builds, the game resolves it
   cross-pak on a cold first open, and a higher-load-order pak overrides it — the author
   channel itself, and the riskiest unknown.
2. **The central constraint is disproven.** An unresolvable roster path is a silent no-op,
   not a broken model, so **placeholders are unnecessary** and the framework collapses from
   hundreds of MB to a table patch plus KB-sized string tables. See §"The rule".

3. **The model works end to end.** Probe 7 built it in its real shape — a **1.15 MB**
   framework pak for two slots, and an author pak claiming one with mesh + portrait + string
   table. All three switched together, and the unclaimed slot read as deliberate. No
   manifest, no exe, no `DT_SkinUIData` or `BP_Player_*` shipped by the author.

Much of this document argues for a placeholder mechanism that is no longer needed. That
argument is kept as the record of why; **it should not be built.** Outstanding: probe 7's
revert path, and rung 8 (selection surviving a raid and a relaunch). v0.1 still ships.

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

### ~~The rule~~ — **DISPROVEN 2026-07-21**

> ~~**Every reserved roster path must resolve to a real mesh.**~~
> ~~Reserved capacity is never inert — it is always live in the respawn roll.~~

**An unresolvable roster path is a silent no-op.** The player keeps the skin they already
have. No broken model, no invisible model, no crash — in *either* code path.

Probe 6 tested selection: a row pointing at a path where nothing is shipped, selected from
the menu, simply does not apply. Probe 6b tested the roll, which is what actually mattered
since selection runs through `GA_Player_ChangeSkin` and the roll does not. It repointed every
vanilla entry to a dead path and appended ten more, leaving 15 of 16 entries resolving to
nothing and **no entry pointing at a base ScavGirl mesh**, so a default-looking respawn could
only be a fallback. Observed:

| Death | Roll landed on | Result |
|---|---|---|
| 1 | unresolvable (p≈0.94) | kept the currently-worn DLC skin — no change, no breakage |
| 2 | unresolvable (p≈0.94) | same |
| 3 | the one resolvable CMSF slot | **October look applied** |

The third death is the other half of this rung: a mesh CMSF *appended* won the roll, which
converts `SkinChoices` feeding the respawn roll from **[INFERRED]** to **[VERIFIED]**, and
proves a CMSF-owned slot path is a first-class participant in it.

Sample is n=2 for the unresolvable case, which is thin on its own — but the prior is strong
(≈88% that both of those rolls were dead paths) and it agrees with the independent selection
result. Worth a few more deaths to firm up, not worth blocking on.

### What this changes

The rule was the reason a reserved slot had to carry a ~10 MB placeholder clone. It does not
hold, so:

- **Placeholders are unnecessary.** Reserved capacity really is inert.
- **The framework pak collapses** from hundreds of MB to a DataTable patch plus a handful of
  KB-sized string tables.
- **Pool size stops being a download-size decision** and goes back to being purely a
  namespace decision — reserve generously.
- **Rung 10 (the entitlement path) loses most of its motivation.** Its main draw was escaping
  the respawn roll; there is now nothing to escape.

The sections below still describe the placeholder architecture. They are kept as the record
of why it was designed that way, but **the placeholder mechanism should be removed from the
v0.2 build**. An unclaimed slot needs a row and a roster entry and nothing else.

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

**Superseded by probe 6.** With placeholders gone, a reserved slot is a DataTable row and a
roster entry — bytes, not megabytes — and an unclaimed one is genuinely inert. Pool depth is
a namespace decision again: **reserve generously**, and raise it on any framework release.

The measurements below are kept because they are real and were correct; they simply no
longer describe a cost anyone pays. They now describe what a *claimed* slot's mesh costs the
author, which is the same as any skin mod today.

~~Keep the pool demand-sized~~ — a placeholder was a full base-mesh clone, 10.4 MB on
average, measured across all six characters (probe 2):

| Pool depth | Slots | Framework pak |
|---|---|---|
| 1 per character | 6 | ~62 MB |
| 2 per character | 12 | ~125 MB |
| 4 per character | 24 | ~250 MB |
| 8 per character | 48 | ~499 MB |

**This is a normal size for a game mod and is not a constraint on the design.** For scale:
one shipped DLC skin, `SK_SCV_FL_OCT`, is 50.9 MB on its own. A framework installed once,
which then makes every skin a small pak trio and retires v0.1's per-change exe run, is worth
a few hundred MB without much argument.

Two second-order notes, neither load-bearing. Pool depth need not be uniform, and demand is
not uniform either — ScavGirl carries most skin mods, while Gunhead and Shaman ship one base
skin each and happen to have the two largest meshes, so uniform reservation spends the most
bytes where claims are least likely. And if the pool ever did grow past what a single
download should carry, per-character framework paks are an easy out.

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
   clone, with all 43 imports surviving the round-trip. See "Tooling: probe 2" below.

**No offline rungs remain.** Everything below needs a launch. Both offline rungs passed, so
**the v0.2 design is intact and the next step is probes 3–5** — the name channel is the
remaining gate on the shipping design.

**In-game, static name channel:**

3. ~~**ST-ref renders, same pak.**~~ **PASSED 2026-07-21** — the selector shows
   `CMSF P3 SAMEPAK` and its description on the appended tile, with every vanilla name still
   correct beside it (`DEFAULT SKIN 5`, `BLIND RUNNER`). **The game resolves a CMSF-authored
   string table.** Took two tries; see "The identity rule" below for what the first one got
   wrong.
4. ~~**ST-ref renders, cross-pak**, and **on the FIRST cold menu open**.~~
   **PASSED 2026-07-21** — `CMSF P4 LOW-AAA` rendered correctly with the string table in a
   *separate pak* from the row, and it was right on the **first** menu open of a cold launch.
   **No `Init()` retrigger is needed**, so the on-demand load lands in time and the partial
   failure this rung was written to catch does not occur. Cross-pak is the realistic v0.2
   shape, so this is the rung that matters more than 3.
5. ~~**ST override by load order.**~~ **PASSED 2026-07-21** — two paks shipped
   `/Game/CMSF/Girl/00/ST_CMSF_Girl_00` at the same path with different strings; the selector
   showed the higher-load-order one (`CMSF P5 HIGH-BBB`). **The author channel works.** A
   framework-owned row can carry an author-owned name, with no runtime text writes and
   nothing shipped by the author except their own packages.

   Load order was decided by **MO2 priority**, not the filename token — `High` at MO2
   priority 21 beat `Low` at 20, confirming the priority-token behaviour noted in
   [cmsf_build.py](../tools/cmsf_build.py). Authors installing manually get the same result
   from the shipped `_N_P` token; both channels work, and MO2's wins when present.

**In-game, the respawn constraint:**

6. ~~**Placeholder absorbs the roll.**~~ **PASSED 2026-07-21 — and killed its own premise.**
   The unresolvable-path test it was told to run "deliberately" turned out to be the whole
   rung. An unresolvable roster path is a **silent no-op** in both the selector and the
   respawn roll, so placeholders are unnecessary and reserved capacity *is* inert. Also
   converted `SkinChoices` → respawn roll from [INFERRED] to **[VERIFIED]**: a CMSF-appended
   slot won a roll and applied. See §"The rule" above.

**In-game, end to end:**

7. **Slot claim.** — **INSTALL HALF PASSED 2026-07-21.** An author pak overriding one slot's
   three packages over the framework switched **all three together**: the author's name
   (`OCTOBER SCAV (CLAIMED)`), the author's portrait (DLC04 rather than the sentinel locked
   plate), and the author's mesh on selection. No partial claim — no author name beside a
   framework portrait, no mesh without its name. The unclaimed slot 01 alongside it showed
   its sentinel name and locked portrait and did nothing when selected.

   This is the whole v0.2 model demonstrated at once, in the post-placeholder shape: a
   **1.15 MB** framework pak for two slots, and an author shipping three packages and
   nothing else. **Still to verify: the revert** — unticking the author pak alone must
   return slot 00 to its sentinel.
8. **Selection applies.** Selecting a claimed slot survives into a raid and across relaunch
   (`SaveGame`), with the pak present and absent.
9. **Prune mechanics** (optional polish): plain `Visibility` byte write on a trailing tile;
   confirm it collapses and survives a re-`Init()`.

**Long shot, high payoff:**

10. **Entitlement path.** If a local grant exists, pool slots could live in
    `LockedSkinChoices` instead — statically invisible when unclaimed **and out of the random
    roll entirely**, which would retire this whole document's central constraint. Chase the
    `Skin.Girl.MAY` loose end ([00-findings.md](00-findings.md) §the May anomaly) alongside it.

    Needs two new `skinpatch` commands before it can be built at all — see "A note on
    rung 10" below. Not a blocker on anything; the placeholder design does not wait on it.

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

### What a placeholder costs

**A placeholder is a full mesh clone.** Nothing in the round-trip shrinks it — the
`.uexp` *is* the render data, and it survives byte-identical because it has to.

Measured for every character's `SkinChoices[0]`, the mesh a placeholder would clone
(`skinpatch bpskins` for the paths, `retoc to-legacy` for the bytes):

| Character | Base mesh | Size |
|---|---|---|
| OldMan | `GH_OldMan` | 6.62 MB |
| BagMan | `SK_SCV_BGM` | 8.11 MB |
| Girl | `SK_SCV_FL` | 8.25 MB |
| MaskMan | `SK_SCV_MSKM` | 12.41 MB |
| Shaman | `SK_SCV_SHM` | 13.40 MB |
| Gunhead | `SK_SCV_GHD_V01` | 13.62 MB |
| | **one slot, all six** | **62.39 MB** |

Incidental confirmation of scale from the same extracts: `SK_SCV_FL_OCT` is 50.9 MB,
`SK_SCV_FL_DSQ` 15.3 MB, `SK_SCV_FL_SPT` 12.7 MB. Base meshes are the *cheap* end.

Note the inverse correlation with demand: Gunhead and Shaman have the **smallest** rosters
(one base skin each, [00-findings.md:277](00-findings.md#L277)) and the **largest** meshes,
so reserving uniformly spends the most bytes on the characters least likely to be claimed.
Per-character pool depth, rather than one uniform N, is the cheap fix.

**This is a cost, not a constraint.** It was briefly written up here as though it reshaped
the design; it does not, and that framing is retracted. A few hundred MB is unremarkable for
a game mod — one shipped DLC skin is 50.9 MB — and v0.2 spends it once to retire v0.1's
per-change exe run, which is the entire point of the redesign. **Both offline rungs have now
passed and the placeholder design stands as written.** Proceed to probes 3–5.

### A note on rung 10

Rung 10 stays a long shot, where the ladder already had it. It is worth listing what it
would buy *besides* size, since those merits do not depend on the size argument:

- `LockedSkinChoices` is out of the respawn roll entirely, so slots there need no
  placeholder — which removes not just bytes but the correctness rule this document is
  built around, and with it the fail-open pruning logic.
- It is what the selector shows by default
  ([00-findings.md:288](00-findings.md#L288)), so CMSF slots would not depend on
  `CMSFUnlock` to be visible, and unclaimed slots would be statically invisible.

Against that: it may not be reachable at all. The question is **where ownership is decided**
— against the local tables, or against a Steam/EOS call. That is open question 4 in
[00-findings.md](00-findings.md) §"what is still unknown", and the `Skin.Girl.MAY` anomaly
is probably evidence about it.

It is also **not** free tooling, contrary to an earlier claim here. Both entitlement tables
are ordinary DataTables, but `skinpatch` cannot currently write them: `add` hardcodes the
`SkinDetails` row shape, while these need `GameplayTagTableRow` and `FWEntitlementTableRow`;
and `bpadd` appends to `SkinChoices`, a `TArray`, whereas `LockedSkinChoices` is a
`TMap<FGameplayTag, FSoftObjectPath>` with no map-write path at all. Two new commands before
the probe can even be built.

## The identity rule

**A cloned package must have its package identity rewritten, not just its filename and
export name.** Probe 3 failed the first time with `<MISSING STRING TABLE ENTRY>` on *every*
tile, including vanilla rows CMSF never touched.

`stgen` had renamed the file and the export, so the clone still carried
`/Game/FW/UI/StringTables/ST_FW_UI_Skins` as its own package name. Its `FPackageId`
therefore collided with the game's table and the loader served ours in its place — 42
entries replaced by 2. Every vanilla row missed its key, and the CMSF row pointed at a
package that had never actually been published.

That is the [README](../README.md) §"The problem" `FolderName`/`FPackageId` collision — the
mechanism the whole overwrite pipeline is built on, and the thing CMSF exists to avoid.
Generating a package by cloning an existing one recreates it by default.

Two fields carry the identity and **both** must be rewritten:

| | |
|---|---|
| the name-map entry holding the package path | the obvious one |
| **`FolderName`** | a separate summary field; rewriting the name map alone leaves the collision intact |

`stgen` now rewrites both and refuses to emit an asset still carrying the template's package
path. The same rule applies to any future CMSF generator that clones — including the
placeholder mesh path, where `mshprobe` renames the export but the eventual generator will
need the identity rewrite too.

**A `TableId` is a hard reference.** It serialises as a bare `FName` and declares no
dependency, so the string table package was not an import at all. [skinpatch's
header](../tools/skinpatch/Program.cs) notes that soft asset refs let appended rows skip the
import table, "unlike ScavgirlCarryPerks' skillpatch, which must synthesise an import chain
for hard object references" — a `TableId` needs exactly that chain, and `addst` now
synthesises it.

### Method note

`/Engine/UnknownPackage` in `to-legacy` output is **not** evidence of a corrupt pak. It also
appears for any package that simply is not mounted in the container set being decoded. It
was read as proof of corruption here and sent the first hour of diagnosis after `retoc`,
which turned out to be innocent.

The thing that actually resolved it was a **control**: CMSFUnlock with no CMSF pak at all,
which showed vanilla names rendering correctly and established in two minutes that the bug
was ours. Run the control before theorising about the mechanism.

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
