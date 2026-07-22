<#
.SYNOPSIS
    Build the CMSF author release zip, and refuse to ship anything that must not be
    redistributed.

.DESCRIPTION
    Publishes cmsf-author as a self-contained single-file exe, assembles the bundle from an
    explicit ALLOWLIST, then scans the result against a DENYLIST and fails if anything
    forbidden appears.

    The denylist is the whole reason this script exists. retoc provisions Oodle itself, so
    oo2core_9_win64.dll appears inside the retoc folder the first time you build anything,
    and the obvious way to package a release (zip the folder) therefore redistributes
    proprietary Epic code. Likewise a .usmap is decoded from the game's own type layout.
    Both are listed in docs/04-authoring.md as things CMSF must never ship, and both would
    otherwise be prevented only by remembering.

    Two nets on purpose: the allowlist controls what goes in, the denylist catches what the
    allowlist did not anticipate (a future retoc layout, an added copy step, a stray build
    artefact).

    ASCII ONLY, deliberately. Windows PowerShell 5.1 reads a UTF-8 file with no BOM as ANSI,
    so a stray em dash in a comment turns into a parser error rather than a typo.

.PARAMETER Retoc
    Path to retoc.exe. Auto-detected across the known dev machines if omitted. retoc is MIT
    and IS redistributable, with attribution, so its LICENSE ships beside it.

.PARAMETER Version
    Version string used in the folder and zip names.

.PARAMETER OutDir
    Where to write the staging folder and zip. Defaults to dist/release.

.EXAMPLE
    .\tools\package-release.ps1
.EXAMPLE
    .\tools\package-release.ps1 -Version 0.2.1 -Retoc "D:\tools\retoc\retoc.exe"
#>
[CmdletBinding()]
param(
    [string]$Retoc,
    [string]$Version = "0.2.0",
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $repo "dist\release" }

# --- things that must never reach a public release ---------------------------------------
# Pattern -> why, so a failure explains itself rather than just naming a file.
$Forbidden = [ordered]@{
    'oo2core*.dll' = 'proprietary Oodle (RAD/Epic). retoc fetches it on first run; never ship it'
    '*.usmap'      = 'decoded from the game own type layout; shipping it redistributes part of the game'
    '*.uasset'     = 'cooked game asset'
    '*.uexp'       = 'cooked game asset'
    '*.ubulk'      = 'cooked game asset'
    '*.pak'        = 'game or mod content pak'
    '*.utoc'       = 'game or mod content pak'
    '*.ucas'       = 'game or mod content pak'
    '*.pdb'        = 'debug symbols; not harmful, just not wanted in a release'
}

