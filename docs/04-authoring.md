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
