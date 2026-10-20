"""
SLSsteam preflight checks for native Steam handoff (including ARM64 / DroidDeck).
"""

import logging
import os
import platform
import struct
from pathlib import Path
from typing import Optional, Tuple

logger = logging.getLogger(__name__)

SLSSTEAM_API_PIPE = "/tmp/SLSsteam.API"

# ELF e_machine values (common)
_ELF_EM_386 = 3
_ELF_EM_X86_64 = 62
_ELF_EM_AARCH64 = 183


def _host_elf_machine() -> Optional[int]:
    machine = platform.machine().lower()
    if machine in ("x86_64", "amd64"):
        return _ELF_EM_X86_64
    if machine in ("aarch64", "arm64", "armv8b", "armv8l"):
        return _ELF_EM_AARCH64
    if machine in ("i386", "i686", "x86"):
        return _ELF_EM_386
    return None


def _read_elf_machine(so_path: Path) -> Optional[int]:
    try:
        with open(so_path, "rb") as f:
            hdr = f.read(20)
        if len(hdr) < 20 or hdr[:4] != b"\x7fELF":
            return None
        ei_class = hdr[4]
        if ei_class == 1:  # 32-bit
            with open(so_path, "rb") as f:
                f.seek(18)
                return struct.unpack("<H", f.read(2))[0]
        if ei_class == 2:  # 64-bit
            with open(so_path, "rb") as f:
                f.seek(18)
                return struct.unpack("<H", f.read(2))[0]
    except OSError as e:
        logger.debug("Could not read ELF header from %s: %s", so_path, e)
    return None


def get_sls_install_paths() -> Tuple[Path, Path]:
    """Return (SLSsteam.so, library-inject.so) under the default install dir."""
    base = Path.home() / ".local" / "share" / "SLSsteam"
    return base / "SLSsteam.so", base / "library-inject.so"


def sls_binaries_present() -> bool:
    so_path, inject_path = get_sls_install_paths()
    return so_path.is_file() and inject_path.is_file()


def sls_binaries_compatible() -> bool:
    """True if SLSsteam.so ELF architecture matches the host CPU."""
    so_path, inject_path = get_sls_install_paths()
    if not so_path.is_file() or not inject_path.is_file():
        return False
    host_em = _host_elf_machine()
    if host_em is None:
        return True
    so_em = _read_elf_machine(so_path)
    inj_em = _read_elf_machine(inject_path)
    if so_em is None or inj_em is None:
        return True
    return so_em == host_em and inj_em == host_em


def sls_binary_arch_mismatch_message() -> str:
    so_path, _ = get_sls_install_paths()
    host = platform.machine()
    so_em = _read_elf_machine(so_path)
    em_name = {62: "x86-64", 183: "aarch64", 3: "i386"}.get(so_em or -1, "unknown")
    return (
        f"SLSsteam at {so_path} is built for {em_name}, but this system is {host}. "
        "Native ARM64 Steam cannot load x86_64 SLSsteam. Use an aarch64 SLS build, "
        "or DroidDeck's x86_64 Steam client under FEX with x86 SLS."
    )


def ensure_sls_config_dir() -> Path:
    """Create ~/.config/SLSsteam if missing; return config directory."""
    cfg = Path.home() / ".config" / "SLSsteam"
    cfg.mkdir(parents=True, exist_ok=True)
    return cfg


def _steam_pids() -> list:
    pids = []
    try:
        for pid_dir in os.listdir("/proc"):
            if not pid_dir.isdigit():
                continue
            try:
                with open(f"/proc/{pid_dir}/comm", "r", encoding="utf-8", errors="ignore") as f:
                    if f.read().strip() == "steam":
                        pids.append(pid_dir)
            except OSError:
                continue
    except OSError:
        pass
    return pids


def is_steam_running() -> bool:
    return bool(_steam_pids())


def is_sls_mapped_in_steam() -> bool:
    """True if SLSsteam.so appears in any steam process memory maps."""
    for pid_dir in _steam_pids():
        try:
            with open(f"/proc/{pid_dir}/maps", "r", encoding="utf-8", errors="ignore") as f:
                if "SLSsteam.so" in f.read():
                    return True
        except OSError:
            continue
    return False


def is_sls_api_available() -> bool:
    return os.path.exists(SLSSTEAM_API_PIPE)


def is_sls_injected_steam_running() -> bool:
    """Steam is running with SLSsteam loaded (maps and/or API pipe)."""
    if not is_steam_running():
        return False
    if is_sls_mapped_in_steam():
        return True
    if is_sls_api_available():
        return True
    return False


def steam_sls_wrapper_path() -> Path:
    return Path.home() / ".local" / "bin" / "steam-sls"


def droiddeck_steam_launch_hint() -> str:
    wrapper = steam_sls_wrapper_path()
    return (
        "Steam must be started with SLSsteam injection for native handoff.\n\n"
        f"Close Steam, then launch it from a terminal:\n  {wrapper}\n\n"
        "Or run: steam-sls"
    )


def check_sls_ready_for_handoff() -> Tuple[bool, str]:
    """
    Preflight for perform_steam_handoff / NativeSteamDownloadTask.
    Returns (ok, user_message_on_failure).
    """
    if not sls_binaries_present():
        return False, (
            "SLSsteam is not installed. Run the ASSella installer with --sls-only "
            "(or install SLSsteam from Settings → SLS)."
        )

    if not sls_binaries_compatible():
        return False, sls_binary_arch_mismatch_message()

    if not is_steam_running():
        return False, (
            "Steam is not running. Start Steam with SLS injection first.\n\n"
            + droiddeck_steam_launch_hint()
        )

    if not is_sls_injected_steam_running():
        return False, droiddeck_steam_launch_hint()

    ensure_sls_config_dir()
    return True, ""
