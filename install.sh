#!/bin/bash
# Quota — One-command installer
# Usage: curl -fsSL https://raw.githubusercontent.com/mittxldesigns/Quota/main/install.sh | bash

set -e

echo ""
echo "  ⚡ Installing Quota..."
echo ""

# Kill existing instance
pkill -x Quota 2>/dev/null && sleep 0.3 || true

# Download latest PKG
echo "  [1/3] Downloading..."
curl -sL https://github.com/mittxldesigns/Quota/releases/latest/download/Quota-1.0.0.pkg -o /tmp/Quota.pkg

# Install (needs password)
echo "  [2/3] Installing (you may need to enter your password)..."
sudo installer -pkg /tmp/Quota.pkg -target / >/dev/null 2>&1
sudo xattr -cr /Applications/Quota.app 2>/dev/null

# Cleanup and launch
rm -f /tmp/Quota.pkg
echo "  [3/3] Launching..."
open /Applications/Quota.app

echo ""
echo "  ✓ Quota installed! Look for it in your menu bar."
echo ""
