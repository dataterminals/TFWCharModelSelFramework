<#
.SYNOPSIS
    Build the CMSF release zips -- one for players, one for skin authors -- and refuse to ship
    anything that must not be redistributed.

.DESCRIPTION
    Emits two bundles:

      CMSF-v<ver>.zip            what a PLAYER installs: the framework pak + CMSFUnlock,
                                 laid out so the whole Windows\ folder drops onto the game root
      CMSF-author-v<ver>.zip     what a SKIN AUTHOR runs: cmsf-author.exe + retoc + an example

    Each is assembled from an explicit ALLOWLIST, then scanned against a DENYLIST and rejected
    if anything forbidden appears.

    The denylist is the whole reason this script exists. retoc provisions Oodle itself, so
    oo2core_9_win64.dll appears in the folder the first time anything is built -- OBSERVED
    2026-07-22, in the release folder, from a single example build -- and the obvious way to
    package a release (zip the folder) therefore ships proprietary Epic code. Likewise a .usmap
    is decoded from the game's own type layout. Both are named in docs/04-authoring.md as
    things CMSF must never ship, and both would otherwise be prevented only by remembering.

    Two nets: the allowlist controls what goes in, the denylist catches what the allowlist did
    not anticipate (a future retoc layout, an added copy step, a stray build artefact).

    ASCII ONLY, deliberately. Windows PowerShell 5.1 reads a UTF-8 file with no BOM as ANSI, so
    a stray em dash in a comment is a parser error rather than a typo.

.PARAMETER Retoc
    Path to retoc.exe. If omitted, looked for in tools\retoc\ and on PATH. retoc is MIT and
    IS redistributable, with attribution, so its LICENSE ships beside it.

.PARAMETER Framework
    Folder holding the built framework pak trio. Defaults to dist\framework. Build it with:
        python tools/cmsf_framework.py --slots 32

.PARAMETER Version
    Version string used in the folder and zip names.

.PARAMETER OutDir
    Where to write staging folders and zips. Defaults to dist\release.

.EXAMPLE
    .\tools\package-release.ps1
.EXAMPLE
    .\tools\package-release.ps1 -Version 0.2.1 -Retoc "D:\tools\retoc\retoc.exe"
#>
[CmdletBinding()]
param(
    [string]$Retoc,
    [string]$Framework,
    [string]$Version = "0.2.1",
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $OutDir)    { $OutDir    = Join-Path $repo "dist\release" }
if (-not $Framework) { $Framework = Join-Path $repo "dist\framework" }

# --- never redistributable, in any bundle --------------------------------------------------
# Pattern -> why, so a failure explains itself rather than just naming a file.
$Forbidden = [ordered]@{
    'oo2core*.dll' = 'proprietary Oodle (RAD/Epic). retoc fetches it on first run; never ship it'
    '*.usmap'      = 'decoded from the game own type layout; shipping it redistributes part of the game'
    'fw_aes.txt'   = 'the game pak AES key; the game own decryption key, supplied per-author, never shipped'
    'aes.key'      = 'a pak AES key file; never ship it'
    '*.uasset'     = 'cooked game asset'
    '*.uexp'       = 'cooked game asset'
    '*.ubulk'      = 'cooked game asset'
    '*.pdb'        = 'debug symbols; not harmful, just not wanted in a release'
}
# Content paks are legitimate in the PLAYER bundle and never in the author one, so they are
# checked separately against the one directory they are allowed to occupy.
$PakExts = @('.pak', '.utoc', '.ucas')

