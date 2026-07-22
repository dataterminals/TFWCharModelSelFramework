# Public-facing copy — DRAFT

Everything here is for reaction, not for shipping as-is. The technical record lives in the
other docs; this is the only file written for people who do not read those.

Three audiences, and they want different things:

| Audience | Where | Wants |
|---|---|---|
| **End user** | Nexus page | what it does, what it needs, how to install it |
| **Skin author** | Nexus "for authors" + repo | how to get their skin into it |
| **Anyone deciding whether to care** | announcement post | why this is not another skin mod |

---

## A. Nexus mod page — the framework

**Title:** CMSF - Character Model Selection Framework
**Version:** 0.2.0

### Short description (the one-liner Nexus shows in listings)

> Adds new character skins to the select screen instead of overwriting the ones the game
> ships with. Also unlocks the base skins the game already has but never lets you pick.

### Description

Every skin mod for The Forever Winter today works by **overwriting** a skin the game already
has. That means you need to own the DLC whose slot you are borrowing, you are capped at
however many slots that character has, two mods wanting the same slot silently fight, and the
character-select portrait still shows the original skin, because the thumbnail lives somewhere
the mod never touched.

CMSF adds skins **alongside** the ones already there. New entry, its own name, its own
description, its own portrait. Nothing gets replaced, nothing gets taken, and two CMSF skins
can never break each other.

**It is worth installing before you have a single skin mod.** The game ships base skins it
never lets you select — and normally, picking a DLC skin strands you on it until you die in a
raid and get randomly reassigned. CMSF unlocks the selector, so you can just choose.

### What you install

Two pieces, once:

- **The framework pak** (0.57 MB) — provisions the slots skins claim
- **CMSFUnlock** — a small UE4SS Lua mod that unlocks the selector and hides slots nobody has
  claimed, so your menu only ever shows real skins

After that, a CMSF skin is an ordinary pak you drop in like any other mod. **No tool to run,
no config file, no re-running a generator when you add one.**

### Requirements

- **UE4SS** — tested against `3.0.1-894`. You likely have it already if you run TFW mods.
- **Signature Bypass** — required for any content pak mod, not just this one.

### Installing

Copy the **`Windows`** folder from the archive into your game folder, so it merges with the
one already there:

```
...\steamapps\common\The Forever Winter\
```

That puts the framework pak in `Content\Paks\Mods\` and `CMSFUnlock` in
`Binaries\Win64\ue4ss\Mods\` in one step. Launch, pick a character, open the skin menu.

> **Mod Organizer 2 users: do not copy anything into the game folder.** Install the archive as
> an ordinary MO2 mod instead, and see the load-order note below.

Skin mods go in the same `Mods\` folder as the framework, and **must load after it** — their
filenames already carry the right load-order token, so do not rename them.

> **Mod Organizer 2 users:** MO2's left-pane priority decides load order and overrides the
> filename, so put skins **above** the framework. You will also want
> [ForeverWinterMO2Support](https://github.com/dataterminals/ForeverWinterMO2Support).

### Things that are not bugs

- **A skin can be missing for about a second** when the menu first opens, then appear. The
  game reuses the same tile widgets across panels, so the first pass reads a stale image. It
  corrects itself immediately.
- **Empty slots do not show.** The framework provisions many slots; you only ever see ones a
  skin actually claimed.

### If a skin you installed is not showing

Almost always load order — the skin pak has to load **after** the framework. Open the console
and type `cmsfnoprune` to show every slot including empty ones. If yours reads
`CMSF SLOT NN UNCLAIMED`, the pak is not loading, or it is loading before the framework.

### Uninstalling

Delete the files. If you were wearing a CMSF skin, the game rolls you onto a normal one next
time you die. Nothing to repair.

### Credits and licence

CMSF is MIT licensed. Built with [retoc](https://github.com/trumank/retoc) (MIT, Truman Kilen
and Archengius) and [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS).

---

## B. Nexus page — the "for skin authors" section

> ### Making a CMSF skin
>
> If you can already produce a cooked mesh for the game, CMSF is the last mile: you claim a
> numbered slot, run one tool, and get an ordinary pak.
>
> ```
> cmsf-author.exe --list-free Girl     # what's available
> cmsf-author.exe my-skin              # build it
> ```
>
> Your pak contains exactly three packages — your mesh, your portrait, and your name — at
> paths reserved for the slot you claimed. It never touches the game's skin table, which is
> precisely why two CMSF skins cannot break each other.
>
> **Your portrait is not decoration.** CMSF works out whether a slot is claimed by checking
> whether a portrait loads at it, so a skin without one is not plain — it is invisible. The
> tool refuses to build without it.
>
> Author tool and full guide: [the repo](https://github.com/dataterminals/TFWCharModelSelFramework).

---

## C. Announcement / release notes — v0.2.0

> **CMSF v0.2.0 — skins that add instead of overwrite**
>
> The Forever Winter gives each character a fixed handful of skin slots, and every skin mod so
> far has had to take one. Own the DLC, pick a slot, hope nobody else picked it. CMSF appends
> instead: a new selector entry with its own name, description and portrait, and no slot taken
> from anyone.
>
> Users install a 0.57 MB framework once. After that a skin is just a pak you drop in — no
> tool, no manifest, no regeneration step. Authors get `cmsf-author.exe`, which turns a cooked
> mesh and a portrait into that pak.
>
> It also unlocks the base skins the game ships but never lets you choose, which is worth
> having on its own.
>
> Validated in-game across all six characters. Multiplayer and behaviour across a game patch
> are **not** yet tested — see the repo for exactly what is proven and what is not.

---

## Notes on what NOT to claim

Things it would be easy to overstate, and should not be:

- **"Unlimited skins."** The pool is 32 per character. Large, not unlimited, and the number is
  a permanent ABI once released.
- **"Works in co-op."** Untested. `docs/03-multiplayer.md` has theory, not observation.
- **"Survives game updates."** The framework must be rebuilt from each new cook, and that has
  never been exercised against a real patch. Author paks *should* survive untouched, because
  slot paths are append-only — but "should" is doing work there.
- **"Just works with MO2."** It does, but only with the companion plugin and the right
  priority. Manual install is the supported baseline.
- Anything implying a skin will look right without the author testing it. The build tool
  proves a portrait is in the pak, not that it renders.
