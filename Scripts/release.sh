#!/usr/bin/env bash
# Scripts/release.sh — build, sign, notarize and package Tinker (SPEC §16 Phase 7).
#
#   Scripts/release.sh                 full release: archive, sign, notarize, staple, DMG
#   Scripts/release.sh --skip-notarize stop after signing; still builds the DMG
#   Scripts/release.sh --share         a universal build to hand to someone without a
#                                      Developer ID: signed with the certificate at hand
#                                      (or ad hoc), zipped; opened once with right-click → Open
#   Scripts/release.sh --unsigned      no signing at all, for a local smoke test
#
# Environment:
#   TINKER_SIGNING_IDENTITY   "Developer ID Application: … (TEAMID)"
#   TINKER_TEAM_ID            the ten-character team identifier
#   TINKER_NOTARY_PROFILE     a notarytool keychain profile (default: Tinker)
#   TINKER_APPCAST_URL        Sparkle feed URL, baked into Info.plist
#   TINKER_SPARKLE_PUBLIC_KEY Sparkle EdDSA public key, baked into Info.plist
#
# Create the notary profile once with:
#   xcrun notarytool store-credentials Tinker \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="full"
for argument in "$@"; do
    case "$argument" in
        --skip-notarize) MODE="skip-notarize" ;;
        --unsigned) MODE="unsigned" ;;
        # A build to hand to someone without a Developer ID: signed with whatever
        # certificate is at hand (or ad hoc), universal, zipped so nothing is lost on
        # the way. The recipient opens it once with right-click → Open.
        --share) MODE="share" ;;
        *) echo "unknown argument: $argument" >&2; exit 2 ;;
    esac
done

bold() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL:\033[0m %s\n' "$*"; exit 1; }

BUILD_DIR=".build/release"
ARCHIVE="$BUILD_DIR/Tinker.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/Tinker.app"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

IDENTITY="${TINKER_SIGNING_IDENTITY:-}"
TEAM_ID="${TINKER_TEAM_ID:-}"
NOTARY_PROFILE="${TINKER_NOTARY_PROFILE:-Tinker}"

if [[ "$MODE" == "share" ]]; then
    if [[ -z "$IDENTITY" ]]; then
        # Any certificate beats none: an unsigned binary does not launch at all on
        # Apple silicon. Ad hoc ("-") is the floor.
        AVAILABLE="$(security find-identity -v -p codesigning 2>/dev/null | grep -E "Developer ID Application|Apple Development" || true)"
        IDENTITY="$(printf '%s' "$AVAILABLE" | head -1 | sed -E 's/.*"(.*)"/\1/')"
        [[ -n "$IDENTITY" ]] || IDENTITY="-"
    fi
    echo "Using signing identity: $IDENTITY"
elif [[ "$MODE" != "unsigned" && -z "$IDENTITY" ]]; then
    # A Developer ID certificate is what separates a distributable build from a local one.
    AVAILABLE="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" || true)"
    if [[ -z "$AVAILABLE" ]]; then
        fail "No Developer ID Application certificate in the keychain.
  Install one from developer.apple.com, run with --share for a build to hand to
  someone (opened once with right-click → Open), or --unsigned for a local build.
  Available identities:
$(security find-identity -v -p codesigning 2>/dev/null | sed 's/^/    /')"
    fi
    IDENTITY="$(printf '%s' "$AVAILABLE" | head -1 | sed -E 's/.*"(.*)"/\1/')"
    echo "Using signing identity: $IDENTITY"
fi

if [[ "$MODE" != "unsigned" && "$MODE" != "share" ]]; then
    # The team identifier is the parenthesised suffix of the identity's common name.
    if [[ -z "$TEAM_ID" && "$IDENTITY" =~ \(([A-Z0-9]{10})\)$ ]]; then
        TEAM_ID="${BASH_REMATCH[1]}"
        echo "Derived team id: $TEAM_ID"
    fi
    [[ -n "$TEAM_ID" ]] || fail "Set TINKER_TEAM_ID; it could not be read from '$IDENTITY'."
    if [[ "$IDENTITY" != "Developer ID Application:"* ]]; then
        warn "'$IDENTITY' is not a Developer ID Application certificate.
  The build will be signed but Gatekeeper will refuse it on another Mac, and it
  cannot be notarized. Use it for local verification only."
    fi
fi

# ---------------------------------------------------------------------------
bold "Version"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    /dev/stdin <<< "$(xcodebuild -project App/Tinker.xcodeproj -target Tinker -showBuildSettings 2>/dev/null |
        awk '/MARKETING_VERSION/ {print "<plist><dict><key>CFBundleShortVersionString</key><string>" $3 "</string></dict></plist>"}' |
        head -1)" 2>/dev/null || echo "0.1.0")"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
echo "  version $VERSION build $BUILD_NUMBER"

