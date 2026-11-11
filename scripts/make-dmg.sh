#!/usr/bin/env bash
# Packs an app into a drag-to-install disk image: opening it shows a Finder window with
# tinyMuesli.app, an arrow and the Applications folder.
#
#   scripts/make-dmg.sh build/tinyMuesli.app build/release/tinyMuesli.dmg
#
# Needs uv (runs dmgbuild, which writes the window layout without scripting Finder) and
# rsvg-convert (`brew install librsvg`, renders Resources/dmg/background.svg).
# Signs the image with TINYMUESLI_SIGN_IDENTITY when it's set.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: scripts/make-dmg.sh <app> <output.dmg>}"
DMG="${2:?usage: scripts/make-dmg.sh <app> <output.dmg>}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 1x and 2x backgrounds; dmgbuild combines background.png and background@2x.png for Retina.
rsvg-convert -w 640 -h 400 Resources/dmg/background.svg -o "$TMP/background.png"
rsvg-convert -w 1280 -h 800 Resources/dmg/background.svg -o "$TMP/background@2x.png"

cat > "$TMP/settings.py" <<PY
import os
app = defines["app"]
name = os.path.basename(app)
files = [app]
symlinks = {"Applications": "/Applications"}
format = "UDZO"
background = defines["background"]
window_rect = ((200, 120), (640, 400))
icon_size = 112
text_size = 13
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
icon_locations = {name: (170, 180), "Applications": (470, 180)}
PY

rm -f "$DMG"
mkdir -p "$(dirname "$DMG")"
uvx --from dmgbuild==1.6.7 dmgbuild -s "$TMP/settings.py" \
  -D app="$APP" -D background="$TMP/background.png" "tinyMuesli" "$DMG"

if [ -n "${TINYMUESLI_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$TINYMUESLI_SIGN_IDENTITY" "$DMG"
fi
echo "Wrote $DMG"
