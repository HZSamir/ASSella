# DroidDeck / ARM64 spike notes

This document records environment assumptions for ASSella on [DroidDeck](https://github.com/Droid-Deck/DroidDeck) desktop. Re-validate on a real device when upstream binaries change.

## Target environment

- Arch Linux ARM64 user-space under **proot** (no real `sudo`, no full-system `pacman -Syu`)
- KDE Plasma desktop; Steam is Valve’s **native ARM64** client under `~/.local/share/Steam`
- ASSella ships as **source + venv** on this platform (x86_64 AppImage is not used)

## SLSsteam / Headcrab

| Check | Expected on DroidDeck |
|--------|------------------------|
| Full `curl headcrab.pages.dev \| bash` | Often **hangs** at “Connecting to Headcrab updater” because `overideupdate` runs `wheresteam -forcesteamupdate` against Steam CDN — skipped by `install.sh --sls-only` |
| `SLSsteam-Any-release.7z` from AceSLS | Ships **32-bit Intel (i386)** `SLSsteam.so` / `library-inject.so` (`-m32` in upstream Makefile) — **cannot** inject DroidDeck’s default **ARM64** Steam. Native handoff needs matching arch: **aarch64 SLS** (not released; [AceSLS#161](https://github.com/AceSLS/SLSsteam/issues/161)) or **x86-64 Steam client under FEX** (see below) |
| `LD_AUDIT` injection under proot | Must be verified on device; ASSella provides `~/.local/bin/steam-sls` wrapper |
| `/tmp/SLSsteam.API` | Present when SLSsteam is loaded in the running Steam process |

## Tooling prerequisites (user-space)

- `python3` (3.12+ recommended; installer can bootstrap 3.13 standalone on failure)
- `python3 -m venv`, `curl`, `tar` (source is fetched as a GitHub tarball — **no `git`**)
- `pip` installs `steam` / `vdf` from **GitHub `.zip` archives** (same commits as `requirements.in`) so pip never invokes `git`
- `7z` or `7za` or `bsdtar` for SLSsteam archive extraction
- User-writable `~/.dotnet` (.NET 9 **linux-arm64** for DepotDownloader)

## SLSsteam on DroidDeck

This is **not** an ASSella installer bug. AceSLS only publishes **i386** Linux builds today. DroidDeck’s default Steam is **aarch64**, so `LD_AUDIT` cannot load those libraries into the running Steam process — you will see `file` report `Intel i386` and ASSella will disable native handoff.

### Recommended path (x86-64 Steam + `steam-sls`)

1. Use the **desktop user** that runs Steam (not `root`). Re-run the installer as that user if you used root before.
2. In Steam: **Settings → Steam client → x86-64** (Valve’s Linux client under FEX). Apply and **fully quit** Steam.
3. From a terminal (same user):

   ```bash
   ~/.local/bin/steam-sls
   ```

   If `steam-sls` is not found: `export PATH="$HOME/.local/bin:$PATH"` or open a new shell after install.

4. Confirm injection:

   ```bash
   test -S /tmp/SLSsteam.API && echo "SLS API up"
   pgrep -a steam
   ```

5. In ASSella: **Settings → SLS** — enable features that require SLS when Health shows binaries compatible / SLS online.

### If injection still fails on x86-64 Steam

- The x86-64 client may be **64-bit** while SLS is still **32-bit**; upstream is tracking **64-bit SLS** in [AceSLS#94](https://github.com/AceSLS/SLSsteam/issues/94).
- There is **no** supported way to build or download **aarch64** SLSsteam from AceSLS today ([AceSLS#161](https://github.com/AceSLS/SLSsteam/issues/161)).
- Ask in [DroidDeck Discord](https://discord.gg/JRGAvawjsm) for device-specific FEX + Steam + SLS reports.

### Without working SLS

ASSella can still use **Hubcap** and **direct depot downloads**; **native Steam handoff** (ACF-independent / live Steam registration) stays unavailable until SLS loads in Steam.

## Verification commands (on device)

```bash
uname -m
file ~/.local/share/SLSsteam/SLSsteam.so ~/.local/share/SLSsteam/library-inject.so
test -S /tmp/SLSsteam.API && echo "API pipe up"
~/.dotnet/dotnet --list-runtimes
~/.local/share/ACCELA/.venv/bin/python3 -c "import PyQt6; print('ok')"
```
