# v0.2 — moving the build to the author

v0.1 has the **end user** run a generator that merges every installed skin into one pak. That
falls out of a real constraint: `DT_SkinUIData` and `BP_Player_*` are whole-asset pak overrides
with exactly one owner ([01-design.md](01-design.md)), so *someone* must merge the installed set,
and the user's machine is the only place that set is fully known.

v0.2 resolves it by assigning ownership instead of merging. The framework owns both assets
permanently and pre-provisions capacity; authors claim into it.

| | v0.1 (shipped) | v0.2 (this design) |
|---|---|---|
| Author ships | pak + `skin.json` | pak + `skin.json` |
| User installs | every skin pak, + runs a generator | framework once, + skin paks |
| User runs an exe | yes, after every change | no |
| Skins per character | unbounded | finite, growable pool |

## Why the pool works

Two properties make a reserved slot able to carry an author's skin without the author touching
any shared asset:

**A framework-owned row can carry an author-owned name, via string-table indirection.** The
row's `SkinName`/`SkinDetails` are references to a per-slot string table
(`ST_CMSF_<Char>_<NN>`), not inline text. The framework ships a sentinel table ("unclaimed"); an
author overrides *that asset* at its frozen path. The row never changes, and no runtime text
write is needed.

**An unresolvable soft path is a silent no-op.** This is the finding that shapes the whole
framework. A reserved slot's `Skin`/`SkinIcon` point at paths where nothing is shipped until an
author claims it. That resolves to nothing in *both* code paths — the selector simply doesn't
show it, and the random respawn roll keeps the skin the player already has. No broken model, no
invisible model, no crash.

