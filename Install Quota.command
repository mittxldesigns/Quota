#!/bin/bash
# ──────────────────────────────────────────────
#  Quota — One-Click Installer
#  Installs, removes Gatekeeper block, launches.
# ──────────────────────────────────────────────

clear
cat << 'BANNER'

  ┌──────────────────────────────────────┐
  │                                      │
  │       ⚡ Installing Quota...         │
  │                                      │
  └──────────────────────────────────────┘

BANNER

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="${SCRIPT_DIR}/Quota.app"
DEST="/Applications/Quota.app"

if [ ! -d "$APP_PATH" ]; then
    echo "  ✗ Error: Quota.app not found."
    echo "    Make sure this file is inside the Quota disk image."
    echo ""
    read -p "  Press Enter to close..."
    exit 1
fi

# Kill existing instance if running
pkill -x "Quota" 2>/dev/null && sleep 0.3

# Remove old version
[ -d "$DEST" ] && rm -rf "$DEST"

# Copy to Applications
echo "  [1/3] Moving to Applications..."
cp -R "$APP_PATH" "$DEST"

# Remove quarantine (Gatekeeper bypass)
echo "  [2/3] Removing Gatekeeper block..."
xattr -cr "$DEST" 2>/dev/null

# Launch
echo "  [3/3] Launching..."
open "$DEST"

cat << 'DONE'

  ✓ Quota installed successfully!

  Look for it in your menu bar (top-right).
  Click the icon → Sign in with Claude → Done.

  You can close this window and eject the disk image.

DONE
sleep 3
