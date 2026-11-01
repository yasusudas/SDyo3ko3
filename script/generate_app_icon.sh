#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER="$PROJECT_ROOT/Resources/AppIcon.png"
ICONSET="$PROJECT_ROOT/dist/AppIcon.iconset"
command -v magick >/dev/null || { echo 'ImageMagick (magick) is required to regenerate the icon.' >&2; exit 1; }
# A full-bleed opaque RGBA master lets macOS apply its own icon mask.
META="$(magick identify -format '%wx%h|%z|%[png:IHDR.color_type]|%[opaque]' "$MASTER")"
if [[ "$META" != '1024x1024|8|6 (RGBA)|True' ]]; then
  echo "AppIcon.png must be 1024x1024, 8-bit RGBA, and fully opaque: $META" >&2
  exit 1
fi
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  magick "$MASTER" -resize "${SIZE}x${SIZE}" -colorspace sRGB -alpha set \
    -channel A -evaluate set 100% +channel -type TrueColorAlpha -depth 8 \
    -define png:color-type=6 "$ICONSET/icon_${SIZE}x${SIZE}.png"
  DOUBLE=$((SIZE * 2))
  magick "$MASTER" -resize "${DOUBLE}x${DOUBLE}" -colorspace sRGB -alpha set \
    -channel A -evaluate set 100% +channel -type TrueColorAlpha -depth 8 \
    -define png:color-type=6 "$ICONSET/icon_${SIZE}x${SIZE}@2x.png"
done
# Store small icons through their 2x PNG representations. On this toolchain,
# iconutil's legacy 16/32px ARGB conversion corrupts blue-channel pixels.
# Modern macOS scales the lossless 2x representations for 1x displays as well.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PACKSET="$WORK/AppIcon.iconset"
mkdir -p "$PACKSET"
for FRAME in "$ICONSET"/*.png; do
  case "$(basename "$FRAME")" in
    icon_16x16.png|icon_32x32.png) continue ;;
  esac
  cp "$FRAME" "$PACKSET/"
done
/usr/bin/iconutil -c icns "$PACKSET" -o "$PROJECT_ROOT/Resources/AppIcon.icns"
printf 'Generated: %s\n' "$PROJECT_ROOT/Resources/AppIcon.icns"
