# Findings — how TFW drives the skin selection screen

**Provenance.** All facts below were decoded from the shipped paks on 2026-07-20.

| | |
|---|---|
| Game build | `24097213` (Steam `buildid`; paks dated 2026-07-07) |
| Engine | UE 5.4.2 |
| Mappings | `ForeverWinter-5.4.2.usmap` |
| Paks | `H:\SteamLibrary\steamapps\common\The Forever Winter\Windows\ForeverWinter\Content\Paks` |
| Tool | `forever-winter-datamine` → `python -m fwdata get <name>` (prebuilt `fwextract.exe`) |
| Files mounted | 76,589 |

> Caveat: `fwdata` stamps its cache dir and catalogs from a **hardcoded** `GAME_BUILD` in
> `fwdata/version.py`, which still reads `24045295` and was never bumped after the
> 2026-07-07 patch. The dumps below were decoded from the live paks and are current for
> `24097213`; only the cache label is stale. Also note `fwdata/paths.py` hardcodes a `D:`
> paks path, so `FW_PAKS` must be exported on this machine.

Reproduce with:

```bash
cd "H:/Github Repositories/forever-winter-datamine"
export FW_PAKS="H:/SteamLibrary/steamapps/common/The Forever Winter/Windows/ForeverWinter/Content/Paks"
python -m fwdata get "DT_SkinUIData,DT_Entitlements,DT_EntitlementTags,DD_Player_,WBP_SkinSelection,GA_Player_ChangeSkin"
```

Claims are tagged **[VERIFIED]** (read directly out of a dump) or **[INFERRED]** (a
reasonable reading that has *not* been tested in-game). Do not promote an inferred claim
without an experiment.

---

## 1. ~~There is exactly one skin registry~~ — CORRECTED 2026-07-20

> **This section's headline was wrong.** `DT_SkinUIData` is the **presentation** table —
> it supplies a skin's display name and icon. It is **not** the roster, and appending rows
> to it does not make a skin available. The real roster lives on each character's pawn
> Blueprint; see **§7**. Everything below about the table's *structure* is accurate and
> still matters, because a CMSF skin does need a row here to be named and pictured. It is
> necessary, not sufficient.
>
> Proven in-game: with our two extra rows confirmed live in the table (35 rows), the
> selector still offered exactly the vanilla set.

`/Game/FW/Player/Data/DT_SkinUIData` — 33 rows, RowStruct `Class'SkinDetails'` from
`/Script/FWGameCore`.

Searching all 76,589 packaged file paths for `skin` returns only two data assets:

```
ForeverWinter/Content/FW/Player/Data/DT_SkinUIData.uasset
ForeverWinter/Content/FW/UI/StringTables/ST_FW_UI_Skins.uasset   (localization only)
```

There is **no** per-character skin roster asset, and no second registry. This one table
gates every selectable skin in the game.

Supporting negative result: `DD_Player_Girl` (the Scav Girl character definition) contains
no skin array whatsoever. Its entire `UIData` is two fields:

```json
{
  "CharacterImage":     { "AssetPathName": ".../T_Menu_PickCharacter_Portrait_ScavGirl...", "SubPathString": "" },
  "CharacterNickname":  { "Namespace": "", "Key": "8E1E...", "SourceString": "Scav Girl" }
}
```

The character definition knows nothing about skins.

## 2. The row struct is self-contained, and the asset refs are soft **[VERIFIED]**

`FSkinDetails` has four fields:

| Field | Type | Notes |
|---|---|---|
| `SkinName` | `FText` | string-table ref **or** inline literal |
| `SkinDetails` | `FText` | description; same |
| `SkinIcon` | `FSoftObjectPath` | character-select portrait |
| `Skin` | `FSoftObjectPath` | skeletal mesh |

A base row, using the string table:

```json
"ScavGirl0": {
  "SkinName":    { "TableId": "/Game/FW/UI/StringTables/ST_FW_UI_Skins.ST_FW_UI_Skins",
                   "Key": "Skin_AllChars_Default_01_Name", "SourceString": "Default Skin 1" },
  "SkinDetails": { "TableId": "...", "Key": "Skin_AllChars_Default_01_Desc" },
  "SkinIcon":    { "AssetPathName": "/Game/UI/Textures/MainMenu/Menu/T_Menu_PickCharacter_Portrait_ScavGirl.T_Menu_PickCharacter_Portrait_ScavGirl", "SubPathString": "" },
  "Skin":        { "AssetPathName": "/Game/Character/Scavengers/Female/SK_SCV_FL.SK_SCV_FL", "SubPathString": "" }
}
```

