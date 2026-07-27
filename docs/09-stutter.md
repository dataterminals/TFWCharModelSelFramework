# The skin-menu stutter — what is known, and what is still guessed

Live thread. `CMSFUnlock` polls for the skin selector, and that poll has been a frame hitch since
v0.1.1. Two fixes have shipped for it. **Neither has been verified in-game**, and the second one
was reported still broken by a player, so read the "what is actually established" section before
trusting anything here.

## The mechanism

`CMSFUnlock` cannot be event-driven today, so it watches for `WBP_SkinSelection_C` on a timer and
unfilters it when it appears. The watch is `FindAllOf`, and **`FindAllOf` is a full walk of the UE
object array** — millions of entries in a shipped build. Running it at a fixed 1 Hz forever is the
whole problem. Everything below is an attempt to pay for that walk less often.

## What was tried, in order

**v0.1.1 — wrap the poll in `ExecuteInGameThread`.** Correct and necessary: off-thread UObject
writes silently do not take, which is why v0.1 did nothing at all. But it put the *entire* poll
body on the game thread, so both `FindAllOf` walks per tick (the apply scan, plus a second one in
the old standalone `reportCount`) now landed on the thread that renders frames. A hitch at exactly
the poll cadence, everywhere, forever — including in raids, where the selector does not exist.

**v0.2.0 — gate the poll off the game thread.** Added `anySelectorResident()`: a read-only
`FindAllOf` presence check *off* the game thread, deciding whether to hop on at all. Folded the
redundant second scan into `apply()`'s existing walk. Net effect: an absent selector costs zero
on-thread walks, a resident one costs one instead of two.

Shipped on reasoning alone. **A player reported the hitch was clearly better and clearly still
there — in raids as well as the ready room.**

**v0.2.1 (this change, unverified) — make the idle poll rare.** The raid report is the important
part: with no selector resident, v0.2.0 does *nothing* on the game thread, so a remaining raid
hitch means the walk costs wherever it runs. Plausibly cache: touching the whole object array once
a second evicts a great deal of it and the game thread pays the misses.

So the scan interval now backs off — doubling on each miss to `IDLE_MAX_TICKS` (8), snapping back
to every tick the moment a selector appears. Scans land at t = 1, 3, 7, 15, 23, 31 s and then
settle; a 30-minute raid goes from ~1800 walks to ~225. The tick itself stays at 1 Hz because
`LoopAsync`'s interval is fixed at registration, so the saving comes from skipping, not from a
slower timer.

## Field test #1 — 2026-07-26: the backoff was disarmed in 7 seconds

First live run of v0.2.1. The whole story was recovered from the run's `UE4SS.log` — under MO2 it
lands at `overwrite/Root/Windows/ForeverWinter/Binaries/Win64/ue4ss/UE4SS.log` and is truncated
each launch, so read it before the next run overwrites it.

Receipts, session 12:59:45 → ~13:00:40 — 55 seconds, never past the frontend:

```
12:59:55.94  [CMSFUnlock] v0.2.1 loaded          right build; the version banner's first day on the job
13:00:03.44  [CMSFUnlock] selector unfiltered    7.5 s after mod start, AT THE MAIN MENU
```

Two conclusions, one of them embarrassing for the design:

1. **Something answering to `WBP_SkinSelection_C` is resident at the main menu.** No hub, no
   ready room, no menu opened — 7.5 s in. The "selector only exists in the ready room" premise
   written into main.lua is measured wrong.
2. **Once it is resident, the backoff is dead code.** The gate sees it, `scanEvery` pins to 1,
   and the poll is back to one on-thread object-array walk per second for the rest of the
   session. The 13:00:03 timestamp even fits the schedule: scans at t≈1 and t≈3 missed, the
   t≈7 scan hit. (The other fit — resident from t=1 with the filter flag only turning true at
   t≈7 — pins it earlier still. Either way it stays pinned.)

Felt result, same day: still cyclical, much fainter, "heartbeat-like" — a ~1 Hz pulse, which is
exactly what a pinned poll produces. The backoff did not fail; it was disarmed by a squatter it
was never taught to ignore.

The squatter's NAME decides everything, and a count cannot supply it, so `cmsfscan` now prints
the full name and validity of each object found:

| Names show | It is | The fix |
|---|---|---|
| Only `Default__WBP_SkinSelection_C` | The class-default object — collateral of the class loading, resident forever after | Teach residency to ignore CDOs. The name check must run on the game thread (the RULE), so the loop backs off whenever a pass sees no real instance. Backoff revives everywhere a menu is not on screen. |
| A real instance, at the menu | The frontend genuinely keeps a selector constructed | The absence-based gate is wrong at the root. Candidates: gate on the hub map package instead (`StaticFindObject` — a hash lookup, not a walk) or an engine event. Neither verified on this build; probe first. |

