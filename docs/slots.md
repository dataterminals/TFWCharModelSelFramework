# CMSF slot registry

A CMSF skin claims one slot, `<Char>/<NN>`, and ships three packages at that slot's frozen
paths. Two skins claiming the same slot is the one failure this framework does not solve on
its own: the higher load order wins and the other is simply invisible — the exact failure
mode CMSF exists to replace. This file is how authors avoid it.

**Claiming is only needed for skins you publish.** See "The private range" below.

---

## Free slots

Run this; it reads the table below and tells you what is available:

```bash
python tools/cmsf_author.py --list-free Girl
```

## The registry

One row per published claim, sorted by character then slot. `ID` must match the skin's
folder name (or its `skin.json` `"id"`), because that is what the build tool checks against.

| Character | Slot | ID | Skin | Author |
|---|---|---|---|---|
| Girl | 00 | octogirl | Octogirl | dataterminals |

---

## Rules

**Slots are per character.** `Girl/00` and `BagMan/00` are unrelated. A Scav Girl skin can
only occupy a Girl slot, so the namespace you are competing for is 32 wide, not 192.

**`00`–`27` are public.** Claim one here by adding a row above. First come, first served,
and please take the lowest free number so the pool stays dense.

**`28`–`31` are the private range.** Never registered, never policed. Use them for personal
or work-in-progress skins, anything you do not intend to publish, and anything you are just
testing. Collisions there are your own business. The point is that a private skin never has
to touch this file, and can never collide with a published one.

> If you publish something that was living at `28`–`31`, rebuild it against a claimed public
> slot first. The slot is baked into the pak, so this is a rebuild, not a rename.

**Claims are permanent-ish.** Slot paths are an append-only public ABI: never renumbered,
never recycled while anything might still be installed. If a skin is abandoned, leave the row
and mark it — a user with the old pak still installed will otherwise see two skins fight.

**Running out is fine.** The pool extends to `99` (slot numbers are two digits by ABI —
`CMSFUnlock` matches `CMSF%.%a+%.%d%d`). If a character's public range fills, the framework
gets rebuilt deeper and the existing claims are untouched. It costs every user a framework
re-download, so it is worth not doing casually, but it is not a wall.

## How to claim

Either works:

- **Open a pull request** adding your row. Self-service, no waiting.
- **Open an issue** with your character, desired slot, ID, skin name and author name, if you
  would rather not touch git.

Then build against it:

```bash
python tools/cmsf_author.py skins/<your-skin> --slot <NN>
```

The build tool reads this file. Claiming a slot registered to someone else is an error;
building on an unregistered public slot is a warning, not a block — so you are never stuck
waiting on a merge to test something locally.

## If two skins collide anyway

One skin shows and the other is absent — no crash, no corruption, no damage to anything else.
The fix is for one author to rebuild against a free slot. Nothing on the user's side needs
repairing beyond installing the new pak.

**Which one wins is not something you can influence, so do not try.** Every CMSF author pak
carries the same `_11_P` load-order token — the build tool sets it, precisely so nobody gets
it wrong against the framework's `_9_P`. Two paks claiming one slot therefore mount at the
*same* Order, and the winner falls to the engine's tiebreak: the alphabetically **lowest**
filename. Since the names are `CMSF_<Char><NN>_<id>_11_P`, that means the author `id` decides
it — `CMSF_Girl00_aardvark_11_P` beats `CMSF_Girl00_zebra_11_P`.

So renaming your pak is not a fix. Claiming a free slot is the only fix.

> Under MO2 none of the above applies: the
> [ForeverWinterMO2Support](https://github.com/dataterminals/ForeverWinterMO2Support) plugin
> rewrites the token from left-pane priority, so the user's mod order decides and the baked-in
> `_11_P` is discarded.
