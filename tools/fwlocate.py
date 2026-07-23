"""Locate the toolchain and game without hardcoding a machine or shipping the game's key.

Every value resolves as: an explicit environment variable first, then discovery. Nothing
that is derived from the game is bundled with CMSF:

  * the pak AES key — set FW_AES_KEY. It is the game's own decryption key, so CMSF does not
    ship it, exactly as it does not ship the usmap. UE4SS can dump it, and it is listed in the
    usual community key databases for each build.
  * the .usmap — set USMAP, or drop a single one under tools/ or a mappings/ folder. Decoded
    from the game's type layout, so it is yours to supply too.

retoc is MIT and may live in tools/retoc/ or on PATH. The game's Paks directory is found
through Steam automatically, mirroring tools/cmsf/Steam.cs; FW_PAKS overrides it.
"""
import os
import re
import sys
from pathlib import Path
from shutil import which

FW_APPID = "2828860"  # The Forever Winter, on Steam
HERE = Path(__file__).resolve().parent


def aes():
    """The game's pak AES key (0x + 64 hex). Supplied via FW_AES_KEY, never shipped."""
    v = (os.environ.get("FW_AES_KEY") or "").strip()
    if not v:
        sys.exit(
            "FW_AES_KEY is not set. It is the game's pak AES key (0x followed by 64 hex "
            "digits), and CMSF does not ship it — it is the game's own decryption key, the "
            "same reason CMSF does not ship a usmap. UE4SS can dump it, or take it from the "
            "usual community key database for your installed build, then set FW_AES_KEY.")
    return v if v.lower().startswith("0x") else "0x" + v


def _env_path(*names):
    for n in names:
        v = os.environ.get(n)
        if v and Path(v).exists():
            return v
    return None


def _steam_roots():
    """Steam install directories, from the Windows registry. Empty off Windows."""
    roots = []
    try:
        import winreg
    except ImportError:
        return roots
    for hive, key in (
        (winreg.HKEY_CURRENT_USER, r"SOFTWARE\Valve\Steam"),
        (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam"),
        (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Valve\Steam"),
    ):
        try:
            with winreg.OpenKey(hive, key) as k:
                for name in ("SteamPath", "InstallPath"):
                    try:
                        p = Path(winreg.QueryValueEx(k, name)[0])
                    except OSError:
                        continue
                    if p.exists() and p not in roots:
                        roots.append(p)
        except OSError:
            continue
    return roots


def _steam_libraries():
    """Every Steam library folder: the install roots plus libraryfolders.vdf entries."""
    libs = []
    for r in _steam_roots():
        if r not in libs:
            libs.append(r)
        vdf = r / "steamapps" / "libraryfolders.vdf"
        if not vdf.is_file():
            continue
        text = vdf.read_text(encoding="utf-8", errors="ignore")
        for m in re.finditer(r'"path"\s+"([^"]+)"', text):
            p = Path(m.group(1).replace("\\\\", "\\"))
            if p.exists() and p not in libs:
                libs.append(p)
    return libs


def paks():
    """The game's Content/Paks. FW_PAKS overrides; otherwise found through Steam."""
    v = _env_path("FW_PAKS")
    if v:
        return v
    for lib in _steam_libraries():
        common = lib / "steamapps" / "common"
        installdir = None
        acf = lib / "steamapps" / f"appmanifest_{FW_APPID}.acf"
        if acf.is_file():
            m = re.search(r'"installdir"\s+"([^"]+)"',
                          acf.read_text(encoding="utf-8", errors="ignore"))
            installdir = m.group(1) if m else None
        for root in ([common / installdir] if installdir else []) + \
                    [common / "The Forever Winter"]:
            p = root / "Windows" / "ForeverWinter" / "Content" / "Paks"
            if p.is_dir():
                return str(p)
    sys.exit("could not locate The Forever Winter through Steam; set FW_PAKS to "
             r"...\The Forever Winter\Windows\ForeverWinter\Content\Paks")


def retoc():
    """retoc.exe. RETOC overrides; otherwise tools/retoc/retoc.exe, then PATH."""
    v = _env_path("RETOC")
    if v:
        return v
    for c in (HERE / "retoc" / "retoc.exe", HERE / "retoc"):
        if c.is_file():
            return str(c)
    w = which("retoc") or which("retoc.exe")
    if w:
        return w
    sys.exit("could not locate retoc.exe; put it in tools/retoc/ or set RETOC. "
             "retoc is MIT — github.com/trumank/retoc.")


def usmap():
    """The .usmap. USMAP/FW_USMAP overrides; otherwise a single *.usmap under tools/ or mappings/."""
    v = _env_path("USMAP", "FW_USMAP")
    if v:
        return v
    found = []
    for d in (HERE, HERE / "mappings", HERE.parent / "mappings"):
        if d.is_dir():
            found += sorted(d.glob("*.usmap"))
    if len(found) == 1:
        return str(found[0])
    if len(found) > 1:
        sys.exit("several .usmap files were found and picking the wrong one silently builds a "
                 "bad package; set USMAP to the one matching your installed build:\n  " +
                 "\n  ".join(str(f) for f in found))
    sys.exit("no .usmap found; set USMAP. CMSF does not ship it — it is decoded from the "
             "game's own type layout. Dump your own once per game version with UE4SS "
             "(Ctrl+Numpad6 in-game, or a DumpUSMAP() call from Lua).")
