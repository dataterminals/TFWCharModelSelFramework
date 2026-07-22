# Next session — pick up here

Updated 2026-07-22, after the run that **validated** v0.2 on all six characters.

**Where things stand: v0.2 is built and validated end to end.** Probes 1–9 pass, everything in
§3 is done — framework generator, author tool, slot registry, rung 9 — and on 2026-07-22 all
six characters were opened in-game against the real 192-slot framework. Every menu populates
and prunes; Octogirl's claim renders with her portrait and applies her mesh on select. No Lua
errors in the run.

What remains is not design work, and no longer includes any per-character unknown:

- **Release packaging** — `cmsf.exe` for authors (the Nexus `.exe` constraint), and the
  public-facing copy the README deliberately leaves undrafted. **This is the only thing
  standing between v0.2 and a release.**
- **Multiplayer and patch day**, both untested. See §8.
- **Three unexplained observations** from the validation run — widget accumulation, a claim
  race at n=4, and per-poll log spam. None fatal, none understood. See §8.

Read this file, then [05-v2-distribution.md](05-v2-distribution.md) for the reasoning. That
document still contains a long argument for a **placeholder mechanism that should not be
built** — probe 6 disproved its premise. It is marked throughout, but do not skim it and
start implementing placeholders.

---

## 1. What is proven

| Rung | Result |
|---|---|
| 1 | A CMSF string table is buildable by cloning `ST_FW_UI_Skins` |
| 2 | A mesh clones to a CMSF slot path with all imports intact |
| 3 | The game **resolves** a CMSF-authored string table |
| 4 | It resolves **cross-pak**, correct on the **first cold menu open** — no `Init()` retrigger |
| 5 | **Load order overrides it** — this is the author channel |
| 6 | An unresolvable roster path is a **silent no-op**, in both the selector and the respawn roll. `SkinChoices` feeding the roll went `[INFERRED]` → **[VERIFIED]** |
| 7 | A claim switches **name + portrait + mesh together**; unticking the author pak reverts cleanly |
| 8 | Selection survives a raid and a relaunch; a dangling selection after uninstall re-rolls gracefully |
| 9 | **Unclaimed tiles prune.** The claim signal is readable from the tile itself — no filesystem scan, no manifest, no author filename convention. Shipped in `CMSFUnlock` |

Rung 9 turned out to be load-bearing rather than polish: it removes the menu-clutter ceiling
on pool depth, and because the signal it uses is the slot's own icon path, it also
**forecloses sentinel portraits** — a sentinel would read as a claim. The framework now ships
no textures at all, so a slot costs ~1 KB instead of 571 KB. Rung 10 (entitlements) is
effectively dead; its only real draw was escaping the respawn roll, and probe 6 removed the
thing to escape.

## 2. The architecture

Probe 6 deleted the placeholder requirement, so this is much smaller than the doc's design.
Built by [cmsf_framework.py](../tools/cmsf_framework.py) and [cmsf_author.py](../tools/cmsf_author.py).

### The framework pak — user installs once

Owns `DT_SkinUIData` and `BP_Player_*` outright. Per slot `<Char>/<NN>` it ships:

- a row `CMSF.<Char>.<NN>` whose `SkinName`/`SkinDetails` are **string-table references** to
  `/Game/CMSF/<Char>/<NN>/ST_CMSF_<Char>_<NN>`, and whose `SkinIcon`/`Skin` are soft paths to
  `T_CMSF_<Char>_<NN>` and `SK_CMSF_<Char>_<NN>`
- the matching `SkinChoices` append on `BP_Player_<Char>`
- a **sentinel string table** ("CMSF SLOT NN UNCLAIMED")
- **no mesh and no portrait.** Both paths resolve to nothing, which is harmless (probe 6),
  and shipping a portrait would defeat rung 9 — a sentinel at the slot's own icon path reads
  as a *claim* and never prunes.

Measured: **~1 KB per slot.** Only the string table has any weight. The 571 KB sentinel
portrait that dominated the earlier estimate is gone, and with it the ceiling on pool depth.