function Test-Bundle {
    param([string]$Staging, [string]$PaksAllowedUnder)

    $violations = @()
    foreach ($pattern in $Forbidden.Keys) {
        foreach ($hit in (Get-ChildItem $Staging -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue)) {
            $violations += ("  {0}`n      {1}" -f $hit.FullName.Replace("$Staging\", ""), $Forbidden[$pattern])
        }
    }
    foreach ($hit in (Get-ChildItem $Staging -Recurse -File -ErrorAction SilentlyContinue)) {
        if ($hit.Extension -notin $PakExts) { continue }
        $rel = $hit.FullName.Replace("$Staging\", "")
        if (-not $PaksAllowedUnder) {
            $violations += ("  {0}`n      a content pak has no business in the author bundle" -f $rel)
        } elseif ($rel -notlike "$PaksAllowedUnder*") {
            $violations += ("  {0}`n      content pak outside {1} -- it would not load from there" -f $rel, $PaksAllowedUnder)
        }
    }
    if ($violations.Count -gt 0) {
        Remove-Item $Staging -Recurse -Force
        throw ("REFUSING TO PACKAGE. The bundle contains files that must not be redistributed:`n" +
               ($violations -join "`n") + "`n`nStaging folder deleted so it cannot be shipped by hand.")
    }
}

function New-Zip {
    param([string]$Staging, [string]$Zip)

    if (Test-Path $Zip) { Remove-Item $Zip -Force }
    Compress-Archive -Path $Staging -DestinationPath $Zip -CompressionLevel Optimal

    # Never trust the archive. Compare it against staging by name AND size: an early run of
    # this script produced a well-formed 2.6 MB zip with the 38 MB exe silently MISSING,
    # because a smoke test still held the image, and reported success.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $inZip = @{}
        foreach ($e in $archive.Entries) { if ($e.Length -gt 0) { $inZip[(Split-Path $e.FullName -Leaf)] = $e.Length } }
    } finally { $archive.Dispose() }

    $bad = @()
    foreach ($f in (Get-ChildItem $Staging -Recurse -File)) {
        if ($f.Length -eq 0) { continue }        # zero-byte markers carry no size to compare
        if (-not $inZip.ContainsKey($f.Name)) { $bad += "  MISSING  $($f.Name)" }
        elseif ($inZip[$f.Name] -ne $f.Length) {
            $bad += ("  SIZE     {0}: staged {1:N0} B, in zip {2:N0} B" -f $f.Name, $f.Length, $inZip[$f.Name])
        }
    }
    if ($bad.Count -gt 0) {
        Remove-Item $Zip -Force
        throw ("the zip does not match the staging folder:`n" + ($bad -join "`n") +
               "`n`nZip deleted. This is usually a file still locked by another process.")
    }
}

function Show-Bundle {
    param([string]$Staging, [string]$Zip)
    Get-ChildItem $Staging -Recurse -File | ForEach-Object {
        "    {0,-58} {1,8:N0} KB" -f $_.FullName.Replace("$Staging\", ""), ($_.Length / 1KB)
    }
    Write-Host ("  -> {0}  ({1:N2} MB)" -f (Split-Path $Zip -Leaf), ((Get-Item $Zip).Length / 1MB)) -ForegroundColor Green
    Write-Host ""
}

function Find-Retoc {
    param([string]$Explicit)
    if ($Explicit) {
        if (-not (Test-Path $Explicit)) { throw "-Retoc: $Explicit does not exist" }
        return (Resolve-Path $Explicit).Path
    }
    $candidates = @(
        (Join-Path $PSScriptRoot "retoc\retoc.exe"),   # tools\retoc\retoc.exe
        (Join-Path $repo "tools\retoc\retoc.exe")
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $onPath = (Get-Command retoc.exe -ErrorAction SilentlyContinue).Source
    if ($onPath) { return $onPath }
    throw "retoc.exe not found. Put it in tools\retoc\, add it to PATH, or pass -Retoc <path>. It is gitignored and not in this repo."
}

# =============================================================================================
#  1. THE PLAYER BUNDLE
# =============================================================================================
Write-Host "==> player bundle" -ForegroundColor Cyan

$userName    = "CMSF-v$Version"
$userStaging = Join-Path $OutDir $userName
$userZip     = Join-Path $OutDir "$userName.zip"
if (Test-Path $userStaging) { Remove-Item $userStaging -Recurse -Force }

$paks = Get-ChildItem $Framework -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in $PakExts -and $_.BaseName -like "CMSF_Core_*" }
if ($paks.Count -lt 3) {
    throw ("no framework pak trio in $Framework (found $($paks.Count) file(s)).`n" +
           "  Build it first:  python tools/cmsf_framework.py --slots 32`n" +
           "  It must be rebuilt from the CURRENT cook -- a stale DT_SkinUIData deletes the" +
           " developers' new rows.")
}

# Mirror the install tree so the player drops one folder onto the game root and every piece
# lands where it has to be. Getting CMSFUnlock into the wrong directory is silent: the pak
# still loads, provisions every slot, and nothing prunes them.
$relPaks   = "Windows\ForeverWinter\Content\Paks\Mods"
$relUnlock = "Windows\ForeverWinter\Binaries\Win64\ue4ss\Mods\CMSFUnlock"
New-Item -ItemType Directory -Force -Path (Join-Path $userStaging $relPaks),
                                         (Join-Path $userStaging "$relUnlock\Scripts") | Out-Null

$paks | ForEach-Object { Copy-Item $_.FullName (Join-Path $userStaging $relPaks) }

$unlockSrc = Join-Path $repo "runtime\CMSFUnlock"
Copy-Item (Join-Path $unlockSrc "Scripts\main.lua") (Join-Path $userStaging "$relUnlock\Scripts")
# UE4SS starts a Lua mod only if it is listed in mods.txt or ships this marker. Without it the
# mod never starts and says nothing about it -- the exact failure TFWWorkbenchMO2Patcher exists
# to fix for someone else's mod. Assert rather than create, so the repo stays the source.
$marker = Join-Path $unlockSrc "enabled.txt"
if (-not (Test-Path $marker)) {
    throw ("runtime\CMSFUnlock\enabled.txt is missing. Without it UE4SS never starts CMSFUnlock" +
           " and gives no error, so the framework would provision every slot with nothing to prune them.")
}
Copy-Item $marker (Join-Path $userStaging $relUnlock)

Copy-Item (Join-Path $repo "LICENSE") (Join-Path $userStaging "LICENSE.txt")

$userReadme = @"
CMSF v$Version -- Character Model Selection Framework
====================================================

Adds new character skins to the select screen instead of overwriting the ones the
game ships with. It also unlocks the base skins the game already has but never
lets you pick, which is worth having even with no skin mods installed.

INSTALLING

  Copy the "Windows" folder from this archive into your game folder, so it merges
  with the one already there:

      ...\steamapps\common\The Forever Winter\

  That puts two things in place:

      Windows\ForeverWinter\Content\Paks\Mods\        the framework pak
      Windows\...\Binaries\Win64\ue4ss\Mods\CMSFUnlock\   the runtime

  The Mods\ folder may not exist yet -- copying the Windows folder in creates it.

  Launch, pick a character, open the skin menu.

  MOD ORGANIZER 2 USERS: do not copy anything into the game folder. Install this
  archive as an ordinary MO2 mod instead. MO2 virtualises both of those
  directories, so files copied in by hand are not what the game sees.

REQUIREMENTS

  UE4SS            tested against 3.0.1-894. You likely have it already.
  Signature Bypass required for any content pak mod, not just this one.

ADDING SKINS

  A CMSF skin is an ordinary pak you drop in the same Mods\ folder. Skin paks
  MUST load after the framework -- their filenames already carry the right
  load-order token, so do not rename them.

  Mod Organizer 2: MO2 priority decides load order and overrides the filename,
  so put skins ABOVE the framework in the left pane.

NOT BUGS

  * A skin can be missing for about a second when the menu first opens, then
    appear. The game reuses tile widgets across panels, so the first pass reads a
    stale image. It corrects itself.
  * Empty slots do not show. The framework provisions many; you only ever see
    ones a skin actually claimed.

IF A SKIN YOU INSTALLED IS NOT SHOWING

  Almost always load order -- the skin pak has to load AFTER the framework. Open
  the console and type  cmsfnoprune  to show every slot including empty ones. If
  yours reads "CMSF SLOT NN UNCLAIMED", the pak is not loading, or is loading
  before the framework.

UNINSTALLING

  Delete the files. If you were wearing a CMSF skin the game rolls you onto a
  normal one next time you die. Nothing to repair.

CMSF is MIT licensed. Built with UE4SS (https://github.com/UE4SS-RE/RE-UE4SS).
"@
Set-Content -Path (Join-Path $userStaging "README.txt") -Value $userReadme -Encoding UTF8

Test-Bundle -Staging $userStaging -PaksAllowedUnder $relPaks
New-Zip -Staging $userStaging -Zip $userZip
Show-Bundle -Staging $userStaging -Zip $userZip

# =============================================================================================
#  2. THE AUTHOR BUNDLE
# =============================================================================================
Write-Host "==> author bundle" -ForegroundColor Cyan

$authName    = "CMSF-author-v$Version"
$authStaging = Join-Path $OutDir $authName
$authZip     = Join-Path $OutDir "$authName.zip"
if (Test-Path $authStaging) { Remove-Item $authStaging -Recurse -Force }
New-Item -ItemType Directory -Force -Path $authStaging, (Join-Path $authStaging "licenses") | Out-Null

$publish = Join-Path $OutDir ".publish"
if (Test-Path $publish) { Remove-Item $publish -Recurse -Force }
dotnet publish (Join-Path $repo "tools\cmsf-author") -c Release -o $publish -v q --nologo
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

$retocPath = Find-Retoc -Explicit $Retoc
$retocDir  = Split-Path $retocPath

Copy-Item (Join-Path $publish "cmsf-author.exe") $authStaging
Copy-Item $retocPath $authStaging
Copy-Item (Join-Path $repo "LICENSE") (Join-Path $authStaging "LICENSE.txt")

$retocLicense = Join-Path $retocDir "LICENSE"
if (-not (Test-Path $retocLicense)) {
    throw "retoc LICENSE not found beside $retocPath. retoc is MIT and REQUIRES the notice to ship with it."
}
Copy-Item $retocLicense (Join-Path $authStaging "licenses\retoc-LICENSE.txt")

# The example is BUILDABLE, not illustrative. Both its sources are /Game/ paths out of the
# author's own cook, so dragging it onto the exe exercises the entire chain -- usmap, retoc,
# Steam detection, clone, pack, verify -- and answers "is my setup right" before the author has
# anything of their own to lose. Slot 28 is in the private range, so it can never collide.
$example = Join-Path $repo "examples\example-skin"
if (-not (Test-Path (Join-Path $example "skin.json"))) {
    throw "examples\example-skin\skin.json is missing; the bundle would ship an example that does not build"
}
New-Item -ItemType Directory -Force -Path (Join-Path $authStaging "example-skin") | Out-Null
Copy-Item (Join-Path $example "skin.json") (Join-Path $authStaging "example-skin")

$authReadme = @"
CMSF author tool v$Version
==========================

  cmsf-author.exe   builds one skin into one pak trio
  retoc.exe         used internally; MIT, (c) Truman Kilen and Archengius

BEFORE YOU START, put two things from your own copy of the game in this folder:
a .usmap, and the pak AES key.

CMSF ships neither -- both are game-derived. Supply your own, once per game version:

  usmap    Decoded from the game's own type layout. Dump it with UE4SS, which you
           already run for CMSFUnlock:
               Ctrl+Numpad6 in-game, or a DumpUSMAP() call from Lua.
  AES key  The game's own pak decryption key. Put it in fw_aes.txt next to
           cmsf-author.exe (or set the FW_AES_KEY environment variable). UE4SS can
           dump it, or take it from the usual community key database for your build.

If Ctrl+Numpad6 does nothing, UE4SS's built-in Keybinds mod is disabled. Set
"Keybinds : 1" in Binaries\Win64\ue4ss\Mods\mods.txt, editing the line where it
already sits -- it is last in the file on purpose.

CHECK YOUR SETUP FIRST

    Drag the bundled "example-skin" folder onto cmsf-author.exe.

    It builds a real pak from assets already in your game, so if it works, your
    usmap, retoc and game detection are all correct and your own skin will build
    too. It claims slot 28 -- the private range -- so it cannot collide with
    anyone's published skin. You can install it and see it in game.

QUICK START -- no terminal needed

    Drag your own skin folder onto cmsf-author.exe.

    Or just double-click cmsf-author.exe and it will ask what you want to do.
    Either way the window stays open so you can read what happened.

skin.json -- copy example-skin\skin.json and edit:

    character     BagMan, Girl, Gunhead, MaskMan, OldMan, Shaman
    slot          two digits. 00-27 public (claim it first), 28-31 private
    name          shown in the selector
    description   shown under the name
    mesh          a /Game/... path cloned from your own cook, OR a .uasset
                  file sitting next to skin.json
    icon          same, and REQUIRED -- a claim with no portrait is not plain,
                  it is invisible

FROM A TERMINAL, if you prefer

    cmsf-author.exe --list-free Girl        what slots are available
    cmsf-author.exe <skin-folder>           build it
    cmsf-author.exe --menu                  the interactive menu
    cmsf-author.exe --help                  everything else

Full guide: docs/07-authoring-v2.md in the CMSF repo.

NOTES

  * The first run may need an internet connection, so retoc can fetch Oodle.
    CMSF does not ship Oodle; it is proprietary.
  * This exe is unsigned, so Windows SmartScreen will say "unknown publisher"
    once. More info -> Run anyway.
"@
Set-Content -Path (Join-Path $authStaging "README.txt") -Value $authReadme -Encoding UTF8

Test-Bundle -Staging $authStaging -PaksAllowedUnder $null

# Smoke-test the PUBLISH copy, not the staged one. A single-file exe extracts itself to temp on
# launch and Windows can hold the image after exit; running the staged copy left
# Compress-Archive unable to read it and produced a zip with the exe silently missing.
Write-Host "==> smoke-testing the published exe" -ForegroundColor Cyan
$out = & (Join-Path $publish "cmsf-author.exe") --help 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $out -notmatch "cmsf-author") {
    throw ("the published exe did not run. A self-contained publish that needs a runtime " +
           "installed is worse than no release.`n$out")
}

New-Zip -Staging $authStaging -Zip $authZip
Remove-Item $publish -Recurse -Force
Show-Bundle -Staging $authStaging -Zip $authZip

Write-Host "Reminder: authors supply their own usmap and AES key (FW_AES_KEY or fw_aes.txt);" -ForegroundColor Yellow
Write-Host "CMSF ships neither. The slot-collision check reads the published registry." -ForegroundColor Yellow
