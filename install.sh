#!/usr/bin/env bash
set -euo pipefail

# Bash version guard (declare -A and modern syntax require Bash 4+)
if (( BASH_VERSINFO[0] < 4 )); then
    echo "This installer requires Bash 4.0 or newer (detected version: $BASH_VERSION)." >&2
    exit 1
fi

# ==============================================================================
#                      ASSella Installer
# ==============================================================================
# Fork / mirror overrides (optional):
#   ASSELLA_GH_OWNER, ASSELLA_GH_REPO, ASSELLA_INSTALL_BRANCH, ASSELLA_ARM64_BRANCH
ASSELLA_GH_OWNER="${ASSELLA_GH_OWNER:-HZSamir}"
ASSELLA_GH_REPO="${ASSELLA_GH_REPO:-ASSella}"
ASSELLA_INSTALL_BRANCH="${ASSELLA_INSTALL_BRANCH:-beta}"
ASSELLA_RAW_BASE="https://raw.githubusercontent.com/${ASSELLA_GH_OWNER}/${ASSELLA_GH_REPO}"
ASSELLA_API_RELEASES="https://api.github.com/repos/${ASSELLA_GH_OWNER}/${ASSELLA_GH_REPO}/releases"
ASSELLA_RELEASES_BASE="https://github.com/${ASSELLA_GH_OWNER}/${ASSELLA_GH_REPO}/releases/download"
# Bump when changing installer behavior (visible in logs to confirm curl fetched latest script)
ASSELLA_INSTALLER_REV="2026-03-20-pip-no-git"
# Pinned VCS deps (must match requirements.in) — installed via zip when git is unavailable
ASSELLA_VDF_GIT_ARCHIVE="https://github.com/solsticegamestudios/vdf/archive/refs/tags/v4.0.zip"
ASSELLA_STEAM_GIT_ARCHIVE="https://github.com/solsticegamestudios/steam/archive/1373e885f26bb636225443787f54d4082283e5f3.zip"

# Terminal Colors & Styling (respect NO_COLOR and non-interactive TTYs)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    NC=''
fi

INSTALL_DESTINATION="$HOME/.local/share/ACCELA"
DESKTOP_DIR="$HOME/.local/share/applications"
PRIMARY_DESKTOP_ENTRY="$DESKTOP_DIR/assella.desktop"
LEGACY_DESKTOP_ENTRY="$DESKTOP_DIR/accela.desktop"
DESKTOP_ENTRY="$PRIMARY_DESKTOP_ENTRY"
ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
PRIMARY_ICON_PATH="$ICON_DIR/assella.png"
LEGACY_ICON_PATH="$ICON_DIR/accela.png"
ICON_PATH="$PRIMARY_ICON_PATH"
VERSION_FILE="$INSTALL_DESTINATION/version"
NIXOS_LAUNCHER="$INSTALL_DESTINATION/launch_nixos.sh"

TARGET_CHANNEL=""
LOCAL_VER="Unknown"
LATEST_VER=""
LATEST_URL=""
FUSE_INSTALLED=false
STEAM_TYPE="none"
STEAM_DIR=""
SLS_CONFIG_DIR=""
SLS_CONFIG_FILE=""
HEADCRAB_INSTALLED=false
IS_STEAM_DECK=false
IS_NIXOS=false
IS_CACHYOS=false
INTERACTIVE=false
TMP_DIR=""
SKIP_CHECKSUM=false
IS_ARM64=false
IS_DROIDDECK=false
NO_SUDO=false
SKIP_SLS=false
SLS_ONLY=false
ARM64_NO_PIP=false
ARM64_SRC_TREE=""
ARM64_REPO_URL="https://github.com/${ASSELLA_GH_OWNER}/${ASSELLA_GH_REPO}.git"
ARM64_BRANCH="${ASSELLA_ARM64_BRANCH:-$ASSELLA_INSTALL_BRANCH}"
PLUGINS_ZIP_URL="https://github.com/ciscosweater/enter-the-wired/releases/download/latest/plugins-deps.zip"
RUN_ASSella_LAUNCHER="$INSTALL_DESTINATION/run-assella.sh"
STEAM_SLS_WRAPPER="$HOME/.local/bin/steam-sls"

cleanup() {
    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

declare -A PKG_FUSE_CMD=(
    [arch]="sudo pacman -S --needed fuse2"
    [debian]="sudo apt install -y libfuse2"
    [fedora]="sudo dnf install -y fuse-libs"
    [opensuse]="sudo zypper install -y libfuse2"
    [alpine]="sudo apk add fuse2"
    [void]="sudo xbps-install -S fuse"
    [solus]="sudo eopkg install -y fuse"
    [gentoo]="sudo emerge --ask sys-fs/fuse"
)

# ------------------------------------------------------------------------------
#  1. System & Distro Detection
# ------------------------------------------------------------------------------
detect_distro() {
    DISTRO_ID="unknown"
    DISTRO_NAME="Generic Linux"
    DISTRO_LIKE=""
    IS_STEAM_DECK=false
    IS_NIXOS=false
    IS_CACHYOS=false

    if [ -f /etc/os-release ]; then
        set +e
        . /etc/os-release
        set -e
        DISTRO_ID="${ID:-unknown}"
        DISTRO_NAME="${PRETTY_NAME:-${NAME:-Generic Linux}}"
        DISTRO_LIKE="${ID_LIKE:-}"
    fi

    if [[ "$DISTRO_ID" == "steamos" ]] || [[ -f /etc/steamos-release ]] || [[ "$HOME" == *deck* ]]; then
        IS_STEAM_DECK=true
    fi

    if [[ "$DISTRO_ID" == "nixos" ]]; then
        IS_NIXOS=true
    fi

    if [[ "$DISTRO_ID" == "cachyos" ]] || [[ "$DISTRO_NAME" == *"CachyOS"* ]]; then
        IS_CACHYOS=true
    fi

    detect_arm64_platform
}

detect_arm64_platform() {
    IS_ARM64=false
    case "$(uname -m)" in
        aarch64|arm64) IS_ARM64=true ;;
    esac

    IS_DROIDDECK=false
    if [[ "${ASSELLA_FORCE_DROIDDECK:-}" == "1" ]]; then
        IS_DROIDDECK=true
    elif [[ -n "${DROIDDECK_VERSION:-}" ]] || [[ -n "${DROIDDECK_ROOT:-}" ]]; then
        IS_DROIDDECK=true
    elif [ -f /etc/os-release ]; then
        if grep -qi 'droiddeck' /etc/os-release 2>/dev/null; then
            IS_DROIDDECK=true
        fi
    fi
    if [[ "$IS_DROIDDECK" = false ]] && [[ "$IS_ARM64" = true ]]; then
        if [ -r /proc/1/cmdline ] && tr '\0' ' ' < /proc/1/cmdline 2>/dev/null | grep -q 'proot'; then
            IS_DROIDDECK=true
        fi
    fi

    NO_SUDO=false
    if [[ "$IS_DROIDDECK" = true ]]; then
        NO_SUDO=true
        ASSELLA_FORCE_NO_GIT=1
    elif ! command -v sudo &>/dev/null; then
        NO_SUDO=true
    fi
}

detect_distro_family() {
    local family="unknown"
    if [ "$IS_STEAM_DECK" = true ]; then
        family="arch"
    elif [ "$DISTRO_ID" = "bazzite" ] || [ "$DISTRO_ID" = "chimeraos" ] || [ "$DISTRO_ID" = "holoiso" ]; then
        family="arch"
    elif [[ "$DISTRO_ID" == "fedora" || "$DISTRO_ID" == "rhel" || "$DISTRO_ID" == "centos" || "$DISTRO_ID" == "nobara" || "$DISTRO_LIKE" =~ "fedora" || "$DISTRO_LIKE" =~ "rhel" ]]; then
        family="fedora"
    elif [[ "$DISTRO_ID" == "debian" || "$DISTRO_ID" == "ubuntu" || "$DISTRO_ID" == "linuxmint" || "$DISTRO_ID" == "pop" || "$DISTRO_LIKE" =~ "debian" || "$DISTRO_LIKE" =~ "ubuntu" ]]; then
        family="debian"
    elif [[ "$DISTRO_ID" == "arch" || "$DISTRO_ID" == "cachyos" || "$DISTRO_ID" == "manjaro" || "$DISTRO_ID" == "endeavouros" || "$DISTRO_LIKE" =~ "arch" ]]; then
        family="arch"
    elif [[ "$DISTRO_ID" =~ opensuse || "$DISTRO_ID" =~ suse || "$DISTRO_LIKE" =~ opensuse || "$DISTRO_LIKE" =~ suse ]]; then
        family="opensuse"
    elif [[ "$DISTRO_ID" == "alpine" ]]; then
        family="alpine"
    elif [[ "$DISTRO_ID" == "void" ]]; then
        family="void"
    elif [[ "$DISTRO_ID" == "solus" ]]; then
        family="solus"
    elif [[ "$DISTRO_ID" == "gentoo" ]]; then
        family="gentoo"
    fi
    echo "$family"
}

check_fuse_status() {
    FUSE_INSTALLED=false
    if command -v ldconfig &>/dev/null; then
        if ldconfig -p 2>/dev/null | grep -q "libfuse.so.2"; then
            FUSE_INSTALLED=true
        fi
    fi

    if [ "$FUSE_INSTALLED" = false ]; then
        if [ -f /usr/lib/libfuse.so.2 ] || [ -f /lib/libfuse.so.2 ] || [ -f /usr/lib64/libfuse.so.2 ] || [ -f /lib64/libfuse.so.2 ] || [ -f /lib/x86_64-linux-gnu/libfuse.so.2 ]; then
            FUSE_INSTALLED=true
        fi
    fi
}

