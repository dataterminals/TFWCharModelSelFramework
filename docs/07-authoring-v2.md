# Authoring a CMSF skin (v0.2)

> This is the guide for **v0.2**, where you build a pak and users install it directly.
> [04-authoring.md](04-authoring.md) describes **v0.1**, in which the *end user* ran a tool
> that merged every installed skin. The two disagree on real details — most dangerously, v0.1
> treats the portrait as optional and v0.2 does not. Follow this one.

CMSF adds skins to the character-select screen **without overwriting** any existing slot. You
do not need to own a DLC and you do not take a slot from anyone. Your skin gets its own name,
description and portrait.

---

## What CMSF does and does not do

**It does not make your model.** CMSF is the plumbing between a finished, cooked asset and the
character selector. You bring:

- a **cooked skeletal mesh** (`.uasset`) that shares the target character's skeleton
- a **cooked portrait texture** (`.uasset`)

How you produce those is the same problem as any UE5.4 asset mod and is out of scope here.
The one rule worth repeating from [04-authoring.md](04-authoring.md#gotchas): a mesh
referencing a different skeleton than the character's rig **will load and T-pose**. Share the
character's skeleton.

If you only want to surface a skin the game already ships but never wired up, you do not need
to cook anything — point `skin.json` at the existing `/Game/` path and CMSF clones it.

## What you ship

Exactly three packages, at the frozen paths of the one slot you claim:

```
/Game/CMSF/<Char>/<NN>/SK_CMSF_<Char>_<NN>     your mesh
/Game/CMSF/<Char>/<NN>/T_CMSF_<Char>_<NN>      your portrait
/Game/CMSF/<Char>/<NN>/ST_CMSF_<Char>_<NN>     your name and description
```

and nothing else. **Never `DT_SkinUIData`, never `BP_Player_*`.** That is what makes two CMSF
skins coexist instead of clobbering each other, and `cmsf-author` fails the build if anything
outside the slot directory appears — you do not have to remember it.

`skin.json` is a build-time input and **never ships**. Your users install a pak trio and
nothing else: no manifest, no config, no exe.

---

## The whole process

### 0. One-time setup

Put `cmsf-author.exe` and `retoc.exe` in a folder. Then dump a `.usmap` from your own copy of
the game and drop it beside them:

- **Ctrl+Numpad6** in-game, or a **`DumpUSMAP()`** call from Lua.

You already run UE4SS for `CMSFUnlock`, so this is not a new dependency. CMSF cannot ship a
usmap for you — it is decoded from the game's own type layout, so distributing it would
redistribute part of the game. Dump a fresh one after any game update.

> If `Ctrl+Numpad6` does nothing, UE4SS's built-in **Keybinds** mod is disabled. Set
> `Keybinds : 1` in `Binaries\Win64\ue4ss\Mods\mods.txt`, editing the line where it already
> sits — it is last in the file on purpose. `DumpUSMAP()` does not depend on the bind.

Everything else is found for you: the game via Steam, retoc beside the exe. Each has an
override (`--game`, `--retoc`, `--usmap`).

### 1. Claim a slot

```bash
cmsf-author --list-free Girl
```

Slots are **per character** — `Girl/00` and `BagMan/00` are unrelated, so you are competing
for a namespace 32 wide, not 192.

- **`00`–`27` are public.** Take the lowest free one, and add your row to
  [slots.md](slots.md) before you publish.
- **`28`–`31` are private.** Never registered, never policed. Use them for anything you are
  testing or not shipping.

You are not blocked waiting on a merge: building on an unregistered public slot is a note,
not an error.

### 2. Write `skin.json`

```json
{
  "character": "Girl",
  "slot": "07",
  "name": "Ash Runner",
  "description": "Scav Girl, kitted for the ash flats.",
  "mesh": "SK_AshRunner.uasset",
  "icon": "T_AshRunner_Portrait.uasset"
}
```

| Field | Required | Notes |
|---|---|---|
| `character` | yes | `BagMan` `Girl` `Gunhead` `MaskMan` `OldMan` `Shaman` |
| `slot` | yes | two digits; `--slot` overrides it |
| `name` | yes | shown in the selector |
| `icon` | **yes** | see below — this is not optional in v0.2 |
| `mesh` | yes | |
| `description` | no | shown under the name |
| `id` | no | defaults to the folder name |

`mesh` and `icon` each take **either** a `/Game/…` path, which is cloned out of your own
installed cook, **or** a path relative to the skin folder, which is how you ship your own
cooked assets.

### 3. Build

**Drag your skin folder onto `cmsf-author.exe`.** Or double-click it and it will ask for the
folder. The window stays open afterwards either way, so you can read the result.

From a terminal, if you prefer:

```bash
cmsf-author skins/ash-runner
```

Out comes `CMSF_Girl07_ash-runner_11_P.{pak,utoc,ucas}` in `./dist/ash-runner/`. The tool
decodes its own output back out to check it before declaring success.

> The `_11_P` in that filename is the load-order token, and the tool sets it — it is what
> makes your pak beat the framework's `_9_P`. **Do not rename the pak.** It also means every
> author's pak carries the same token, so on a slot collision the winner is decided by an
> alphabetical tiebreak you cannot influence. Claiming a free slot is the only fix.

### 4. Install and test

Alongside the framework, and **it must load above it**:

- **Manual install:** `_11_P` beats `_9_P`. The tool bakes this in; leave the filename alone.
- **MO2:** left-pane priority decides and **the filename token is discarded entirely**. Drag
  your skin above the framework.

Then boot, switch to the character, and open the skin menu.

### 5. Publish

Add your row to [slots.md](slots.md) by PR or issue, and ship the pak trio.

---

## The portrait is mandatory, and why

`CMSFUnlock` decides a slot is unclaimed by checking whether its icon resolves to the slot's
own path. A claim shipping no portrait is not merely plain — it is **pruned, invisible, and
indistinguishable from not being installed**.

That is the one authoring mistake that produces a clean build and a missing skin, so
`cmsf-author` makes it a hard error rather than a surprise in-game.

### The limit of that check

The build proves your portrait is **in the pak**. It cannot prove it **loads**. A corrupt or
badly-cooked texture yields a clean build, a green verify, and an invisible skin.

**If you supplied your own cooked texture rather than cloning a `/Game/` path, test in-game
before publishing.** This is the one failure the tool cannot catch for you.

---

## When your skin does not appear

Every failure here is silent, so start by telling them apart. Open the console and run:

```
cmsfnoprune
```

That disables hiding, so every slot shows. Now look at your slot:

| What you see with `cmsfnoprune` | What it means |
|---|---|
| `CMSF SLOT NN UNCLAIMED` | Your pak is not loading, **or is loading below the framework** |
| **Your** name, but the tile was hidden before | Pak loads fine — **your portrait failed to load** |
| Nothing at all at that slot | Slot is outside the installed pool — check the framework's depth |

That split works because the name and the visibility come from different packages: your name
comes from the string table, visibility from the portrait. A correct name on a pruned tile
isolates the fault to the texture.

`cmsfunlock` forces a re-run and prints a report; `cmsfoff` disables CMSFUnlock entirely.

### Two skins on one slot

Higher load order wins and the other is simply absent — no crash, no corruption, and nothing
on the user's side to repair beyond installing a rebuild. This is the failure the registry
exists to prevent, and why publishing means claiming.

---

## Looks like a bug, is not

**Your skin is missing for about a second** when the menu opens, then appears. Tile widgets
are pooled across the four ready-room panels, so on first population your tile still holds the
previous brush and the first prune pass misreads it. The next pass corrects it and logs
`restored N claimed CMSF tile(s)`.

**`skin menu open: N skin(s) listed` counts hidden tiles.** Collapsed tiles are still children
of the WrapBox, so 39 listed with 8 visible is correct.

---

## Slot paths are a permanent public ABI

`/Game/CMSF/<Char>/<NN>/` is append-only and never renumbered. That promise is what lets your
pak survive every framework rebuild untouched — when the framework is rebuilt for a game
patch, you do nothing.

The corollary: **the slot is baked into your pak.** Moving a skin from the private range to a
public slot is a rebuild, not a rename.

## What must not be redistributed

| File | Why |
|---|---|
| `ForeverWinter-*.usmap` | decoded from the game's type layout — shipping it redistributes part of the game |
| `oo2core_9_win64.dll` | proprietary Oodle (RAD/Epic). retoc provisions it itself |

`retoc.exe` is MIT and may be redistributed with attribution. Because retoc fetches Oodle on
demand, **an author's first run may need an internet connection** — and since `cmsf-author.exe`
is unsigned, Windows SmartScreen will show "unknown publisher" once.
