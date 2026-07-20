# Findings — how TFW drives the skin selection screen

**Provenance.** All facts below were decoded from the shipped paks on 2026-07-20.

| | |
|---|---|
| Game build | `24045295` |
| Engine | UE 5.4.2 |
| Mappings | `ForeverWinter-5.4.2.usmap` |
| Paks | `H:\SteamLibrary\steamapps\common\The Forever Winter\Windows\ForeverWinter\Content\Paks` |
| Tool | `forever-winter-datamine` → `python -m fwdata get <name>` (prebuilt `fwextract.exe`) |
| Files mounted | 76,589 |

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

## 1. There is exactly one skin registry **[VERIFIED]**

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

### The consequence that matters

**Every `<Character><N>` base row has no entitlement counterpart at all.** `ScavGirl0`–`4`,
`Bagman0`–`3`, `MaskMan0`–`2`, `OldMan0`–`1`, `Shaman0` appear in `DT_SkinUIData` and
nowhere in either entitlement table — and they are the free, always-available skins.

So: **a row with no matching entitlement tag is ungated.** [INFERRED, but strongly
supported.] An appended CMSF row deliberately named outside the entitlement namespace
should therefore be free and unlocked, with no ownership check to defeat.

This is the difference between CMSF and every existing skin mod, which requires the user to
*own* the DLC slot being overwritten.

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
