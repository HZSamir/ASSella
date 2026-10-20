#!/usr/bin/env bash
# ==============================================================================
# install-armada.sh — Delegates to unified install.sh (ARM64 / DroidDeck)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/../install.sh"

if [ ! -f "$INSTALLER" ]; then
    echo "Error: install.sh not found at $INSTALLER" >&2
    exit 1
fi

exec bash "$INSTALLER" --droiddeck "$@"
