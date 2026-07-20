# Design — injection vectors

Read [00-findings.md](00-findings.md) first. This document is about *how* rows get in.

## The constraint that shapes everything

A pak override replaces the **entire asset**. If two mods each ship their own edited
`DT_SkinUIData`, one wins and the other's rows vanish — silently, decided by pak load order.

So "every modder ships a pak that adds their row to the table" **cannot work**. It is the
same clobbering problem as today, moved up one level.

Any viable design must ensure **exactly one artifact owns `DT_SkinUIData`**, with everything
else composing around it.

Corollary: whoever owns the table must rebase on each game patch. A patch that adds a DLC
skin row would be reverted by a stale override. `FWBehaviorLab`'s discipline applies —
always rebuild from the current cook, never from a committed snapshot.

This cuts against the intuition that CMSF's rows are at risk of being *overwritten* by
official content. The direction is inverted: **a stale CMSF table deletes the developers'
new rows, not the reverse.** Staleness, not collision, is the recurring hazard — and it is
the price of Vector A+'s no-runtime-dependency design. Vector B does not pay it, which is
the main argument for eventually migrating.

---

## Vector A — naive static pak

Ship a modified `DT_SkinUIData` with extra rows appended.

- ✅ No runtime code, no UE4SS, no ABI risk. Simplest thing that could work.
- ❌ **Not composable.** One mod per table. Fails the actual goal.

Useful only as the PoC harness. See [02-poc.md](02-poc.md).

## Vector A+ — reserved slot pool ★ recommended

**CMSF owns `DT_SkinUIData` exactly once** and appends *N* reserved rows per character whose
soft paths point at predictable, framework-owned package paths that ship empty:

```
Row  ScavGirl5
  Skin      -> /Game/CMSF/ScavGirl/05/SK_CMSF_ScavGirl_05.SK_CMSF_ScavGirl_05
  SkinIcon  -> /Game/CMSF/ScavGirl/05/T_CMSF_ScavGirl_05.T_CMSF_ScavGirl_05
```

A skin mod then ships an ordinary pak that places **its own mesh and portrait at those two
paths**. It never touches the table. No `FPackageId` games — the paths are genuinely the
mod's own assets, and soft paths resolve by string.

- ✅ **Composable.** Two mods claiming different slots coexist cleanly.
- ✅ **Zero runtime code.** No UE4SS, no TFWWorkbench, no ABI pin, no signature-bypass
  dependency beyond what pak mods already need.
- ✅ Custom portrait per skin, for free.
- ✅ Conflicts become *detectable*: two mods claiming slot 05 is a checkable condition, not
  a silent loss.
- ⚠️ Pool size is fixed at build time — but rows are tiny, so reserve generously (64+ per
  character costs nothing).
- ⚠️ **Display name and description are baked into the reserved row.** Slots would read
  "CMSF Slot 05" rather than the skin's real name, because `FText` lives in the row, not at
  a soft path we can redirect. This is the one real cosmetic wart.

The name wart has a clean fix that composes on top — see Vector C.

Slot **naming** depends on open question 1 in the findings doc. If enumeration is
`<Character><N>` sequential, reserved rows must continue the base sequence
(`ScavGirl5`, `ScavGirl6`, …), which conveniently also keeps them outside the entitlement
namespace and therefore free. If it is a full row scan, reserved rows can live under a
`CMSF.*` namespace instead, where the developers will never collide with them. The PoC
answers this directly — see [02-poc.md](02-poc.md) §Naming.

Note that **row names are internal to CMSF**. Mods bind to the *asset path*, so CMSF can
renumber rows during a patch rebase without breaking anything already shipped. This is what
makes an occasional name collision cheap rather than structural.

## Vector B — runtime DataTable row injection

Each skin mod ships a pak (own assets, own paths) plus a small JSON manifest. A UE4SS mod
reads all manifests at startup and injects rows into the live `DT_SkinUIData`.

- ✅ Fully composable, unbounded, and **real per-skin names** — no slot pool, no wart.
- ❌ Needs a **native** row-add primitive. A `UDataTable`'s `RowMap` holds raw `uint8*`
  row memory, not reflected UObjects, so UE4SS Lua alone almost certainly cannot append to
  it. This is presumably exactly why TFWWorkbench implements `AddDataTableRow` in C++.
