#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
/usr/bin/pkill -x yo3komi >/dev/null 2>&1 || true
"$PROJECT_ROOT/script/build_app.sh"
APP_BUNDLE="$PROJECT_ROOT/dist/yo3komi.app"
case "$MODE" in
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --debug|debug) /usr/bin/lldb -- "$APP_BUNDLE/Contents/MacOS/yo3komi" ;;
  --logs|logs|--telemetry|telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "yo3komi"' ;;
  --verify|verify)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/pgrep -x yo3komi ;;
  *) printf 'usage: %s [run|--debug|--logs|--telemetry|--verify]\n' "$0" >&2; exit 2 ;;
esac
