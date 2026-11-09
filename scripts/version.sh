#!/bin/bash
# Gibt die aktuelle Version aus: <VERSION-Datei>.<Commits seit der letzten Änderung der VERSION-Datei>
# Jeder Push auf main erhöht damit automatisch die letzte Stelle (1.0.0, 1.0.1, …).
# Für einen Sprung (z. B. 1.1) einfach die VERSION-Datei ändern – die Zählung beginnt dann wieder bei .0
set -euo pipefail
cd "$(dirname "$0")/.."
BASE="$(tr -d '[:space:]' < VERSION)"
COMMIT="$(git log -1 --format=%H -- VERSION 2>/dev/null || true)"
if [ -n "$COMMIT" ]; then
  N="$(git rev-list --count "$COMMIT"..HEAD)"
else
  N=0
fi
echo "$BASE.$N"
