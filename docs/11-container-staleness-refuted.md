# Container staleness is REFUTED — and what the crash is still not explained by

**STATUS 2026-09-10: the script-object-store hypothesis is dead, measured three independent ways.
The v0.2.5 rebuild is a NULL INTERVENTION with respect to it. The mod-detection subsystem is dated
out too — it shipped six weeks earlier, at build `24479102`. CMSF's launch crash is unexplained,
and the leading untested candidate is `PackageImport` public-export-hash staleness.**

`docs/10-patch-25071553.md` was written on 2026-09-09 and asserts that CMSF's pak crashes the game
because the game's global script-object store changed between the July cook and the live one. That
claim is wrong. This file records the refutation, because the wrong turn is more instructive than
the finding and because a reader who trusts §"P0 — why it crashes" in that document will rebuild
things for nothing.

Do not treat the v0.2.5 rebuild as a fix. See "What the rebuild actually did".

---

## The hypothesis, and how it died

The claim was: a zen (IoStore) container serialises its imports of native classes, functions and
structs as references *into* the global ScriptObjects chunk; that store grew 3,012,295 → 3,017,553
bytes (+5,258); therefore a pak packed against the old store no longer lines up, and
`BP_Player_*` — dense with such imports and loaded at pawn construction — crashes at launch.

The load-bearing premise is that script imports are **positional**. They are not. Three lenses
attacked this independently, all with direct measurement rather than argument, and all three
refuted it with high confidence.

### 1. The encoding is content-addressed, not positional

`FScriptObjectEntry` is `{ObjectName, GlobalIndex, OuterIndex, CDOClassIndex}`, 32 bytes. Every
`GlobalIndex` in both cooks has top-2-bits == `01` (ScriptImport) and is a full 64-bit value spread
across the 62-bit space (max observed `0x3fff645c1a1ba501`) — a hash of the object's path, not an
ordinal. The decisive structural tell: **the index is stored explicitly in each entry.** An
array-position encoding would never need to store the position; the runtime must key a map by the
value.

### 2. The store change is provably inert

Cross-resolving every entry's outer chain to a full path across both cooks:

| | |
|---|---|
| July entries | 46,497 |
| live entries | 46,576 |
| shared paths | **46,495** |
| shared entries whose `GlobalIndex` changed | **0** |
| added | 81 |
| removed | **2** |
| shared entries sitting at a **different array position** in live | **46,374 (99.7%)** |

Position moved for almost everything. Not one index changed. That is exactly the condition stated
in advance as refuting the hypothesis: if resolution is by hash, store size is irrelevant.

The removed pair, with full paths:

    FWReplicatedAimRecord
    FWHardpointContainerComponent.OnRep_AimReplication

Both are the client aim-replication rework. The 81 additions are the announced work —
`/Script/FWAICore` 28, `/Script/FWWeapon` 19, `/Script/AgentAI` 12.

### 3. The direct test on the artifact — the one that settles it

Unpacked the shipped 2026-07-21 `CMSF_Core_9_P.utoc` raw, parsed all **199** zen package headers,
and read each `ImportMap` (`[ImportMapOffset, ExportMapOffset)` as `FPackageObjectIndex` u64,
type = top 2 bits):

- **220 distinct ScriptImports. All 220 resolve against the LIVE store, to identical paths.**
- **Zero dangling. Zero changed path. Neither removed object is referenced by any of the 199
  packages.**
- Same for the July octogirl skin pak: 19 script imports, 0 dangling.

The mechanism does not fire on the very pak it was invented to explain.

## What the rebuild actually did

Comparing the July-shipped pak against the v0.2.5 rebuild, package by package:

- **identical script-import and package-import lists in all 199 packages**
- **193 of 199 packages byte-identical**
- the 6 pawn packages differ by 2–22 bytes, all past the header

So with respect to script imports the rebuild changes **nothing**, and its own predicted fix is a
null intervention. It is still the right artifact to ship eventually — it re-bases on the current
cook and recovers a few reverted tuning scalars — but it is **not** a fix for the crash, and
nobody should install it expecting one.

## The mistake worth keeping

Two failures of method, and they were mine:

1. **A size delta was treated as evidence of breakage.** It is a symptom of a patch. The
   correct-shaped question — "which names were *removed or renamed*" — was reachable from the same
   two files in about ten minutes, and it returns a two-symbol answer that touches nothing we ship.
2. **The hypothesis was rescued instead of tested.** When newly-built paks kept working and a
   modder reported an *un-rebuilt* pak still working, I invented an exposure asymmetry
   ("Blueprint-dense paks break, data-only paks may not") to absorb the counter-evidence. Under
   content addressing no asymmetry is needed: a pak's *age* is not a variable at all. Both
   observations were the expected outcome, not anomalies. The asymmetry was never evidence *for*
   the hypothesis — it was introduced to protect it.