### The author's pak — one per skin

Three packages at the slot's frozen paths, nothing else:
`SK_CMSF_<Char>_<NN>`, `T_CMSF_<Char>_<NN>`, `ST_CMSF_<Char>_<NN>`, at a higher load order.

Authors never ship `DT_SkinUIData` or `BP_Player_*`, which is why two CMSF skins cannot
clobber each other. `skin.json` is a build-time input and never ships.

### Slot paths are a permanent public ABI

`/Game/CMSF/<Char>/<NN>/` is append-only, never renumbered. That promise is what lets author
paks survive every framework rebase untouched.

## 3. What was built

1. ~~**Framework generator.**~~ **Done** — [tools/cmsf_framework.py](../tools/cmsf_framework.py),
   a sibling script rather than a mode on `cmsf_build.py` (v0.1 merges registered skins;
   v0.2 emits a fixed pool and knows nothing about skins — different enough that one script
   with modes would muddy both, and v0.1 must stay a working rollback path). Rebuilds from
   the live cook, verifies by decoding the pak back out, and **refuses to ship a mesh or a
   portrait** for any slot, since either would silently make that slot unprunable.

   `python tools/cmsf_framework.py --slots 32`  ->  `dist/framework/CMSF_Core_9_P.*`
2. ~~**Author tool.**~~ **Done** — [tools/cmsf_author.py](../tools/cmsf_author.py). Takes a
   `skin.json` plus a claimed slot and emits exactly three packages at the slot's frozen
   paths. Sources may be `/Game/` paths cloned out of the live cook, or the author's own
   cooked `.uasset` files. Still to do: package it as `cmsf.exe` for authors — see the Nexus
   `.exe` constraint in the repo's prior art.

   **The portrait is mandatory, and the tool enforces it.** Rung 9 decides a slot is
   unclaimed by checking whether its icon resolves to the slot's own path, so a claim
   shipping no portrait is not merely plain — it is *pruned*, invisible, indistinguishable
   from not being installed. That is the one authoring mistake that yields a clean build and
   a missing skin, so it is a hard error at build time.

   The verify pass also fails the build if the pak contains **anything** outside
   `/Game/CMSF/<Char>/<NN>/`. "Authors never ship `DT_SkinUIData` or `BP_Player_*`" is now
   mechanically enforced rather than remembered.
3. ~~**Slot registry.**~~ **Done** — [docs/slots.md](slots.md), enforced by the author tool.
   Claiming a slot registered to someone else is a hard error; an unregistered public slot is
   only a note, so nobody is blocked waiting on a merge to test locally. Slots **28–31 are a
   private range**: never registered, never policed, so a personal skin never touches the
   registry and can never collide with a published one.

   `python tools/cmsf_author.py --list-free Girl`
4. ~~**Rung 9, optional.**~~ **Done** — shipped in `CMSFUnlock`. It derives each slot's
   expected icon path from the row name, so it needs no slot table and never needs
   regenerating when the pool grows.

**Pool depth: 32 per character, 192 slots.** Measured, not guessed — the three things that
could have constrained it do not:

| Constraint | Measured |
|---|---|
| download size | 0.57 MB for 192 slots (3.0 KB/slot). 384 slots was still only 0.83 MB |
| menu clutter | zero — unclaimed slots are hidden (rung 9) |
| selector cost | `Init()` 0.60 ms at 7 tiles, 4.80 ms at 71. ~0.066 ms/tile, linear, once per menu open — under a third of a 60 fps frame at **double** the shipped depth |

Slot numbers are **two digits by ABI** (`CMSFUnlock` matches `CMSF%.%a+%.%d%d`), so 100 is
the hard cap and 32 leaves room to extend. Extending is legal — the pool is append-only —
but it costs every user a framework re-download, so prefer not to.

> The ABI is only frozen once v0.2 **ships**. Nothing is public yet, so the depth is still
> cheap to change; after release it is not.

## 4. Tools that exist and work

**The two you will actually run:**

