#!/usr/bin/env bash
# Scripts/release.sh — build, sign, notarize and package DBStudio (SPEC §16 Phase 7).
#
#   Scripts/release.sh                 full release: archive, sign, notarize, staple, DMG
#   Scripts/release.sh --skip-notarize stop after signing; still builds the DMG
#   Scripts/release.sh --unsigned      no signing at all, for a local smoke test
#
# Environment:
#   DBSTUDIO_SIGNING_IDENTITY   "Developer ID Application: … (TEAMID)"
#   DBSTUDIO_TEAM_ID            the ten-character team identifier
#   DBSTUDIO_NOTARY_PROFILE     a notarytool keychain profile (default: DBStudio)
#   DBSTUDIO_APPCAST_URL        Sparkle feed URL, baked into Info.plist
#   DBSTUDIO_SPARKLE_PUBLIC_KEY Sparkle EdDSA public key, baked into Info.plist
#
# Create the notary profile once with:
#   xcrun notarytool store-credentials DBStudio \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="full"
for argument in "$@"; do
    case "$argument" in
        --skip-notarize) MODE="skip-notarize" ;;
        --unsigned) MODE="unsigned" ;;
        *) echo "unknown argument: $argument" >&2; exit 2 ;;
    esac
done

bold() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL:\033[0m %s\n' "$*"; exit 1; }

BUILD_DIR=".build/release"
ARCHIVE="$BUILD_DIR/DBStudio.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/Tinker.app"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

IDENTITY="${DBSTUDIO_SIGNING_IDENTITY:-}"
TEAM_ID="${DBSTUDIO_TEAM_ID:-}"
NOTARY_PROFILE="${DBSTUDIO_NOTARY_PROFILE:-DBStudio}"

if [[ "$MODE" != "unsigned" && -z "$IDENTITY" ]]; then
    # A Developer ID certificate is what separates a distributable build from a local one.
    AVAILABLE="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" || true)"
    if [[ -z "$AVAILABLE" ]]; then
        fail "No Developer ID Application certificate in the keychain.
  Install one from developer.apple.com, or run with --unsigned for a local build.
  Available identities:
$(security find-identity -v -p codesigning 2>/dev/null | sed 's/^/    /')"
    fi
    IDENTITY="$(printf '%s' "$AVAILABLE" | head -1 | sed -E 's/.*"(.*)"/\1/')"
    echo "Using signing identity: $IDENTITY"
fi

if [[ "$MODE" != "unsigned" ]]; then
    # The team identifier is the parenthesised suffix of the identity's common name.
    if [[ -z "$TEAM_ID" && "$IDENTITY" =~ \(([A-Z0-9]{10})\)$ ]]; then
        TEAM_ID="${BASH_REMATCH[1]}"
        echo "Derived team id: $TEAM_ID"
    fi
    [[ -n "$TEAM_ID" ]] || fail "Set DBSTUDIO_TEAM_ID; it could not be read from '$IDENTITY'."
    if [[ "$IDENTITY" != "Developer ID Application:"* ]]; then
        warn "'$IDENTITY' is not a Developer ID Application certificate.
  The build will be signed but Gatekeeper will refuse it on another Mac, and it
  cannot be notarized. Use it for local verification only."
    fi
fi

# ---------------------------------------------------------------------------
bold "Version"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    /dev/stdin <<< "$(xcodebuild -project App/DBStudio.xcodeproj -target DBStudio -showBuildSettings 2>/dev/null |
        awk '/MARKETING_VERSION/ {print "<plist><dict><key>CFBundleShortVersionString</key><string>" $3 "</string></dict></plist>"}' |
        head -1)" 2>/dev/null || echo "0.1.0")"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
echo "  version $VERSION build $BUILD_NUMBER"

# ---------------------------------------------------------------------------
bold "Archive"
ARCHIVE_ARGS=(
    -project App/DBStudio.xcodeproj
    -scheme DBStudio
    -configuration Release
    -destination 'generic/platform=macOS'
    -archivePath "$ARCHIVE"
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
    ONLY_ACTIVE_ARCH=NO
    ARCHS=arm64
)
if [[ -n "${DBSTUDIO_APPCAST_URL:-}" ]]; then
    ARCHIVE_ARGS+=(DBSTUDIO_APPCAST_URL="$DBSTUDIO_APPCAST_URL")
