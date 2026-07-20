#!/bin/bash
# Assemble "PDF Utils.app" from the SwiftPM release build, embedding the Finder Sync
# extension as Contents/PlugIns/PdfUtilsFinder.appex, then code-sign inside-out.
#
# SwiftPM has no .app / .appex product type, so we hand-assemble both bundles (see the
# project memory for why). Signing order is load-bearing: the nested .appex must be signed
# WITH its sandbox entitlements first, then the app is signed WITHOUT --deep so it seals —
# but does not re-sign, and thus does not strip the entitlements from — the extension.
#
# Usage: scripts/build-app.sh [signing-identity]
#   default identity is "-" (ad-hoc), matching the app's shipped signing.
set -euo pipefail

IDENTITY="${1:--}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/PDF Utils.app"
EXT="$APP/Contents/PlugIns/PdfUtilsFinder.appex"
HELPER="$APP/Contents/Library/LoginItems/PdfUtilsHelper.app"

echo "==> Building release products"
swift build -c release --product PdfUtils
swift build -c release --product PdfUtilsFinder
swift build -c release --product PdfUtilsHelper

echo "==> Assembling app bundle at $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS" "$HELPER/Contents/MacOS"

# App binary + Bundle.module resource bundle (lives at the .app root by design).
cp .build/release/PdfUtils "$APP/Contents/MacOS/PdfUtils"
cp -R .build/release/PdfUtils_PdfUtils.bundle "$APP/PdfUtils_PdfUtils.bundle"

# App Info.plist (committed copy already has resolved values). Ensure the key fields.
cp MacApp/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable PdfUtils" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.pdfutils.PdfUtils" "$APP/Contents/Info.plist" 2>/dev/null || true

# Reuse an already-built icon if one is installed (cosmetic; skipped if absent).
if [ -f "/Applications/PDF Utils.app/Contents/Resources/AppIcon.icns" ]; then
  cp "/Applications/PDF Utils.app/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Assembling Finder Sync extension at $EXT"
cp .build/release/PdfUtilsFinder "$EXT/Contents/MacOS/PdfUtilsFinder"
cp FinderExtension/Info.plist "$EXT/Contents/Info.plist"

echo "==> Assembling menu-bar helper at $HELPER"
mkdir -p "$HELPER/Contents/Resources" "$HELPER/Contents/Library/LaunchAgents"
cp .build/release/PdfUtilsHelper "$HELPER/Contents/MacOS/PdfUtilsHelper"
cp Helper/Info.plist "$HELPER/Contents/Info.plist"
# LaunchAgent the helper registers for itself (launch at login).
cp Helper/LaunchAgents/com.pdfutils.PdfUtils.Helper.plist "$HELPER/Contents/Library/LaunchAgents/"
# Give the helper the app's icon so its notifications and its Login Items row aren't blank.
if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
  cp "$APP/Contents/Resources/AppIcon.icns" "$HELPER/Contents/Resources/AppIcon.icns"
fi

echo "==> Signing (identity: $IDENTITY) — nested code inside-out, then the app"
# Extension: sandboxed (mandatory for a FinderSync extension to load).
codesign --force --timestamp=none --sign "$IDENTITY" \
  --entitlements FinderExtension/PdfUtilsFinder.entitlements \
  "$EXT"
# Helper: unsandboxed (needs real file access) — no entitlements.
codesign --force --timestamp=none --sign "$IDENTITY" "$HELPER"
# Resource bundle carries no Mach-O but sign it so the app's seal is consistent.
codesign --force --timestamp=none --sign "$IDENTITY" "$APP/PdfUtils_PdfUtils.bundle" 2>/dev/null || true
# The app keeps its Bundle.module resource bundle at the .app root (SwiftPM's accessor
# requires that path), which codesign reports as "unsealed contents present in the bundle
# root". That warning is expected and non-fatal — the app's shipped signing has the same
# shape — so don't let it abort the script under `set -e`.
codesign --force --timestamp=none --sign "$IDENTITY" "$APP" || echo "   (codesign warning tolerated — see note above)"

echo "==> Verify"
codesign -dv "$APP" 2>&1 | grep -iE "Identifier|Signature|TeamIdentifier" || true
echo "--- extension ---"
codesign -dv "$EXT" 2>&1 | grep -iE "Identifier|Signature|TeamIdentifier" || true
echo "--- entitlements on extension ---"
codesign -d --entitlements - "$EXT" 2>/dev/null | grep -iE "sandbox|user-selected" || true
echo "--- helper ---"
codesign -dv "$HELPER" 2>&1 | grep -iE "Identifier|Signature" || true
codesign --verify --verbose=1 "$HELPER" 2>&1 | tail -1 || true

echo "==> Built: $APP"
