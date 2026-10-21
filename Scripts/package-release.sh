#!/bin/zsh
set -euo pipefail

# Share candidate packaging, identity checks and temporary App cleanup.
SCRIPT_DIR="${0:A:h}"
exec zsh "$SCRIPT_DIR/package-candidate.sh" --release
