# PoC — resurrect `SK_SCV_FL_OCT`

## What this proves

Open question 1 from [00-findings.md](00-findings.md): **does the character-select screen
enumerate `DT_SkinUIData` rows, or work from a fixed roster?**

Everything else in the project depends on the answer. If the UI enumerates rows, Vector A+
works and CMSF is mostly a build-tooling problem. If it works from a hardcoded array, data
injection is dead and we fall back to widget-level injection (Vector C).

## Why this particular experiment

`SK_SCV_FL_OCT` is a **complete, cooked, shipped Scav Girl skin with no row pointing at
it** — mesh, its own skeleton, material instance, and all three texture maps. It is
invisible for exactly one reason.

That makes it a clean single-variable test:

- **No new art.** Nothing to model, texture, or cook.
- **No new packages.** No mesh repathing, no `FPackageId` collision risk, no skeleton or
  material reference repair — the very failure modes that produced T-poses in the existing
  skin-mod pipeline. Every asset already exists and already resolves.
- **The only change in the entire experiment is one added table row.**

If the skin appears, the row was the only thing missing, and appending rows works.
If it does not appear, the roster is not row-driven — and that is equally decisive.

Pleasant side effect: success un-cuts a finished skin the game shipped and never exposed.

## Build

1. Extract the current `DT_SkinUIData` from the live cook — never from a committed
   snapshot:

   ```bash
   retoc -a 0x84B2244BE0AF90C22976D739FA0665569219F4CEA119CEA37C81F2D9ABEE4795 \
     to-legacy --version UE5_4 -f <DT_SkinUIData filter> "$GAME_PAKS" build/
   ```

2. Append one row with UAssetAPI (`ScavgirlCarryPerks`' `skillpatch` is the precedent):

   ```
   RowName:      ScavGirl5
   SkinName:     inline FText literal, "October"          (DLC rows prove inline works)
   SkinDetails:  inline FText literal
   SkinIcon:     /Game/UI/Textures/MainMenu/Menu/T_Menu_PickCharacter_Portrait_ScavGirl.T_Menu_PickCharacter_Portrait_ScavGirl
   Skin:         /Game/Character/Scavengers/Female/Skins/OCT/SK_SCV_FL_OCT.SK_SCV_FL_OCT
   ```

   `ScavGirl5` continues the base sequence (`ScavGirl0`–`4`) and sits **outside** the
   entitlement namespace, so it should need no ownership. Reuse the vanilla Scav Girl
   portrait — testing one variable, not two.

3. Repack and name for load order:

   ```bash
   retoc to-zen --version UE5_4 build/ dist/CMSF_PoC_9_P.utoc
   ```

   `_9_P` → `ChunkVersionNumber` 10 → order 1003, ahead of casual mods.

4. Install the trio to `Content\Paks\Mods\`, with the signature bypass present.

## Result matrix

| Observation | Reading | Next |
|---|---|---|
| Appears, selectable, applies | Rows are enumerated. **Vector A+ confirmed.** | Build the slot-pool generator |
| Appears but **locked** | Enumerated, but gated by something beyond entitlements | Investigate `SelectLockedSkinsOnly` |
| Appears, selecting reverts/crashes | UI enumerates; `GA_Player_ChangeSkin` re-validates | Inspect the ability |
| Does not appear | Roster is not row-driven | Fall back to Vector C |
| Slot appears **blank/empty** | Enumeration is sequential and found the row, mesh path failed | Check soft-path resolution |

Record which one actually happened — the failure readings are as informative as success,
and the fallback is already designed.

## Before trusting any result

- Confirm the bypass matched: `Binaries\Win64\bitfix.txt` should contain a
  `writing C3 to <addr>` line. **No line means no pak mod loaded at all**, and the
  experiment measured nothing.
- Confirm no other mod in `Paks\Mods\` also overrides `DT_SkinUIData`.
- Verify the row survived the repack by re-decoding the built pak, rather than assuming the
  UAssetAPI write landed.
