#!/usr/bin/env bash
# Scripts/release.sh — build, sign, notarize and package Tinker (SPEC §16 Phase 7).
#
#   Scripts/release.sh                 full release: archive, Developer ID sign (Xcode
#                                      cloud signing), notarize, staple, zip and DMG
#   Scripts/release.sh --skip-notarize stop after signing; still builds the DMG
#   Scripts/release.sh --share         an Apple-silicon build to hand to someone without a
#                                      Developer ID: signed with the certificate at hand
#                                      (or ad hoc), zipped; opened once with right-click → Open
#   Scripts/release.sh --unsigned      no signing at all, for a local smoke test
#   Scripts/release.sh --publish       full release, then a GitHub release carrying the DMG,
#                                      the zip and the signed appcast (needs `gh auth login`)
#
# Updates: the project's TINKER_APPCAST_URL points at
#   https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml
# so each GitHub release must carry an appcast.xml naming its own DMG. This script writes
# it, signed with the Sparkle EdDSA private key in the login keychain (made once with
# `generate_keys`; the matching public key is the project's TINKER_SPARKLE_PUBLIC_KEY).
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
        # certificate is at hand (or ad hoc), Apple silicon only, zipped so nothing is lost on
        # the way. The recipient opens it once with right-click → Open.
        --share) MODE="share" ;;
        --publish) PUBLISH=1 ;;
        *) echo "unknown argument: $argument" >&2; exit 2 ;;
    esac
done
PUBLISH="${PUBLISH:-0}"
if [[ "$PUBLISH" == 1 && "$MODE" != "full" ]]; then
    echo "--publish needs a full (notarized) release" >&2
    exit 2
fi

bold() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL:\033[0m %s\n' "$*"; exit 1; }

BUILD_DIR=".build/release"
ARCHIVE="$BUILD_DIR/Tinker.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/Tinker.app"
# The stapled zip; only a full release makes one.
RELEASE_ZIP=""
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
elif [[ "$MODE" != "unsigned" ]]; then
    # Developer ID signing goes through Xcode's automatic signing: the Developer ID
    # certificate is cloud-managed by Xcode, created on first use, and never lands in
    # the local keychain, so nothing here looks for it. The team comes from the project.
    if [[ -z "$TEAM_ID" ]]; then
        TEAM_ID="$(xcodebuild -project App/Tinker.xcodeproj -target Tinker -showBuildSettings 2>/dev/null |
            awk '/DEVELOPMENT_TEAM/ {print $3; exit}')"
    fi
    [[ -n "$TEAM_ID" ]] || fail "Set TINKER_TEAM_ID; the project has no DEVELOPMENT_TEAM."
    echo "Signing with Xcode automatic signing for team $TEAM_ID (Developer ID on export)"
fi

# ---------------------------------------------------------------------------
bold "Version"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    /dev/stdin <<< "$(xcodebuild -project App/Tinker.xcodeproj -target Tinker -showBuildSettings 2>/dev/null |
        awk '/MARKETING_VERSION/ {print "<plist><dict><key>CFBundleShortVersionString</key><string>" $3 "</string></dict></plist>"}' |
        head -1)" 2>/dev/null || echo "0.1.0")"
# The build number is the project's CURRENT_PROJECT_VERSION, so what ships is what the
# "bump" commit says and what the About panel shows. It used to be a timestamp, which
# never matched the project and made two archives of one commit two different builds.
BUILD_NUMBER="$(xcodebuild -project App/Tinker.xcodeproj -target Tinker -showBuildSettings 2>/dev/null |
    awk '/CURRENT_PROJECT_VERSION/ {print $3; exit}')"