# ---------------------------------------------------------------------------
bold "Archive"
ARCHIVE_ARGS=(
    -project App/Tinker.xcodeproj
    -scheme Tinker
    -configuration Release
    -destination 'generic/platform=macOS'
    -archivePath "$ARCHIVE"
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
    # Universal: the recipient may be on an Intel Mac.
    ONLY_ACTIVE_ARCH=NO
    ARCHS="arm64 x86_64"
)
if [[ -n "${TINKER_APPCAST_URL:-}" ]]; then
    ARCHIVE_ARGS+=(TINKER_APPCAST_URL="$TINKER_APPCAST_URL")
fi
if [[ -n "${TINKER_SPARKLE_PUBLIC_KEY:-}" ]]; then
    ARCHIVE_ARGS+=(TINKER_SPARKLE_PUBLIC_KEY="$TINKER_SPARKLE_PUBLIC_KEY")
else
    warn "TINKER_SPARKLE_PUBLIC_KEY is unset; the build will report updates as not configured"
fi
if [[ "$MODE" == "unsigned" || "$MODE" == "share" ]]; then
    # Signed afterwards, in one pass over the whole bundle.
    ARCHIVE_ARGS+=(CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="")
else
    ARCHIVE_ARGS+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY")
    [[ -n "$TEAM_ID" ]] && ARCHIVE_ARGS+=(DEVELOPMENT_TEAM="$TEAM_ID")
fi
xcodebuild "${ARCHIVE_ARGS[@]}" -quiet archive

# ---------------------------------------------------------------------------
bold "Export"
mkdir -p "$EXPORT_DIR"
if [[ "$MODE" == "unsigned" || "$MODE" == "share" ]]; then
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
if [[ "$MODE" == "share" ]]; then
    bold "Sign for sharing"
    # Nested code first — Sparkle's XPC services, updater and framework — then the app,
    # all with the hardened runtime and the app's own entitlements.
    find "$APP/Contents/Frameworks" -type d \( -name "*.xpc" -o -name "*.app" \) -print0 2>/dev/null |
        xargs -0 -I{} codesign --force --options runtime --sign "$IDENTITY" {}
    find "$APP/Contents/Frameworks" -type f -perm -111 -path "*/Versions/*/Autoupdate" -print0 2>/dev/null |
        xargs -0 -I{} codesign --force --options runtime --sign "$IDENTITY" {}
    find "$APP/Contents/Frameworks" -type d -name "*.framework" -print0 2>/dev/null |
        xargs -0 -I{} codesign --force --options runtime --sign "$IDENTITY" {}
    codesign --force --options runtime --entitlements App/Tinker/Resources/Tinker.entitlements \
        --sign "$IDENTITY" "$APP"
    # Nothing that was ever downloaded should carry quarantine into the zip.
    xattr -cr "$APP"
fi

bold "Verify signature and hardened runtime"
if [[ "$MODE" == "unsigned" ]]; then
    warn "unsigned build: signature and notarization are skipped"
else
    codesign --verify --deep --strict --verbose=2 "$APP"
    FLAGS="$(codesign -d --verbose=2 "$APP" 2>&1 | grep -oE "flags=[^ ]+" | head -1 || true)"
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
bold "Architectures"
lipo -info "$APP/Contents/MacOS/Tinker" | sed 's/^/  /'

if [[ "$MODE" == "share" ]]; then
    bold "Zip to share"
    ZIP="$BUILD_DIR/Tinker-$VERSION.zip"
    # ditto keeps the bundle's permissions and structure; a folder dragged into a chat
    # or a Finder-compressed copy of a modified bundle may not.
    ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"
    echo "  $ZIP"
    ls -lh "$ZIP" | awk '{print "  " $5}'
    cat <<SHARE

  This build is not notarized (that needs a Developer ID certificate), so on the
  recipient's Mac Gatekeeper will refuse a double-click the first time. Tell them:
    1. Unzip, move Tinker.app to Applications.
    2. Right-click Tinker.app → Open → Open. (Once; after that it opens normally.)
       Or, in Terminal:  xattr -dr com.apple.quarantine /Applications/Tinker.app
  It needs macOS 14 or later, and runs on Apple silicon and Intel.
SHARE
fi

bold "DMG"
DMG="$BUILD_DIR/Tinker-$VERSION.dmg"
STAGING="$BUILD_DIR/dmg"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Tinker $VERSION" -srcfolder "$STAGING" \
    -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
if [[ "$MODE" != "unsigned" && "$MODE" != "share" ]]; then
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
if [[ -n "${TINKER_APPCAST_URL:-}" ]]; then
    cat <<APPCAST
  Sign the DMG for Sparkle and add an <item> to the appcast:
    ./bin/sign_update "$DMG"
  The feed this build points at is $TINKER_APPCAST_URL
APPCAST
else
    warn "TINKER_APPCAST_URL is unset; this build cannot check for updates"
fi

echo
echo "Release build complete."
