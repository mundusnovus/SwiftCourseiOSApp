#!/bin/bash
# Copies Smartz (Smartz*.swift in Asteria Search: Smartz by Asteria, the AI every Asteria app shares, with its voice,
# its brain and the Asteria Account) into
# ZeroToHero/Intelligence. `--check` fails if the copy has drifted from the library.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="../../Asteria Technology/AsteriaSearch/Sources/AsteriaSearch"
DEST="ZeroToHero/Intelligence"
[ -d "$SRC" ] || { echo "sync-intelligence: $SRC not found (Asteria Technology/AsteriaSearch sits next to MundusNovus)"; exit 1; }
copy() { for f in "$SRC"/Smartz*.swift; do cp "$f" "$1/$(basename "$f")"; done; }
if [ "${1:-}" = "--check" ]; then
  tmp=$(mktemp -d); copy "$tmp"
  diff -r "$tmp" "$DEST" >/dev/null && echo "Smartz copy matches" || { echo "Smartz copy differs: run tools/sync-intelligence.sh"; rm -rf "$tmp"; exit 1; }
  rm -rf "$tmp"; exit 0
fi
mkdir -p "$DEST" && find "$DEST" \( -name 'AsteriaIntelligence*.swift' -o -name 'Smartz*.swift' \) -delete && copy "$DEST"
echo "synced $(ls "$DEST" | wc -l | tr -d ' ') files from Asteria Search @ $(git -C "../../Asteria Technology/AsteriaSearch" rev-parse --short HEAD)"