[[ -n "$BUILD_NUMBER" ]] || fail "The project has no CURRENT_PROJECT_VERSION; set one before releasing."
# A release needs its notes: the CHANGELOG must carry a section for this version.
grep -q "^## \[$VERSION\]" CHANGELOG.md || fail "CHANGELOG.md has no \"## [$VERSION]\" section; write the release notes first."
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
    # Apple silicon only: Intel Macs are not supported, so no x86_64 slice is built.
    ONLY_ACTIVE_ARCH=NO
    ARCHS="arm64"
)
if [[ -n "${TINKER_APPCAST_URL:-}" ]]; then
    # Sparkle verifies the update's signature, but the feed itself must not be fetched
    # in the clear: a plain-http appcast can be swapped for one pointing anywhere.
    [[ "$TINKER_APPCAST_URL" == https://* ]] || fail "TINKER_APPCAST_URL must start with https:// (got $TINKER_APPCAST_URL)"
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
    # Signed for development during the archive (which is what carries the hardened
    # runtime into the export), re-signed with Developer ID by the export.
    ARCHIVE_ARGS+=(-allowProvisioningUpdates CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID")
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
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>destination</key><string>export</string>
</dict>
</plist>
PLIST
    xcodebuild -exportArchive -archivePath "$ARCHIVE" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
        -exportPath "$EXPORT_DIR" -allowProvisioningUpdates -quiet
    IDENTITY="$(codesign -dvv "$APP" 2>&1 | grep -E "^Authority=Developer ID Application" | head -1 | cut -d= -f2-)"
    [[ -n "$IDENTITY" ]] || fail "the export is not signed with a Developer ID Application certificate"
    echo "  signed by $IDENTITY"
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
    # The stapled app, zipped for sending: this is what a recipient double-clicks.
    RELEASE_ZIP="$BUILD_DIR/Tinker-$VERSION.zip"
    ditto -c -k --keepParent --sequesterRsrc "$APP" "$RELEASE_ZIP"
    echo "  $RELEASE_ZIP"
fi

# ---------------------------------------------------------------------------
bold "Architectures"
lipo -info "$APP/Contents/MacOS/Tinker" | sed 's/^/  /'

if [[ "$MODE" == "share" ]]; then
    bold "Zip to share"
    ZIP="$BUILD_DIR/Tinker-$VERSION.zip"
    SHARE_DIR="$BUILD_DIR/Tinker-$VERSION"
    rm -rf "$SHARE_DIR"
    mkdir -p "$SHARE_DIR"
    cp -R "$APP" "$SHARE_DIR/"
    # The steps the recipient has to take, next to the app so they are not lost.
    cat > "$SHARE_DIR/Read me first.txt" <<README
Tinker $VERSION — how to open it the first time

This copy is signed but not notarized by Apple, so macOS blocks the first launch
with "Tinker Not Opened — Apple could not verify…". That is expected. Do this once:

  1. Move Tinker.app into Applications.
  2. Double-click it. When the "Not Opened" message appears, click Done (NOT Move to Bin).
  3. Open System Settings → Privacy & Security, scroll down to Security.
     You will see "Tinker was blocked to protect your Mac" — click Open Anyway,
     then Open in the confirmation. (Password or Touch ID may be asked.)
  4. From then on Tinker opens normally.

  Shortcut, if you use Terminal:
     xattr -dr com.apple.quarantine /Applications/Tinker.app
  and then open it as usual.

Needs macOS 14 or later on an Apple silicon (M-series) Mac. Intel Macs are not supported.
README
    # ditto keeps the bundle's permissions and structure; a folder dragged into a chat
    # or a Finder-compressed copy of a modified bundle may not.
    ditto -c -k --keepParent --sequesterRsrc "$SHARE_DIR" "$ZIP"
    echo "  $ZIP"
    ls -lh "$ZIP" | awk '{print "  " $5}'
    cat <<SHARE

  This build is not notarized (that needs a Developer ID certificate), so on the
  recipient's Mac the first double-click shows "Tinker Not Opened — Apple could not
  verify…" with only Done / Move to Bin. On macOS 15 and later right-click → Open
  does NOT get past this. The recipient has to, once:
    1. Click Done, then open System Settings → Privacy & Security → scroll to
       Security → "Tinker was blocked…" → Open Anyway → Open.
    Or, in Terminal:  xattr -dr com.apple.quarantine /Applications/Tinker.app
  The zip carries "Read me first.txt" saying the same. macOS 14 or later.
SHARE
fi

bold "DMG"
DMG="$BUILD_DIR/Tinker-$VERSION.dmg"
STAGING="$BUILD_DIR/dmg"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
if [[ "$MODE" == "share" ]]; then cp "$SHARE_DIR/Read me first.txt" "$STAGING/"; fi
# A file saved by a sandboxed App Store app (WhatsApp, Telegram, Mail) carries a
# quarantine mark that macOS 15 and later refuses to run, however good the signature:
# spctl reports "File created by an AppSandbox, exec/open not allowed" (seen 2026-09-07
# on two Macs). The note in the image says what to do about it.
cat > "$STAGING/If Tinker won't open.txt" <<NOTE
If double-clicking Tinker shows only "The application 'Tinker' can't be opened":

  The file reached this Mac through WhatsApp, Telegram, Mail or another App Store
  app. macOS marks anything those apps save as not runnable, whatever its signature.
  Either of these fixes it:

    - Terminal:  xattr -dr com.apple.quarantine /Applications/Tinker.app
    - Or fetch the file again over AirDrop or a download link opened in Safari/Chrome.

  Needs macOS 14 or later on an Apple silicon (M-series) Mac. Intel Macs are not supported.
NOTE
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Tinker $VERSION" -srcfolder "$STAGING" \
    -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
if [[ "$MODE" == "full" ]]; then
    # The disk image is notarized separately from the (already stapled) app inside it.
    # It is not code-signed: the Developer ID key is cloud-managed, and notarization
    # does not require the image itself to be signed.
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi
echo "  $DMG"
ls -lh "$DMG" | awk '{print "  " $5}'

# ---------------------------------------------------------------------------
bold "Appcast"
# The feed and key baked into this build: an explicit environment value, else the project's.
FEED_URL="${TINKER_APPCAST_URL:-$(xcodebuild -project App/Tinker.xcodeproj -target Tinker -showBuildSettings 2>/dev/null |
    awk '/ TINKER_APPCAST_URL = / {print $3; exit}')}"
SPARKLE_BIN="$(find .build/DerivedData/SourcePackages/artifacts/sparkle -type d -path "*/Sparkle/bin" 2>/dev/null | head -1)"
APPCAST="$BUILD_DIR/appcast.xml"
if [[ -z "$FEED_URL" ]]; then
    warn "no appcast URL in the build; it cannot check for updates"
elif [[ -z "$SPARKLE_BIN" || ! -x "$SPARKLE_BIN/sign_update" ]]; then
    warn "Sparkle's sign_update was not found under .build/DerivedData; build the app once, then sign $DMG by hand"
elif [[ "$MODE" == "unsigned" ]]; then
    warn "unsigned build: no appcast is written"
else
    # Where the DMG will be downloadable from. A GitHub "latest/download" feed implies the
    # release's own asset URL; any other feed needs TINKER_DOWNLOAD_URL.
    TAG="v$VERSION-$BUILD_NUMBER"
    DOWNLOAD_URL="${TINKER_DOWNLOAD_URL:-}"
    REPO=""
    if [[ "$FEED_URL" =~ ^https://github\.com/([^/]+/[^/]+)/releases/latest/download/appcast\.xml$ ]]; then
        REPO="${BASH_REMATCH[1]}"
        DOWNLOAD_URL="${DOWNLOAD_URL:-https://github.com/$REPO/releases/download/$TAG/$(basename "$DMG")}"
    fi
    if [[ -z "$DOWNLOAD_URL" ]]; then
        warn "the feed $FEED_URL is not a GitHub release feed; set TINKER_DOWNLOAD_URL to where the DMG will live"
    else
        # sign_update prints: sparkle:edSignature="…" length="…"
        SIGNATURE="$("$SPARKLE_BIN/sign_update" "$DMG")"
        [[ "$SIGNATURE" == *edSignature* ]] || fail "sign_update produced no signature (is the Sparkle private key in the keychain?)"
        # What changed: this version's changelog section. The GitHub release gets the Markdown;
        # Sparkle's update window gets HTML (Scripts/release-notes.sh says why).
        NOTES_MD="$BUILD_DIR/release-notes.md"
        Scripts/release-notes.sh "$VERSION" --markdown > "$NOTES_MD"
        NOTES_HTML="$(Scripts/release-notes.sh "$VERSION" --html)"
        if [[ -z "$(tr -d '[:space:]' < "$NOTES_MD")" ]]; then
            echo "Bug fixes and improvements." > "$NOTES_MD"
            NOTES_HTML="<p>Bug fixes and improvements.</p>"
        fi
        cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Tinker</title>
        <description>Tinker releases</description>
        <language>en</language>
        <item>
            <title>Tinker $VERSION ($BUILD_NUMBER)</title>
            <sparkle:version>$BUILD_NUMBER</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <pubDate>$(date -R)</pubDate>
            <description><![CDATA[$NOTES_HTML]]></description>
            <enclosure url="$DOWNLOAD_URL" type="application/octet-stream" $SIGNATURE />
        </item>
    </channel>
</rss>
XML
        echo "  $APPCAST"
        echo "  enclosure $DOWNLOAD_URL"
        echo "  feed      $FEED_URL"
        if [[ "$PUBLISH" == 1 ]]; then
            bold "Publish"
            [[ -n "$REPO" ]] || fail "--publish needs a GitHub release feed (got $FEED_URL)"
            command -v gh >/dev/null || fail "gh is not installed (brew install gh; gh auth login)"
            gh release create "$TAG" "$DMG" "$RELEASE_ZIP" "$APPCAST" \
                --repo "$REPO" --title "Tinker $VERSION ($BUILD_NUMBER)" --notes-file "$NOTES_MD"
            echo "  https://github.com/$REPO/releases/tag/$TAG"
        else
            cat <<PUBLISH
  To publish (the feed reads the latest GitHub release):
    gh release create "$TAG" "$DMG" "$RELEASE_ZIP" "$APPCAST" --repo "$REPO" \\
        --title "Tinker $VERSION ($BUILD_NUMBER)" --notes-file "$NOTES_MD"
  or run Scripts/release.sh --publish next time.
PUBLISH
        fi
    fi
fi

echo
echo "Release build complete."