function Find-Retoc {
    param([string]$Explicit)
    if ($Explicit) {
        if (-not (Test-Path $Explicit)) { throw "-Retoc: $Explicit does not exist" }
        return (Resolve-Path $Explicit).Path
    }
    $candidates = @(
        "H:\Github Repositories\AllWeaponsUnlockableFix\tools\retoc\retoc.exe",
        "D:\Github Repositories\HeavyRifleRebalanceFix\tools\retoc\retoc.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    throw "retoc.exe not found. Pass -Retoc with a path. It is gitignored and not in this repo."
}

# --- publish -------------------------------------------------------------------------------
$name    = "CMSF-author-v$Version"
$staging = Join-Path $OutDir $name
$zip     = Join-Path $OutDir "$name.zip"

Write-Host "==> publishing cmsf-author" -ForegroundColor Cyan
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
if (Test-Path $zip)     { Remove-Item $zip -Force }
New-Item -ItemType Directory -Force -Path $staging, (Join-Path $staging "licenses") | Out-Null

$publish = Join-Path $OutDir ".publish"
if (Test-Path $publish) { Remove-Item $publish -Recurse -Force }
dotnet publish (Join-Path $repo "tools\cmsf-author") -c Release -o $publish -v q --nologo
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

# --- assemble, from an explicit allowlist --------------------------------------------------
Write-Host "==> assembling bundle" -ForegroundColor Cyan
$retocPath = Find-Retoc -Explicit $Retoc
$retocDir  = Split-Path $retocPath

Copy-Item (Join-Path $publish "cmsf-author.exe") $staging
Copy-Item $retocPath $staging
Copy-Item (Join-Path $repo "LICENSE") (Join-Path $staging "LICENSE.txt")

$retocLicense = Join-Path $retocDir "LICENSE"
if (-not (Test-Path $retocLicense)) {
    throw "retoc LICENSE not found beside $retocPath. retoc is MIT and REQUIRES the notice to ship with it."
}
Copy-Item $retocLicense (Join-Path $staging "licenses\retoc-LICENSE.txt")

$readme = @"
CMSF author tool v$Version
==========================

  cmsf-author.exe   builds one skin into one pak trio
  retoc.exe         used internally; MIT, (c) Truman Kilen and Archengius

BEFORE YOU START, put a .usmap in this folder.

CMSF cannot ship one: a usmap is decoded from the game's own type layout, so
distributing it would redistribute part of the game. Dump your own from your own
copy, once per game version, with UE4SS, which you already run for CMSFUnlock:

    Ctrl+Numpad6 in-game, or a DumpUSMAP() call from Lua.

If Ctrl+Numpad6 does nothing, UE4SS's built-in Keybinds mod is disabled. Set
"Keybinds : 1" in Binaries\Win64\ue4ss\Mods\mods.txt, editing the line where it
already sits -- it is last in the file on purpose.

QUICK START

    cmsf-author.exe --list-free Girl        what slots are available
    cmsf-author.exe <skin-folder>           build it
    cmsf-author.exe --help                  everything else

Full guide: docs/07-authoring-v2.md in the CMSF repo.

NOTES

  * The first run may need an internet connection, so retoc can fetch Oodle.
    CMSF does not ship Oodle; it is proprietary.
  * This exe is unsigned, so Windows SmartScreen will say "unknown publisher"
    once. More info -> Run anyway.
"@
Set-Content -Path (Join-Path $staging "README.txt") -Value $readme -Encoding UTF8

# --- the guard -----------------------------------------------------------------------------
Write-Host "==> checking nothing forbidden is in the bundle" -ForegroundColor Cyan
$violations = @()
foreach ($pattern in $Forbidden.Keys) {
    $hits = Get-ChildItem $staging -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue
    foreach ($hit in $hits) {
        $rel = $hit.FullName.Replace("$staging\", "")
        $violations += ("  {0}`n      {1}" -f $rel, $Forbidden[$pattern])
    }
}
if ($violations.Count -gt 0) {
    Remove-Item $staging -Recurse -Force
    throw ("REFUSING TO PACKAGE. The bundle contains files that must not be redistributed:`n" +
           ($violations -join "`n") + "`n`nStaging folder deleted so it cannot be shipped by hand.")
}

# --- prove the exe actually runs ------------------------------------------------------------
# Deliberately run the PUBLISH copy, not the staged one. A single-file exe extracts itself to
# temp on launch and Windows can hold the image briefly after exit; running the staged copy
# left Compress-Archive unable to read it, which produced a 2.6 MB zip with the 38 MB exe
# silently MISSING, and the script still reported success.
Write-Host "==> smoke-testing the published exe" -ForegroundColor Cyan
$out = & (Join-Path $publish "cmsf-author.exe") --help 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $out -notmatch "cmsf-author") {
    throw ("the published exe did not run. A self-contained publish that needs a runtime " +
           "installed is worse than no release.`n$out")
}

# --- zip -------------------------------------------------------------------------------------
Write-Host "==> zipping" -ForegroundColor Cyan
Compress-Archive -Path $staging -DestinationPath $zip -CompressionLevel Optimal

# Never trust the archive. Compare it against staging by name AND size, because the failure
# mode above was a well-formed zip that was simply missing its largest file.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
try {
    $inZip = @{}
    foreach ($e in $archive.Entries) {
        if ($e.Length -gt 0) { $inZip[(Split-Path $e.FullName -Leaf)] = $e.Length }
    }
} finally { $archive.Dispose() }

$missing = @()
foreach ($f in (Get-ChildItem $staging -Recurse -File)) {
    if (-not $inZip.ContainsKey($f.Name)) { $missing += "  MISSING  $($f.Name)" }
    elseif ($inZip[$f.Name] -ne $f.Length) {
        $missing += ("  SIZE     {0}: staged {1:N0} B, in zip {2:N0} B" -f $f.Name, $f.Length, $inZip[$f.Name])
    }
}
if ($missing.Count -gt 0) {
    Remove-Item $zip -Force
    throw ("the zip does not match the staging folder:`n" + ($missing -join "`n") +
           "`n`nZip deleted. This is usually a file still locked by another process.")
}
Remove-Item $publish -Recurse -Force

Write-Host ""
Get-ChildItem $staging -Recurse -File | ForEach-Object {
    "    {0,-32} {1,8:N0} KB" -f $_.FullName.Replace("$staging\", ""), ($_.Length / 1KB)
}
Write-Host ""
Write-Host ("done -> {0}  ({1:N2} MB, {2} files verified)" -f $zip, ((Get-Item $zip).Length / 1MB), $inZip.Count) -ForegroundColor Green
Write-Host ""
Write-Host "Before publishing: the slot registry is fetched from the repo raw URL, so the" -ForegroundColor Yellow
Write-Host "collision check stays INERT until that repo is public. Flip it first." -ForegroundColor Yellow