Next session's script, ~90 seconds, pasting output each time:

1. Main menu, once the heartbeat is felt: `cmsfoff`. If the pulse survives with the mod off, it
   is not (only) ours — attribution before optimisation.
2. `cmsfunlock` to re-arm, then `cmsfscan` at the menu — the names.
3. `cmsfscan` in the hub.
4. `cmsfscan` in a raid — prices the walk where it cannot early-out (the number
   `IDLE_MAX_TICKS = 8` is still a guess against), and shows whether the squatter survives the
   map change.

**v0.2.1's raid behaviour remains untested.** The one live session never left the frontend.

## Field test #2 — 2026-07-26: names and a number, and the case is closed

Second live session (13:25–13:28), running the exact script above. Everything below is measured,
not argued.

**The walk costs ~35 ms ON the game thread** — 36.2 / 34.75 / 33.85 ms across the three
`cmsfscan` runs, dead consistent whether it finds five objects or one. At 60 fps that is
two-plus dropped frames every time a scan lands. The decision table's worst row fired: the poll
cannot merely be rationed, it has to go away wherever possible.

**The squatter is named, and it is neither of the two candidates.** Not the CDO, not a live
frontend widget:

```
WBP_SkinSelection_C /Game/FW/UI/MainMenu/UMG/Widgets/WBP_PlayerStatusWidget.WBP_PlayerStatusWidget_C:WidgetTree.WBP_SkinSelection
```

That is the **WidgetTree template inside the `WBP_PlayerStatusWidget` asset** — the design-time
subobject every UMG blueprint carries. It loads with the menu UI (~7 s after boot, which is what
field test #1 caught), it is `/Game/`-rooted because it lives in a cooked package, and it stays
resident to process exit. It is what answered "yes" to every `anySelectorResident()` and
`FindAllOf`-non-empty check in v0.2.0 and v0.2.1 — everywhere, raids included. Both prior fixes
were defeated by this one object.

**The live panels are real, four of them, and GameInstance-owned.** `Player1ReadyPanel` through
`Player4ReadyPanel` under `WBP_MenuMaster → WBP_ReadyRoom`, rooted in `/Engine/Transient` —
constructed at the main menu, surviving into the hub **with identical object IDs across scans
17 s apart**, destroyed on raid entry (the raid scan finds only the template). This is the
missing lifecycle: cacheable in the frontend, absent in raids.

**The discriminator is the name root.** Live = rooted under `/Engine/Transient` (runtime
construction). Template = rooted under `/Game/` (asset package). Runtime widgets are never
constructed into cooked packages, so the split is definitional, not heuristic. Fail open:
an unreadable name counts as live — wrongly polling for a template costs a hitch, wrongly
ignoring a real selector is v0.1 again.

Bonus verifications from the same session, free of charge: rung 9 arithmetic exact at scale —
`39 skin(s) listed` = 7 vanilla + 32 CMSF, `hid 128` = 32 slots × 4 panels (Octogirl's pak
disabled in this profile, so all 32 prune). And the version banner did its job twice.

### v0.2.2 (unverified) — cache the panels, discount the template, drop the gate

1. **Live-handle cache.** A walk stores the live panels' handles (obtained on the game thread;
   only ever used on the game thread; `IsValid()`-revalidated on every pass, one stale entry
   dumps the lot). Frontend steady state: **zero walks** — enforcement is a handful of property
   reads on four widgets. The cache survives menu↔hub because the panels do (measured above);
   raid entry invalidates it, and the next walk repopulates it on return.
2. **Backoff keys on live instances only.** The template no longer counts as residency, so a
   raid converges to at most one 35 ms walk per `IDLE_MAX_TICKS` (8 s) — and that walk is also
   the raid→hub return detector, so the worst case is an 8 s delay before a fresh frontend gets
   re-enforced, self-correcting and manually overridable with `cmsfunlock`.
3. **The off-thread gate is gone.** The template kept it permanently true, so it was a second
   35 ms walk per landed scan buying nothing. The RULE is back to "no exceptions."
4. New assumption to watch: a cached handle whose object died reads `IsValid() == false` rather
   than crashing. Everything is pcall'd; a crash on raid entry in field test #3 points here.

Expected feel, if right: menu/hub heartbeat **gone** (one walk at boot, then cached); raid pulse
at most one 35 ms blip every 8 s. Expected log: `v0.2.2 loaded`, and in a raid `cmsfscan` still
reports 1 found (the template) — that is now fine.

