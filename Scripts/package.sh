#!/usr/bin/env bash
# Build DiskScope.app, sign it, and (optionally) make a DMG and notarize.
#
#   ./Scripts/package.sh            build + sign + verify the .app
#   ./Scripts/package.sh --dmg      …and build a distributable DMG
#   ./Scripts/package.sh --dmg --notarize   …and notarize + staple the DMG
#
# Signing identity selection (in order):
#   1. $SIGN_IDENTITY            — explicit, e.g. "Developer ID Application: Name (TEAMID)"
#   2. auto-detected "Developer ID Application" in the keychain
#   3. ad-hoc ("-")             — runs locally; CANNOT be notarized or distributed
#
# Notarization needs a Developer ID signature AND a notarytool keychain profile in
# $NOTARY_PROFILE (set one up once with: xcrun notarytool store-credentials — see
# Packaging/README.md).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DiskScope"
PRODUCT="DiskScopeApp"          # SwiftPM product (the GUI executable)
CLI_PRODUCT="diskscope-scan"    # SwiftPM product (the CLI/TUI; bundled + exposed as `diskscope`)
VERSION="1.0.2"                 # marketing version; keep in sync with Packaging/Info.plist
DIST="dist"
APP="$DIST/$APP_NAME.app"
ENTITLEMENTS="Packaging/DiskScope.entitlements"
ICNS="Packaging/AppIcon.icns"

DO_DMG=0; DO_NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --dmg) DO_DMG=1 ;;
    --notarize) DO_NOTARIZE=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

step() { printf "\n\033[1;36m▸ %s\033[0m\n" "$1"; }

# --- Icon (render if missing) ----------------------------------------------------------
if [[ ! -f "$ICNS" ]]; then
  step "icon missing — rendering"
  bash Scripts/make-icon.sh
fi

# --- Build -----------------------------------------------------------------------------
step "building release binaries (GUI + CLI)"
swift build -c release --product "$PRODUCT"
swift build -c release --product "$CLI_PRODUCT"
BIN=".build/release/$PRODUCT"
CLI_BIN=".build/release/$CLI_PRODUCT"
[[ -x "$BIN" ]] || { echo "build did not produce $BIN" >&2; exit 1; }
[[ -x "$CLI_BIN" ]] || { echo "build did not produce $CLI_BIN" >&2; exit 1; }

# --- Assemble bundle -------------------------------------------------------------------
step "assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
# The CLI/TUI ships inside the bundle. It keeps its filename here (DiskScope vs diskscope
# would collide on a case-insensitive volume); the cask exposes it on PATH as `diskscope`.
cp "$CLI_BIN" "$APP/Contents/MacOS/$CLI_PRODUCT"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Stamp the build number from the git commit count (monotonic, no manual bumping).
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
echo "  version $VERSION (build $BUILD)"

# --- Choose signing identity -----------------------------------------------------------
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"$/\1/' || true)"
fi

# --- Sign (inside-out: nested CLI first, then the bundle) ------------------------------
if [[ -n "$IDENTITY" ]]; then
  step "signing (Developer ID): $IDENTITY"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/$CLI_PRODUCT"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"
  SIGNED_DEVID=1
else
  step "signing ad-hoc (no Developer ID identity found)"
  echo "  ⚠ ad-hoc signature: runs on THIS Mac only; not distributable, not notarizable."
  echo "  ⚠ set up a Developer ID cert (Packaging/README.md) then re-run to ship."
  codesign --force --sign - "$APP/Contents/MacOS/$CLI_PRODUCT"
  codesign --force --sign - "$APP"
  SIGNED_DEVID=0
fi

# --- Verify ----------------------------------------------------------------------------
step "verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "  Gatekeeper assessment (informational):"
spctl --assess --type execute --verbose=4 "$APP" || \
  echo "  (rejected — expected until Developer-ID-signed + notarized)"

echo "✓ built $APP"

# --- DMG -------------------------------------------------------------------------------
DMG="$DIST/$APP_NAME-$VERSION.dmg"
if [[ "$DO_DMG" == 1 ]]; then
  step "building DMG → $DMG"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  if [[ "$SIGNED_DEVID" == 1 ]]; then
    codesign --force --sign "$IDENTITY" "$DMG"
  fi
  echo "✓ built $DMG"
fi

# --- Notarize --------------------------------------------------------------------------
if [[ "$DO_NOTARIZE" == 1 ]]; then
  step "notarizing"
  if [[ "$SIGNED_DEVID" != 1 ]]; then
    echo "  ✗ cannot notarize an ad-hoc-signed build — need a Developer ID signature." >&2; exit 1
  fi
  : "${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile name}"
  TARGET="$DMG"; [[ -f "$TARGET" ]] || { echo "  ✗ run with --dmg too" >&2; exit 1; }
  xcrun notarytool submit "$TARGET" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$TARGET"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$TARGET" || true
  echo "✓ notarized + stapled $TARGET"
fi
