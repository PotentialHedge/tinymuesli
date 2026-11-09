#!/bin/sh
# Installs or updates tinyMuesli:
#
#   curl -fsSL https://github.com/PotentialHedge/tinymuesli/releases/latest/download/install.sh | sh
#
# Downloads the latest release from GitHub into /Applications (~/Applications if that isn't
# writable) and opens it. Later updates come from "Check for Updates…" in the app's menu.
set -eu

REPO="PotentialHedge/tinymuesli"
APP_NAME="tinyMuesli.app"

say() { printf '%s\n' "$*"; }
fail() { printf 'tinyMuesli: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "tinyMuesli is a Mac app."
[ "$(uname -m)" = arm64 ] || fail "tinyMuesli needs an Apple Silicon Mac."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 26 ] || fail "tinyMuesli needs macOS 26 or later (this Mac has $(sw_vers -productVersion))."

if pgrep -xq tinyMuesli; then
  fail "tinyMuesli is running. Update it with \"Check for Updates…\" in its menu, or quit it and run this again."
fi

if [ -w /Applications ]; then
  DEST=/Applications
else
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

# The latest release's appcast names its zip, so this needs no GitHub API call.
url=$(curl -fsSL "https://github.com/$REPO/releases/latest/download/appcast.xml" |
  sed -n 's/.*<enclosure url="\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$url" ] || fail "couldn't find the latest release."
version=$(printf '%s' "$url" | sed -n 's/.*tinyMuesli-\(.*\)\.zip$/\1/p')

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "Downloading tinyMuesli $version…"
curl -fL --progress-bar "$url" -o "$tmp/tinyMuesli.zip"
ditto -x -k "$tmp/tinyMuesli.zip" "$tmp"
[ -d "$tmp/$APP_NAME" ] || fail "the download doesn't contain $APP_NAME."

rm -rf "${DEST:?}/$APP_NAME"
ditto "$tmp/$APP_NAME" "$DEST/$APP_NAME"
xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true

say "Installed tinyMuesli $version in $DEST. Opening it…"
open "$DEST/$APP_NAME"
