#!/usr/bin/env bash
#
# Parses every app source file without the iOS SDK.
#
# The app target can only be *type*-checked by CI, because there is no macOS here,
# but a plain parse catches syntax slips (unbalanced braces, broken string
# interpolation) in about a second. Run it before pushing:
#
#   bash tools/check-app-syntax.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

export LD_LIBRARY_PATH="$HOME/.local/swift-libs:${LD_LIBRARY_PATH:-}"
SWIFTC="${SWIFT_HOME:-$HOME/swift}/usr/bin/swiftc"
[[ -x "$SWIFTC" ]] || { echo "swiftc not found; run tools/setup-local-swift.sh" >&2; exit 1; }

shopt -s globstar nullglob
files=(App/**/*.swift AppTests/**/*.swift)
[[ ${#files[@]} -gt 0 ]] || { echo "no sources found" >&2; exit 1; }

"$SWIFTC" -parse "${files[@]}" 2>&1 | grep -v 'warning: libc not found' || true
echo "parsed ${#files[@]} files"