- ❌ Depending on TFWWorkbench inherits its fragility: the UE4SS `-894` pin, and a
  `main.dll` that **cannot be rebuilt** by anyone outside the project (the UEPseudo
  submodule is private). See `tfworkbench-compat-research`.

Viable, and the best end state, but it puts a load-bearing dependency with a known
unrebuildable binary underneath a framework meant to outlive game patches. Not where to
start.

## Vector C — widget-level injection

Ignore the table. Poll for the live `WBP_SkinSelection` instance and append entries to its
`SkinOptions` `WrapBox` directly, then hook `SkinSelected` to apply the mesh.

- ✅ Pure UE4SS Lua, no native dependency, no table ownership at all.
- ✅ The polling pattern is **already proven on this exact game** — `TFWQuestItemTag` polls
  for live widgets and rewrites `TextBlock` text; `FWStealth` polls and writes properties
  via reflection.
- ❌ Must re-implement selection, mesh application (`GA_Player_ChangeSkin`), and
  persistence across sessions — all of which Vector A+ gets for free from the game.
- ❌ Breaks on UFunction/widget renames at any patch.

**Its real value is as a supplement:** Vector C can fix Vector A+'s only wart. When a CMSF
slot is displayed, rewrite `SkinNameText`/`SkinDescription` on the live widget from the
mod's manifest. That is precisely the `TFWQuestItemTag` mechanism, and if the Lua half is
absent or broken the skins still work — they just show generic names. **Graceful
degradation, no hard dependency.**

---

## Recommendation

**A+ as the mechanism, C as optional polish, B as the eventual end state.**

```
A+  static pak, CMSF owns DT_SkinUIData, reserves N slots per character
 +  C   optional Lua that names the slots properly at runtime
 →  B   migrate when/if a rebuildable native row-add primitive exists
```

This gets a working, composable, DLC-free, custom-portrait framework with **no runtime
dependency at all**, and leaves the pretty-names problem to an optional component that
cannot take the system down with it.

## REVISION 2026-07-20 — the target moved

Everything above targets `DT_SkinUIData`. **That was the wrong asset.** The PoC proved it:
our two rows reached the live table (35 rows confirmed at runtime) and the selector still
offered exactly the vanilla set.

The roster is `FWSkinChangeComponent.SkinChoices` / `.LockedSkinChoices` on each
`BP_Player_<Char>` — see [00-findings.md](00-findings.md) §7. `DT_SkinUIData` only supplies
the display name and icon, keyed off the mesh path.

**Vectors A / A+ / B as written above are obsolete** — they all solve "get a row into a
DataTable", which is not the problem. What survives is more useful than what it replaces:

### What the correction buys

- **The composability constraint is gone.** The reason A+ existed was that a pak override
  clobbers a whole DataTable, so only one artifact could own it. Appending to a *reflected
  array at runtime* has no such limit — every mod's entries coexist. **No reserved slot
  pool, no fixed pool size, no slot-allocation registry, no "CMSF Slot 05" naming wart.**
- **The native dependency is gone.** A `UDataTable`'s `RowMap` is raw row memory, which is
  why Vector B needed TFWWorkbench's C++ `AddDataTableRow`. `SkinChoices` is an ordinary
  `TArray<FSoftObjectPath>` UPROPERTY, reachable by the same Lua reflection `FWStealth`
  already uses here. **No TFWWorkbench, no `-894` ABI pin, no unrebuildable `main.dll`.**
- **The staleness hazard is gone.** Nothing gets pak-overridden, so CMSF no longer deletes
  rows a patch adds, and no longer owes a rebase every patch.

### The shape it wants now

```
UE4SS Lua mod, at runtime:
  1. append each registered skin's mesh path -> FWSkinChangeComponent.SkinChoices
  2. clear WBP_SkinSelection.SelectLockedSkinsOnly so the selector shows that array
  3. ensure DT_SkinUIData has a row whose Skin path matches, for name + icon
Skin mods ship: an ordinary pak (own mesh + icon at own paths) + a small manifest.
```

Step 3 is the only part still wanting a table write. It may not need one — if the selector
falls back gracefully when no row matches, a skin could ship nameless-but-working, with the
name applied by the `TFWQuestItemTag` live-TextBlock trick instead.

### A side effect worth having

Step 2 makes the **shipped base skins selectable at all** — which they currently are not.
Today, picking a DLC skin strands you there until you die in a raid and get randomly
reassigned. That is a real annoyance CMSF would fix incidentally, independent of any custom
skin.

