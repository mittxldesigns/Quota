#!/bin/bash
# ──────────────────────────────────────────────
#  Quota — Install Helper
#  Moves Quota to Applications & bypasses Gatekeeper
# ──────────────────────────────────────────────

clear
echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║       Quota — Install Helper         ║"
echo "  ╚══════════════════════════════════════╝"
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="${SCRIPT_DIR}/Quota.app"
DEST="/Applications/Quota.app"

if [ ! -d "$APP_PATH" ]; then
    echo "  ✗ Quota.app not found next to this script."
    echo "    Make sure this file is in the same folder as Quota.app"
    echo ""
    read -p "  Press Enter to close..."
    exit 1
fi

echo "  → Moving Quota to Applications..."
if [ -d "$DEST" ]; then
    rm -rf "$DEST"
fi
cp -R "$APP_PATH" "$DEST"

echo "  → Removing quarantine flag..."
xattr -cr "$DEST" 2>/dev/null

echo "  → Launching Quota..."
open "$DEST"

echo ""
echo "  ✓ Done! Quota is now installed and running."
echo "    You'll see it in your menu bar."
echo ""
echo "  You can eject this disk image now."
echo ""
read -p "  Press Enter to close..."
