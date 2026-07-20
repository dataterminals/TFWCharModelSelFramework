# PoC — resurrect `SK_SCV_FL_OCT`

## What this proves

Open question 1 from [00-findings.md](00-findings.md): **does the character-select screen
enumerate `DT_SkinUIData` rows, or work from a fixed roster?**

Everything else in the project depends on the answer. If the UI enumerates rows, Vector A+
works and CMSF is mostly a build-tooling problem. If it works from a hardcoded array, data
injection is dead and we fall back to widget-level injection (Vector C).

Secondarily it answers **how free we are to name reserved rows**, which determines whether
CMSF can sit in a namespace the developers will never collide with. See §Naming below.

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

2. Append **two** rows with UAssetAPI (`ScavgirlCarryPerks`' `skillpatch` is the
   precedent), both pointing at the same mesh:

   ```
   RowName:      ScavGirl5            # continues the base sequence
   RowName:      CMSF.Girl.TEST       # dotted, in a namespace the devs do not use

   # both rows, identical otherwise:
   SkinName:     inline FText literal                     (DLC rows prove inline works)
   SkinDetails:  inline FText literal
   SkinIcon:     /Game/UI/Textures/MainMenu/Menu/T_Menu_PickCharacter_Portrait_ScavGirl.T_Menu_PickCharacter_Portrait_ScavGirl
   Skin:         /Game/Character/Scavengers/Female/Skins/OCT/SK_SCV_FL_OCT.SK_SCV_FL_OCT
   ```

   `ScavGirl5` continues the base sequence (`ScavGirl0`–`4`) and sits **outside** the
   entitlement namespace, so it should need no ownership. `CMSF.Girl.TEST` tests whether
   naming is free (§Naming). Reuse the vanilla Scav Girl portrait — the variable under test
   is the row, not the art.

   **Confound to control for:** if a row the game cannot attribute to a character throws,
   it could take the `ScavGirl5` signal down with it and read as a false "not row-driven".
   Build a single-row fallback pak at the same time so a total failure can be disambiguated
   in one extra launch.

3. Repack and name for load order:

   ```bash
   retoc to-zen --version UE5_4 build/ dist/CMSF_PoC_9_P.utoc
   ```

   `_9_P` → `ChunkVersionNumber` 10 → order 1003, ahead of casual mods.

4. Install the trio to `Content\Paks\Mods\`, with the signature bypass present.

## Result matrix

| Observation | Reading | Next |
|---|---|---|
| **Both** rows appear | Full row scan. **Vector A+ confirmed, naming is free.** | Slot-pool generator, CMSF namespace |
| **Only `ScavGirl5`** | Sequential/prefix enumeration. Vector A+ confirmed, naming is **constrained** | Slot pool must stay contiguous |
| **Only `CMSF.Girl.TEST`** | Unexpected — grouping is not prefix-based at all | Re-examine attribution before building |
| Appears but **locked** | Enumerated, but gated by something beyond entitlements | Investigate `SelectLockedSkinsOnly` |
| Appears, selecting reverts/crashes | UI enumerates; `GA_Player_ChangeSkin` re-validates | Inspect the ability |
| Neither appears | Roster is not row-driven — **or** the dotted row threw | Retest with the single-row fallback pak first |
| Slot appears **blank/empty** | Row was found, mesh path failed to resolve | Check soft-path resolution |

Record which one actually happened — the failure readings are as informative as success,
and the fallback is already designed.

## Naming — how much distance can we keep from official rows?

The intuitive worry is that a reserved row named `ScavGirl5` gets clobbered when the
developers ship their own `ScavGirl5`. **That is the wrong way round.** CMSF's pak
replaces the *entire* `DT_SkinUIData` asset, so a stale CMSF table doesn't lose to the new
official row — it **deletes** it, along with every other row that patch added.

Two consequences:

1. **The dominant hazard is staleness, not collision.** Any patch touching the table
   obligates a re-extract and re-append, whatever anything is named. That obligation
   already exists (see [01-design.md](01-design.md)).
2. **A name collision therefore costs ~nothing extra.** It forces a rebase we already owed
   on that patch. And renumbering is safe: skin mods key off the **asset path**
   (`/Game/CMSF/ScavGirl/05/...`), never the row name, so CMSF can renumber rows freely
   without breaking a single shipped mod.

Still worth picking a distant namespace *if we can* — but whether we can is not our choice:

- **If enumeration is sequential-until-miss**, reserved rows must be **contiguous** with
  the base sequence. A gap at `ScavGirl5` would terminate the scan and orphan everything
  after it. Distance is impossible — and padding `ScavGirl5`–`9` as filler to start real
  slots at 10 would be actively worse, handing the devs five collision targets instead of
  one.
- **If it is a full row scan**, naming is free: put every reserved row under `CMSF.*` and
  collision probability goes to ~zero permanently.

This experiment decides which. Do not pick a slot-naming scheme before it runs.

## Before trusting any result

- Confirm the bypass matched: `Binaries\Win64\bitfix.txt` should contain a
  `writing C3 to <addr>` line. **No line means no pak mod loaded at all**, and the
  experiment measured nothing.
- Confirm no other mod in `Paks\Mods\` also overrides `DT_SkinUIData`.
- Verify the row survived the repack by re-decoding the built pak, rather than assuming the
  UAssetAPI write landed.
