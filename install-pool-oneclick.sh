#!/bin/bash
# LongCatLongClawsContrib: One-click installer
# Installs the /pool feature into any Hermes agent
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/B-A-M-N/hermes-agent/feat/LongCatLongClawsContrib/install-pool.sh | bash
#
# Or manually:
#   git clone https://github.com/B-A-M-N/hermes-agent.git /tmp/hermes-pool
#   cd /tmp/hermes-pool && git checkout feat/LongCatLongClawsContrib
#   bash install-pool.sh [HERMES_AGENT_DIR]

set -euo pipefail

REPO_URL="https://github.com/B-A-M-N/hermes-agent.git"
BRANCH="feat/LongCatLongClawsContrib"
POOL_SRC="${1:-/tmp/hermes-pool}"
HERMES_AGENT="${2:-${HERMES_AGENT_DIR:-/home/bamn/hermes-agent}}"

echo "=== LongCatLongClawsContrib: Pool Feature Installer ==="
echo ""

# Step 1: Clone if needed
if [ ! -d "$POOL_SRC" ]; then
    echo "[1/2] Cloning pool feature branch..."
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$POOL_SRC" 2>&1 | tail -3
    echo "  ✓ Cloned to $POOL_SRC"
else
    echo "[1/2] Using existing pool source: $POOL_SRC"
fi

# Step 2: Run installer
echo ""
echo "[2/2] Running installer..."
bash "$POOL_SRC/install-pool.sh" "$HERMES_AGENT" "$POOL_SRC"

echo ""
echo "=== Done ==="
echo ""
echo "Quick start:"
echo "  hermes --tui"
echo "  /pool list"
echo "  /pool add vm https://vm.tail.ts.net"
echo "  /pool test vm"
echo "  /pool switch vm"