The peer-session ops board caught the positional-vs-hash premise before any of this reached another
repository. Six repos were one step away from a precautionary rebuild for a mechanism that does not
exist.

## Surviving candidates for the crash, ranked

### 1. `PackageImport` public-export-hash staleness — the properly-formed container hypothesis, UNTESTED

This is what "container staleness" should have meant. CMSF's 199 packages carry **1,094
PackageImports**, which resolve by `(ImportedPackageIndex, ImportedPublicExportHashIndex)` against
the **target base package's public export hashes** — and those live in the live cook, not in the
script store. A renamed or removed *public export* in a base package that 0.9.5.0 reworked makes a
missing import, which is fatal in a shipping build.

Nothing has tested this. It is a different mechanism from the script store, it needs no game launch,
no usmap and no AES key for the mod pak, and it is the next thing to run.

### 2. ~~A mod-detection subsystem shipped in this window~~ — DATED OUT, build `24479102`

**Retired as a crash candidate on 2026-09-10.** The datamine repo archives a usmap per build, and
a usmap is a full type dump, so this was answerable from disk:

| usmap | `FWModIntegritySubsystem` |
|---|---|
| `archive/…-build24097213.usmap` | **absent** |
| `archive/…-build24479102.usmap` | **PRESENT** |
| live map (`24536482`) | PRESENT |

So the subsystem first appears at **`24479102`, the 2026-07-30 patch** — six weeks before the
crash reports begin, and the collection ran against it symptomless the whole time. It cannot
explain an onset at `0.9.5.0`. Independently corroborated by the ops board from a second
artifact: `FWPakManifest.json` is absent in the `pre-24479102` baseline and present in
`post-24479102`, so manifest and subsystem arrived in the *same* patch.

Controls, since a bare grep over a binary proves nothing alone: `FWWeaponDefinition` and
`FWPartySubsystem` hit in all three maps; `FWAIGoal_Investigate_Phased` and
`BTTask_SuppressiveFire`, both `25071553`-only, miss in all three.

Caveat: a usmap dates the **type**, not when behaviour behind it was switched on.

**It remains a live concern — just not for this crash, and not for CMSF.** `IsStockWeapon` plus
the damage-override path is aimed at the weapon mods, and the party-wide predicates at
multiplayer. Full symbol list and the dating table live in
`tfw-update-ops/state/scriptobjects-25071553.md`.

<details><summary>Original text, kept for the record</summary>

New in the live store, absent in July — 13 symbols forming one coherent surface:

    /Script/FWOnlineServices.FWModIntegritySubsystem   (+ Default__, GetFindings,
                                                        IsLocalGamePotentiallyModded)
    /Script/FWGameCore.FWPlayerStateBase.IsPotentiallyModded
                                        .OnRep_PotentiallyModded
                                        .ServerReportPotentiallyModded
    /Script/FWOnlineServices.FWLobbySearchResult.IsHostPotentiallyModded
    /Script/FWOnlineServices.FWPartySubsystem.IsPartyHostPotentiallyModded
                                             .IsPartyMemberPotentiallyModded
    FWWeaponBase.IsStockWeapon / GetBaseWeaponDamage / SetBaseWeaponDamage
                / ClearWeaponDamageOverride / OnRep_WeaponDamageOverride

Read together: mod detection with **party-wide replication**, plus a weapon-damage override path
gated on `IsStockWeapon`. New code that inspects mounted containers and produces "findings" at
startup fits "crashes at launch, only with some paks" far better than an inert hash map does.

> **⚠ This dev rig cannot test any integrity path.** The MO2 instance runs **Signature Bypass**
> (`dsound.dll`) enabled. Whatever the subsystem does about signatures or container validation,
> this machine is not a valid control for it — and neither is any measurement taken here.

**Dating caveat.** These symbols are new since the **2026-07-21** cook, a window spanning
`24479102 → 24501089 → 24536482 → 25071553`. They cannot be attributed to 0.9.5.0 specifically; the
intermediate cooks are gone. That is itself the argument for capturing `scriptobjects.bin` in every
baseline going forward.

**Blast radius is the weapon mods, not the skin mods.** `IsStockWeapon` + damage override is what
would act on `AllWeaponsUnlockableFix`, `HeavyRifleRebalanceFix` and the community damage mods. CMSF
appends cosmetic rows and touches no weapon stat.

</details>

### 3. Unversioned property-schema drift

Cooked Blueprint exports encode property values by **schema index** into the native parent's
property list — an index-based encoding, just in the export data rather than the script store. The
2–22 changed export bytes sit where a re-cook against a changed `FWPlayer`/component schema would
land. Testable by decoding those exact byte offsets with the live usmap and asking whether each
changed byte falls inside an unversioned-property header/bitmap or inside bytecode or a scalar
literal. **Blocked on gate 1b** (the usmap is stale).

### 4. It may not be the framework pak at all