| Tool | Does |
|---|---|
| `cmsf_framework.py --slots 32` | the framework pak users install once. Rebuild from every fresh cook. Refuses to ship a mesh or portrait, and asserts vanilla roster entries survive `bpadd` |
| `cmsf_author.py <skin-dir>` | one skin -> one pak trio. Enforces the registry, requires a portrait, and fails if the pak contains anything outside the slot directory. `--list-free CHAR` shows availability |

**The layer underneath**, used by both:

| Tool | Does |
|---|---|
| `skinpatch add` | DataTable rows with **inline** FText (v0.1) |
| `skinpatch addst` | DataTable rows with **string-table** FText, and synthesises the import chain |
| `skinpatch bpadd` | Append to `SkinChoices` (dedupes) |
| `skinpatch bpset` | Repoint one `SkinChoices` entry by index |
| `skinpatch inspect` / `schema` / `bpskins` | Read-only; `schema <row>` dumps every field reflectively and is the fastest way to learn a struct |
| `stgen` | Generate a CMSF string table from the game's own, with identity rewrite |
| `mshgen` | Clone **any** cooked package to a slot path with a new identity (mesh *and* texture) |
| `stprobe` / `mshprobe` | Historical probe harnesses. **`mshprobe` does not rewrite identity** — use `mshgen` |

**Runtime:**

| Mod | Does |
|---|---|
| `CMSFUnlock` | unfilters the selector (v0.1) **and** hides unclaimed CMSF slots (rung 9). `cmsfnoprune` is the escape hatch |
| `CMSFTime` | `cmsftime` times `Init()` over N reps. Only needed if pool depth is revisited |

## 5. Gotchas that will bite

**UE4SS hands back `RemoteUnrealParam` wrappers, and indexing into one silently yields
`nil`.** This applies to struct members and array elements alike — `:get()` unwraps. The
array case is loud: calling a UObject method on a wrapper throws *"attempt to call a
RemoteUnrealParam value"*. The struct case is the dangerous one, because it produces a
**confident wrong answer** instead of an error: reading `tile.SkinIcon.Brush.ResourceObject`
without unwrapping `SkinIcon` first returned `null` for *every* tile, including vanilla
portraits that were visibly rendering on screen. It survived a full in-game round trip
looking like a clean negative result. Unwrap at **every** hop.

> Only a control caught it. The vanilla tiles were logged alongside the CMSF ones precisely
> so a read that fails for both would be distinguishable from a real finding — and that is
> the only reason the false negative did not get designed around.

**A plain `Visibility` property write does not hide a widget.** It updates the UPROPERTY
without Slate noticing. `SetVisibility(Collapsed)` is required, and it does not survive
`Init()` — re-prune on each poll.


**The identity rule.** Cloning a package must rewrite *both* the name-map package entry
**and** `FolderName`. Miss either and the clone collides by `FPackageId` and the loader
serves it in its template's place. This cost an hour: a cloned string table silently replaced
the game's `ST_FW_UI_Skins`, and every vanilla skin rendered as
`<MISSING STRING TABLE ENTRY>`. `stgen`/`mshgen` now refuse to emit a colliding asset.

**Verify identity by whole name-map entries, not byte scans.** `SK_SCV_FL_OCT_Skeleton`
contains `SK_SCV_FL_OCT` as a prefix and is a legitimate sibling import.

**Renaming the file does not rename the export.** A soft path and a `TableId` are both
`/Package/Path.ObjectName`.

**A `TableId` is a hard reference.** It serialises as a bare `FName` and declares no
dependency; without a synthesised import chain `to-zen` emits a broken import table.
`addst` handles this.

**`/Engine/UnknownPackage` in `to-legacy` output is NOT proof of corruption.** It also
appears for any package simply not mounted in the container set being decoded. Misreading it
sent an hour of diagnosis after `retoc`, which was innocent.

**`-f` is mandatory** on `to-legacy` against a full-game mount. Unfiltered it extracts the
whole cook — it filled the drive at 5 GB before dying.

**`to-legacy` on a mod pak needs `global.utoc`/`global.ucas` staged beside it**, or the whole
game mounted.

