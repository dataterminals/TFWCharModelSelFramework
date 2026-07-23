# How The Forever Winter drives skin selection

Everything here was decoded from the shipped paks (UE 5.4.2) with the
[`forever-winter-datamine`](https://github.com/dataterminals/forever-winter-datamine) CUE4Parse
decoder and the game's own `.usmap`. Anything not confirmed by an in-game observation is called
out as an inference; the rest was read directly out of a dump or watched happening in-game.

To reproduce a dump:

```bash
python -m fwdata get "DT_SkinUIData,DT_Entitlements,DT_EntitlementTags,DD_Player_,WBP_SkinSelection,GA_Player_ChangeSkin"
```

## The short version

A selectable skin needs **two** things, in two different places:

1. its mesh present in the character's **roster** — `SkinChoices` / `LockedSkinChoices` on the
   pawn Blueprint's `FWSkinChangeComponent` (§"The roster"), and
2. a **`DT_SkinUIData` row** whose `Skin` path points at that mesh, supplying the display name,
   description and portrait (§"The presentation table").

The selector iterates table rows and shows a row when its `Skin` path is in the character's
roster — not the other way round. Neither half alone appears. `DT_SkinUIData` is **not** the
roster, and appending a row to it does not by itself make a skin available; that was the first
wrong assumption this project corrected, proven by a live table with extra rows the selector
still ignored.

Both asset references in a row are **soft object paths**, resolved by string at load, so a row
can point at assets that were never part of the game — which is the whole reason appending is
possible without package-identity surgery.

## The presentation table — `DT_SkinUIData`

`/Game/FW/Player/Data/DT_SkinUIData`, RowStruct `SkinDetails` from `/Script/FWGameCore`. A
search of all packaged paths for `skin` returns only this table and one localisation string
table (`ST_FW_UI_Skins`); there is no second registry. It supplies a skin's **name and icon**,
keyed off the mesh path, and nothing else — the character definitions (`DD_Player_*`) carry no
skin data at all.

`FSkinDetails` has four fields, and both asset refs are soft:

| Field | Type | Role |
|---|---|---|
| `SkinName` | `FText` | string-table ref **or** inline literal |
| `SkinDetails` | `FText` | description; same |
| `SkinIcon` | `FSoftObjectPath` | character-select portrait |
| `Skin` | `FSoftObjectPath` | skeletal mesh |

A base row uses the string table; a recent DLC row uses **inline literal `FText`** with no
string-table entry required:

```json
"ScavGirl0": {
  "SkinName":    { "TableId": "/Game/FW/UI/StringTables/ST_FW_UI_Skins.ST_FW_UI_Skins",
                   "Key": "Skin_AllChars_Default_01_Name", "SourceString": "Default Skin 1" },
  "SkinIcon":    { "AssetPathName": "/Game/UI/Textures/MainMenu/Menu/T_Menu_PickCharacter_Portrait_ScavGirl.T_Menu_PickCharacter_Portrait_ScavGirl" },
  "Skin":        { "AssetPathName": "/Game/Character/Scavengers/Female/SK_SCV_FL.SK_SCV_FL" }
}

"Skin.Girl.MAY": {
  "SkinName":    { "Namespace": "", "Key": "007683904154CDB942807086A1D0CF64", "SourceString": "Scav Female May" },
  "SkinIcon":    { "AssetPathName": ".../T_Menu_PickCharacter_Portrait_DLC04_Scavgirl..." },
  "Skin":        { "AssetPathName": "/Game/Character/Scavengers/Female/Skins/MAY/SK_SCV_FL_May.SK_SCV_FL_May" }
}
```

Three consequences, and they are why appending is worth doing:

1. `Skin` and `SkinIcon` are **soft paths resolved by string at load**, so a row may point at a
   package that only exists inside a mod's own pak — no `FPackageId` collision engineering, no
   repathing, no `FolderName` header patching.
2. `SkinIcon` is **per-row**, so an appended skin gets its own correct portrait. The
   "thumbnail lies" defect of the overwrite approach does not exist here.
3. `SkinName` / `SkinDetails` accept **inline literals** (proven by the DLC rows), so a mod
   supplies its own name and description without touching `ST_FW_UI_Skins`.

There is no entitlement, ownership, DLC, or owning-character field anywhere in the row struct.

### Two naming conventions

The 33 shipped rows use two eras of convention, and they disagree on the character token:

- **Legacy / base:** `<Character><N>`, sequential from `0` (`ScavGirl0`–`4`, `Bagman0`–`3`,
  `MaskMan0`–`2`, `OldMan0`–`1`, `Shaman0`), plus ad-hoc suffixed names for older unlockables.
- **Current:** dotted, GameplayTag-shaped `Skin.<Character>.<Name>`.

Note `ScavGirl0` but `Skin.Girl.MAY` — a naive prefix match on `ScavGirl` misses every dotted
row, so per-character grouping is not pure prefix matching on one token.

## The roster — `FWSkinChangeComponent` on the pawn

Every playable character's pawn Blueprint (`/Game/FW/Player/Class/BP_Player_<Char>`) carries an
`FWSkinChangeComponent` whose template holds the actual roster:

| Property | Type | Role |
|---|---|---|
| `SkinChoices` | `TArray<FSoftObjectPath>` | free pool — the random respawn roll. **Not menu-selectable by default.** |
| `LockedSkinChoices` | `TMap<FGameplayTag, FSoftObjectPath>` | entitlement-gated — **this is what the selector shows** |

`BP_Player_Girl`, in full:

```
SkinChoices (5)          SK_SCV_FL, SK_SCV_FL1 .. SK_SCV_FL4
LockedSkinChoices (3)    Entitlement.Skin.Girl.BlindFang    -> Skins/SPT/SK_SCV_FL_SPT
                         Entitlement.Skin.Girl.Dec2025      -> Skins/DEC/SK_FL_SCV_DEC
                         Entitlement.Skin.Girl.April2026.DSQ-> Skins/DSQ/SK_SCV_FL_DSQ
```

Per-character counts: BagMan 4/1, Girl 5/3, Gunhead 1/3, MaskMan 3/3, OldMan 2/2, Shaman 1/3
(`SkinChoices`/`LockedSkinChoices`).

Both are ordinary reflected UPROPERTYs on a `UActorComponent`, **not** a `UDataTable`'s raw
`RowMap`. So they are reachable from UE4SS Lua by the same reflection other mods already use on
this game — no native `AddDataTableRow` primitive is required, and no dependency on a native
DataTable-writing binary.

### What the selector actually shows

`WBP_SkinSelection.SelectLockedSkinsOnly` selects which array feeds the selector. Measured live:

| `SelectLockedSkinsOnly` | Selector shows | Composition |
|---|---|---|
| `true` (default) | 2 entries | owned `LockedSkinChoices` only |
| `false` (cleared) | 7 entries | 5 `SkinChoices` + 2 owned locked |

So the shipped **base skins are not selectable at all** by default: the menu offers only
entitlement-gated DLC skins, and once a DLC skin is picked there is no UI route back. A base
skin reappears only when you **die in a raid and respawn**, at which point the game randomly
assigns one from `SkinChoices`. `DT_SkinUIData` therefore feeds two consumers:

| Consumer | Rows it uses | Reached how |
|---|---|---|
| Skin **selector** UI | entitlement-gated only (until the filter is cleared) | player picks |
| Random respawn roll | base `SkinChoices` (and DLC) | assigned on tunnel respawn |

Having no entitlement tag does not make a row free — it makes it **invisible to the selector**,
leaving only the random pool. This is why appending a row is necessary but not sufficient, and
why clearing `SelectLockedSkinsOnly` (what `CMSFUnlock` does) is what makes appended — and base
— skins selectable at all.

### How the two halves join

Repointing `SkinChoices[4]` from `SK_SCV_FL4` to the cut mesh `SK_SCV_FL_OCT`, and shipping two
`DT_SkinUIData` rows both pointing at that mesh, with the filter cleared: **both** rows appeared
as separate named entries, `ScavGirl4` disappeared (its mesh left the roster), total 8. From
that:

1. **A skin needs both halves** — mesh in the roster *and* a row pointing at it.
2. **Row names are free.** A dotted `CMSF.Girl.TEST` rendered correctly, so a `CMSF.*` namespace
   is safe from collision with official row names.
3. **Many rows may share one mesh** — one shipped mesh can back several named menu identities.

`SkinName` / `SkinDetails` inline `FText` rendered verbatim, confirming a mod supplies its own
strings with no string-table edit.

### The component's API

Reflected off a live `FWSkinChangeComponent` (superclass `ActorComponent`):

```
fn SetSelectedSkin   fn GetUnlockedSkins   fn OnRep_UpdateSkin
fn SetNewSkin        fn GetAvailableSkins  fn OnDeath
fn ForceUpdateSkin
prop SkinChoices  prop LockedSkinChoices  prop SaveGame  prop SelectedSkin  prop OnChangedSkin
```

`GetAvailableSkins` is the natural feed for the selector, `SetNewSkin` / `ForceUpdateSkin` the
apply path, `OnDeath` presumably the random reassignment on respawn (inference). `SaveGame` on
the component is where skin persistence lives.

Two Lua caveats learned the hard way, both load-bearing for any runtime approach:

- `SkinChoices` elements come back as opaque `TSoftObjectPtrUserdata`; guessed accessors
  (`.AssetPathName`, `:GetFullName()`, `:get()`) return the element itself or error. Enumerate
  the metatable rather than guessing.
- Handing a loaded asset to `SetNewSkin` crashed the client with an access violation, and
  `pcall` does **not** catch a C++ access violation. Plain bool writes and no-argument UFunction
  calls are the only operations proven safe on this component.

## Entitlement gating is external and tag-based

Two DataTables, neither of them the skin registry:

- **`DT_Entitlements`** (15 rows) maps a store SKU or gift to a list of tags, e.g. `dlc:3651810`
  → `Entitlement.Skin.Bagman.LoadBreaker`, `Entitlement.Skin.Girl.BlindFang`, ...
- **`DT_EntitlementTags`** (19 rows) defines the tags.

For current-era skins the `DT_EntitlementTags` row name equals the `DT_SkinUIData` row name, and
the tag is that name prefixed with `Entitlement.` (`FName` comparison is case-insensitive, so
`May`/`MAY` are the same key). Every `<Character><N>` base row has no entitlement counterpart at
all — consistent with base skins being reachable only through the respawn roll, not the
selector.

Whether the player *owns* a tag is presumably resolved against Steam/EOS, which a data table
cannot fake. But some entitlements are granted by in-game achievement rather than purchase (the
`GIFT.*` rows), which hints a **local** grant path exists — the one route by which a data-only
mod could make a slot selectable without clearing the selector filter. Chasing it is the only
open question that could remove the runtime dependency entirely; it is not needed for the
shipping design.

## What is not in any data asset

The per-character grouping and enumeration logic lives in Blueprint bytecode
(`WBP_SkinSelection` / `WBP_CharacterSelection`) or native `/Script/FWGameCore`, which CUE4Parse
does not decompile. The readable structure of `WBP_SkinSelection`: functions `Init`, `Construct`,
`SkinSelected`, `HoverSkin`; widgets `SkinOptions` (a `WrapBox` populated at runtime), `SkinIcon`,
`SkinNameText`, `SkinDescription`, `UseSkinButton`; and the CDO property `SelectLockedSkinsOnly:
true`. The applier is `/Game/FW/Player/GameplayAbilities/GA_Player_ChangeSkin`.

One loose end worth resolving before assuming `LockedSkinChoices` is the complete gate:
`DT_SkinUIData` contains `Skin.Girl.MAY`, but `LockedSkinChoices` has no May entry — only 3 of
Girl's 4 DLC skins. Either May is wired up by another path, or it shipped in the table ahead of
the component.

## A free test subject — `SK_SCV_FL_OCT`

A complete, cooked Scav Girl skin ships in the paks — mesh, its own skeleton, material instance,
all three texture maps — with **no `DT_SkinUIData` row pointing at it**, so it is invisible for
exactly one reason. That makes it a clean single-variable subject for the experiment that first
established the roster mechanism, without cooking any new art. See
[02-poc.md](02-poc.md). (The mesh itself is a visibly unfinished cut skin, which is presumably
why it shipped unwired — irrelevant to the mechanism.)