detect_steam_paths() {
    STEAM_TYPE="none"
    STEAM_DIR=""
    SLS_CONFIG_DIR=""
    SLS_CONFIG_FILE=""

    # 1. Check where SLSsteam configuration exists
    if [ -f "$HOME/.var/app/com.valvesoftware.Steam/.config/SLSsteam/config.yaml" ]; then
        STEAM_TYPE="flatpak"
        SLS_CONFIG_DIR="$HOME/.var/app/com.valvesoftware.Steam/.config/SLSsteam"
    elif [ -f "$HOME/.config/SLSsteam/config.yaml" ]; then
        STEAM_TYPE="native"
        SLS_CONFIG_DIR="$HOME/.config/SLSsteam"
    elif [ -d "$HOME/.var/app/com.valvesoftware.Steam/.config/SLSsteam" ]; then
        STEAM_TYPE="flatpak"
        SLS_CONFIG_DIR="$HOME/.var/app/com.valvesoftware.Steam/.config/SLSsteam"
    elif [ -d "$HOME/.config/SLSsteam" ]; then
        STEAM_TYPE="native"
        SLS_CONFIG_DIR="$HOME/.config/SLSsteam"
    fi

    # 2. Check Steam client installation directories if SLS not located yet
    if [ "$STEAM_TYPE" = "none" ]; then
        if [ -d "$HOME/.var/app/com.valvesoftware.Steam/.steam/steam" ] || [ -d "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam" ]; then
            STEAM_TYPE="flatpak"
            SLS_CONFIG_DIR="$HOME/.var/app/com.valvesoftware.Steam/.config/SLSsteam"
        elif [ -d "$HOME/.local/share/Steam" ] || [ -d "$HOME/.steam/steam" ] || [ -d "$HOME/.steam/root" ]; then
            STEAM_TYPE="native"
            SLS_CONFIG_DIR="$HOME/.config/SLSsteam"
        elif [ -d "$HOME/snap/steam/common/.steam/steam" ]; then
            STEAM_TYPE="snap"
            SLS_CONFIG_DIR="$HOME/snap/steam/common/.config/SLSsteam"
        else
            STEAM_TYPE="native"
            SLS_CONFIG_DIR="$HOME/.config/SLSsteam"
        fi
    fi

    # 3. Resolve Steam directory
    if [ "$STEAM_TYPE" = "flatpak" ]; then
        STEAM_DIR="$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
        [ -d "$STEAM_DIR" ] || STEAM_DIR="$HOME/.var/app/com.valvesoftware.Steam/.steam/steam"
    elif [ "$STEAM_TYPE" = "snap" ]; then
        STEAM_DIR="$HOME/snap/steam/common/.local/share/Steam"
        [ -d "$STEAM_DIR" ] || STEAM_DIR="$HOME/snap/steam/common/.steam/steam"
    else
        STEAM_DIR="$HOME/.local/share/Steam"
        [ -d "$STEAM_DIR" ] || STEAM_DIR="$HOME/.steam/steam"
    fi

    SLS_CONFIG_FILE="$SLS_CONFIG_DIR/config.yaml"
}

check_headcrab_status() {
    HEADCRAB_INSTALLED=false
    detect_steam_paths
    if [ -f "$HOME/.local/share/SLSsteam/SLSsteam.so" ]; then
        HEADCRAB_INSTALLED=true
    elif [ -f "$SLS_CONFIG_FILE" ] || [ -d "$SLS_CONFIG_DIR" ] || [ -d "/tmp/SLSsteam" ]; then
        HEADCRAB_INSTALLED=true
    elif command -v systemctl &>/dev/null && systemctl --user is-active slssteam &>/dev/null; then
        HEADCRAB_INSTALLED=true
    fi
}

get_local_version() {
    LOCAL_VER="Not Installed"
    if [ -f "$VERSION_FILE" ]; then
        read -r LOCAL_VER < "$VERSION_FILE" || LOCAL_VER="Unknown"
        LOCAL_VER=$(printf '%s' "$LOCAL_VER" | tr -d '\r\n')
    elif [ -f "$INSTALL_DESTINATION/squashfs-root/bin/src/res/version" ]; then
        read -r LOCAL_VER < "$INSTALL_DESTINATION/squashfs-root/bin/src/res/version" || LOCAL_VER="Unknown"
        LOCAL_VER=$(printf '%s' "$LOCAL_VER" | tr -d '\r\n')
    fi
}

detect_channel() {
    if [ -n "${TARGET_CHANNEL:-}" ]; then
        return 0
    fi
    if [[ "${IS_ARM64:-false}" = true ]]; then
        TARGET_CHANNEL="${TARGET_CHANNEL:-arm64}"
        ARM64_BRANCH="${ASSELLA_ARM64_BRANCH:-$ASSELLA_INSTALL_BRANCH}"
        return 0
    fi
    # Default to beta channel for beta branch installer
    TARGET_CHANNEL="beta"
}

python3_version_ok() {
    local ver
    ver="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0.0")"
    local major="${ver%%.*}"
    local minor="${ver#*.}"
    if (( major > 3 )) || { (( major == 3 )) && (( minor >= 12 )); }; then
        return 0
    fi
    return 1
}

ensure_bundled_python_arm64() {
    local py_root="$INSTALL_DESTINATION/.python"
    local py_bin="$py_root/bin/python3"
    if [ -x "$py_bin" ]; then
        return 0
    fi
    echo -e "${YELLOW}[INFO] Bootstrapping Python 3.13 (aarch64 standalone) for ASSella...${NC}"
    local tgz="${TMP_DIR:-/tmp}/cpython-arm64.tar.gz"
    mkdir -p "$TMP_DIR" "$py_root" 2>/dev/null || true
    if ! curl -fsSL --retry 3 -o "$tgz" \
        "https://github.com/astral-sh/python-build-standalone/releases/download/20241016/cpython-3.13.0+20241016-aarch64-unknown-linux-gnu-install_only.tar.gz"; then
        echo -e "${RED}[ERROR] Failed to download standalone Python for ARM64.${NC}" >&2
        return 1
    fi
    tar -xzf "$tgz" -C "$py_root" --strip-components=1 2>/dev/null || tar -xzf "$tgz" -C "$py_root"
    [ -x "$py_bin" ] || py_bin="$(find "$py_root" -maxdepth 3 -name python3 -type f 2>/dev/null | head -n1)"
    if [ ! -x "$py_bin" ]; then
        echo -e "${RED}[ERROR] Standalone Python extraction failed.${NC}" >&2
        return 1
    fi
    echo -e "${GREEN}[OK] Standalone Python ready at $py_bin${NC}"
}

resolve_python3_for_venv() {
    if python3_version_ok && command -v python3 &>/dev/null; then
        echo "python3"
        return 0
    fi
    ensure_bundled_python_arm64 || return 1
    local py_bin="$INSTALL_DESTINATION/.python/bin/python3"
    [ -x "$py_bin" ] || py_bin="$(find "$INSTALL_DESTINATION/.python" -maxdepth 3 -name python3 -type f 2>/dev/null | head -n1)"
    if [ -x "$py_bin" ]; then
        echo "$py_bin"
        return 0
    fi
    return 1
}

arm64_can_use_git() {
    # Git is optional on ARM64; tarball fetch works without it (required on DroidDeck).
    if [[ "${ASSELLA_FORCE_NO_GIT:-}" == "1" ]] || [[ "${IS_DROIDDECK:-false}" = true ]]; then
        return 1
    fi
    command -v git &>/dev/null
}

download_arm64_source_tarball() {
    local branch="${ARM64_BRANCH:-$ASSELLA_INSTALL_BRANCH}"
    local url="https://codeload.github.com/${ASSELLA_GH_OWNER}/${ASSELLA_GH_REPO}/tar.gz/${branch}"
    local work="${TMP_DIR:-}"
    if [ -z "$work" ] || [ ! -d "$work" ]; then
        work="$(mktemp -d -t assella-src-XXXXXX)"
    fi
    local tgz="$work/assella-src.tar.gz"
    local extract_parent="$work/assella-src-extract"

    echo -e "${YELLOW}[INFO] Downloading ASSella source archive (${branch}) via curl...${NC}"
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tgz" "$url"; then
        echo -e "${RED}[ERROR] Failed to download source tarball from GitHub.${NC}" >&2
        echo -e "${YELLOW}       URL: $url${NC}" >&2
        return 1
    fi

    rm -rf "$extract_parent"
    mkdir -p "$extract_parent"
    if ! tar -xzf "$tgz" -C "$extract_parent"; then
        echo -e "${RED}[ERROR] Failed to extract source archive (need tar + gzip).${NC}" >&2
        return 1
    fi

    local topdir
    topdir="$(find "$extract_parent" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)"
    if [ -z "$topdir" ] || [ ! -f "$topdir/src/main.py" ]; then
        echo -e "${RED}[ERROR] Downloaded archive layout was unexpected (missing src/main.py).${NC}" >&2
        return 1
    fi

    rm -rf "$ARM64_SRC_TREE"
    mv "$topdir" "$ARM64_SRC_TREE"
    echo -e "${GREEN}[OK] Source tree ready at $ARM64_SRC_TREE (no git required).${NC}"
}