A recent DLC row, using **inline literal FText** — no string-table entry required:

```json
"Skin.Girl.MAY": {
  "SkinName":    { "Namespace": "", "Key": "007683904154CDB942807086A1D0CF64", "SourceString": "Scav Female May" },
  "SkinDetails": { "Namespace": "", "Key": "58C31E4A4F326138C6D0308C4F8247DD", "SourceString": "May 2026 Female SKin" },
  "SkinIcon":    { "AssetPathName": ".../T_Menu_PickCharacter_Portrait_DLC04_Scavgirl...", "SubPathString": "" },
  "Skin":        { "AssetPathName": "/Game/Character/Scavengers/Female/Skins/MAY/SK_SCV_FL_May.SK_SCV_FL_May", "SubPathString": "" }
}
```

**Three consequences, and they are the reason this project is worth doing:**

1. `Skin` and `SkinIcon` are **soft object paths — resolved by string at load**. A new row
   may point at any package path, including one that only exists inside a mod's own pak.
   No `FPackageId` collision engineering, no `fwrepath`, no `FolderName` header patching.
2. `SkinIcon` is **per-row**, so an appended skin gets a correct custom portrait. The
   "thumbnail lies" defect of the overwrite approach does not exist here.
3. `SkinName`/`SkinDetails` accept **inline literals**, proven by the DLC rows. A mod
   supplies its own display name and description without touching `ST_FW_UI_Skins`.

**There is no entitlement, ownership, DLC, or owning-character field in the row struct.**

## 3. The 33 rows, and two naming conventions **[VERIFIED]**

```
Bagman0  Bagman1  Bagman2  Bagman3  BagmanMNG
ScavGirl0  ScavGirl1  ScavGirl2  ScavGirl3  ScavGirl4  ScavGirlSPT  ScavGirlDec2025
OldMan0  OldMan1  OldManWaterTheif  OldManBER
MaskMan0  MaskMan1  MaskMan2  MaskManCIC  MaskManAnniversary
Shaman0  ShamanDogHead  ShamanDec2025
GunheadFLF  GunheadDec2025
Skin.Maskman.April2026.LHD  Skin.Gunhead.DSQ  Skin.Shaman.DSQ  Skin.Girl.DSQ
Skin.Girl.MAY  Skin.Gunhead.May  Skin.Shaman.May
```

Two eras of convention:

- **Legacy / base:** `<Character><N>` for free skins, sequential from `0`
  (`ScavGirl0`–`4`, `Bagman0`–`3`, `MaskMan0`–`2`, `OldMan0`–`1`, `Shaman0`), plus
  ad-hoc suffixed names for older unlockables (`ShamanDogHead`, `OldManBER`).
- **Current:** dotted, GameplayTag-shaped `Skin.<Character>.<Name>`.

Note the character token differs between eras: `ScavGirl0` but `Skin.Girl.MAY`. A naive
prefix match on `"ScavGirl"` would **miss** every dotted row, so per-character grouping
cannot be pure prefix matching on a single token. See §6.

## 4. Entitlement gating is external and tag-based **[VERIFIED]**

Two tables, neither of which is the skin registry:

**`/Game/FW/Player/Data/DT_Entitlements`** — 15 rows, RowStruct `FWEntitlementTableRow`.
Maps a store SKU or gift to a list of tags:

```json
"dlc:3651810": {
  "DisplayName": { "SourceString": "Never Summer - Nosebleed Skin Pack" },
  "EntitlementTags": [
    "Entitlement.Skin.Bagman.LoadBreaker",
    "Entitlement.Skin.Girl.BlindFang",
    "Entitlement.Skin.Shaman.EtherealPup"
  ]
}
```

**`/Game/FW/Player/Data/DT_EntitlementTags`** — 19 rows, RowStruct `GameplayTagTableRow`,
the tag definitions:

```json
"Skin.Girl.MAY":       { "Tag": "Entitlement.Skin.Girl.MAY" }
"SkinGirlBlindFang":   { "Tag": "Entitlement.Skin.Girl.BlindFang", "DevComment": "Skin - Girl - Blind Fang" }
```

### The join **[INFERRED]**

For current-era skins the `DT_EntitlementTags` **RowName** equals the `DT_SkinUIData`
**RowName**, and the tag is that name prefixed with `Entitlement.`:

| `DT_SkinUIData` row | `DT_EntitlementTags` row | Tag |
|---|---|---|
| `Skin.Girl.MAY` | `Skin.Girl.MAY` | `Entitlement.Skin.Girl.MAY` |
| `Skin.Girl.DSQ` | `Skin.Girl.DSQ` | `Entitlement.Skin.Girl.DSQ` |
| `Skin.Gunhead.May` | `Skin.Gunhead.MAY` | `Entitlement.Skin.Gunhead.MAY` |
| `Skin.Maskman.April2026.LHD` | `Skin.Maskman.April2026.LHD` | … |

