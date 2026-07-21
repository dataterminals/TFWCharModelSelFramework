# Next session — pick up here

Written 2026-07-21, at the end of the session that validated v0.2 in-game.

**Where things stand: the design is proven, the framework is not built.** Probes 1–9 all
pass. Every mechanism v0.2 depends on has been demonstrated running in the actual game. What
is left is writing a generator, not answering questions.

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

## 2. The architecture to build

Probe 6 deleted the placeholder requirement, so this is much smaller than the doc's design.

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

## 3. What to build

1. **Framework generator.** Probably a mode on `tools/cmsf_build.py`, or a sibling script.
   Emit rows + roster entries + a sentinel ST for N slots × 6 characters. **No portraits.**
   `tools/build_probe7.py` already does exactly this for one character and two slots — it is
   the working prototype; generalise it. Always rebuild from the **live cook**, never a
   committed snapshot ([04-authoring.md](04-authoring.md) staleness inversion).
2. **Author tool.** Takes a mesh + portrait + `skin.json` + a claimed slot, emits the three
   packages. `build_probe7.py`'s author half is the prototype. This is what becomes
   `cmsf.exe` for authors — see the Nexus `.exe` constraint in the repo's prior art.
3. **Slot registry.** A public list mapping `<Char>/<NN>` → who claimed it, so authors do not
   collide. Design question, not a technical one.
4. ~~**Rung 9, optional.**~~ **Done** — shipped in `CMSFUnlock`. It derives each slot's
   expected icon path from the row name, so it needs no slot table and never needs
   regenerating when the pool grows.

Pool sizing is now purely a **namespace** decision — not download size (~1 KB/slot) and no
longer menu clutter either (unclaimed slots are hidden). Reserve generously.

## 4. Tools that exist and work

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

## 6. This machine

| | |
|---|---|
| retoc 0.1.5 | `H:\Github Repositories\AllWeaponsUnlockableFix\tools\retoc\retoc.exe` (gitignored, not in this repo) |
| usmap | `H:\Github Repositories\forever-winter-datamine\datamine\mappings\ForeverWinter-5.4.2.usmap` |
| game paks | `H:\SteamLibrary\steamapps\common\The Forever Winter\Windows\ForeverWinter\Content\Paks` |
| AES | `0x84B2244BE0AF90C22976D739FA0665569219F4CEA119CEA37C81F2D9ABEE4795` |

`cmsf_build.py`'s hardcoded defaults point at `D:` and **fail on this box**; override with
`RETOC` / `USMAP` / `FW_PAKS`. The `build_probe*.py` scripts auto-detect across both drives —
worth porting that helper into `cmsf_build.py`.

**Deployment is MO2**, mod store at `H:\MO2Instance_ModData\ForeverWinter\mods`. Layout is
`mods\<Name>\Mods\<pak trio>`, plus `mods\<Name>\Root\Windows\ForeverWinter\Binaries\Win64\ue4ss\Mods\CMSFUnlock\`
for the Lua side. **MO2 priority decides pak load order**, beating the filename `_N_P` token:
higher number wins, the column ascends, so the winner sits at the *bottom* of the list.

`build/` reads ~180 GB but is almost entirely hardlinks into the Steam install from
full-mount verification farms; real usage is a few hundred MB. Do not "reclaim" it.

## 7. Probe mods currently staged in MO2

All disabled unless noted. Safe to delete once the real framework exists.

`CMSF Probe3 SamePak`, `CMSF Probe45 Core/Low/High`, `CMSF Probe6 Respawn`,
`CMSF Probe6b RollTest`, `CMSF P7 Core`, `CMSF P7 Author`, `CMSFUnlock ONLY (control)`.

**`CMSF Probe6b RollTest` strips vanilla skins out of the respawn pool** — it is a
diagnostic. Do not leave it enabled.

The `CMSFUnlock ONLY (control)` mod is worth keeping permanently: it is the fastest way to
establish whether a bug is CMSF's or the game's.

## 8. Still unknown

- **n=2** on the unresolvable-path-in-the-roll observation. The prior is strong (~88% both
  rolls were dead paths) and it agrees with the independent selection result, but a few more
  deaths would firm it up.
- **Other five characters untested.** Everything in-game was ScavGirl. The roster shapes
  differ ([00-findings.md:277](00-findings.md#L277)) and Gunhead/Shaman ship a single base
  skin each, so their `SkinChoices` arrays are shortest.
- **Multiplayer.** [03-multiplayer.md](03-multiplayer.md) covers the theory; a CMSF slot has
  not been observed in co-op.
- **Patch day.** The framework must be rebuilt from each fresh cook. Untested against an
  actual game update.