### The v0.3 probe is armed

CMSFTime now registers `NotifyOnNewObject("/Script/UMG.UserWidget")`, filters for the selector
class by name, and **logs only** (the object is mid-construction; nothing touches it). If the
next session's log shows `NOTIFY` lines when the frontend builds its panels — and again on every
raid→hub return — then v0.3 goes event-driven and even the raid's 8 s walk disappears: construct
→ enforce, no polling at all. Zero NOTIFY lines across a menu→raid→menu cycle means the
mechanism is dead on this UE4SS build and v0.3 gates on the hub map instead. `cmsfscan` also
prints the selector's exact class path now, for exact-class registration later.

## What is actually established, versus assumed

Established, all of it measured as of field test #2: one walk = **~35 ms on the game thread**,
regardless of hit count; the squatter that pinned every gate is the **`WBP_PlayerStatusWidget`
asset's WidgetTree template** (resident from menu load to exit); the four live panels are
GameInstance-owned, built at the main menu, stable across menu↔hub, destroyed in raids;
live-vs-template splits cleanly on the name root (`/Engine/Transient` vs `/Game/`).

**Assumed, and load-bearing, in v0.2.2:** that cached game-thread handles stay safe to hold
across polls — a dead object must read `IsValid() == false` rather than crash — and that the
cache-invalidation → walk → backoff sequencing behaves at real map transitions. Neither is
verified in-game yet. `NotifyOnNewObject` viability for v0.3 is exactly what the armed probe
measures next session.

The original sizing table, kept for the record — the third row is what fired (35 ms), which is
why v0.2.2 caches instead of merely rationing:

| `cmsfscan` says | What it means | Next move |
|---|---|---|
| Well under 1 ms | The backoff is over-cautious and the walk is not the story | Look at the `Init()`-every-poll suspect below |
| Around 1 ms | Backoff is roughly right; a raid now hitches once per 8 s instead of every second | Tune `IDLE_MAX_TICKS`, ship |
| **Several ms** ← this one | Every landed scan drops a frame, and rarity is not enough | The poll has to go away entirely — v0.2.2's cache + the v0.3 event probe |

## The suspect nobody has ruled out

`apply()` calls `w:Init()` whenever `SelectLockedSkinsOnly` reads as anything but `false`, **or
when the read fails**. If the game re-sets that flag on each panel rebuild, or the read is
unreliable, that is a full widget rebuild × 4 ready-room panels *every second* — and the `quiet`
flag suppresses the log after the first success, so this would be **completely invisible in the
log**. `cmsftime` measures what one `Init()` costs. Check this before doing anything clever.

*Field test #2 largely acquits this suspect:* the poll unfiltered once at load, and a manual
`cmsfunlock` ninety seconds of polling later reported `0 changed / 5 selector(s) found` — the
flag held `false` across that whole window, so `Init()` was not being re-triggered every pass.
The walk was the cost, full stop.

## Still outstanding as of v0.2.1: the ready room *(addressed by v0.2.2's cache — see field test #2)*

A resident selector still costs one on-thread walk per second, because `apply()` must re-run
`FindAllOf` on the game thread — handles taken off-thread could be collected between the scan and
the use. The backoff deliberately does not apply here: `prune()` has to stay quick behind `Init()`,
which rebuilds the tiles and undoes the previous pass. *(v0.2.2 resolves the tension a third way:
handles obtained on-thread during one walk are cached and revalidated with `IsValid()` each pass,
so the 1 Hz enforcement no longer needs any walk at all.)*

Removing that means replacing the poll with an event. Two candidates, **neither verified against
this build (UE4SS 3.0.1-894)**:

- `NotifyOnNewObject` on the selector's Blueprint class. Fires at construction, so a bounded
  follow-up is still needed for the texture claim race (an author's icon may not resolve for
  seconds — see rung 9). Registration may need the full `/Game/...` class path, **which this repo
  has never recorded**, and the class may not be loaded at mod-load time.
- `RegisterLoadMapPostHook` to learn ready room versus raid, and only poll in the former.

Whichever is chosen: keep the polled path as a fallback, log which one is live, and verify in-game.
An event path that silently never fires is v0.1's failure mode exactly.

## Housekeeping

`dist/release/CMSF-v0.2.0.zip` still contains the **pre-v0.2.0** Lua — it was built before the gate
landed and has not been rebuilt since. Deliberate: do not rebuild it until the fix is confirmed
live. `tools/package-release.ps1` now defaults to `-Version 0.2.1`.