### Open before building

- Can Lua **append** to a `TArray<FSoftObjectPath>`, or only mutate existing elements? The
  probe's `cmsfadd` tests overwrite-in-place first because that is likelier to work; append
  is what the framework actually needs.
- Is the component **per-pawn-instance** (patch each spawn) or is the class default enough?
  `bReplicates = true` means skin state syncs — check against
  [03-multiplayer.md](03-multiplayer.md) before assuming client-side-only.
- Does `LockedSkinChoices` gate on a tag the player **owns**, and is ownership
  platform-resolved? If a tag can be granted locally, that is a second, tidier route than
  disabling the filter.

## Superseded — the selector filter changes the calculus

The first in-game run (2026-07-20) showed no new skin, and the reason is not the
enumeration question this PoC was built to answer. It is that **the skin selector only
offers entitlement-gated skins at all** — see [00-findings.md](00-findings.md) §4. Adding a
row is necessary but not sufficient.

Three ways forward, and the choice matters because two of them cost Vector A+ its main
advantage:

**(a) Grant an entitlement.** Add a row to `DT_EntitlementTags` (also a plain DataTable,
RowStruct `GameplayTagTableRow`) matching the skin row's name. Data-only, so it would keep
CMSF runtime-free. **But** whether the player *owns* the tag is presumably resolved against
EOS/Steam, which a data table cannot fake. The `GIFT.*` rows
(`GIFT.ThunderDome.ThiefSkin.Win` → `Entitlement.PlayerUpgrade.ThunderdomeWin`,
`GIFT.Anniversary.Skin.Maskman`) prove some entitlements are granted by **in-game
achievement**, not purchase — so a local grant path exists. Worth understanding before
ruling this out, since it is the only option that preserves a no-dependency design.

**(b) Disable the selector's filter.** `WBP_SkinSelection`'s CDO carries
`SelectLockedSkinsOnly: true`. Clearing it may make the selector list every row for the
character, appended ones included. Two ways to do it: a **static pak override of the widget
Blueprint's CDO** (keeps CMSF runtime-free, but overriding a widget BP is far more
patch-fragile than a DataTable), or **UE4SS at runtime** (easy and robust to asset changes,
but reintroduces the runtime dependency). Being tested by `probe/` (`cmsfunlock`).

**(c) Widget-level injection — Vector C.** Now considerably more attractive than when it
was written as a fallback, because the selector must be touched *anyway* under (b).

Note that (b) and (c) both need UE4SS, which removes "no runtime dependency" as a reason to
prefer A+. If the filter cannot be cleared statically, the honest comparison is between
"A+ plus a runtime filter patch" and "Vector B done properly" — and B is the better system
if a runtime dependency is being paid for regardless.

**Do not pick until the probe reports.** If the live table shows 35 rows, appending itself
works and only the selector is in the way; if it shows 33, there is a deployment bug to fix
first and none of this applies yet.

## Deferred / unresolved

- **Pak load order.** Ordering is derived from the token between the last two underscores
  of a `_P.pak` name: numeric ≥1 → `ChunkVersionNumber = N+1`, `PakOrder += 100 × CVN`. A
  numeric *prefix* does nothing. CMSF's table pak must outrank casual mods —
  `CMSF_9_P.pak` → order 1003. (Source: `ForeverWinterMO2Support` ARCHITECTURE.md, verified
  in-game 2026-07-16.)
- **Signature bypass** (`dsound.dll` + `bitfix\`) is required for any pak mod and is tied
  to the game build. It fails *silently* when a patch breaks the byte pattern.
- **Multiplayer behaviour is resolved** — see [03-multiplayer.md](03-multiplayer.md).
  Co-op is a host-authoritative listen server over EOS P2P with no anti-cheat, and nothing
  validates paks at join. Nothing server-side validates cosmetics. The CMSF-relevant part:
  a skin crosses the wire as a **soft object path string** (`BP_PlayerBase`'s
  `SERVER`/`CLIENTS Skin Has Changed`), so an appended skin reaches peers as a path they
  cannot resolve without the pak — a fallback/absent mesh, not a desync or kick. Content
  mods need the pak on every peer that should see them. Structural evidence only; the
  two-client test has not been run.
- **Editing the table.** `ScavgirlCarryPerks`' UAssetAPI `skillpatch` tool is the closest
  existing precedent for synthesising cross-package references and is the likely starting
  point for the table builder.