**`skinpatch` does not create its output directory.** `stgen`/`mshgen` do.

**Run a control before theorising.** The string-table bug was settled in two minutes by
booting CMSFUnlock with no CMSF pak at all, after an hour of speculation. When something
breaks, first establish *whose* bug it is.

## 6. The two machines

Both are set up. `cmsf_framework.py` / `cmsf_author.py` locate everything themselves — the
`find()` helper lists both drives' candidates, so **neither box needs env overrides**. Only
the older `cmsf_build.py` (v0.1) still hardcodes `D:` and needs `RETOC` / `USMAP` / `FW_PAKS`
on the desktop; porting `find()` into it is a loose end.

| | desktop | laptop |
|---|---|---|
| retoc 0.1.5 | `H:\Github Repositories\AllWeaponsUnlockableFix\tools\retoc\retoc.exe` | `D:\Github Repositories\HeavyRifleRebalanceFix\tools\retoc\retoc.exe` |
| usmap | `H:\...\forever-winter-datamine\datamine\mappings\ForeverWinter-5.4.2.usmap` | `D:\...\forever-winter-datamine\datamine\mappings\ForeverWinter-5.4.2.usmap` |
| game paks | `H:\SteamLibrary\...\Content\Paks` | `D:\SteamLibrary\...\Content\Paks` |
| MO2 mod store | `H:\MO2Instance_ModData\ForeverWinter\mods` | `D:\MO2_InstanceData\TheForeverWinter\mods` |
| MO2 itself | — | `C:\Modding\MO2` |

AES is the same on both:
`0x84B2244BE0AF90C22976D739FA0665569219F4CEA119CEA37C81F2D9ABEE4795`

retoc is gitignored and not in this repo on either box.

