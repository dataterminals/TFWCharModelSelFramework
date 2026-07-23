# How the roster mechanism was established

The central question was whether the character-select screen **enumerates `DT_SkinUIData`
rows** or works from a fixed roster the table only decorates. Everything downstream depended on
the answer: if the UI enumerates rows, appending works and CMSF is mostly a build-tooling
problem; if it reads a hardcoded array, data injection is dead and only widget-level injection
remains. The result is folded into [00-findings.md](00-findings.md); this records how it was
settled, because the method matters as much as the answer.

## A single-variable experiment

`SK_SCV_FL_OCT` is a complete, cooked, shipped Scav Girl skin with **no `DT_SkinUIData` row
pointing at it** (see [00-findings.md](00-findings.md#a-free-test-subject--sk_scv_fl_oct)). That
made it the ideal subject: reviving it needs **no new art and no new packages** — no mesh
repathing, no `FPackageId` risk, no skeleton or material reference repair, none of the failure
modes that produce T-poses in the overwrite pipeline. Every asset already exists and already
resolves, so the **only variable in the experiment is the added table row**.

Two rows were appended to a table freshly re-extracted from the live cook, both pointing at that
one mesh:

```
ScavGirl5        continues the base <Char><N> sequence, outside the entitlement namespace
CMSF.Girl.TEST   dotted, in a namespace the developers do not use
```

`ScavGirl5` tested whether an appended row appears at all; `CMSF.Girl.TEST` tested whether row
naming is free or constrained to the base sequence. Both used inline `FText` and reused the
vanilla Scav Girl portrait, since the variable under test was the row, not the art.

One confound was designed around up front: a row the game cannot attribute to a character might
throw and take the `ScavGirl5` signal down with it, reading as a false "not row-driven." A
single-row fallback pak (`ScavGirl5` only) was built alongside, so a total failure could be
disambiguated in one extra launch rather than guessed at.

## What each outcome would have meant

| Observation | Reading |
|---|---|
| **Both** rows appear | full row scan — appending works, **naming is free** |
| **Only `ScavGirl5`** | sequential/prefix enumeration — appending works, naming is constrained |
| Appears but **locked** | enumerated, but gated by something beyond entitlements |
| Selecting reverts/crashes | UI enumerates, but `GA_Player_ChangeSkin` re-validates |
| **Neither** appears | roster is not row-driven — or the dotted row threw (retest with the fallback) |

The failure readings were as informative as success, which is why the fallback pak was built
before the first launch rather than after the first surprise.

## The result

The first run showed nothing, and it was **not** the enumeration question — it was that the
selector only offers entitlement-gated skins at all, so an appended row is necessary but not
sufficient (see [00-findings.md](00-findings.md#what-the-selector-actually-shows)). With the
selector filter cleared, both rows appeared as separate named entries: a **full row scan**, and
**naming is free**. That settled the direction of the whole project — a `CMSF.*` namespace is
safe, appending is viable, and the roster lives on the pawn component rather than in the table.

## Build hygiene that carried into the shipping tools

Two habits from this experiment became rules for every CMSF build tool:

- **Always re-extract `DT_SkinUIData` from the live cook**, never from a committed snapshot — a
  stale table override would delete rows a game patch added (see [01-design.md](01-design.md)).
- **Verify by decoding the built pak back out** and asserting the rows are present, rather than
  trusting the write landed. A pak that installs cleanly and does nothing is indistinguishable
  in-game from "the approach does not work."

Both are enforced by [cmsf_build.py](../tools/cmsf_build.py) and the v0.2 generators. Deployment
throughout is via Mod Organizer 2, so the real game directory stays clean by design — a
vanilla-looking game folder is the expected state, not evidence anything is missing.
