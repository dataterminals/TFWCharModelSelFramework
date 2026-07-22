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

4. Install as an **MO2 mod** — not into the game directory. See §Environment.

Steps 1–4 are automated by `tools/build_poc.sh`, which re-extracts from the live cook every
run and fails loudly if a built pak does not read back with both rows.

## Environment

This machine runs the game through **Mod Organizer 2**, so the real game directory stays
clean by design and is *not* where mods live. Checking
`...\The Forever Winter\Windows\ForeverWinter\Content\Paks\` for a `Mods\` folder, or
`Binaries\Win64\` for `dsound.dll`, shows nothing — Root Builder deploys those at launch and
withdraws them afterwards. **A vanilla-looking game directory is the expected state, not
evidence that anything is missing.**

| | |
|---|---|
| MO2 instance | `%LOCALAPPDATA%\ModOrganizer\The Forever Winter\` |
| Mod store | `H:\MO2Instance_ModData\ForeverWinter\mods\` |
| Profile | `Default` |
| Game | `H:\SteamLibrary\steamapps\common\The Forever Winter` |

A pak mod is staged as `mods\<Name>\Mods\<pak trio>` — the inner `Mods\` maps to
`Content\Paks\Mods\`. The signature bypass uses Root Builder layout instead:
`mods\Signature Bypass\Root\Windows\ForeverWinter\Binaries\Win64\{dsound.dll,bitfix\sig.lua}`.

**Do not edit `profiles\Default\modlist.txt` while MO2 is running** — it is held in memory
and rewritten on exit, which silently discards outside changes. Stage the mod folder, then
refresh MO2 (F5) and enable it in the UI.

### Bypass status — verified, not assumed

`sig.lua` carries a hand-updated pattern (*"Original pattern updated for game version
0.1.53312.0 — TEB access from wildcard `??` to fixed `58 00 00 00`"*). It **matches the
currently installed build**: `bitfix.txt` receipts from 2026-07-16 record four consecutive
launches ending `writing C3 to 7FF7D6770290`, on the same cook that is installed now
(paks dated 2026-07-07, buildid `24097213`).

### Conflict check — clean

Extracting every pak across all installed MO2 mods yields 70 assets, and **none is
`DT_SkinUIData`**. The four character-ish mods (Augmented Kane, Naughty Luca, Bunco-chan,
Recruiter Slade) are NPC/vendor **portrait** swaps mounted under `MyProject2/`, not player
skins. CMSF has sole ownership of the table.

Note also that installed mods use three different mount roots — `ForeverWinter/`,
`MyProject2/`, `BagmanTest/` (mod authors' project names). CMSF builds under
`ForeverWinter/`, matching the game's own mount.

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

- **Enable exactly one** of `CMSF PoC` / `CMSF PoC Fallback` — never both. They ship the
  same asset and would fight over it.
- Confirm the bypass matched **on this run**: `Binaries\Win64\bitfix.txt` should gain a
  fresh `writing C3 to <addr>` line. **No new line means no pak mod loaded at all**, and
  the experiment measured nothing. Under MO2 the file is written into the real game dir at
  launch, so check it after the run, not before.
- ~~Confirm no other mod also overrides `DT_SkinUIData`~~ — done, see §Conflict check.
- ~~Verify the row survived the repack~~ — `build_poc.sh` does this automatically by
  decoding the built pak back out and asserting both rows are present.
