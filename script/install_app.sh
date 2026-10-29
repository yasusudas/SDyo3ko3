#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$PROJECT_ROOT/script/build_app.sh"
DESTINATION="/Applications/yo3komi.app"
if [[ -e "$DESTINATION" ]]; then
  BACKUP="/Applications/yo3komi.previous.$(date +%Y%m%d%H%M%S).app"
  mv "$DESTINATION" "$BACKUP"
fi
/usr/bin/ditto "$PROJECT_ROOT/dist/yo3komi.app" "$DESTINATION"
/usr/bin/codesign --verify --strict "$DESTINATION"
printf 'Installed: %s\n' "$DESTINATION"
