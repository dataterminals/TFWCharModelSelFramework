# Implementation notes — gotchas and a possible extension

Hard-won lessons from building the CMSF tools and runtime. The architecture-level identity rule,
the `/Engine/UnknownPackage` red herring, and "run a control before theorising" live in
[05-v2-distribution.md](05-v2-distribution.md#the-identity-rule); this collects the ones that
bite at the keyboard.

## Runtime (UE4SS Lua)

**UE4SS hands back `RemoteUnrealParam` wrappers, and indexing into one silently yields `nil`.**
This applies to struct members and array elements alike; `:get()` unwraps. The array case is
loud — calling a UObject method on a wrapper throws *"attempt to call a RemoteUnrealParam
value"*. The struct case is the dangerous one, because it produces a **confident wrong answer**
instead of an error: reading `tile.SkinIcon.Brush.ResourceObject` without unwrapping `SkinIcon`
first returns `null` for *every* tile, including vanilla portraits visibly rendering on screen,
and survives a full in-game round trip looking like a clean negative result. Unwrap at **every**
hop. Log a known-good control (a vanilla tile) alongside the thing under test, so a read that
fails for both is distinguishable from a real finding — that control is the only reason this
false negative was caught rather than designed around.

**A plain `Visibility` property write does not hide a widget.** It updates the UPROPERTY without
Slate noticing; `SetVisibility(Collapsed)` is required. That is a UFunction call, but its only
parameter is a `uint8` enum by value, so it cannot type-confuse a pointer dereference — the same
safe class as the bool write `CMSFUnlock` has always done. It does **not** survive `Init()`,
which rebuilds the tiles, so re-prune on each poll rather than once.

**`FindAllOf` is a full walk of the object array, and the cost is the walk — not the thread it
runs on.** Polling it at 1 Hz is a frame hitch in a shipped build whether or not it finds anything,
and moving it off the game thread reduces that without removing it (measured the hard way: a player
still reported hitching in raids, where the on-thread path does nothing at all). Treat any repeated
`FindAllOf` as a cost to be made *rare*, not merely relocated. Handles it returns off-thread must
not be carried onto the game thread — they can be collected in between — so an off-thread presence
check has to be followed by an on-thread re-scan, which is a second walk. Budget for that. The
running record of this is [09-stutter.md](09-stutter.md).

## Build tooling (retoc / UAssetAPI)

**Verify package identity by whole name-map entries, not byte scans.** `SK_SCV_FL_OCT_Skeleton`
contains `SK_SCV_FL_OCT` as a prefix and is a legitimate sibling import, so a substring check
misfires. Compare whole entries.

**Renaming the file does not rename the export.** A soft path and a `TableId` are both
`/Package/Path.ObjectName`, so a clone whose export keeps the template's name is still referenced
by the old object name. The generator must rename the export, not just the file — and for a mesh
this is load-bearing, because a roster entry is a soft path
`/Game/CMSF/<Char>/<NN>/SK_CMSF_<Char>_<NN>.SK_CMSF_<Char>_<NN>`, so an unrenamed export makes the
entry unresolvable.

**`-f` is mandatory on `to-legacy` against a full-game mount.** Unfiltered it extracts the entire
cook — it will fill the drive.

**`to-legacy` on a mod pak needs `global.utoc`/`global.ucas` staged beside it** (or the whole
game mounted), or it fails with `ScriptObjects not found in any containers`. The verify step in
each build tool stages exactly `global.*` — 2.9 MB, not the 45 GB cook — which also makes the
"must not ship" check a real assertion: with only our own pak mounted, anything that comes out
came from us.

**`skinpatch` does not create its output directory; `stgen`/`mshgen` do.** Create the parent
before calling `skinpatch`.

## Possible extension — a default portrait in the author's pak

Today an author who omits `icon` in `skin.json` gets a hard error, because a claim with no
portrait is pruned as unclaimed. A future version could instead have `cmsf-author` clone a
CMSF-branded placeholder (the `assets/icon.svg` badge) to the slot's icon path.

This does **not** violate the sentinel rule, and the distinction is the whole point: the rule
forbids the *framework* shipping a texture at a slot's own path, because then an *unclaimed* slot
would read as claimed and never prune. A default in the *author's* pak is different — that slot
genuinely is claimed. The framework still ships nothing, unclaimed slots still prune, and the
claim signal only asks whether a package exists at the path, not what it depicts.

It is blocked on producing one cooked UE5.4 `Texture2D` of our own: the clean route is to cook the
badge once in a UE5.4 project, commit it (with a `.gitignore` exception, since `*.uasset` is
blanket-ignored for copyright reasons that do not apply to our own art), and clone it with the
existing package-clone step. Scope it honestly — a missing `icon` is already a hard error, so the
invisible-skin outcome is already prevented; this only buys the ability to build and test before
the art exists. It does **not** close the remaining gap, since a supplied but badly-cooked texture
still builds clean and vanishes, and no build-time check can catch that without loading the asset.
Emit a NOTE when the placeholder is used, or authors will ship the badge without noticing.