Every reporter installed CMSF *to use a skin*. Skin paks clone July meshes to frozen paths, and
0.9.5.0 updated Scav Girl shoulders, updated the Gunhead mesh, and renamed three Shaman MAY
materials. A stale skin pak holding a hard reference to a renamed material would fail while the
player character is constructed.

And the workaround does not localise the fault: **deleting `CMSF_Core_9_P` disables the whole slot
system**, so it also stops every skin slot pak from ever loading. RyanLane's advice is a user's
guess at which of several files is guilty, not a bisect.

### 5. Report attribution may be an artifact

Three reports out of 156 unique downloads, with one user's 0.9.5.0 dating echoed by the others.
"No reports against the three hotfixes" means nobody kept the pak installed after the top comment
said to delete it — survivorship, not evidence of a 0.9.5.0-specific mechanism. So the timing
selects *the patch*, and every candidate above is inside that patch.

### 6. Environment, not container

Root Builder's armed revert (untouched since 2026-08-04) leaving a part-July install; UE4SS
`-894` + `CMSFUnlock` against a September exe (gate 3 has never run); or the pak trio installed
outside `Content/Paks/Mods/`, which has already been the answer once in the TFW Discord.

## Class A exposure audit

Seven repos audited read-only. **Risk ratings below were assigned under the now-refuted rubric**
("ships Blueprints + packed pre-0.9.5.0"), so read them as *overlap with the reworked subsystems*
rather than as script-import exposure — which is zero everywhere, since the removed set is two
aim-replication symbols wide.

| repo | pak | pre-0.9.5.0 | overrides base | Blueprints | MO2 | rated |
|---|---|---|---|---|---|---|
| **UnkillablesRebalanceFix** | yes | yes | yes | **yes (7 of 11)** | **ENABLED** | **critical** |
| HeavyRifleRebalanceFix | yes | yes | yes | no | disabled | medium |
| forever-winter-skin-mods | yes | yes | yes | no | absent | medium |
| ScavgirlCarryPerks | yes | yes | yes | no | disabled | low |
| TFWQuestGiverPortraitPatch | yes | yes | yes | no | absent | low |
| TFWQuestItemTag | no | n/a | no | no | absent | none |
| TFW_CyborgNerfFix | no | n/a | no | no | absent | none |

`AllWeaponsUnlockableFix` and a whole-tree sweep were cut off by the session limit and are still
owed.

**`UnkillablesRebalanceFix` is the one to look at, and not for script imports.** It whole-asset-
overrides eleven base packages including `BP_AI_Euruska_MeatMan`, `BP_Mech_Toothy` and
`BPC_IncomingDamageMod` — *precisely the AI subsystem 0.9.5.0 rebuilt from the ground up* — carries
295 ScriptImports and 1,149 PackageImports, was packed 2026-08-01/08-24, and is **enabled in the
MO2 profile right now**. Its content-reversion exposure alone is severe: the repo's last commit is
2026-08-23, before 0.9.5.0 shipped. Its own `tools/verify_build.sh` should be re-run against the
live build. **That is its owner-session's call, not this repo's.**

## What survives of the tooling

`tools/scriptobjects_diff.py` is still correct and worth keeping — but for the *right* predicate.
It diffs name sets and reports **removals only**, treating growth as the non-event it is, and on
this build it correctly reports "2 removed, nothing we ship references either, not exposed". It is
wired into `verify_build.sh` check [5]. Its limits are stated in its own docstring: a clean run
rules out a dead ScriptImport, and rules out nothing else.

## Working this on SylDesk

Two things do not travel with the repo, and both will bite:

- **The rebuilt pak is not in git.** `dist/**/*.{pak,utoc,ucas}` is gitignored, deliberately. So
  `git pull` on SylDesk brings the tooling and the docs but no artifact.
- **A pak is specific to the cook it was packed against**, which is the entire subject of this
  document. SylDesk is on build **24501089** per `tfw-update-ops/registry/repos.json`, two builds
  behind. A pak built there would be for the wrong cook, and any measurement of the crash taken
  there is measuring a different game.

So the order on SylDesk is: patch to `25071553` first (deliberately, from the Steam Downloads page),
**then** remediate Root Builder — its cache and `Backup\` are still unremediated there and its
displaced exe is armed, per the ops board — and only then rebuild locally with
`FW_AES_KEY`, `RETOC` and `USMAP` set. Do not carry a pak between machines.

## Next moves, in order

1. **Run the `PackageImport` export-hash check** (candidate 1). Launch-free, usmap-free. The one
   container mechanism still untested, and it discriminates cleanly.
2. **Regenerate the usmap** (gate 1b), which unblocks candidate 3.
3. **Bisect on the reporter's machine, not by theory** — the one thing that separates candidates
   1/2/3 from 4: does the crash happen with the framework pak *alone*, no skin paks?
4. **Get `UE4SS.log`** and close gate 3 (candidate 6).
5. Only then decide what ships.
