# Design — why CMSF is shaped the way it is

Read [00-findings.md](00-findings.md) first: it establishes that a skin needs both a roster
entry on the pawn component and a `DT_SkinUIData` row, and that both asset references are soft
paths. This document is about how those get in without mods clobbering each other.

## The constraint that shapes everything

A pak override replaces the **entire asset**. If two mods each ship their own edited
`DT_SkinUIData`, one wins and the other's rows vanish — silently, decided by pak load order. The
same is true of the six `BP_Player_*` Blueprints that carry the roster. So "every author ships a
pak that adds their row" **cannot work**: it is the same clobbering problem as the overwrite
pipeline, moved up one level.

Any composable design must therefore ensure **exactly one artifact owns each whole asset**, with
everything else arranged around that single owner.

### The hazard is staleness, not collision

A consequence that inverts the naive intuition: because CMSF's pak replaces the *whole*
`DT_SkinUIData`, a **stale CMSF table deletes the developers' new rows** — it does not lose to
them. Whoever owns the table must rebuild from the current cook on every game patch that touches
it. Staleness, not collision with official content, is the recurring hazard, and every CMSF
build tool re-extracts from the live cook for exactly this reason.

Because authors bind to an **asset path**, not a row name, the owner can renumber its own rows
during a patch rebase without breaking anything already shipped. That is what makes the single
owner maintainable.

## Three ways to get a skin in

**Static reserved-slot pool.** One framework pak owns `DT_SkinUIData` and the `BP_Player_*`
Blueprints and pre-provisions *N* reserved slots per character, whose soft paths point at
predictable, framework-owned package paths. An author ships an ordinary pak that places their
own assets at one slot's paths; they never touch the table.

- Composable — two authors claiming different slots coexist. Conflicts become a *detectable*
  condition (two mods at one slot), not a silent loss.
- The only runtime dependency is the one the selector forces anyway (below); no native
  DataTable-writing primitive.
- Costs: the pool is finite (though a slot is bytes, so reserve generously), and the framework
  owner rebases each patch.

**Runtime DataTable injection.** Each author ships a pak plus a manifest; a UE4SS mod reads the
manifests and injects rows into the live table at startup. Fully composable and unbounded, with
real per-skin names — but a `UDataTable`'s `RowMap` holds raw `uint8*` row memory, not reflected
UObjects, so Lua alone cannot append to it. It needs a **native** row-add primitive, which means
depending on a third-party binary that cannot be rebuilt outside its own project. Best end state
in the abstract; wrong foundation for a framework meant to outlive game patches.

**Widget-level injection.** Ignore the table; poll for the live `WBP_SkinSelection` and append
entries to its `SkinOptions` `WrapBox` directly. Pure Lua, no table ownership — but it must
re-implement selection, mesh application and persistence that the static approach gets from the
game for free, and it breaks on any widget/UFunction rename. Its real value is narrow: it can
rewrite a live tile's name and description, which is a graceful-degradation supplement, not a
foundation.

## Why runtime registration was rejected

The pure-runtime design is not pursued, on evidence rather than taste. The `FWSkinChangeComponent`
exposes the right-looking API, but every route to *writing* the roster from Lua failed, and the
last attempt **crashed the client** — an access violation inside the engine, because `SetNewSkin`
takes an object parameter and was handed the wrong kind of object.

The durable lesson: **`pcall` does not make native calls safe.** It catches Lua errors; it cannot
catch a C++ access violation — the process is gone before Lua sees anything. Wrapping a native
call in `pcall` and calling it defensive is false comfort. Combined with `SkinChoices` elements
being opaque userdata with no usable accessor, this rules out registering skins at runtime. The
only runtime operations proven safe on this game are **plain bool writes and no-argument UFunction
calls** — which is exactly, and only, what the selector filter needs.

## What CMSF ships

A **static reserved-slot pool**, with UE4SS Lua used solely to unlock and prune — never to
register.

| Layer | Mechanism |
|---|---|
| Roster | static pak — `SkinChoices` appends on each `BP_Player_<Char>` |
| Identity | static pak — appended `DT_SkinUIData` rows, name/description via per-slot string tables |
| Selector filter | UE4SS Lua (`CMSFUnlock`) — clear `SelectLockedSkinsOnly`, re-run `Init()` |
| Pruning | UE4SS Lua (`CMSFUnlock`) — hide unclaimed slot tiles |

Every operation is one observed working. The filter step writes only a **bool** and calls a
**no-argument** UFunction the game itself calls constantly — neither can type-confuse a native
call, which is where the crash came from.

`CMSFUnlock` is worth installing on its own: clearing `SelectLockedSkinsOnly` makes the game's
shipped **base skins selectable**, which vanilla never allows — normally, picking a DLC skin
strands you on it until you die in a raid and are randomly reassigned.

The costs are the ones the reserved-slot design was built to absorb: CMSF owns `DT_SkinUIData`
and the six `BP_Player_*` assets, so it rebases each game patch, and authors claim slots from a
registry rather than registering freely. Accepted, in exchange for a framework that never risks
the player's client and needs no unrebuildable native dependency. The full v0.2 distribution
design — reserved slots, frozen paths, the claim signal, and why the framework ships no
placeholder meshes — is in [05-v2-distribution.md](05-v2-distribution.md).

## Two distribution modes over one core

v0.1 and v0.2 are not two versions but two modes sharing `CMSFUnlock`:

- **v0.1** (`cmsf_build.py`) has the *end user* run a generator that merges every installed skin
  into one pak. Unbounded skins, no slot registry, no claim — at the price of re-running a tool
  after every change. It remains the rollback path and the private/local workflow.
- **v0.2** (`cmsf_framework.py` + `cmsf-author`) moves the build to the author: the user installs
  a small framework once, and each skin is an ordinary pak. This is the shipping design.

## Deferred / standing technical notes

- **Pak load order.** Order derives from the token between the last two underscores of a
  `_P.pak` name: numeric ≥1 → `ChunkVersionNumber = N+1`, `PakOrder += 100 × CVN`. A numeric
  *prefix* is inert. CMSF's framework ships at `_9_P`; an author's claim ships higher (`_11_P`)
  so it wins. Under Mod Organizer 2 the filename token is discarded entirely — left-pane
  priority decides — so a skin must sit **above** the framework there.
- **Signature bypass** (`dsound.dll` + `bitfix\`) is required for any content pak mod and is tied
  to the game build; it fails *silently* when a patch breaks the byte pattern.
- **Multiplayer** is a host-authoritative listen server over EOS P2P with no anti-cheat, and
  nothing validates paks at join. A skin crosses the wire as a **soft object path string**, so an
  appended skin reaches a peer without the pak as an unresolved/absent mesh — not a desync or a
  kick. Content mods need the pak on every peer that should see them. See
  [03-multiplayer.md](03-multiplayer.md).
