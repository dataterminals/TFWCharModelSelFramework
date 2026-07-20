# Authoring a CMSF skin

CMSF adds skins to the character-select screen **without overwriting** any existing slot.
You do not need to own a DLC, you do not need to give up a slot, and your skin gets its own
name, description and portrait.

## What you ship

An ordinary IoStore pak trio (`.pak` + `.utoc` + `.ucas`) containing **your own mesh at your
own package path**. Nothing has to collide with a game asset — CMSF points at your path
directly, so none of the `FPackageId` / `FolderName` retargeting that overwrite-style skin
mods need applies here.

Optionally include a portrait texture the same way.

## Registering it

Drop a folder under `skins/`:

```
skins/
  my-cool-scavgirl/
    skin.json
```

```json
{
  "character": "Girl",
  "name": "Ash Runner",
  "description": "Scav Girl, kitted for the ash flats.",
  "mesh": "/Game/MyMod/Skins/AshRunner/SK_AshRunner.SK_AshRunner",
  "icon": "/Game/MyMod/Skins/AshRunner/T_AshRunner_Portrait.T_AshRunner_Portrait"
}
```

| Field | Required | Notes |
|---|---|---|
| `character` | yes | one of `BagMan` `Girl` `Gunhead` `MaskMan` `OldMan` `Shaman` |
| `name` | yes | shown in the selector |
| `mesh` | yes | full `/Game/Path/Asset.Asset` — note the object name after the dot |
| `description` | no | shown under the name |
| `icon` | no | falls back to a stock portrait, so an icon-less skin still renders |
| `id` | no | defaults to the folder name; becomes the row name `CMSF.<Character>.<id>` |
| `order` | no | position **among CMSF skins** — lower first, default 100, ties break on `id` |

`order` does not interleave with the stock skins: appended rows always come after every
vanilla row, so CMSF's skins sit at the end of the list and `order` arranges them within
that block. Set it if you care; leaving it out is stable regardless, since ties fall back to
`id` rather than to whatever sequence the filesystem returned.

## Collisions

What CMSF catches:

| Case | Result |
|---|---|
| Two manifests with the same `id` for one character | **error**, naming both files |
| An `id` colliding with a row the game already ships | **error** — otherwise the skin would silently never appear |
| Two manifests declaring the same mesh path | **warning**, naming both files |

The mesh warning is not always a bug — several rows may share one mesh deliberately to give
it multiple named entries. But it is also exactly what happens when two authors ship
different assets at the same `/Game/` path, in which case one silently overwrites the other
at the pak layer. That is likelier than it sounds: an author who never renamed their Unreal
project ships under a default name, and default names are identical across projects.
**Publish your assets under a path unique to your mod.**

What CMSF cannot catch:

- A non-CMSF mod shipping an asset at a path one of your skins uses. CMSF only sees paths
  declared in manifests.
- Another mod overriding `DT_SkinUIData` or `BP_Player_*`. CMSF owns those assets, and a pak
  override replaces a whole asset, so whichever pak has the higher load order wins outright.
  Nothing else is known to ship them today.

There is no `Mech Trooper` — the sixth character is `MaskMan`.

Then:

```bash
python tools/cmsf_build.py --list     # check it parsed
python tools/cmsf_build.py            # build dist/CMSF/CMSF_9_P.*
```

Install the generated trio alongside your own mod's pak, and enable the **CMSFUnlock** UE4SS
mod.

## Why you re-run the build instead of shipping a patch

A pak override replaces a **whole asset**. `DT_SkinUIData` and the `BP_Player_*` Blueprints
can therefore only have one owner — if every skin mod shipped its own edit, the last one to
load would silently erase the others.

So CMSF regenerates a single combined pak from everything registered. The cost is a rebuild
when the set of skins changes; what it buys is that skins genuinely compose, with real
per-skin names rather than a fixed pool of "CMSF Slot 05" placeholders.

## How it works, briefly

A skin needs **two halves**, and neither is visible alone:

1. **Availability** — the mesh path appended to `FWSkinChangeComponent.SkinChoices` on
   `BP_Player_<Char>`. This is the actual roster.
2. **Identity** — a row in `DT_SkinUIData` whose `Skin` points at that same mesh, carrying
   the name, description and icon.

The selector walks the table and shows a row when its mesh is in the roster. A mesh with no
row is unreachable (that is exactly why the game's own cut `SK_SCV_FL_OCT` never appeared);
a row with no roster entry is equally invisible.

`CMSFUnlock` supplies the third piece: the selector normally shows only entitlement-gated
DLC skins, so it clears that filter.

## What ships, and what must not

`cmsf.exe` is self-contained (no .NET runtime needed), but two files sit beside it that
**CMSF must not redistribute**:

| File | Why not ours to ship |
|---|---|
| `ForeverWinter-*.usmap` | decoded from the game's own type layout — shipping it redistributes part of the game. Users dump their own with UE4SS (`Ctrl+Numpad6`, or a Lua `DumpUSMAP()` call), once per game version. |
| `oo2core_9_win64.dll` | proprietary Oodle (RAD/Epic). **retoc provisions this itself** — observed appearing next to the tool during a build, and it is not present in the game install. |

Two consequences worth stating on a mod page: **the first run may need an internet
connection** for retoc to fetch Oodle, and because `cmsf.exe` is unsigned, Windows
SmartScreen will show "unknown publisher" once — a one-click *More info → Run anyway*.

`retoc.exe` itself is MIT and can be redistributed with attribution.

## Gotchas

- **Object name after the dot.** `/Game/X/SK_Foo.SK_Foo`, not `/Game/X/SK_Foo`. The game
  resolves `<package>.<object>` strictly.
- **Watch the skeleton.** A skin whose mesh references a different skeleton than the
  character's rig will load but T-pose. Share the character's skeleton.
- **Many rows may share one mesh.** Two rows pointing at the same mesh produce two
  independently-named entries — useful for variants, and harmless if unintended.
- **Rebuild after a game patch.** CMSF owns those assets, so a stale pak would revert rows
  the patch added. The build always re-extracts from the live cook, so re-running it is the
  whole fix.
- **Co-op is client-side for appearance.** See [03-multiplayer.md](03-multiplayer.md).
