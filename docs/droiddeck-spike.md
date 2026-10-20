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
| `SLSsteam-Any-release.7z` from AceSLS | Historically contains **x86_64** `SLSsteam.so` / `library-inject.so` — **cannot** inject native ARM64 Steam. Installer runs `file` and warns; native handoff needs **aarch64** SLS builds or DroidDeck’s optional **x86_64 Steam + FEX** path |
| `LD_AUDIT` injection under proot | Must be verified on device; ASSella provides `~/.local/bin/steam-sls` wrapper |
| `/tmp/SLSsteam.API` | Present when SLSsteam is loaded in the running Steam process |

## Tooling prerequisites (user-space)

- `python3` (3.12+ recommended; installer can bootstrap 3.13 standalone on failure)
- `python3 -m venv`, `curl`, `tar` (source is fetched as a GitHub tarball — **no `git`**)
- `7z` or `7za` or `bsdtar` for SLSsteam archive extraction
- User-writable `~/.dotnet` (.NET 9 **linux-arm64** for DepotDownloader)

## Verification commands (on device)

```bash
uname -m
file ~/.local/share/SLSsteam/SLSsteam.so ~/.local/share/SLSsteam/library-inject.so
test -S /tmp/SLSsteam.API && echo "API pipe up"
~/.dotnet/dotnet --list-runtimes
~/.local/share/ACCELA/.venv/bin/python3 -c "import PyQt6; print('ok')"
```