**Deployment is MO2.** Layout is `mods\<Name>\Mods\<pak trio>`, plus
`mods\<Name>\Root\Windows\ForeverWinter\Binaries\Win64\ue4ss\Mods\CMSFUnlock\` for the Lua
side. **MO2 priority decides pak load order**, overriding the filename `_N_P` token entirely:
`ForeverWinterMO2Support` renames each pak `_<N>_P` with N derived from priority, so a token
a build tool baked in is discarded. In `modlist.txt` the first line is the highest priority;
in the MO2 UI that is the *bottom* of the list.

> **MO2 tooling has a prerequisite, and the order is load-bearing.** Bringing the laptop up on
> 2026-07-21 needed `ForeverWinterMO2Support` upgraded from **`main`** *first*, and only then
> `TFWWorkbenchMO2Patcher`. The patcher empties `Settings.ModChildDirs`, which is only safe
> because the plugin pre-creates the DataTable tree in Overwrite — run it against a stale
> plugin and TFWWorkbench dies with `attempt to index a nil value (local 'modDir')` instead of
> merely flashing ~160 `cmd.exe` windows per launch. Verify with
> `CollectData] Collecting data from ...\Mods\TFWWorkbench\DataTable\<dir>` in `UE4SS.log`.

`build/` reads ~180 GB but is almost entirely hardlinks into the Steam install from
full-mount verification farms; real usage is a few hundred MB. Do not "reclaim" it.

## 7. What is staged in MO2

**Enabled — this is the real v0.2 configuration:**

| Mod | Contains |
|---|---|
| `CMSF Skin - Octogirl (Girl 00)` | the author pak. **Must out-prioritise the framework** |
| `CMSF v0.2 Framework` | `CMSF_Core_9_P` (192 slots) + `CMSFUnlock` |

In `modlist.txt` the **first line is the highest priority**, so Octogirl sitting above the
framework is correct. In the MO2 UI that is the *bottom* of the list — the two views are
inverted, which is easy to trip over.

**Disabled, worth keeping:**

- `CMSFUnlock ONLY (control)` — CMSFUnlock + CMSFTime, no pak. The fastest way to establish
  whether a bug is CMSF's or the game's. Keep permanently.
- `CMSF Stress 384` — 64 slots x 6, the pool-depth measurement. Keep until the ABI is frozen.
- `CMSF P9 IconSignal` — the rung 9 probe. Superseded; safe to delete.

**Disabled, safe to delete** — every mod from the probe era: `CMSF Probe3 SamePak`,
`CMSF Probe45 Core/Low/High`, `CMSF Probe6 Respawn`, `CMSF Probe6b RollTest`, `CMSF P7 Core`,
`CMSF P7 Author`, `CMSF Roster Test`, `CMSF Probe`, `CMSF PoC`, `CMSF PoC Fallback`, `CMSF`.

**`CMSF Probe6b RollTest` strips vanilla skins out of the respawn pool** — it is a
diagnostic. Do not leave it enabled.

## 8. Still unknown

- **n=2** on the unresolvable-path-in-the-roll observation. The prior is strong (~88% both
  rolls were dead paths) and it agrees with the independent selection result, but a few more
  deaths would firm it up.
- ~~**Other five characters never rendered.**~~ **Closed 2026-07-22.** All six were opened
  in-game on the laptop against the real 192-slot framework: every menu populates and prunes,
  with no Lua errors in the run. Gunhead and Shaman — the single-entry `SkinChoices` pair,
  the shape most likely to differ — behave like the rest.
- ~~**Octogirl's mesh since the rename.**~~ **Closed 2026-07-22.** `CMSF_Girl00_octogirl_11_P`
  renders with her portrait and the mesh applies on select. The log is unambiguous on the
  claim itself: exactly one pass logged `hid 31 unclaimed CMSF tile(s)` where every other
  logged 32, so rung 9 read the claim from the slot's own icon path and declined to prune it.
- **Multiplayer.** [03-multiplayer.md](03-multiplayer.md) covers the theory; a CMSF slot has
  not been observed in co-op.
- **Patch day.** The framework must be rebuilt from each fresh cook. Untested against an
  actual game update.

### Surfaced by the 2026-07-22 run — unexplained, none fatal

Read off `UE4SS.log` for a single session in which all six menus were opened. Nothing here
broke the run, and the operator's summary was "they were all good" — but none of it is
explained, so do not treat any of it as understood.

- **`hid 128 unclaimed CMSF tile(s)` fired three times.** 128 = 4 x 32, i.e. four characters'
  worth of tiles pruned in one pass, against single-character passes of 31 and 32 elsewhere in
  the same run. The working hypothesis is that tile widgets from previously-viewed characters
  stay instantiated, so a later poll catches several characters at once — which would also
  explain the operator seeing "a bunch of tiles, then they all vanished once I scrolled".
  **Unverified.** If it holds, the prune is racing widget accumulation rather than pruning
  each character in isolation.
- **`restored 4` fired once**, where the claim race as documented below predicts n=1 (only
  Octogirl is claimed in this configuration). Four tiles being wrongly hidden and then restored
  suggests the stale-pooled-texture misread scales with the accumulated widgets, not with the
  number of real claims.
- **`skin menu open: N` is logged on every poll** — 33 lines in ~17 seconds, in pairs ~0.1 ms
  apart, so two widgets are being polled at once. Log on change instead. The pair also has an
  anomaly worth chasing: 35 and 37 match MaskMan (3+32) and Girl (5+32), but the frequently
  logged **39 matches no pawn** — no character has 7 vanilla skins.

### Known and accepted, not bugs

- **A claimed slot is hidden for up to one poll (~1 s) after the menu opens**, then appears.
  The tile's icon still holds a stale pooled texture on first population, so the first prune
  pass misreads the claim; the bidirectional pass corrects it and logs
  `restored N claimed CMSF tile(s)`. Deferring the first hide would instead make 31 unclaimed
  tiles visibly collapse, which is the larger flinch. See
  [05-v2-distribution.md](05-v2-distribution.md) §"The claim race".
  **2026-07-22: observed at n=4, not n=1** — see above.
- **`skin menu open: N skin(s) listed` counts hidden tiles too.** Collapsed tiles are still
  children of the WrapBox. 39 listed with 8 visible is correct, not a prune failure.
