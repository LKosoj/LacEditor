#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
cd "${SCRIPT_DIR:h}"
mkdir -p .build
maintenance_binary='.build/file-association-maintenance'
if [[ ! -x "$maintenance_binary" || "$SCRIPT_DIR/FileAssociationMaintenance.swift" -nt "$maintenance_binary" ]]; then
    swiftc -O -parse-as-library "$SCRIPT_DIR/FileAssociationMaintenance.swift" -o "$maintenance_binary"
fi
# Default is a read-only inventory. Mutations require an explicit argument.
"$maintenance_binary" "$@"