Case differs (`May` vs `MAY`) but `FName` comparison in UE is case-insensitive, so these
are the same key. 6 of the 7 dotted rows correspond exactly. The one exception:
`DT_SkinUIData` has `Skin.Shaman.DSQ` while `DT_EntitlementTags` has `Skin.Shaman.Apr2026`
— either a rename mid-development or a genuine mismatch.

### ~~The consequence that matters~~ — RETRACTED 2026-07-20

**Every `<Character><N>` base row has no entitlement counterpart at all.** `ScavGirl0`–`4`,
`Bagman0`–`3`, `MaskMan0`–`2`, `OldMan0`–`1`, `Shaman0` appear in `DT_SkinUIData` and
nowhere in either entitlement table. **[VERIFIED — this part still holds.]**

What was wrong was the conclusion drawn from it. This doc previously claimed:

> ~~a row with no matching entitlement tag is ungated … free and unlocked, with no
> ownership check to defeat~~

**That is backwards, and it is why the first PoC run showed nothing.**

### What actually happens **[OBSERVED in-game, 2026-07-20]**

The skin selector **only ever offers entitlement-gated DLC skins.** The shipped base skins
are *not selectable there at all*. Concretely, as played:

- The skin menu for a character lists **only the DLC skins**, not `ScavGirl0`–`4`.
- Once a DLC skin is picked there is **no way back** to a base skin through the UI.
- A base skin only reappears when you **die in a raid and respawn in the tunnels**, at
  which point the game **randomly assigns** a skin — which may be a DLC skin or one of the
  shipped base variants.

So `DT_SkinUIData` feeds **two different consumers**:

| Consumer | Rows it uses | Reachable how |
|---|---|---|
| Skin **selector** UI | entitlement-gated rows only | player picks |
| Random respawn roll | base `<Char><N>` rows (and DLC) | assigned on tunnel respawn |

Having no entitlement tag does not make a row free — it makes it **invisible to the
selector**, leaving only the random pool. An appended row named in base convention lands in
the pool nobody can choose from.

This is corroborated by `WBP_SkinSelection`'s CDO property **`SelectLockedSkinsOnly: true`**
(§6), which reads exactly as "keep only locked/entitled rows" — a filter that would reject
an appended row regardless of what it is named.

### What this costs the design

Appending a row is necessary but **not sufficient**. To be *selectable*, a CMSF skin must
additionally either (a) carry an entitlement the player actually owns, (b) run with the
selector's filter disabled, or (c) be injected at the widget level. Only (a) is
data-only — and it is the one that depends on platform ownership we cannot grant. See
[01-design.md](01-design.md) §Post-PoC.

## 5. `SK_SCV_FL_OCT` — a complete, shipped, unreachable skin **[VERIFIED]**

A finished Scav Girl skin ships in the paks with **no `DT_SkinUIData` row pointing at it**:

```
ForeverWinter/Content/Character/Scavengers/Female/Skins/OCT/SK_SCV_FL_OCT.uasset
ForeverWinter/Content/Character/Scavengers/Female/Skins/OCT/SK_SCV_FL_OCT_Skeleton.uasset
ForeverWinter/Content/Character/Scavengers/Female/Skins/OCT/Materials/MI_SCV_FL_OCT.uasset
ForeverWinter/Content/Character/Scavengers/Female/Skins/OCT/Textures/T_FL_SCV_OCT_{D,N,RMFT}.uasset
```

Mesh, its own skeleton, material instance, and all three texture maps — cooked and shipped.
It is invisible purely because no row references it.

This proves the negative direction of the thesis — **a mesh without a row is unreachable**
— and hands us a free PoC subject. See [02-poc.md](02-poc.md).

## 7. The real registry — `FWSkinChangeComponent` on the pawn Blueprint **[VERIFIED]**

Every playable character's pawn Blueprint (`/Game/FW/Player/Class/BP_Player_<Char>`) carries
an **`FWSkinChangeComponent`** whose component template holds the actual roster:

| Property | Type | Role |
|---|---|---|
| `SkinChoices` | `TArray<FSoftObjectPath>` | free pool — the random respawn roll. **Not menu-selectable by default.** |
| `LockedSkinChoices` | `TMap<FGameplayTag, FSoftObjectPath>` | entitlement-gated — **this is what the selector shows** |
| `bReplicates` | bool | `true` |

