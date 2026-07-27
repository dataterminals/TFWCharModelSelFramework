# The skin-menu stutter — what is known, and what is still guessed

**SOLVED, field test #4 (2026-07-27). The cause was never the poll. It is `prune()`.**

Read that section first; most of what follows it was written while chasing the wrong object and
is kept only because the wrong turns are instructive.

The one-line version: `enforceOne` calls `prune(w)` on **every pass, for every panel,
unconditionally**, and `prune` re-derives each tile's claimed/unclaimed verdict from scratch —
about 128 tiles × five reflective UObject reads plus 128 `GetFullName()` calls, every second, on
the game thread. It logs **only when it changes a tile's visibility**, so a pass that inspects all
128 and changes nothing is completely silent. Three consecutive fixes optimised `FindAllOf` while
this sat one line below the code they were editing.

The cost of not measuring: v0.2.0, v0.2.1 and v0.2.2 were each shipped on reasoning, each
genuinely made the poll cheaper, and none of them touched the actual cause. A single three-second
`cmsfoff` in field test #1 would have got there four versions earlier. **Measure first** is the
whole lesson of this document.

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

*Outcome (field test #3): the log expectations all held; the feel expectations did not. The
stutter is still reported at the menu and in Innards. Every prediction this section makes about
CMSF's own cost was confirmed, which is precisely why the symptom surviving points away from CMSF.*

### The v0.3 probe is armed

CMSFTime now registers `NotifyOnNewObject("/Script/UMG.UserWidget")`, filters for the selector
class by name, and **logs only** (the object is mid-construction; nothing touches it). If the
next session's log shows `NOTIFY` lines when the frontend builds its panels — and again on every
raid→hub return — then v0.3 goes event-driven and even the raid's 8 s walk disappears: construct
→ enforce, no polling at all. Zero NOTIFY lines across a menu→raid→menu cycle means the
mechanism is dead on this UE4SS build and v0.3 gates on the hub map instead. `cmsfscan` also
prints the selector's exact class path now, for exact-class registration later.

*Answered by field test #3: the mechanism is alive, including for runtime constructions. v0.3 is go.*

## Field test #3 — 2026-07-27: the internals check out, the stutter does not go away

First live run of v0.2.2. Session 08:01:34 → raid → clean exit; **no crash dump** (the newest in
the instance is still 2026-07-20). Log lines cited below are from this session's `UE4SS.log`.

**`NotifyOnNewObject` fires on this build, for runtime constructions as well as templates.** This
was the v0.3 go/no-go and it is unambiguous. Two populations, cleanly separated by exactly the
name root established in field test #2:

```
08:01:35  NOTIFY #1–6    /Game/...      package load — the asset's own WidgetTree subwidgets,
                                        #6 being the WBP_PlayerStatusWidget squatter itself
08:02:29  NOTIFY #7–10   /Engine/Transient...  GameInstance → WBP_MenuMaster → WBP_ReadyRoom →
                                        Player1..4ReadyPanel → PlayerStatus → WBP_SkinSelection
```

`#7–10` are the four live panels, constructed at runtime, caught by the event. Construct →
enforce with no polling is therefore viable. Two design notes fell out for free: the probe's
substring filter also matched `WBP_BackgroundPanel_C`, `WBP_Border_C` and `WBP_SingleButton_C` —
sub-widgets that merely live under the selection widget's path — so **v0.3 must key on class
`WBP_SkinSelection_C` *and* an `/Engine/Transient` root**, which would have cut these ten lines
to the four that matter. And `#7–10` landed 55 s after the probe armed, while the mod's own
load-time state was necessarily built before any panel existed: **v0.3 still needs one sweep at
mod load, plus the event** — the polled path shrinks to a single boot pass rather than vanishing.

**The live-handle cache survives a frontend rebuild, and the `IsValid()` assumption held.** The
panels unfiltered at 08:01:39 were superseded by *new* instances at 08:02:29 (different object
IDs), killing every cached handle. What followed is the whole invalidation path executing
correctly, in the log:

```
08:02:48  skin menu open: 39 skin(s) listed
08:02:48  hid 128 unclaimed CMSF tile(s)
```

Stale handles read `IsValid() == false` instead of crashing, the cache dumped, one walk
repopulated it, and enforcement re-applied to the new panels. Raid entry — the second and harsher
invalidation, where the panels die and nothing replaces them — also passed without a crash or a
single log line, which is exactly the designed silence. Rung 9 arithmetic came out exact again:
`39` = 7 vanilla + 32 CMSF, `128` = 32 slots × 4 panels.

**The stutter is NOT fixed, and the raid reports conflict.** Recorded verbatim, because the
disagreement is itself the datum. Entering Innards: *"stutters still stuttering, that's for sure,
in innards."* Mid-raid, a few minutes later: *"the raid feels fine, honestly."* After the session:
*"innards stutter still isn't fixed though."* The menu was reported stuttering throughout, first
noticed after opening the escape menu. **No measurement was taken at any of those moments** — no
`cmsfoff`, no `cmsfscan` — so all three are impressions, and the middle one was taken at face
value in the first draft of this section. It should not have been.

What matters is that the signatures no longer match the accused mechanism. In a raid v0.2.2
converges to **one ~35 ms walk per 8 s**; in the frontend, with the cache warm, it does **none**.
A stutter that is continuous, or cyclical faster than every eight seconds, cannot be that poll —
and Innards is a heavy map with vanilla traversal and shader-compilation hitching of its own.
Three fixes have now been aimed at this poll on reasoning alone, and the felt problem has survived
all three. The likeliest reading is no longer "the fix was insufficient" but **"the poll was never
what the player is feeling"** — which is exactly what a single `cmsfoff` would confirm or kill.

**`Init()`-every-pass is now acquitted by a mechanism that cannot hide it.** The prune log has no
`quiet` flag — `if pruned > 0 then log(...)` fires on *every* pass that re-hides a tile. A
three-minute frontend session produced exactly two such lines (08:02:48 and 08:04:45), not one per
second. Init() is not re-running per pass, and frontend steady state really is the cached path:
four handles, a few property reads per second, zero walks.

That second re-prune is itself the interesting artefact. `hid 128` means all 32 slots × all 4
panels were rebuilt and needed re-hiding — yet **no NOTIFY fired**, so the panels themselves were
not reconstructed; only their tiles were. Reported alongside it: the menu felt fine at first, and
the stutter was noticed *after opening the escape menu*. Something in that UI path rebuilds the
tiles in place. Worth understanding, but 128 visibility writes twice in three minutes is not a
1 Hz heartbeat.

### The gap this session leaves *(closed by field test #4, same day)*

**`cmsfoff` was not run, so the stutter — menu or raid — remains unattributed to anything.** It is
the same test this doc has asked for since field test #1, and skipping it has now cost three
sessions. It matters more each time, because the mechanism that made "it's ours" the obvious
reading keeps shrinking: through v0.2.1 there was a real 1 Hz on-thread 35 ms walk to blame, and
under v0.2.2 there is no frontend walk at all and one per 8 s in a raid. Either the stutter is not
ours, or it lives somewhere other than the poll — and the entire rest of this investigation is
guesswork until that three-second test happens.

The trap to avoid on the next pass: **do not ship a v0.2.3 aimed at the poll.** v0.2.0, v0.2.1 and
v0.2.2 were each shipped on reasoning, each made the poll cheaper, and none fixed the symptom. A
fourth would be the same mistake with a new number.

Also unmeasured: **no raid → hub return occurred**, so whether NOTIFY fires when the frontend is
rebuilt after a raid is still unknown — and that is precisely the case v0.3's event path has to
cover. No `cmsfscan`/`cmsftime` either, so the ~35 ms walk cost stands on field test #2's numbers
alone.

Next session, attribution before anything else, and nothing else until it is done:

1. **At the stuttering menu: `cmsfoff`, wait three seconds.** Does the stutter stop? Then
   `cmsfunlock` and confirm it comes back. Both directions, because a one-way test invites
   coincidence.
2. **In Innards, once it is stuttering: `cmsfoff` again, same three seconds.** This is the one
   that has never been tried, and Innards is where the report is most consistent.
3. If the stutter survives `cmsfoff` in either place, **stop optimising CMSF** — pull the mod
   entirely for one raid and confirm against vanilla. A hitch that outlives a disabled mod and a
   removed mod is the game's, and this document ends there.
4. Only if it *does* track `cmsfoff`: `cmsfscan` for names and cost, then raid → **return to the
   hub** and watch for NOTIFY #11+ to settle v0.3's event coverage.

## Field test #4 — 2026-07-27: attribution, at last, and it is not the poll

The `cmsfoff` test this document had been asking for since field test #1 finally happened. Three
states, felt at the frontend, all three agreeing:

| State | Poll running? | Tile inspection? | Stutter |
|---|---|---|---|
| `cmsfoff` (10:07:09) | no | no | **gone** |
| `cmsfunlock` (10:09:42) | yes | yes | **back** |
| `cmsfnoprune` (10:09:52) | **yes** | no | **gone** |

The third row is the one that settles it. With the poll, the enforcement and the 1 Hz cadence all
still running, disabling *only* the tile inspection removes the stutter. **The poll is exonerated
and `prune()` is the cause.** Both directions were confirmed rather than one, so this is not a
coincidence of timing.

### The mechanism, in the code

[`enforceOne`](../runtime/CMSFUnlock/Scripts/main.lua) calls `prune(w)` unconditionally on every
pass — not gated on the filter having changed, deliberately, because reopening the menu
repopulates the WrapBox without necessarily re-setting the flag. `prune` then walks
`SkinOptions:GetAllChildren()` and calls `slotState(t)` per tile, which per CMSF tile does:

1. `tostr(t.SkinRow.RowName)` — struct member through a RemoteUnrealParam wrapper, plus `ToString`
2. `unwrap(t.SkinIcon)` → `unwrap(img.Brush)` → `unwrap(brush.ResourceObject)` — three more
   wrapped reads, each with a `pcall` and a `:get()`
3. `tostr(res:GetFullName())` — a **string-building UObject call**, the expensive one

Four panels × 32 CMSF tiles = **128 tiles, ~640 reflective operations and 128 `GetFullName()`
calls, per second, on the game thread.** That is the heartbeat. It is the same shape as the
`Init()`-every-pass suspect this document chased and cleared in field test #2 — and it was one
line further down the same function the whole time.

**Why it stayed invisible.** `prune` returns counts, and the loop logs `hid N` only when
`N > 0` — i.e. only when a tile's visibility actually *changed*. Steady state changes nothing,
so 128 tile inspections per second produce zero log output. Field test #3 read the sparse `hid`
lines as evidence the per-pass path was cheap. They were evidence of nothing at all.

**Supporting number, from the `cmsfunlock` run.** Verbose mode logs once per panel, and those four
lines came 18 ms apart (10:09:42.142 / .161 / .179 / .198): **~18 ms per panel** for `Init()` plus
a 32-tile prune, ~72 ms for the set. Field test #2's 35 ms was the walk; this is a second,
independent, larger cost that nobody had measured.

**Bonus finding:** `apply: 4 changed / 5 selector(s) found (4 live)` after two minutes of
`cmsfoff` — the game had re-filtered all four panels in that window. Enforcement genuinely cannot
be one-shot; the flag really does get re-set.

### Why three fixes all missed, and why the raid reports conflicted

The menu and the raid had **different causes**, which is exactly why fixing either one never
resolved "the stutter":

- **In a raid** the four panels are destroyed, so `prune` has nothing to walk. The cost there was
  the 1 Hz `FindAllOf` — held at full cadence by the asset template — and **v0.2.2 genuinely fixed
  it.** That is the mid-session *"the raid feels fine, honestly."*
- **At the menu** the panels exist, so `prune` runs on all four every second. No version has ever
  touched it. That is every "still stuttering" report, in every field test.

The Innards report still needs its own `cmsfoff`: v0.2.2 leaves at most one 35 ms walk per 8 s
there, which does not match a continuous hitch, and Innards has vanilla traversal and
shader-compilation stutter of its own. Frontend attribution does not transfer to a raid map.

### What v0.2.3 must do

The verdict for a row is **stable once resolved** — `CMSF.Girl.00` either has a texture at
`/Game/CMSF/Girl/00/T_CMSF_Girl_00` or it does not, and a pak does not mount mid-session. So the
per-second re-derivation buys nothing. Reuse the pattern field test #3 already proved works for the
panel cache:

1. **Cache tile handles plus their resolved verdicts per panel.** A pass revalidates handles with
   `IsValid()`; if they all hold, the tiles were not rebuilt and the pass can **skip entirely**.
   Steady state becomes four `IsValid()` calls per second.
2. **A dead handle means `Init()` rebuilt the tiles** — dump that panel's cache, re-derive once,
   re-cache. Exactly the invalidation shape that survived a frontend rebuild and raid entry.
3. **Memoise `slotState` by row name** for the re-derive path, so even a rebuild pays the
   `GetFullName()` cost once per row per session rather than once per pass.
4. **Keep fail-open intact.** A `nil` verdict (icon not resolved yet — the claim race) must stay
   *uncached* so it is retried; that is what makes a transient misread self-correct, and rung 9
   already learned that lesson the hard way.
5. **The endgame is events.** `NotifyOnNewObject` is confirmed working (field test #3), so v0.3
   can register `WBP_SkinButton_C` construction and prune on that signal alone — no polling, no
   revalidation.

Do **not** ship this on reasoning. The three-state `cmsfoff` / `cmsfunlock` / `cmsfnoprune` table
above is now the regression test: after v0.2.3, plain `cmsfunlock` should feel like `cmsfnoprune`
does today.

## What is actually established, versus assumed

Established as of field test #2: one walk = **~35 ms on the game thread**, regardless of hit
count; the squatter that pinned every gate is the **`WBP_PlayerStatusWidget` asset's WidgetTree
template** (resident from menu load to exit); the four live panels are GameInstance-owned, built
at the main menu, stable across menu↔hub, destroyed in raids; live-vs-template splits cleanly on
the name root (`/Engine/Transient` vs `/Game/`).

Added by field test #3, and these retire what v0.2.2 was assuming: **cached game-thread handles
are safe to hold across polls** — a dead one reads `IsValid() == false` rather than crashing,
proven at a frontend rebuild and again at raid entry, no crash dump either time; **the
invalidation → walk → re-enforce sequence works at a real transition** (39 listed / 128 hidden on
freshly constructed panels); **`Init()` does not re-run per pass** (the unsuppressed prune log
fired twice in three minutes, not 180 times); **`NotifyOnNewObject` fires for runtime-constructed
panels**, not just templates, which clears v0.3's event path.

All of that is about v0.2.2's *internals*, and all of it held up.

Added by field test #4, and this is the load-bearing one: **the frontend stutter is `prune()`**,
established by a three-state test whose middle state keeps the poll running — `cmsfoff` quiet,
`cmsfunlock` stuttering, `cmsfnoprune` quiet again. **The poll is exonerated at the frontend.**
Per-panel enforcement measured at **~18 ms** (`Init()` + a 32-tile prune), ~72 ms for four. The
game **re-filters all four panels** if enforcement is absent for ~2 minutes, so enforcement cannot
be one-shot. And a single-panel rebuild (`hid 32`, one panel's worth) fires on menu *interaction*,
confirming the prune's *logged* work is event-driven even though its *unlogged* work is per-pass.

**Still assumed, or simply unmeasured:** whether the **Innards** report has the same cause — it
cannot be `prune` (no panels exist in a raid) and v0.2.2 leaves only one 35 ms walk per 8 s there,
so it needs its own `cmsfoff` before CMSF is blamed or cleared; Innards also has vanilla traversal
and shader hitching. Whether NOTIFY fires on a **raid → hub return** is still unknown (no return
has happened in two sessions) and v0.3's event design depends on it. The ~35 ms walk cost has not
been re-measured since field test #2. And the in-place tile rebuild around an escape-menu open
still has no identified trigger, though it now matters much less: with the verdict cached, a
rebuild costs one re-derive instead of a permanent per-second tax.

The original sizing table, kept for the record — the third row is what fired (35 ms), which is
why v0.2.2 caches instead of merely rationing:

| `cmsfscan` says | What it means | Next move |
|---|---|---|
| Well under 1 ms | The backoff is over-cautious and the walk is not the story | Look at the `Init()`-every-poll suspect below |
| Around 1 ms | Backoff is roughly right; a raid now hitches once per 8 s instead of every second | Tune `IDLE_MAX_TICKS`, ship |
| **Several ms** ← this one | Every landed scan drops a frame, and rarity is not enough | The poll has to go away entirely — v0.2.2's cache + the v0.3 event probe |

## The suspect nobody has ruled out *(resolved: the suspect was next door — see field test #4)*

*This section had the right instinct and the wrong line. It suspected `Init()` running every pass,
invisibly, because the log suppresses repeats — and field test #2 cleared `Init()`. The actual
culprit was `prune()`, called on the line immediately after, invisible for exactly the reason
described below. Kept verbatim as a record of how close a correct instinct can get while still
naming the wrong function.*

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

**The built zips in `dist/release` are stale and must not be shipped.** `CMSF-v0.2.1.zip` and
`CMSF-author-v0.2.1.zip` were both built 2026-07-24, and the `CMSFUnlock` Lua inside them carries
**no version banner at all** — that is pre-v0.2.1 code wearing a v0.2.1 filename, the same trap
the v0.2.0 zip fell into. Rebuild before any release; `tools/package-release.ps1` now defaults to
`-Version 0.2.2`. Note also that **git tags stop at v0.2.0** — neither 0.2.1 nor 0.2.2 is tagged.

Test-rig gotcha, cost a session: the MO2 mod folder had **stale v0.2.0-era Lua** (dated 2026-07-21)
and **no `CMSFTime` at all**, so `cmsfscan`/`cmsftime`/the v0.3 probe were simply absent. Field
test #3 needed both mods copied in from `runtime/` and the framework mod re-enabled first. Check
the version banner in the log before trusting any felt result — that is what it is for, and it has
now earned its keep twice.
