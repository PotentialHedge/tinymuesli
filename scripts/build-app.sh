#!/usr/bin/env bash
# Builds build/tinyMuesli.app from the Swift package.
#
#   CONFIG=debug scripts/build-app.sh
#   TINYMUESLI_SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#
# macOS ties privacy permissions to the signature, and an ad-hoc one changes on every build: the
# Accessibility toggle in System Settings stays on but no longer applies, and mic / system audio
# ask again. So it signs with the "Muesli Self-Signed" certificate (the one releases use) when it's
# in the keychain, and ad-hoc ("-") only when it isn't.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
if [ -z "${TINYMUESLI_SIGN_IDENTITY:-}" ] && security find-identity -p codesigning | grep -q '"Muesli Self-Signed"'; then
  TINYMUESLI_SIGN_IDENTITY="Muesli Self-Signed"
fi
SIGN_IDENTITY="${TINYMUESLI_SIGN_IDENTITY:--}"
APP="build/tinyMuesli.app"

# Optimise for size: most of the binary is FluidAudio, of which we use only the diarizer.
FLAGS=()
[ "$CONFIG" = release ] && FLAGS=(-Xswiftc -Osize)
swift build -c "$CONFIG" --product tinyMuesli ${FLAGS[@]+"${FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${FLAGS[@]+"${FLAGS[@]}"} --show-bin-path)"
BIN="$BIN_DIR/tinyMuesli"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/tinyMuesli"
# Drop local symbols (~half the file). Crash logs still symbolicate public/exported ones.
[ "$CONFIG" = release ] && strip -x "$APP/Contents/MacOS/tinyMuesli"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Sparkle (updates). tinyMuesli isn't sandboxed, so it doesn't need Sparkle's XPC services. The framework
# is re-signed with our identity: the hardened runtime only loads libraries signed by the same team.
# Ad-hoc and self-signed signatures have no team, so those builds turn library validation off instead.
FW="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$FW"
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices"
for item in "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app" "$FW"; do
  codesign --force --options runtime --sign "$SIGN_IDENTITY" "$item"
done

ENTITLEMENTS=Resources/tinyMuesli.entitlements
if [ "$(codesign -dv "$FW" 2>&1 | sed -n 's/^TeamIdentifier=//p')" = "not set" ]; then
  ENTITLEMENTS="$(mktemp -t tinymuesli-entitlements).plist"
  cp Resources/tinyMuesli.entitlements "$ENTITLEMENTS"
  plutil -insert com\\.apple\\.security\\.cs\\.disable-library-validation -bool YES "$ENTITLEMENTS"
fi

codesign --force --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