That second property is not obvious, because **`SkinChoices` is also the random respawn pool**
([00-findings.md](00-findings.md#what-the-selector-actually-shows)), not only the selector
roster. Reserve *M* paths per character and the respawn roll draws from them at roughly
`M / (M + real)` — at any real pool depth, most tunnel respawns land on a reserved path. Were an
unresolved path to break the player model, the framework pak alone would degrade vanilla
behaviour for every user with **zero skin mods installed**. It was tested directly: with 15 of 16
roster entries repointed to dead paths and no base mesh reachable, deaths that rolled a dead path
simply kept the current skin, and a death that rolled the one live CMSF slot applied that skin.
Reserved capacity really is inert.

The consequence: **the framework ships no meshes and no portraits.** A reserved slot is a
DataTable row, a roster entry, and a ~1 KB sentinel string table — bytes, not megabytes. Pool
depth is a namespace decision, not a download-size one, so reserve generously. (A *claimed*
slot's mesh costs whatever any skin mod's mesh costs — the author's concern, not the framework's.)

## Architecture

### The framework release — user installs once

Owns `DT_SkinUIData` and all six `BP_Player_*` outright. Per slot `<Char>/<NN>` it bakes:

- a row `CMSF.<Char>.<NN>` whose `SkinName`/`SkinDetails` are **string-table references** to
  `/Game/CMSF/<Char>/<NN>/ST_CMSF_<Char>_<NN>`, and whose `SkinIcon`/`Skin` are soft paths to
  `T_CMSF_<Char>_<NN>` and `SK_CMSF_<Char>_<NN>`;
- the matching `SkinChoices` append on `BP_Player_<Char>`;
- a ~1 KB sentinel string table — **no mesh and no portrait.**

Plus `CMSFUnlock` (the runtime, below).

### The author's pak — one per skin

Exactly three packages at the slot's frozen paths, at a higher load order:
`SK_CMSF_<Char>_<NN>`, `T_CMSF_<Char>_<NN>`, `ST_CMSF_<Char>_<NN>`. Higher load order wins all
three together, so a skin arrives coherently or not at all — never a name without its mesh.

Authors never ship `DT_SkinUIData` or `BP_Player_*` — that is what makes two CMSF skins coexist.
`skin.json` is a build-time input and never ships; the user installs pak trios only, no manifest,
no config, no exe. The author tool enforces both rules mechanically (see
[07-authoring-v2.md](07-authoring-v2.md)).

### The runtime — hide and unlock, never create

`CMSFUnlock` keeps its proven core (clear `SelectLockedSkinsOnly`, re-run `Init()`), and
additionally collapses unclaimed slot tiles. It uses only plain-type property writes and the
`SetVisibility` UFunction, which takes a `uint8` enum by value and so cannot type-confuse a
pointer — the same safe class as the bool write. Registration at runtime stays impossible and
unattempted: `RowMap` is raw memory, roster elements are opaque userdata
([01-design.md](01-design.md)).

## The claim signal

`CMSFUnlock` decides a tile is unclaimed by reading two properties off the `WBP_SkinButton_C`
tile itself — no filesystem scan, no manifest, no author filename convention:

| Property | Gives |
|---|---|
| `SkinRow` (`FDataTableRowHandle`) | `RowName` — the tile's exact DataTable row |
| `SkinIcon` (`UImage`) | `Brush.ResourceObject` — the texture that actually resolved |

A slot's icon path is frozen, so the **expected** value is derived from the row name
(`CMSF.Girl.00` → `/Game/CMSF/Girl/00/T_CMSF_Girl_00`). An author claims the slot by shipping a
package there, so the tile is unclaimed exactly when its icon does **not** match. The test is
"does it match," never "is it null": bare slots resolve to an unrelated character's portrait,
because `WBP_SkinButton_C` instances are pooled across the four ready-room panels and a failed
resolve leaves the previous brush in place.

**This forecloses sentinel portraits, and is the second reason the framework ships no textures.**
A texture at a slot's own icon path reads as a *claim* and would never prune. So an unclaimed slot
must ship nothing at its icon path — which the inertness finding already made safe.

Pruning fails open: it hides a tile only on a *positive* reading (row parses as `CMSF.<Char>.<NN>`,
icon readable, icon does not match). Anything unreadable leaves the tile visible, because a stray
placeholder tile is always better than a hidden real skin. `cmsfnoprune` is the user-facing escape
hatch and does not disturb the unlock. A v0.1 registered skin can never be pruned — its row uses a
folder id, not the two-digit slot pattern.

### The claim race

A tile's icon is not correct the instant the menu populates: on first population it still holds
the stale pooled texture, and the author's real texture lands a beat later. So the first prune
pass reads a *claimed* slot as unclaimed and hides it. The fix is that the prune pass is
**bidirectional** — it drives every CMSF tile to its correct state on each poll, rather than only
ever collapsing, so a transient misread self-corrects on the next pass instead of persisting for
the session.

The logged counts are **per panel**: with a 192-slot framework and one claim, `hid 128` is
32 × 4 panels, and `restored 4` is one claim × 4 panels — the expected shape, not a scaled-up
race. Cost to the user: a claimed slot is missing for up to one poll (~1 s) after the menu opens,
then appears. Deferring the first hide would instead make dozens of unclaimed tiles visibly
collapse, a larger flinch, so it is left as is.

## Slot paths are a permanent public ABI

`/Game/CMSF/<Char>/<NN>/` is **append-only, never renumbered.** That promise is what lets an
author's pak survive every framework rebuild untouched: on a game patch the maintainer rebuilds
the framework from the fresh cook (a stale table would delete the developers' new rows), and
authors do nothing. Slot numbers are two digits by ABI — `CMSFUnlock` matches `CMSF%.%a+%.%d%d` —
so 100 is the hard cap; the shipped depth of 32 leaves room to extend, though extending costs
every user a framework re-download, so it is done sparingly.

## The identity rule

Any tool that clones a cooked package must rewrite its package identity — **both** the name-map
package entry **and** the separate `FolderName` summary field. Miss either and the clone keeps its
template's package name, its `FPackageId` collides with the template, and the loader serves the
clone in the template's place. This is the exact `FolderName`/`FPackageId` mechanism the overwrite
pipeline is built on and CMSF exists to avoid; cloning a package recreates it by default. The
generators (`stgen`, `mshgen`, and the `cmsf-author` clone step) rewrite both and refuse to emit a
package still carrying the template's path.

A related trap: a `TableId` is a **hard reference** that serialises as a bare `FName` and declares
no dependency, so a string-table clone is not an import and `to-zen` emits a broken import table
unless the chain is synthesised. `skinpatch addst` handles this. And when diagnosing:
`/Engine/UnknownPackage` in `to-legacy` output is **not** proof of corruption — it also appears
for any package not mounted in the set being decoded. When something breaks, run a control (e.g.
`CMSFUnlock` with no CMSF pak) before theorising about the mechanism.

## What v0.1 keeps

v0.1 is not superseded. It remains the **rollback path** (if the string-table channel ever
regressed, v0.1 is the shipping design), the **unbounded-skin mode** for users willing to run the
generator, and the **private/local workflow** that needs no slot claim. Both modes share
`CMSFUnlock`. Treat them as two distribution modes over one core.

## Rejected alternatives

- **Runtime registration (the "Lua way").** Retired on safety grounds — `pcall` does not catch a
  C++ access violation, and every roster-write route failed or crashed ([01-design.md](01-design.md)).
  Its *distribution model* was never the problem, and is what v0.2 recovers by static means.
- **Composite DataTable registry.** `UCompositeDataTable.ParentTables` holds **hard** object
  references resolved by `FPackageId`, re-entering the exact identity surgery CMSF exists to
  escape, and it serialises a combined `RowMap` at cook time so author overrides need never take.
- **Per-author `DT_SkinUIData` edits.** The known-fatal baseline: the last pak loaded silently
  erases every other author's skins.
- **Unattended repathing of third-party paks.** `to-legacy` needs the full game mounted or
  skeleton/material imports go null, and the rename pass has silent misses that surface only as a
  T-pose in game. v0.2 avoids needing it — authors cook at the slot path from the start.

## Behaviour worth documenting for users

Removing a skin mod *while wearing it* replays the first-spawn cutscene and rolls a fresh skin
from the pool, landing on a default — harmless, consistent with the inertness finding, confirmed
on the `SaveGame` path, but surprising enough to belong in the user-facing notes.
