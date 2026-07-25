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

## What is actually established, versus assumed

Established: the walk is expensive enough to feel; off-thread is cheaper than on-thread but not
free; the selector is resident throughout the ready room, not only while the menu is open.

**Assumed, and load-bearing:** that cache/contention from the walk is what remains. Nobody has
timed a single `FindAllOf`. `IDLE_MAX_TICKS = 8` is a guess sized against a number that does not
exist yet.

That is what `cmsfscan` in the `CMSFTime` dev mod is for. Run it in the ready room, then **in a
raid**, where it finds nothing and therefore cannot early-out — the raid figure is the one the
backoff is sized against.

| `cmsfscan` says | What it means | Next move |
|---|---|---|
| Well under 1 ms | The backoff is over-cautious and the walk is not the story | Look at the `Init()`-every-poll suspect below |
| Around 1 ms | Backoff is roughly right; a raid now hitches once per 8 s instead of every second | Tune `IDLE_MAX_TICKS`, ship |
| Several ms | Every landed scan drops a frame, and rarity is not enough | The poll has to go away entirely — see below |

## The suspect nobody has ruled out

`apply()` calls `w:Init()` whenever `SelectLockedSkinsOnly` reads as anything but `false`, **or
when the read fails**. If the game re-sets that flag on each panel rebuild, or the read is
unreliable, that is a full widget rebuild × 4 ready-room panels *every second* — and the `quiet`
flag suppresses the log after the first success, so this would be **completely invisible in the
log**. `cmsftime` measures what one `Init()` costs. Check this before doing anything clever.

## Still outstanding: the ready room

A resident selector still costs one on-thread walk per second, because `apply()` must re-run
`FindAllOf` on the game thread — handles taken off-thread could be collected between the scan and
the use. The backoff deliberately does not apply here: `prune()` has to stay quick behind `Init()`,
which rebuilds the tiles and undoes the previous pass.

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