fi
if [[ -n "${DBSTUDIO_SPARKLE_PUBLIC_KEY:-}" ]]; then
    ARCHIVE_ARGS+=(DBSTUDIO_SPARKLE_PUBLIC_KEY="$DBSTUDIO_SPARKLE_PUBLIC_KEY")
else
    warn "DBSTUDIO_SPARKLE_PUBLIC_KEY is unset; the build will report updates as not configured"
fi
if [[ "$MODE" == "unsigned" ]]; then
    ARCHIVE_ARGS+=(CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="")
else
    ARCHIVE_ARGS+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY")
    [[ -n "$TEAM_ID" ]] && ARCHIVE_ARGS+=(DEVELOPMENT_TEAM="$TEAM_ID")
fi
xcodebuild "${ARCHIVE_ARGS[@]}" -quiet archive

# ---------------------------------------------------------------------------
bold "Export"
mkdir -p "$EXPORT_DIR"
if [[ "$MODE" == "unsigned" ]]; then
    cp -R "$ARCHIVE/Products/Applications/Tinker.app" "$EXPORT_DIR/"
else
    cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>$IDENTITY</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>destination</key><string>export</string>
</dict>
</plist>
PLIST
    xcodebuild -exportArchive -archivePath "$ARCHIVE" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
        -exportPath "$EXPORT_DIR" -quiet
fi
[[ -d "$APP" ]] || fail "the export produced no app at $APP"

# ---------------------------------------------------------------------------
bold "Verify signature and hardened runtime"
if [[ "$MODE" == "unsigned" ]]; then
    warn "unsigned build: signature and notarization are skipped"
else
    codesign --verify --deep --strict --verbose=2 "$APP"
    FLAGS="$(codesign -d --verbose=2 "$APP" 2>&1 | grep -E "^flags=" || true)"
    echo "  $FLAGS"
    [[ "$FLAGS" == *runtime* ]] || fail "the hardened runtime is not enabled"
    codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "app-sandbox" \
        || warn "no sandbox entitlement found (expected: sandbox off)"
fi

# ---------------------------------------------------------------------------
if [[ "$MODE" == "full" ]]; then
    bold "Notarize"
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        fail "No notarytool profile named '$NOTARY_PROFILE'.
  Create one with:
    xcrun notarytool store-credentials $NOTARY_PROFILE \\
        --apple-id <apple-id> --team-id ${TEAM_ID:-<team-id>} --password <app-specific-password>
  Or run with --skip-notarize."
    fi
    ZIP="$BUILD_DIR/Tinker-notarize.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    # Gatekeeper's own verdict is the one that matters on a clean machine.
    spctl --assess --type execute --verbose=4 "$APP"
fi

# ---------------------------------------------------------------------------
bold "DMG"
DMG="$BUILD_DIR/Tinker-$VERSION.dmg"
STAGING="$BUILD_DIR/dmg"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Tinker $VERSION" -srcfolder "$STAGING" \
    -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
if [[ "$MODE" != "unsigned" ]]; then
    codesign --sign "$IDENTITY" --timestamp "$DMG"
    if [[ "$MODE" == "full" ]]; then
        # The disk image is notarized separately from the app inside it.
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi
echo "  $DMG"
ls -lh "$DMG" | awk '{print "  " $5}'

# ---------------------------------------------------------------------------
bold "Appcast"
if [[ -n "${DBSTUDIO_APPCAST_URL:-}" ]]; then
    cat <<APPCAST
  Sign the DMG for Sparkle and add an <item> to the appcast:
    ./bin/sign_update "$DMG"
  The feed this build points at is $DBSTUDIO_APPCAST_URL
APPCAST
else
    warn "DBSTUDIO_APPCAST_URL is unset; this build cannot check for updates"
fi

echo
echo "Release build complete."