`BP_Player_Girl`'s, in full:

```
SkinChoices (5)
  /Game/Character/Scavengers/Female/SK_SCV_FL      .SK_SCV_FL
  /Game/Character/Scavengers/Female/SK_SCV_FL1     .SK_SCV_FL1
  /Game/Character/Scavengers/Female/SK_SCV_FL2     .SK_SCV_FL2
  /Game/Character/Scavengers/Female/SK_SCV_FL3     .SK_SCV_FL3
  /Game/Character/Scavengers/Female/SK_SCV_FL4     .SK_SCV_FL4

LockedSkinChoices (3)
  Entitlement.Skin.Girl.BlindFang       -> Skins/SPT/SK_SCV_FL_SPT
  Entitlement.Skin.Girl.Dec2025         -> Skins/DEC/SK_FL_SCV_DEC
  Entitlement.Skin.Girl.April2026.DSQ   -> Skins/DSQ/SK_SCV_FL_DSQ
```

Across all six characters:

| Pawn | `SkinChoices` | `LockedSkinChoices` |
|---|---|---|
| `BP_Player_BagMan` | 4 | 1 |
| `BP_Player_Girl` | 5 | 3 |
| `BP_Player_Gunhead` | 1 | 3 |
| `BP_Player_MaskMan` | 3 | 3 |
| `BP_Player_OldMan` | 2 | 2 |
| `BP_Player_Shaman` | 1 | 3 |

### This explains every observation

`WBP_SkinSelection.SelectLockedSkinsOnly` selects **which array feeds the selector**.
Measured live on 2026-07-20:

| `SelectLockedSkinsOnly` | `SkinOptions` children | Composition |
|---|---|---|
| `true` (default) | **2** | owned `LockedSkinChoices` only |
| `false` (via probe) | **7** | 5 `SkinChoices` + 2 owned locked |

That accounts exactly for the reported behaviour: the menu offers only DLC skins; base
skins are unreachable there and surface only through the random respawn roll, which draws
from `SkinChoices`.

### Why this is good news

`SkinChoices` and `LockedSkinChoices` are **ordinary reflected UPROPERTYs on a
UActorComponent**, not a `UDataTable`'s raw `RowMap`. So they are reachable from UE4SS Lua
by the same reflection that `FWStealth` already uses on this game — **no native
`AddDataTableRow` primitive is required**, and the TFWWorkbench dependency (with its `-894`
ABI pin and unrebuildable `main.dll`) drops out of the design entirely.

### Loose end

`DT_SkinUIData` contains `Skin.Girl.MAY` (mesh `Skins/MAY/SK_SCV_FL_May`), but
`LockedSkinChoices` has **no** May entry — only 3 of the table's 4 girl DLC skins. Either
May is wired up by some other path, or it shipped in the table ahead of the component.
Worth understanding before assuming `LockedSkinChoices` is the complete gate.

## 6. What is still unknown

The per-character grouping and enumeration logic is **not** in any data asset. It lives in
Blueprint bytecode (`WBP_SkinSelection` / `WBP_CharacterSelection`) or in native
`/Script/FWGameCore`, and CUE4Parse does not decompile bytecode to readable form.

`WBP_SkinSelection` structure that *is* readable:

- Functions: `Init`, `Construct`, `SkinSelected`, `HoverSkin`, `UnhoverSkin`, `CanScroll`,
  `TriggerInput`, `NewFunction`
- Delegates: `UpdateSkin`, `CancelSelection`
- Widgets: `SkinOptions` (`WrapBox`, populated at runtime), `SB_SkinOptions` (`FWScrollBox`),
  `SkinIcon`, `SkinNameText`, `SkinDescription`, `UseSkinButton`
- CDO property: **`SelectLockedSkinsOnly: true`** — locked/unlocked filtering exists and is
  a live concern

The applier is `/Game/FW/Player/GameplayAbilities/GA_Player_ChangeSkin`.

Open questions, in priority order:

1. **Does the UI enumerate all rows, or a fixed list?** If it iterates `<Char><N>` until a
   miss, a new row must be sequentially numbered. If it scans every row and groups them,
   naming is freer. If the roster is a hardcoded array in bytecode, data-level injection
   fails outright and we fall back to widget-level injection.
2. **How does a dotted row get attributed to a character?** Related to (1).
3. **What does `SelectLockedSkinsOnly` gate?** Could an unrecognised row render as locked?
4. **Does `GA_Player_ChangeSkin` re-validate** the skin against an ownership list before
   applying the mesh?

Question 1 is answerable with a single cheap experiment, and its answer constrains 2 and 3.
That experiment is the next thing to build.
