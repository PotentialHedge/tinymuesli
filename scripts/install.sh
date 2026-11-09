#!/bin/sh
# Installs or updates tinyMuesli:
#
#   curl -fsSL https://github.com/PotentialHedge/tinymuesli/releases/latest/download/install.sh | sh
#
# Downloads the latest release from GitHub and opens it. An existing copy in /Applications or
# ~/Applications is updated in place (a running one only after asking, since quitting it stops a
# recording); a new one goes into /Applications, or ~/Applications if that isn't writable.
# Later updates come from "Check for Updates…" in the app's menu.
#
# It also links the app's binary as `tinymuesli` into a directory on the PATH, so the CLI
# (`tinymuesli list`, `tinymuesli search …`) works from any terminal.
set -eu

REPO="PotentialHedge/tinymuesli"
APP_NAME="tinyMuesli.app"

say() { printf '%s\n' "$*"; }
fail() { printf 'tinyMuesli: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "tinyMuesli is a Mac app."
[ "$(uname -m)" = arm64 ] || fail "tinyMuesli needs an Apple Silicon Mac."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 26 ] || fail "tinyMuesli needs macOS 26 or later (this Mac has $(sw_vers -productVersion))."

# Update an existing copy where it is; otherwise install into /Applications if writable.
if [ -d "/Applications/$APP_NAME" ]; then
  DEST=/Applications
elif [ -d "$HOME/Applications/$APP_NAME" ]; then
  DEST="$HOME/Applications"
elif [ -w /Applications ]; then
  DEST=/Applications
else
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi
APP="$DEST/$APP_NAME"

# The latest release's appcast names its zip, so this needs no GitHub API call.
url=$(curl -fsSL "https://github.com/$REPO/releases/latest/download/appcast.xml" |
  sed -n 's/.*<enclosure url="\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$url" ] || fail "couldn't find the latest release."
version=$(printf '%s' "$url" | sed -n 's/.*tinyMuesli-\(.*\)\.zip$/\1/p')

# The menu bar app is this binary with no arguments (`tinyMuesli mcp` etc. are CLI runs, which
# keep working from the old copy until they exit).
running() { pgrep -fx "$APP/Contents/MacOS/tinyMuesli" > /dev/null; }

# Links `tinymuesli` to this copy: into the first writable directory of /opt/homebrew/bin and
# /usr/local/bin that's on the PATH, else ~/.local/bin. Never replaces a file that isn't a link.
link_cli() {
  target="$APP/Contents/MacOS/tinyMuesli"
  [ "$(readlink "$(command -v tinymuesli 2>/dev/null || true)" 2>/dev/null || true)" = "$target" ] && return 0
  dir=""
  for d in /opt/homebrew/bin /usr/local/bin; do
    case ":$PATH:" in *":$d:"*) [ -d "$d" ] && [ -w "$d" ] && { dir=$d; break; } ;; esac
  done
  if [ -z "$dir" ]; then
    dir="$HOME/.local/bin"
    mkdir -p "$dir"
  fi
  if [ -e "$dir/tinymuesli" ] && [ ! -L "$dir/tinymuesli" ]; then
    say "Not linking the tinymuesli command: $dir/tinymuesli already exists."
    return 0
  fi
  ln -sf "$target" "$dir/tinymuesli"
  case ":$PATH:" in
    *":$dir:"*) say "Linked the tinymuesli command into $dir (try: tinymuesli help)." ;;
    *) say "Linked the tinymuesli command into $dir. Add it to your PATH to use it: export PATH=\"$dir:\$PATH\"" ;;
  esac
}

installed=""
if [ -d "$APP" ]; then
  installed=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)
  if [ "$installed" = "$version" ]; then
    say "tinyMuesli $version, the latest version, is already in $DEST."
    link_cli
    running || open "$APP"
    exit 0
  fi
fi

if running; then
  say "tinyMuesli ${installed:-} is running. Updating to $version quits it, which stops a meeting it's recording (it's transcribed when tinyMuesli opens again)."
  # This script is usually piped into sh, so ask the terminal, not stdin.
  answer=""
  if (exec < /dev/tty) 2> /dev/null; then
    printf 'Quit tinyMuesli and update? [y/N] '
    read -r answer < /dev/tty || answer=""
  fi
  case "$answer" in
    y | Y | yes | Yes) ;;
    *) fail "not updated. Quit tinyMuesli and run this again, or use \"Check for Updates…\" in its menu." ;;
  esac
  pkill -fx "$APP/Contents/MacOS/tinyMuesli" || true
  i=0
  while running; do
    i=$((i + 1))
    [ "$i" -le 50 ] || fail "tinyMuesli didn't quit."
    sleep 0.2
  done
fi

tmp=$(mktemp -d)
# macOS sh (bash 3.2) runs an EXIT trap with $? reset to 0 after an error such as an unbound
# variable, so the script would exit 0; $finished is set only at the end, so any earlier exit is 1.
finished=""
trap 'rm -rf "$tmp"; [ -n "$finished" ] || exit 1' EXIT

say "Downloading tinyMuesli ${version}…"
curl -fL --progress-bar "$url" -o "$tmp/tinyMuesli.zip"
ditto -x -k "$tmp/tinyMuesli.zip" "$tmp"
[ -d "$tmp/$APP_NAME" ] || fail "the download doesn't contain $APP_NAME."

rm -rf "$APP"
ditto "$tmp/$APP_NAME" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
link_cli

if [ -n "$installed" ]; then
  say "Updated tinyMuesli from $installed to $version in $DEST. Opening it…"
else
  say "Installed tinyMuesli $version in $DEST. Opening it…"
fi
open "$APP"
finished=1
