#!/usr/bin/env bash
# mcpx installer
# curl -fsSL https://raw.githubusercontent.com/nunoquispe/mcpx/main/install.sh | bash

set -euo pipefail

REPO="nunoquispe/mcpx"
INSTALL_DIR="${MCPX_INSTALL_DIR:-$HOME/bin}"
BINARY="mcpx"

R='\033[0;31m' G='\033[0;32m' B='\033[1m' D='\033[0;90m' N='\033[0m'

info() { echo -e "${G}+${N} $1"; }
die()  { echo -e "${R}error:${N} $1" >&2; exit 1; }

# Check dependencies
for cmd in jq curl; do
  command -v "$cmd" &>/dev/null || die "$cmd is required — install it first"
done

# Create install dir
mkdir -p "$INSTALL_DIR"

# Download
echo -e "${B}installing mcpx${N}"
curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/mcpx" -o "${INSTALL_DIR}/${BINARY}"
chmod +x "${INSTALL_DIR}/${BINARY}"

# Check PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
  echo ""
  echo -e "${D}add to your shell profile:${N}"
  echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
fi

echo ""
info "installed to ${INSTALL_DIR}/${BINARY}"
echo -e "${D}next: mcpx init${N}"