ensure_arm64_prereqs() {
    local missing=()
    for cmd in curl tar; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if ! command -v python3 &>/dev/null && ! resolve_python3_for_venv &>/dev/null; then
        missing+=("python3")
    fi
    if ((${#missing[@]} > 0)); then
        echo -e "${RED}[ERROR] Missing required tools: ${missing[*]}${NC}" >&2
        echo -e "${YELLOW}       ARM64/DroidDeck needs curl, tar, and python3 — not git.${NC}" >&2
        return 1
    fi
    if ! python3_version_ok; then
        echo -e "${YELLOW}[WARN] System python3 is older than 3.12; will try standalone Python 3.13.${NC}"
    fi
    return 0
}

sync_arm64_source() {
    ARM64_SRC_TREE="$INSTALL_DESTINATION/src-tree"
    mkdir -p "$INSTALL_DESTINATION"

    local script_root=""
    if [ -f "${BASH_SOURCE[0]:-}" ]; then
        script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi
    if [ -n "$script_root" ] && [ -f "$script_root/src/main.py" ]; then
        echo -e "${YELLOW}[INFO] Copying local ASSella source into $ARM64_SRC_TREE...${NC}"
        mkdir -p "$ARM64_SRC_TREE"
        if command -v rsync &>/dev/null; then
            rsync -a --delete --exclude '.git' --exclude '.venv' --exclude 'node_modules' \
                "$script_root/" "$ARM64_SRC_TREE/"
        else
            rm -rf "$ARM64_SRC_TREE"/*
            cp -a "$script_root"/. "$ARM64_SRC_TREE/"
        fi
        return 0
    fi

    if arm64_can_use_git && [ -d "$ARM64_SRC_TREE/.git" ]; then
        echo -e "${YELLOW}[INFO] Updating ASSella source ($ARM64_BRANCH) via git...${NC}"
        git -C "$ARM64_SRC_TREE" fetch origin "$ARM64_BRANCH" --depth 1 2>/dev/null || \
            git -C "$ARM64_SRC_TREE" fetch origin "$ARM64_BRANCH"
        git -C "$ARM64_SRC_TREE" checkout "$ARM64_BRANCH"
        git -C "$ARM64_SRC_TREE" pull origin "$ARM64_BRANCH" --ff-only || \
            git -C "$ARM64_SRC_TREE" reset --hard "origin/$ARM64_BRANCH"
        return 0
    fi

    if arm64_can_use_git; then
        echo -e "${YELLOW}[INFO] Cloning ASSella ($ARM64_BRANCH) into $ARM64_SRC_TREE...${NC}"
        rm -rf "$ARM64_SRC_TREE"
        git clone --branch "$ARM64_BRANCH" --depth 1 "$ARM64_REPO_URL" "$ARM64_SRC_TREE"
        return 0
    fi

    download_arm64_source_tarball
}

fetch_arm64_deps_dlls() {
    local deps_dir="$ARM64_SRC_TREE/src/deps"
    local branch="${ARM64_BRANCH:-arm64}"
    local base="${ASSELLA_RAW_BASE}/${branch}/src/deps"
    mkdir -p "$deps_dir"
    local dlls=(
        DepotDownloader.dll
        DepotDownloader.deps.json
        DepotDownloader.runtimeconfig.json
        SteamKit2.dll
        protobuf-net.dll
        protobuf-net.Core.dll
        ZstdSharp.dll
        System.IO.Hashing.dll
        QRCoder.dll
    )
    local name
    for name in "${dlls[@]}"; do
        if [ ! -s "$deps_dir/$name" ]; then
            echo -e "${YELLOW}[INFO] Fetching $name...${NC}"
            curl -fsSL "$base/$name" -o "$deps_dir/$name" || {
                echo -e "${RED}[WARN] Could not download $name${NC}"
            }
        fi
    done
}

ensure_arm64_dotnet() {
    local dotnet_root="$HOME/.dotnet"
    if [ -x "$dotnet_root/dotnet" ] && "$dotnet_root/dotnet" --list-runtimes 2>/dev/null | grep -q "Microsoft.NETCore.App 9"; then
        echo -e "${GREEN}[OK] .NET 9 runtime (ARM64) already installed.${NC}"
        return 0
    fi
    echo -e "${YELLOW}[INFO] Installing .NET 9 runtime (linux-arm64) to $dotnet_root...${NC}"
    local ds
    ds="$(mktemp -t dotnet-install.XXXXXX.sh)"
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$ds"
    chmod +x "$ds"
    bash "$ds" --runtime dotnet --channel 9.0 --architecture arm64 --install-dir "$dotnet_root"
    rm -f "$ds"
}

arm64_pip_needs_gitless_vcs() {
    if [[ "${ASSELLA_FORCE_NO_GIT:-}" == "1" ]] || [[ "${IS_DROIDDECK:-false}" = true ]]; then
        return 0
    fi
    if ! command -v git &>/dev/null; then
        return 0
    fi
    return 1
}

install_arm64_pip_dependencies() {
    local venv_py="$1"
    local req_file="$ARM64_SRC_TREE/requirements.txt"
    local filtered_req="${TMP_DIR:-/tmp}/requirements-arm64-no-vcs.txt"

    if ! arm64_pip_needs_gitless_vcs; then
        "$venv_py" -m pip install -r "$req_file" -q
        return 0
    fi

    echo -e "${YELLOW}[INFO] Installing steam/vdf from GitHub zip archives (git not used)...${NC}"
    # vdf before steam; steam's metadata may reference git for vdf if vdf is missing.
    if ! "$venv_py" -m pip install --no-cache-dir "$ASSELLA_VDF_GIT_ARCHIVE"; then
        echo -e "${RED}[ERROR] Failed to pip install vdf from GitHub archive.${NC}" >&2
        return 1
    fi
    if ! "$venv_py" -m pip install --no-cache-dir "$ASSELLA_STEAM_GIT_ARCHIVE"; then
        echo -e "${RED}[ERROR] Failed to pip install steam from GitHub archive.${NC}" >&2
        return 1
    fi

    grep -viE '^[[:space:]]*(steam|vdf)[[:space:]]+@ git\+' "$req_file" > "$filtered_req" || true
    if [ ! -s "$filtered_req" ]; then
        echo -e "${RED}[ERROR] Could not build filtered requirements file.${NC}" >&2
        return 1
    fi
    "$venv_py" -m pip install -r "$filtered_req" -q
}

ensure_arm64_venv() {
    local py
    py="$(resolve_python3_for_venv)" || return 1
    local venv="$INSTALL_DESTINATION/.venv"
    if [ ! -x "$venv/bin/python3" ]; then
        echo -e "${YELLOW}[INFO] Creating Python virtual environment...${NC}"
        "$py" -m venv "$venv"
    fi
    if [[ "${ARM64_NO_PIP:-false}" = true ]]; then
        echo -e "${YELLOW}[INFO] Skipping pip install (--no-pip).${NC}"
        return 0
    fi
    echo -e "${YELLOW}[INFO] Installing Python dependencies (this may take several minutes)...${NC}"
    "$venv/bin/python3" -m pip install --upgrade pip wheel -q
    install_arm64_pip_dependencies "$venv/bin/python3"
}

write_run_assella_launcher() {
    cat >"$RUN_ASSella_LAUNCHER" <<'EOL'
#!/usr/bin/env bash
export DOTNET_ROOT="${HOME}/.dotnet"
export PATH="${HOME}/.dotnet:${HOME}/.local/bin:${PATH}"
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
INSTALL_ROOT="${HOME}/.local/share/ACCELA"
SRC_TREE="${INSTALL_ROOT}/src-tree"
cd "$SRC_TREE" || exit 1
exec "${INSTALL_ROOT}/.venv/bin/python3" "$SRC_TREE/src/main.py" "$@"
EOL
    chmod +x "$RUN_ASSella_LAUNCHER"
}

write_steam_sls_wrapper() {
    mkdir -p "$HOME/.local/bin"
    cat >"$STEAM_SLS_WRAPPER" <<'EOL'
#!/usr/bin/env bash
SLS_DIR="${HOME}/.local/share/SLSsteam"
export LD_AUDIT="${SLS_DIR}/library-inject.so:${SLS_DIR}/SLSsteam.so"
exec steam "$@"
EOL
    chmod +x "$STEAM_SLS_WRAPPER"
}

verify_sls_elf_arch() {
    local so="$HOME/.local/share/SLSsteam/SLSsteam.so"
    local inj="$HOME/.local/share/SLSsteam/library-inject.so"
    if [ ! -f "$so" ] || [ ! -f "$inj" ]; then
        return 1
    fi
    if ! command -v file &>/dev/null; then
        echo -e "${YELLOW}[WARN] 'file' command missing; cannot verify SLSsteam architecture.${NC}"
        return 0
    fi
    local host arch_so arch_inj
    host="$(uname -m)"
    arch_so="$(file -b "$so" 2>/dev/null || true)"
    arch_inj="$(file -b "$inj" 2>/dev/null || true)"
    case "$host" in
        aarch64|arm64)
            if [[ "$arch_so" != *"ARM aarch64"* ]] && [[ "$arch_so" != *"aarch64"* ]]; then
                echo -e "${RED}${BOLD}[WARN] SLSsteam.so architecture mismatch for $host:${NC}"
                echo -e "  $arch_so"
                echo -e "${YELLOW}Native ARM64 Steam cannot load x86_64 SLSsteam. See docs/droiddeck-spike.md${NC}"
                return 1
            fi
            ;;
        x86_64|amd64)
            if [[ "$arch_so" != *"x86-64"* ]]; then
                echo -e "${YELLOW}[WARN] SLSsteam.so may not match x86_64 host.${NC}"
            fi
            ;;
    esac
    return 0
}

install_sls_lua_plugins() {
    local cfg_dir="$HOME/.config/SLSsteam"
    local plugins_dir="$cfg_dir/plugins"
    mkdir -p "$plugins_dir"
    local zip="${TMP_DIR:-$(mktemp -d)}/plugins-deps.zip"
    if ! curl -fsSL --retry 3 "$PLUGINS_ZIP_URL" -o "$zip"; then
        echo -e "${YELLOW}[WARN] Could not download Lua plugins package.${NC}"
        return 1
    fi
    if command -v unzip &>/dev/null; then
        unzip -j -o -q "$zip" "*.lua" -d "$plugins_dir" || true
    else
        echo -e "${YELLOW}[WARN] unzip not found; skipping Lua plugin extraction.${NC}"
        return 1
    fi
    local cfg="$cfg_dir/config.yaml"
    if [ ! -s "$cfg" ]; then
        printf 'Plugins: yes\n' > "$cfg"
    elif grep -qE '^[[:space:]]*Plugins:' "$cfg"; then
        sed -i -E 's/^[[:space:]]*Plugins:[[:space:]]*.*/Plugins: yes/' "$cfg"
    else
        printf '\nPlugins: yes\n' >> "$cfg"
    fi
    echo -e "${GREEN}[OK] Lua plugins deployed to $plugins_dir${NC}"
}

install_slssteam_minimal() {
    echo -e "\n${CYAN}${BOLD}=== SLSsteam install (DroidDeck-safe, no Steam updater) ===${NC}"

    local sls_dir="$HOME/.local/share/SLSsteam"
    local cfg_dir="$HOME/.config/SLSsteam"
    mkdir -p "$sls_dir" "$cfg_dir"

    if [ ! -d "$HOME/.local/share/Steam/steamapps" ] && [ ! -d "$HOME/.steam/steam/steamapps" ]; then
        echo -e "${YELLOW}[WARN] Steam library not found. Launch Steam once before SLS install.${NC}"
    fi

    local work="${TMP_DIR:-}"
    if [ -z "$work" ] || [ ! -d "$work" ]; then
        work="$(mktemp -d -t assella-sls-XXXXXX)"
    fi
    local dl_dir="$work/SLSsteam_Download"
    mkdir -p "$dl_dir"
    cd "$dl_dir" || return 1

    echo -e "${YELLOW}[INFO] Downloading netsock patch...${NC}"
    mkdir -p "$cfg_dir/tools/netsock"
    curl -fsSL "https://cdn.jsdelivr.net/gh/yesyes0649/steamnetsock-patch@builds/fix.so" \
        -o "$cfg_dir/tools/netsock/netsock.so" 2>/dev/null || true

    echo -e "${YELLOW}[INFO] Downloading latest SLSsteam release...${NC}"
    local tag
    tag="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
        "https://github.com/AceSLS/SLSsteam/releases/latest" 2>/dev/null | sed 's|.*/||')"
    if [ -z "$tag" ]; then
        echo -e "${RED}[ERROR] Could not resolve SLSsteam release tag.${NC}"
        return 1
    fi
    if ! curl -fsSL -o SLSsteam-Any.7z \
        "https://github.com/AceSLS/SLSsteam/releases/download/${tag}/SLSsteam-Any-release.7z"; then
        echo -e "${RED}[ERROR] Failed to download SLSsteam archive.${NC}"
        return 1
    fi

    local extract_ok=false
    if command -v 7z &>/dev/null; then
        7z x -y SLSsteam-Any.7z -o"$dl_dir/extracted" >/dev/null && extract_ok=true
    elif command -v 7za &>/dev/null; then
        7za x -y SLSsteam-Any.7z -o"$dl_dir/extracted" >/dev/null && extract_ok=true
    elif command -v bsdtar &>/dev/null; then
        mkdir -p "$dl_dir/extracted"
        bsdtar -xf SLSsteam-Any.7z -C "$dl_dir/extracted" && extract_ok=true
    fi
    if [[ "$extract_ok" != true ]]; then
        echo -e "${RED}[ERROR] Install 7z, p7zip, or bsdtar to extract SLSsteam.${NC}"
        return 1
    fi

    echo -e "${YELLOW}[INFO] Installing SLSsteam into $sls_dir...${NC}"
    rm -rf "$sls_dir"
    mkdir -p "$sls_dir"
    if [ -d "$dl_dir/extracted" ]; then
        cp -a "$dl_dir/extracted"/* "$sls_dir/" 2>/dev/null || cp -a "$dl_dir/extracted/." "$sls_dir/"
    fi
    if [ -f "$dl_dir/extracted/res/config.yaml" ]; then
        mkdir -p "$cfg_dir"
        if [ ! -s "$cfg_dir/config.yaml" ]; then
            cp -a "$dl_dir/extracted/res/config.yaml" "$cfg_dir/config.yaml"
        fi
    fi

    install_sls_lua_plugins || true
    write_steam_sls_wrapper
    verify_sls_elf_arch || true

    HEADCRAB_INSTALLED=true
    SLS_CONFIG_DIR="$cfg_dir"
    SLS_CONFIG_FILE="$cfg_dir/config.yaml"
    echo -e "${GREEN}[OK] SLSsteam installed. Restart Steam with: steam-sls${NC}"
}

do_install_arm64_source() {
    echo -e "\n${CYAN}[INFO] ASSella installer rev: ${ASSELLA_INSTALLER_REV}${NC}"
    echo -e "${YELLOW}[INFO] Installing ASSella (ARM64 source build)...${NC}"
    mkdir -p "$INSTALL_DESTINATION"
    check_disk_space "$INSTALL_DESTINATION" || return 1
    ensure_arm64_prereqs || return 1

    TMP_DIR="$(mktemp -d -t assella-arm64-XXXXXX)" || {
        echo -e "${RED}[ERROR] Could not create temporary directory.${NC}"
        return 1
    }

    sync_arm64_source || return 1
    fetch_arm64_deps_dlls
    ensure_arm64_dotnet || return 1
    ensure_arm64_venv || return 1

    write_run_assella_launcher

    if [ -f "$ARM64_SRC_TREE/src/res/version" ]; then
        cp -a "$ARM64_SRC_TREE/src/res/version" "$VERSION_FILE"
        read -r LOCAL_VER < "$VERSION_FILE" || LOCAL_VER="ARM64"
    else
        echo "arm64-source" > "$VERSION_FILE"
    fi

    local exec_cmd="$RUN_ASSella_LAUNCHER %u"
    echo -e "${YELLOW}[INFO] Configuring desktop shortcut...${NC}"
    mkdir -p "$DESKTOP_DIR" "$ICON_DIR"
    cat >"$PRIMARY_DESKTOP_ENTRY" <<EOL
[Desktop Entry]
Version=2.0
Name=ASSella
Comment=Steam depot management (ARM64)
Exec=$exec_cmd
Icon=assella
Terminal=false
Type=Application
Categories=Utility;Game;
MimeType=x-scheme-handler/accela;
EOL

    local icon_src="$ARM64_SRC_TREE/src/res/logo/icon.png"
    if [ -f "$icon_src" ]; then
        cp -a "$icon_src" "$PRIMARY_ICON_PATH"
    else
        curl -sL -o "$PRIMARY_ICON_PATH" \
            "${ASSELLA_RAW_BASE}/${ARM64_BRANCH}/src/res/logo/icon.png" || true
    fi

    if command -v update-desktop-database &>/dev/null; then
        update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    fi

    if [[ "${SKIP_SLS:-false}" = false ]] && [[ "${SLS_ONLY:-false}" = false ]]; then
        if [[ "${IS_DROIDDECK:-false}" = true ]] || [[ "${INSTALL_SLS_WITH_ARM64:-}" == "1" ]]; then
            install_slssteam_minimal || echo -e "${YELLOW}[WARN] SLS install failed; continue with depot-only mode.${NC}"
        fi
    fi

    echo -e "\n${GREEN}${BOLD}[OK] ASSella ARM64 installation complete.${NC}"
    echo -e "Launch: ${GREEN}$RUN_ASSella_LAUNCHER${NC} or the ASSella desktop icon."
    if [[ -x "$STEAM_SLS_WRAPPER" ]]; then
        echo -e "Steam + SLS: ${GREEN}steam-sls${NC}"
    fi
}

prompt_user() {
    local prompt_msg="$1"
    local default_val="${2:-}"
    local response=""
    if [ -t 0 ]; then
        read -r -p "$prompt_msg" response || true
    elif [ -r /dev/tty ]; then
        read -r -p "$prompt_msg" response </dev/tty || true
    else
        read -r response || true
    fi
    echo "${response:-$default_val}"
}

check_and_warn_fuse() {
    check_fuse_status
    if [ "$FUSE_INSTALLED" = true ] || [ "$IS_NIXOS" = true ]; then
        return 0
    fi

    local family
    family=$(detect_distro_family)
    local cmd="${PKG_FUSE_CMD[$family]:-}"

    echo -e "\n${YELLOW}${BOLD}[WARN] FUSE 2 (libfuse.so.2) is not detected!${NC}"
    echo -e "ASSella AppImage requires fuse2 to run on your system."

    if [ -n "$cmd" ]; then
        echo -e "If the AppImage does not launch, install fuse2 on ${BOLD}$DISTRO_NAME${NC}:"
        echo -e "  ${GREEN}$cmd${NC}\n"
    else
        echo -e "If the AppImage does not launch, please install fuse2 / libfuse2 using your package manager.\n"
    fi
}

check_disk_space() {
    local target_dir="${1:-$INSTALL_DESTINATION}"
    local need_bytes=$(( 200 * 1024 * 1024 )) # 200 MB
    mkdir -p "$target_dir" 2>/dev/null || true
    if command -v df &>/dev/null; then
        local avail
        avail=$(df --output=avail -B1 "$target_dir" 2>/dev/null | tail -n 1 | tr -d '[:space:]')
        if [[ "$avail" =~ ^[0-9]+$ ]] && (( avail < need_bytes )); then
            echo -e "${RED}[ERROR] Insufficient disk space in $target_dir (less than 200MB free).${NC}" >&2
            return 1
        fi
    fi
    return 0
}

fetch_github_json() {
    local url="$1"
    local tries=3
    local delay=2
    local auth_header=()

    if [ -n "${ASSELLA_GH_TOKEN:-}" ]; then
        auth_header=(-H "Authorization: Bearer $ASSELLA_GH_TOKEN")
    elif [ -n "${GITHUB_TOKEN:-}" ]; then
        auth_header=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi

    while (( tries-- > 0 )); do
        local body
        if body=$(curl -fsSL -H "Accept: application/vnd.github+json" \
                -H "User-Agent: ASSella-Installer" \
                "${auth_header[@]}" \
                --max-time 15 \
                "$url" 2>/dev/null); then
            printf '%s' "$body"
            return 0
        fi
        sleep "$delay"
        delay=$(( delay * 2 ))
    done
    return 1
}

run_headcrab_installer() {
    echo -e "\n${CYAN}${BOLD}=== Running Headcrab (SLSsteam) Installer ===${NC}"
    detect_steam_paths
    local config_file="$SLS_CONFIG_FILE"
    local backup_config=""
    if [ -n "$config_file" ] && [ -f "$config_file" ]; then
        backup_config=$(mktemp "${config_file}.pre_headcrab.XXXXXX")
        cp -a "$config_file" "$backup_config"
        echo -e "${YELLOW}[INFO] Backed up SLSsteam config before running Headcrab.${NC}"
    fi

    local tmp_headcrab
    tmp_headcrab="$(mktemp -t headcrab.XXXXXX.sh)"
    echo -e "${YELLOW}[INFO] Downloading latest Headcrab installer...${NC}"
    if curl -fsSL --retry 3 --retry-delay 2 "https://raw.githubusercontent.com/Deadboy666/h3adcr-b/main/headcrab.sh" -o "$tmp_headcrab"; then
        chmod +x "$tmp_headcrab"
        if [ -t 0 ]; then
            bash "$tmp_headcrab" || true
        elif [ -r /dev/tty ]; then
            bash "$tmp_headcrab" </dev/tty || true
        else
            bash "$tmp_headcrab" || true
        fi
    else
        echo -e "${RED}[ERROR] Failed to download Headcrab installer.${NC}"
    fi
    rm -f "$tmp_headcrab"

    # Restore and merge any custom sections (AdditionalDepots, DecryptionKeys) that Headcrab stripped
    if [ -n "$backup_config" ] && [ -f "$backup_config" ]; then
        detect_steam_paths
        config_file="$SLS_CONFIG_FILE"
        if [ -n "$config_file" ] && [ -f "$config_file" ]; then
            python3 -c '
import sys

backup_path = sys.argv[1]
current_path = sys.argv[2]

try:
    with open(backup_path, "r", encoding="utf-8") as f:
        bak_lines = f.readlines()
    with open(current_path, "r", encoding="utf-8") as f:
        curr_lines = f.readlines()

    bak_sections = {}
    curr_key = None
    curr_content = []

    for line in bak_lines:
        if line.strip() and not line.startswith(" ") and not line.startswith("\t") and not line.startswith("#") and ":" in line:
            if curr_key:
                bak_sections[curr_key] = "".join(curr_content)
            curr_key = line.split(":", 1)[0].strip()
            curr_content = [line]
        elif curr_key:
            curr_content.append(line)
    if curr_key:
        bak_sections[curr_key] = "".join(curr_content)

    curr_text = "".join(curr_lines)
    missing_sections = []
    protected_keys = ["AdditionalDepots", "DecryptionKeys", "ExtraDepots", "DlcData", "FakeAppIds", "AppList"]
    for k in protected_keys:
        if k in bak_sections and f"{k}:" not in curr_text:
            missing_sections.append(bak_sections[k])

    if missing_sections:
        # Append in-place to preserve system inode
        with open(current_path, "a", encoding="utf-8") as f:
            f.write("\n# Restored by ASSella (protected from Headcrab wipe):\n")
            for sec in missing_sections:
                f.write(sec)
                if not sec.endswith("\n"):
                    f.write("\n")
        print("[INFO] Re-injected protected sections (AdditionalDepots/DecryptionKeys) into SLSsteam config.")
except Exception as e:
    print(f"[WARN] Error restoring protected config sections: {e}")
' "$backup_config" "$config_file" 2>/dev/null || true
        fi
        rm -f "$backup_config"
    fi

    check_headcrab_status
    if [ "$HEADCRAB_INSTALLED" = true ]; then
        echo -e "${GREEN}[OK] Headcrab (SLSsteam) installation completed.${NC}"
    else
        echo -e "${YELLOW}[WARN] Headcrab finished, but ~/.config/SLSsteam was not detected.${NC}"
    fi
}

get_latest_github_version() {
    LATEST_VER="Unknown"
    LATEST_URL=""
    detect_channel

    REL_JSON=$(fetch_github_json "$ASSELLA_API_RELEASES" || true)
    if [ -n "$REL_JSON" ]; then
        if command -v python3 &>/dev/null; then
            PARSED=$(echo "$REL_JSON" | python3 -c '
import sys, json

target_channel = sys.argv[1] if len(sys.argv) > 1 else "beta"
try:
    data = json.load(sys.stdin)
    for r in data:
        tag = str(r.get("tag_name", "")).strip()
        tag_lower = tag.lower()
        is_canary = any(x in tag_lower for x in ("canary", "testing", "release_candidate", "releasecandidate"))
        is_beta = any(x in tag_lower for x in ("beta", "dev", "rc")) and not is_canary
        is_stable = not is_canary and not is_beta

        if target_channel == "canary" and not is_canary:
            continue
        elif target_channel == "beta" and not is_beta:
            continue
        elif target_channel == "stable" and not is_stable:
            continue

        for a in r.get("assets", []):
            name = a.get("name", "")
            if name.lower().endswith(".appimage") and not name.lower().endswith(".zsync") and not name.lower().endswith(".sha256"):
                print(tag)
                print(a.get("browser_download_url", ""))
                sys.exit(0)
except Exception:
    sys.exit(1)
' "$TARGET_CHANNEL" || true)
            if [ -n "$PARSED" ]; then
                TAG_NAME=$(echo "$PARSED" | sed -n '1p')
                DL_URL=$(echo "$PARSED" | sed -n '2p')
                if [ -n "$TAG_NAME" ]; then LATEST_VER="$TAG_NAME"; fi
                if [ -n "$DL_URL" ]; then LATEST_URL="$DL_URL"; fi
            fi
        fi

        if ! command -v python3 &>/dev/null && [ "$LATEST_VER" = "Unknown" ]; then
            TAG_NAME=$(echo "$REL_JSON" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | cut -d '"' -f 4 || true)
            if [ -n "$TAG_NAME" ]; then
                LATEST_VER="$TAG_NAME"
            fi

            DL_URL=$(echo "$REL_JSON" | grep -o '"browser_download_url": *"[^"]*ASSella\.AppImage"' | head -n 1 | cut -d '"' -f 4 || true)
            if [ -n "$DL_URL" ]; then
                LATEST_URL="$DL_URL"
            fi
        fi
    fi

    # Channel-aware fallback if GitHub API rate-limits or network fails
    if [ -z "$LATEST_URL" ]; then
        if [ "$TARGET_CHANNEL" = "canary" ]; then
            LATEST_VER="v3.0Release_candidate111026001"
            LATEST_URL="${ASSELLA_RELEASES_BASE}/v3.0Release_candidate111026001/assella3.0canary.appimage"
        elif [ "$TARGET_CHANNEL" = "stable" ]; then
            LATEST_VER="v2.6.5"
            LATEST_URL="${ASSELLA_RELEASES_BASE}/v2.6.5/ASSella.AppImage"
        else
            LATEST_VER="v2.7.0beta"
            LATEST_URL="${ASSELLA_RELEASES_BASE}/v2.7.0beta/ASSella.AppImage"
        fi
    fi
}

# ------------------------------------------------------------------------------
#  2. Header & Status Display
# ------------------------------------------------------------------------------
show_header() {
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}===================================================================${NC}"
    echo -e "${GREEN}${BOLD}                         ASSella Installer                         ${NC}"
    echo -e "${CYAN}${BOLD}===================================================================${NC}"
    echo -e "  ${BOLD}OS Detected:${NC}      ${DISTRO_NAME:-Generic Linux} ($(uname -m))"
    if [ "${IS_STEAM_DECK:-false}" = true ]; then
        echo -e "  ${BOLD}Device:${NC}           Steam Deck (SteamOS)"
    elif [ "${IS_DROIDDECK:-false}" = true ]; then
        echo -e "  ${BOLD}Device:${NC}           DroidDeck (ARM64 / proot)"
    elif [ "${IS_ARM64:-false}" = true ]; then
        echo -e "  ${BOLD}Device:${NC}           ARM64 Linux"
    fi

    # Steam Client Status
    if [ "$STEAM_TYPE" = "flatpak" ]; then
        echo -e "  ${BOLD}Steam Client:${NC}     ${CYAN}Flatpak (com.valvesoftware.Steam)${NC}"
    elif [ "$STEAM_TYPE" = "snap" ]; then
        echo -e "  ${BOLD}Steam Client:${NC}     ${CYAN}Snap (snap.steam)${NC}"
    elif [ "$STEAM_TYPE" = "native" ] && [ -d "$STEAM_DIR" ]; then
        echo -e "  ${BOLD}Steam Client:${NC}     ${GREEN}Native ($STEAM_DIR)${NC}"
    else
        echo -e "  ${BOLD}Steam Client:${NC}     ${YELLOW}Not Detected${NC}"
    fi

    # Headcrab Status
    if [ "${HEADCRAB_INSTALLED:-false}" = true ]; then
        echo -e "  ${BOLD}Headcrab (SLS):${NC}   ${GREEN}Installed ($SLS_CONFIG_DIR)${NC}"
    else
        echo -e "  ${BOLD}Headcrab (SLS):${NC}   ${YELLOW}Not Detected${NC}"
    fi

    # FUSE Status
    if [ "${IS_NIXOS:-false}" = true ]; then
        echo -e "  ${BOLD}AppImage FUSE:${NC}    ${CYAN}NixOS Mode (Uses steam-run / appimage-run wrapper)${NC}"
    elif [ "${FUSE_INSTALLED:-false}" = true ]; then
        echo -e "  ${BOLD}AppImage FUSE:${NC}    ${GREEN}OK (libfuse.so.2 found)${NC}"
    else
        echo -e "  ${BOLD}AppImage FUSE:${NC}    ${RED}WARNING: fuse2 missing (Required for AppImages)${NC}"
    fi

    # Version Status
    echo -e "  ${BOLD}Local Version:${NC}    ${LOCAL_VER:-Not Installed}"
    if [ -n "${LATEST_VER:-}" ] && [ "${LATEST_VER}" != "Unknown" ]; then
        echo -e "  ${BOLD}Latest Online:${NC}    ${LATEST_VER}"
    fi
    echo -e "${CYAN}${BOLD}===================================================================${NC}"
}

# ------------------------------------------------------------------------------
#  4. Distro-Specific Requirements Guide
# ------------------------------------------------------------------------------
pause_if_interactive() {
    if [ "${INTERACTIVE:-false}" = true ]; then
        read -p "Press Enter to continue..." dummy
    fi
}

show_distro_guide() {
    show_header
    echo -e "\n${YELLOW}${BOLD}=== Distro-Specific Setup & Requirements ===${NC}\n"

    if [ "$IS_NIXOS" = true ]; then
        echo -e "${CYAN}${BOLD}NixOS Installation Guide:${NC}"
        echo -e "NixOS does not use standard /lib64 glibc linkers out of the box."
        echo -e "ASSella automatically generates a launcher using ${GREEN}steam-run${NC} or ${GREEN}appimage-run${NC}.\n"
        echo -e "  ${BOLD}Command to launch directly:${NC}"
        echo -e "    ${GREEN}nix-shell -p steam-run --run 'steam-run ~/.local/share/ACCELA/ASSella.AppImage'${NC}\n"
        echo -e "  ${BOLD}Global fix (Optional):${NC} Add ${GREEN}programs.nix-ld.enable = true;${NC} in /etc/nixos/configuration.nix"
    else
        local family
        family=$(detect_distro_family)
        local cmd="${PKG_FUSE_CMD[$family]:-}"
        echo -e "${CYAN}${BOLD}AppImage FUSE Requirements for $DISTRO_NAME:${NC}"
        echo -e "Modern Linux systems require ${GREEN}fuse2${NC} (libfuse.so.2) to execute AppImages.\n"
        if [ -n "$cmd" ]; then
            echo -e "  ${BOLD}Install command:${NC}"
            echo -e "    ${GREEN}$cmd${NC}"
        else
            echo -e "  ${BOLD}Install command:${NC}"
            echo -e "    Install ${GREEN}fuse2${NC} or ${GREEN}libfuse2${NC} via your system package manager."
        fi
    fi

    echo -e "\n${CYAN}${BOLD}-------------------------------------------------------------------${NC}\n"
    pause_if_interactive
}

# ------------------------------------------------------------------------------
#  5. Main Installation & Update Engine
# ------------------------------------------------------------------------------
do_install() {
    echo -e "\n${YELLOW}[INFO] Installing / Updating ASSella...${NC}"
    mkdir -p "$INSTALL_DESTINATION"

    check_disk_space "$INSTALL_DESTINATION" || {
        pause_if_interactive
        return 1
    }

    if [ -f "$INSTALL_DESTINATION/ACCELA.AppImage" ] && [ ! -L "$INSTALL_DESTINATION/ACCELA.AppImage" ]; then
        echo -e "${YELLOW}[INFO] Existing ACCELA.AppImage found (will back up after verification).${NC}"
    fi

    get_latest_github_version
    echo -e "${YELLOW}[INFO] Downloading ASSella.AppImage ($LATEST_VER)...${NC}"

    TMP_DIR="$(mktemp -d -t assella-install-XXXXXX)" || {
        echo -e "${RED}[ERROR] Could not create temporary download directory.${NC}"
        pause_if_interactive
        return 1
    }
    local DL_TMP="$TMP_DIR/ASSella.AppImage"

    # --- Delta (zsync) fast path ---------------------------------------------
    local used_zsync=false
    if [ "${ASSELLA_NO_ZSYNC:-0}" != "1" ] && command -v zsync &>/dev/null && [ -f "$INSTALL_DESTINATION/ASSella.AppImage" ]; then
        echo -e "${CYAN}[INFO] zsync delta update available — syncing changed blocks only.${NC}"
        local zsync_url="${LATEST_URL}.zsync"
        if curl -fsL --max-time 30 -o "${DL_TMP}.zsync" "$zsync_url" 2>/dev/null; then
            local zsync_log="${DL_TMP}.zsync.log"
            if zsync -i "$INSTALL_DESTINATION/ASSella.AppImage" -o "$DL_TMP" "$zsync_url" >"$zsync_log" 2>&1; then
                [ -s "$zsync_log" ] && sed 's/^/    /' "$zsync_log"
                used_zsync=true
                echo -e "${GREEN}[INFO] zsync delta sync complete.${NC}"
            else
                [ -s "$zsync_log" ] && sed 's/^/    /' "$zsync_log"
                echo -e "${YELLOW}[WARN] zsync delta sync failed; falling back to full download.${NC}"
                rm -f "$DL_TMP"
            fi
            rm -f "$zsync_log"
        else
            echo -e "${YELLOW}[INFO] No .zsync published for this release; using full download.${NC}"
        fi
        rm -f "${DL_TMP}.zsync"
    elif [ "${ASSELLA_NO_ZSYNC:-0}" != "1" ] && ! command -v zsync &>/dev/null; then
        echo -e "${YELLOW}[INFO] zsync not installed — using full download.${NC}"
    fi

    if [ "$used_zsync" = false ]; then
        if ! curl -fL --progress-bar -o "$DL_TMP" "$LATEST_URL"; then
            echo -e "${RED}[ERROR] Download failed! Please check your connection to GitHub.${NC}"
            rm -f "$DL_TMP"
            pause_if_interactive
            return 1
        fi
    fi

    # --- Integrity check -----------------------------------------------------
    local sha_state="missing"
    local expected_sha="" actual_sha=""

    if curl -fsL --max-time 20 -o "$DL_TMP.sha256" "${LATEST_URL}.sha256" 2>/dev/null || \
       curl -fsL --max-time 20 -o "$DL_TMP.sha256" "${LATEST_URL}.zsync.sha256" 2>/dev/null; then
        expected_sha=$(grep -oiE '[a-f0-9]{64}' "$DL_TMP.sha256" | head -n1)
        if [ -z "$expected_sha" ]; then
            sha_state="malformed"
        else
            if command -v sha256sum &>/dev/null; then
                actual_sha=$(sha256sum "$DL_TMP" | awk '{print $1}')
            elif command -v shasum &>/dev/null; then
                actual_sha=$(shasum -a 256 "$DL_TMP" | awk '{print $1}')
            fi
            if [ -z "$actual_sha" ]; then
                sha_state="notool"
            elif [ "$(printf '%s' "$expected_sha" | tr 'A-F' 'a-f')" = "$(printf '%s' "$actual_sha" | tr 'A-F' 'a-f')" ]; then
                sha_state="ok"
            else
                sha_state="mismatch"
            fi
        fi
    fi
    rm -f "$DL_TMP.sha256"

    case "$sha_state" in
        ok)
            echo -e "${GREEN}[OK] SHA-256 verified: $actual_sha${NC}"
            ;;
        mismatch)
            echo -e "${RED}${BOLD}[ERROR] CHECKSUM MISMATCH — download corrupted or tampered.${NC}"
            echo -e "${RED}  expected: $expected_sha${NC}"
            echo -e "${RED}  actual:   $actual_sha${NC}"
            local proceed="n"
            if [ "${SKIP_CHECKSUM:-false}" = true ] || [ "${ASSELLA_SKIP_CHECKSUM:-0}" = "1" ]; then
                echo -e "${YELLOW}[WARN] Checksum mismatch bypassed via flag/environment.${NC}"
                proceed="y"
            elif [ -t 0 ] || [ -r /dev/tty ]; then
                proceed=$(prompt_user "Do you want to ignore the checksum mismatch and proceed anyway? [y/N]: " "n")
            fi

            if [[ "$proceed" =~ ^[yY] ]]; then
                echo -e "${YELLOW}[WARN] Proceeding with installation despite checksum mismatch...${NC}"
            else
                rm -f "$DL_TMP"
                echo -e "${RED}Refusing to install. Existing installation left untouched.${NC}"
                pause_if_interactive
                return 1
            fi
            ;;
        malformed|notool)
            echo -e "${RED}[WARN] Checksum file unusable ($sha_state); cannot verify integrity.${NC}"
            ;;
        missing)
            echo -e "${YELLOW}[WARN] No published .sha256 for this release; integrity NOT verified.${NC}"
            if [ "${ASSELLA_REQUIRE_SHA256:-0}" = "1" ]; then
                echo -e "${RED}[ERROR] ASSELLA_REQUIRE_SHA256=1 set, refusing unverified download.${NC}"
                rm -f "$DL_TMP"
                pause_if_interactive
                return 1
            fi
            ;;
    esac

    # Promote verified download into place
    if ! mv -f "$DL_TMP" "$INSTALL_DESTINATION/ASSella.AppImage"; then
        echo -e "${RED}[ERROR] Failed to move verified binary into place.${NC}"
        rm -f "$DL_TMP"
        pause_if_interactive
        return 1
    fi

    chmod +x "$INSTALL_DESTINATION/ASSella.AppImage"

    # Backup previous non-symlink ACCELA.AppImage
    if [ -f "$INSTALL_DESTINATION/ACCELA.AppImage" ] && [ ! -L "$INSTALL_DESTINATION/ACCELA.AppImage" ]; then
        echo -e "${YELLOW}[INFO] Backing up previous ACCELA.AppImage to ACCELA.AppImage.bak...${NC}"
        mv -f "$INSTALL_DESTINATION/ACCELA.AppImage" "$INSTALL_DESTINATION/ACCELA.AppImage.bak"
    fi

    # Save local version file
    echo "$LATEST_VER" > "$VERSION_FILE"

    # Compatibility symlink ACCELA.AppImage -> ASSella.AppImage
    ln -sf ASSella.AppImage "$INSTALL_DESTINATION/ACCELA.AppImage"
    echo -e "${GREEN}[INFO] Created compatibility symlink ACCELA.AppImage -> ASSella.AppImage.${NC}"

    # Handle NixOS Launcher Script
    local EXEC_COMMAND=""
    if [ "$IS_NIXOS" = true ]; then
        echo -e "${YELLOW}[INFO] Configuring NixOS compatibility launcher...${NC}"
        cat >"$NIXOS_LAUNCHER" <<'EOL'
#!/usr/bin/env bash
if command -v steam-run &>/dev/null; then
    exec steam-run "$HOME/.local/share/ACCELA/ASSella.AppImage" "$@"
elif command -v appimage-run &>/dev/null; then
    exec appimage-run "$HOME/.local/share/ACCELA/ASSella.AppImage" "$@"
else
    echo "NixOS detected! Please install steam-run or appimage-run to launch ASSella:"
    echo "  nix-shell -p steam-run --run 'steam-run ~/.local/share/ACCELA/ASSella.AppImage'"
    read -p "Press Enter to exit..."
fi
EOL
        chmod +x "$NIXOS_LAUNCHER"
        EXEC_COMMAND="$NIXOS_LAUNCHER %u"
    else
        EXEC_COMMAND="$INSTALL_DESTINATION/ACCELA.AppImage %u"
    fi

    # Desktop Shortcut Creation
    echo -e "${YELLOW}[INFO] Configuring desktop shortcut ($PRIMARY_DESKTOP_ENTRY)...${NC}"
    mkdir -p "$DESKTOP_DIR"
    cat >"$PRIMARY_DESKTOP_ENTRY" <<EOL
[Desktop Entry]
Version=2.0
Name=ASSella
Comment=god is in the ass
Exec=$EXEC_COMMAND
Icon=assella
Terminal=false
Type=Application
Categories=Utility;Game;
MimeType=x-scheme-handler/accela;
EOL

    # If legacy accela.desktop existed, symlink it for backward compatibility
    if [ -f "$LEGACY_DESKTOP_ENTRY" ] || [ -L "$LEGACY_DESKTOP_ENTRY" ]; then
        ln -sf assella.desktop "$LEGACY_DESKTOP_ENTRY"
    fi

    # Application Icon Download
    echo -e "${YELLOW}[INFO] Applying application icon...${NC}"
    mkdir -p "$ICON_DIR"
    curl -sL -o "$PRIMARY_ICON_PATH" "${ASSELLA_RAW_BASE}/${ASSELLA_INSTALL_BRANCH}/src/res/logo/icon.png" || true
    if [ -f "$LEGACY_ICON_PATH" ] || [ -L "$LEGACY_ICON_PATH" ]; then
        ln -sf assella.png "$LEGACY_ICON_PATH"
    fi

    # Update system desktop database
    if command -v update-desktop-database &>/dev/null; then
        update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    fi
    if [ -z "${XDG_CURRENT_DESKTOP:-}" ] || [[ "$XDG_CURRENT_DESKTOP" != *"KDE"* ]]; then
        command -v gtk-update-icon-cache &>/dev/null && gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
    fi

    # Check FUSE
    check_fuse_status
    if [ "$FUSE_INSTALLED" = false ] && [ "$IS_NIXOS" = false ]; then
        local family
        family=$(detect_distro_family)
        local cmd="${PKG_FUSE_CMD[$family]:-}"
        echo -e "\n${RED}${BOLD}[WARN] FUSE (libfuse.so.2) is not installed on your system!${NC}"
        if [ -n "$cmd" ]; then
            echo -e "${YELLOW}Please run: $cmd${NC}"
        fi
    fi

    echo -e "\n${GREEN}${BOLD}=========================================${NC}"
    echo -e "${GREEN}${BOLD}[OK] ASSella has been installed & patched!${NC}"
    echo -e "${GREEN}${BOLD}=========================================${NC}\n"

    get_local_version
}

# ------------------------------------------------------------------------------
#  6. Restore Original ACCELA Backup
# ------------------------------------------------------------------------------
do_restore_accela() {
    echo -e "\n${YELLOW}[INFO] Restoring original ACCELA backup...${NC}"

    if [ -f "$INSTALL_DESTINATION/ACCELA.AppImage.bak" ]; then
        rm -f "$INSTALL_DESTINATION/ACCELA.AppImage"
        mv "$INSTALL_DESTINATION/ACCELA.AppImage.bak" "$INSTALL_DESTINATION/ACCELA.AppImage"
        chmod +x "$INSTALL_DESTINATION/ACCELA.AppImage"
        echo -e "${GREEN}[INFO] Restored ACCELA.AppImage from backup.${NC}"
    else
        echo -e "${YELLOW}[WARN] No ACCELA.AppImage.bak found to restore.${NC}"
    fi

    if [ -f "$PRIMARY_DESKTOP_ENTRY" ]; then
        sed -i 's/^Name=ASSella$/Name=ACCELA/' "$PRIMARY_DESKTOP_ENTRY"
        echo -e "${GREEN}[INFO] Restored desktop entry name to ACCELA in $PRIMARY_DESKTOP_ENTRY.${NC}"
    fi

    echo -e "\n${GREEN}[OK] ACCELA restoration complete!${NC}"
    pause_if_interactive
}

# ------------------------------------------------------------------------------
#  7. Clean Uninstall ASSella
# ------------------------------------------------------------------------------
do_uninstall() {
    echo -e "\n${RED}${BOLD}=== ASSella Clean Uninstaller ===${NC}\n"
    if [ "${INTERACTIVE:-false}" = true ]; then
        read -p "Are you sure you want to uninstall ASSella? [y/N]: " confirm
        if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
            echo "Uninstallation cancelled."
            return
        fi
    fi

    echo -e "${YELLOW}[INFO] Removing binaries, symlinks, and desktop entries...${NC}"
    rm -f "$INSTALL_DESTINATION/ASSella.AppImage"
    rm -f "$INSTALL_DESTINATION/ACCELA.AppImage"
    rm -f "$INSTALL_DESTINATION/version"
    rm -f "$NIXOS_LAUNCHER"
    rm -f "$PRIMARY_DESKTOP_ENTRY"
    rm -f "$LEGACY_DESKTOP_ENTRY"
    rm -f "$PRIMARY_ICON_PATH"
    rm -f "$LEGACY_ICON_PATH"

    if [ -f "$INSTALL_DESTINATION/ACCELA.AppImage.bak" ]; then
        mv "$INSTALL_DESTINATION/ACCELA.AppImage.bak" "$INSTALL_DESTINATION/ACCELA.AppImage"
        echo -e "${GREEN}[INFO] Restored original ACCELA.AppImage backup.${NC}"
    fi

    if command -v update-desktop-database &>/dev/null; then
        update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    fi

    echo -e "\n${GREEN}[OK] ASSella has been uninstalled.${NC}"
    pause_if_interactive
}

# ------------------------------------------------------------------------------
#  8. Pre-Flight Diagnostics
# ------------------------------------------------------------------------------
run_diagnostics() {
    show_header
    echo -e "\n${YELLOW}${BOLD}=== ASSella Pre-Flight Diagnostics ===${NC}\n"

    echo -n "  1. Python 3: "
    if command -v python3 &>/dev/null; then
        echo -e "${GREEN}OK ($(python3 --version | cut -d' ' -f2))${NC}"
    else
        echo -e "${RED}MISSING${NC}"
    fi

    echo -n "  2. Curl utility: "
    if command -v curl &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}MISSING${NC}"
    fi

    echo -n "  3. FUSE (libfuse.so.2): "
    if [ "$FUSE_INSTALLED" = true ] || [ "$IS_NIXOS" = true ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}MISSING (AppImage won't open without fuse2)${NC}"
    fi

    echo -n "  4. Steam Client: "
    if [ "$STEAM_TYPE" = "flatpak" ]; then
        echo -e "${GREEN}FLATPAK ($STEAM_DIR)${NC}"
    elif [ "$STEAM_TYPE" = "snap" ]; then
        echo -e "${GREEN}SNAP ($STEAM_DIR)${NC}"
    elif [ "$STEAM_TYPE" = "native" ] && [ -d "$STEAM_DIR" ]; then
        echo -e "${GREEN}NATIVE ($STEAM_DIR)${NC}"
    else
        echo -e "${YELLOW}NOT DETECTED${NC}"
    fi

    echo -n "  5. Headcrab (SLSsteam): "
    if [ "$HEADCRAB_INSTALLED" = true ]; then
        echo -e "${GREEN}INSTALLED ($SLS_CONFIG_DIR)${NC}"
    else
        echo -e "${YELLOW}NOT INSTALLED${NC}"
    fi

    echo -n "  6. Desktop Shortcut: "
    if [ -f "$PRIMARY_DESKTOP_ENTRY" ]; then
        echo -e "${GREEN}OK ($PRIMARY_DESKTOP_ENTRY)${NC}"
    elif [ -f "$LEGACY_DESKTOP_ENTRY" ]; then
        echo -e "${GREEN}OK (legacy: $LEGACY_DESKTOP_ENTRY)${NC}"
    else
        echo -e "${YELLOW}NOT CREATED YET${NC}"
    fi

    if [[ "${IS_ARM64:-false}" = true ]]; then
        echo -n "  7. DroidDeck profile: "
        if [[ "${IS_DROIDDECK:-false}" = true ]]; then
            echo -e "${GREEN}YES${NC}"
        else
            echo -e "${YELLOW}NO (generic ARM64)${NC}"
        fi
        echo -n "  8. ARM64 launcher: "
        if [ -x "$RUN_ASSella_LAUNCHER" ]; then
            echo -e "${GREEN}OK ($RUN_ASSella_LAUNCHER)${NC}"
        else
            echo -e "${YELLOW}NOT INSTALLED${NC}"
        fi
        echo -n "  9. steam-sls wrapper: "
        if [ -x "$STEAM_SLS_WRAPPER" ]; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${YELLOW}MISSING${NC}"
        fi
        if command -v file &>/dev/null && [ -f "$HOME/.local/share/SLSsteam/SLSsteam.so" ]; then
            echo -e "  10. SLSsteam.so: $(file -b "$HOME/.local/share/SLSsteam/SLSsteam.so" 2>/dev/null)"
        fi
    fi

    echo -e "\n${CYAN}${BOLD}-------------------------------------------------------------------${NC}\n"
    read -p "Press Enter to return to main menu..." dummy
}

# ------------------------------------------------------------------------------
#  9. Interactive Setup Wizard & Menu Loop
# ------------------------------------------------------------------------------
interactive_flow() {
    INTERACTIVE=true
    show_header
    echo -e "${BOLD}${CYAN}Welcome to the ASSella Setup Wizard${NC}\n"

    if [[ "${IS_ARM64:-false}" = true ]]; then
        echo -e "${BOLD}--- [Step 1/2] SLSsteam (DroidDeck-safe) ---${NC}"
        check_headcrab_status
        local default_sls="n"
        local sls_prompt=""
        if [ "$HEADCRAB_INSTALLED" = true ] || [ -f "$HOME/.local/share/SLSsteam/SLSsteam.so" ]; then
            echo -e "  Status: ${GREEN}SLS files present${NC}"
            sls_prompt="Reinstall SLSsteam (skips Headcrab updater)? [y/N]: "
            default_sls="n"
        else
            echo -e "  Status: ${YELLOW}Not Detected${NC}"
            sls_prompt="Install SLSsteam now (no Headcrab Steam updater)? [Y/n]: "
            default_sls="y"
        fi
        local run_sls=""
        run_sls=$(prompt_user "$sls_prompt" "$default_sls")
        if [[ "$run_sls" =~ ^[yY] ]]; then
            install_slssteam_minimal
        else
            echo -e "${YELLOW}[INFO] Skipping SLSsteam installation.${NC}"
        fi
        echo ""
        echo -e "${BOLD}--- [Step 2/2] ASSella Application (ARM64 source) ---${NC}"
        get_local_version
        echo -e "  Currently Installed: ${YELLOW}$LOCAL_VER${NC}"
        local install_prompt="Do you want to install / update ASSella? [Y/n]: "
        local run_install=""
        run_install=$(prompt_user "$install_prompt" "y")
        if [[ "$run_install" =~ ^[yY] ]]; then
            SKIP_SLS=true
            do_install_arm64_source
        else
            echo -e "${YELLOW}[INFO] Skipping ASSella installation.${NC}"
        fi
    else
        # Step 1: Headcrab (SLSsteam)
        echo -e "${BOLD}--- [Step 1/2] Headcrab (SLSsteam) Setup ---${NC}"
        check_headcrab_status
        local default_hc="n"
        local hc_prompt=""
        if [ "$HEADCRAB_INSTALLED" = true ]; then
            echo -e "  Status: ${GREEN}Installed ($SLS_CONFIG_DIR)${NC}"
            hc_prompt="Do you want to re-run / update Headcrab (SLSsteam)? [y/N]: "
            default_hc="n"
        else
            echo -e "  Status: ${YELLOW}Not Detected${NC}"
            echo -e "  ${CYAN}Headcrab is required for SLSsteam integration and game launching.${NC}"
            hc_prompt="Do you want to install Headcrab (SLSsteam) now? [Y/n]: "
            default_hc="y"
        fi

        local run_hc=""
        run_hc=$(prompt_user "$hc_prompt" "$default_hc")
        if [[ "$run_hc" =~ ^[yY] ]]; then
            run_headcrab_installer
        else
            echo -e "${YELLOW}[INFO] Skipping Headcrab installation.${NC}"
        fi

        check_and_warn_fuse

        echo ""
        echo -e "${BOLD}--- [Step 2/2] ASSella Application Setup ---${NC}"
        get_local_version
        get_latest_github_version
        echo -e "  Currently Installed: ${YELLOW}$LOCAL_VER${NC}"
        echo -e "  Latest Available:    ${GREEN}$LATEST_VER${NC} (${CYAN}Channel: $TARGET_CHANNEL${NC})"

        local install_prompt="Do you want to install / update ASSella? [Y/n]: "
        local run_install=""
        run_install=$(prompt_user "$install_prompt" "y")
        if [[ "$run_install" =~ ^[yY] ]]; then
            do_install
        else
            echo -e "${YELLOW}[INFO] Skipping ASSella installation.${NC}"
        fi
    fi

    echo -e "\n${GREEN}${BOLD}Setup completed!${NC}\n"
}

interactive_menu() {
    INTERACTIVE=true
    detect_distro
    check_fuse_status
    check_headcrab_status
    get_local_version
    get_latest_github_version

    while true; do
        show_header
        echo -e "  ${BOLD}[1]${NC} Install / Update ASSella"
        echo -e "  ${BOLD}[2]${NC} Run Headcrab (SLSsteam) Installer"
        echo -e "  ${BOLD}[3]${NC} Check for Updates & View Release Info"
        echo -e "  ${BOLD}[4]${NC} View Distro Requirements Guide"
        echo -e "  ${BOLD}[5]${NC} Restore Original ACCELA (Revert Backup)"
        echo -e "  ${BOLD}[6]${NC} Uninstall ASSella (Clean Files & Shortcuts)"
        echo -e "  ${BOLD}[7]${NC} Run Pre-Flight Diagnostics"
        echo -e "  ${BOLD}[8]${NC} Exit"
        echo -e "${CYAN}${BOLD}===================================================================${NC}"
        read -p "Select option [1-8]: " choice

        case "$choice" in
            1)
                do_install
                read -p "Press Enter to continue..." dummy
                ;;
            2)
                run_headcrab_installer
                read -p "Press Enter to continue..." dummy
                ;;
            3)
                show_header
                echo -e "\n${YELLOW}Installed:${NC} $LOCAL_VER  -->  ${GREEN}Latest Online ($TARGET_CHANNEL):${NC} $LATEST_VER"
                if [ "$LOCAL_VER" != "$LATEST_VER" ]; then
                    echo -e "${GREEN}${BOLD}An update is available! Select Option 1 to update.${NC}\n"
                else
                    echo -e "${GREEN}You are already on the latest version!${NC}\n"
                fi
                read -p "Press Enter to continue..." dummy
                ;;
            4)
                show_distro_guide
                ;;
            5)
                do_restore_accela
                ;;
            6)
                do_uninstall
                ;;
            7)
                run_diagnostics
                ;;
            8|q|Q)
                echo "Exiting..."
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option!${NC}"
                sleep 1
                ;;
        esac
    done
}

# Apply flags that must be set before detect_distro / prereq checks.
preparse_installer_flags() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --droiddeck)
                IS_DROIDDECK=true
                IS_ARM64=true
                NO_SUDO=true
                ASSELLA_FORCE_NO_GIT=1
                ;;
            --install|-i|--yes|-y|--sls-only|--skip-sls|--no-pip)
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
#  10. CLI Execution Entry Point
# ------------------------------------------------------------------------------
main() {
    preparse_installer_flags "$@"

    detect_distro
    check_fuse_status
    check_headcrab_status
    get_local_version

    local non_interactive=false
    local action="interactive"
    local run_hc=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --droiddeck)
                IS_DROIDDECK=true
                IS_ARM64=true
                NO_SUDO=true
                ASSELLA_FORCE_NO_GIT=1
                ;;
            --skip-sls)
                SKIP_SLS=true
                ;;
            --sls-only)
                SLS_ONLY=true
                action="sls-only"
                ;;
            --no-pip)
                ARM64_NO_PIP=true
                ;;
            --canary)
                TARGET_CHANNEL="canary"
                ;;
            --beta)
                TARGET_CHANNEL="beta"
                ;;
            --stable)
                TARGET_CHANNEL="stable"
                ;;
            --headcrab|--sls)
                if [[ "${IS_ARM64:-false}" = true ]]; then
                    action="sls-only"
                else
                    action="headcrab"
                fi
                ;;
            --with-headcrab)
                run_hc=true
                action="install"
                ;;
            --install|-i)
                action="install"
                ;;
            --yes|-y)
                non_interactive=true
                ;;
            --menu|-m)
                action="menu"
                ;;
            --update|-u)
                action="update"
                ;;
            --restore)
                action="restore"
                ;;
            --uninstall)
                action="uninstall"
                ;;
            --skip-checksum|--ignore-checksum|--no-verify)
                SKIP_CHECKSUM=true
                ;;
            --help|-h)
                action="help"
                ;;
            *)
                echo "Unknown option: $1"
                echo "Use ./install.sh --help for usage instructions."
                exit 1
                ;;
        esac
        shift
    done

    detect_channel

    case "$action" in
        interactive)
            if [ "$non_interactive" = true ]; then
                if [[ "${IS_ARM64:-false}" = true ]]; then
                    do_install_arm64_source
                else
                    do_install
                fi
            elif [ -t 0 ] || [ -r /dev/tty ]; then
                interactive_flow
            else
                if [[ "${IS_ARM64:-false}" = true ]]; then
                    do_install_arm64_source
                else
                    do_install
                fi
            fi
            ;;
        sls-only)
            install_slssteam_minimal
            ;;
        headcrab)
            if [[ "${IS_ARM64:-false}" = true ]]; then
                install_slssteam_minimal
            else
                run_headcrab_installer
            fi
            ;;
        install)
            if [[ "${IS_ARM64:-false}" = true ]]; then
                if [ "$run_hc" = true ] && [[ "${SKIP_SLS:-false}" = false ]]; then
                    install_slssteam_minimal || true
                fi
                do_install_arm64_source
            else
                if [ "$run_hc" = true ]; then
                    run_headcrab_installer
                fi
                do_install
            fi
            ;;
        menu)
            interactive_menu
            ;;
        update)
            if [[ "${IS_ARM64:-false}" = true ]]; then
                do_install_arm64_source
            else
                get_latest_github_version
                if [ "$LOCAL_VER" != "$LATEST_VER" ]; then
                    do_install
                else
                    echo -e "${GREEN}ASSella is already up to date ($LOCAL_VER) on channel ($TARGET_CHANNEL).${NC}"
                fi
            fi
            ;;
        restore)
            do_restore_accela
            ;;
        uninstall)
            do_uninstall
            ;;
        help)
            echo "ASSella Installer & Management Suite"
            echo "Usage: ./install.sh [OPTIONS]"
            echo ""
            echo "Channel Options:"
            echo "  --beta           Target Beta channel (v2.7.0beta)"
            echo "  --canary         Target Canary channel (v3.0.x)"
            echo "  --stable         Target Stable channel"
            echo ""
            echo "DroidDeck / ARM64 Options:"
            echo "  --droiddeck      Force DroidDeck profile (ARM64 source install)"
            echo "  --sls-only       Install SLSsteam without Headcrab Steam updater"
            echo "  --skip-sls       Skip SLS install during ARM64 setup"
            echo "  --no-pip         Skip pip install on ARM64 update (refresh source only)"
            echo ""
            echo "Execution Options:"
            echo "  (no args)        Interactive wizard (prompts for Headcrab & ASSella)"
            echo "  --install, -i    Install or update ASSella directly"
            echo "  --with-headcrab  Install Headcrab (SLSsteam) followed by ASSella"
            echo "  --headcrab       Run Headcrab (SLSsteam) installer only"
            echo "  --yes, -y        Non-interactive / assume yes"
            echo "  --menu, -m       Launch full maintenance menu"
            echo "  --update, -u     Check and update if a new release exists"
            echo "  --restore        Restore original ACCELA backup"
            echo "  --uninstall      Uninstall ASSella"
            echo "  --skip-checksum  Ignore checksum mismatch and proceed with installation"
            echo "  --help, -h       Display this help message"
            ;;
    esac
}

main "$@"
