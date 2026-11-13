#!/usr/bin/env bash
# Builds Project Coldfall.app — a real macOS bundle you can double-click, keep in
# /Applications and pin to the Dock.
#
# This matters beyond polish. A binary launched from a terminal inherits that
# terminal's environment, which is how a stray CLAUDECODE variable can leak in
# and stop a nested agent session from starting. A bundle launched from Finder
# gets a clean environment from launchd instead.
set -euo pipefail

cd "$(dirname "$0")/../app"
DEST="${1:-$HOME/Applications}/Project Coldfall.app"
# Assembled here and moved into place only once it's whole: a failed build or
# copy leaves the installed app exactly as it was.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Project Coldfall.app"
VERSION="$(git -C .. describe --tags --always 2>/dev/null || echo 0.1.0)"
SOURCE_ROOT="$(cd .. && pwd)"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Ghostty's terminal goes in when scripts/ghostty-kit.sh has built its
# library on this Mac (see Package.swift). Without it, or with
# COLDFALL_GHOSTTY=0, the app is built with SwiftTerm alone, as it always was.
if [ "${COLDFALL_GHOSTTY:-}" != "0" ] && [ -d Vendor/GhosttyKit.xcframework ]; then
  export COLDFALL_GHOSTTY=1
  echo "building, with Ghostty's terminal…"
else
  export COLDFALL_GHOSTTY=0
  echo "building…"
fi
# A build that didn't finish stops here. (SwiftPM can report a build-database
# error after a complete build on a synced folder; "Build complete!" is what
# counts.)
LOG="$STAGE/build.log"
if swift build -c release >"$LOG" 2>&1 || grep -q "Build complete!" "$LOG"; then
  grep -vE "build database|^\[" "$LOG" || true
else
  grep -vE "^\[" "$LOG" | tail -30
  echo "build failed; the installed app is untouched"
  exit 1
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Ghostty is MIT licensed: its notice travels with any build that links it.
if [ "$COLDFALL_GHOSTTY" = "1" ] && [ -f Vendor/ghostty-src/LICENSE ]; then
  cp Vendor/ghostty-src/LICENSE "$APP/Contents/Resources/Ghostty-LICENSE.txt"
fi
cp .build/release/Coldfall "$APP/Contents/MacOS/Coldfall"
# Ship the headless core alongside it, so `coldfall-cli` is available without a
# second build.
cp .build/release/coldfall-cli "$APP/Contents/MacOS/coldfall-cli"
# Keeps desks running when the app quits (see Holder in ColdfallCore).
cp .build/release/coldfall-holder "$APP/Contents/MacOS/coldfall-holder"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                 <string>Project Coldfall</string>
  <key>CFBundleDisplayName</key>          <string>Project Coldfall</string>
  <key>CFBundleIdentifier</key>           <string>dev.projectcoldfall.app</string>
  <key>CFBundleExecutable</key>           <string>Coldfall</string>
  <key>CFBundleIconFile</key>             <string>AppIcon</string>
  <key>CFBundlePackageType</key>          <string>APPL</string>
  <key>CFBundleShortVersionString</key>   <string>${VERSION}</string>
  <key>CFBundleVersion</key>              <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>       <string>13.0</string>
  <key>NSHighResolutionCapable</key>      <true/>
  <!-- Terminals live here; the app is not a document editor. -->
  <key>LSApplicationCategoryType</key>    <string>public.app-category.developer-tools</string>
  <!-- Programs run in a desk are Coldfall's children, so macOS asks about the
       microphone and camera on Coldfall's behalf. Without these keys it
       doesn't ask at all: it kills the program (SIGABRT, exit 134) the moment
       it opens the mic. A meeting recorder run from a desk died that way. -->
  <key>NSMicrophoneUsageDescription</key> <string>Programs you run in a desk, such as recorders or voice tools, can use the microphone.</string>
  <key>NSCameraUsageDescription</key>     <string>Programs you run in a desk can use the camera.</string>
  <!-- Where this bundle was built from, so the app can rebuild and update
       itself without the user opening a terminal. Absent in a bundle shipped
       without source, and the app says so rather than guessing. -->
  <key>DWSourceRoot</key>                 <string>${SOURCE_ROOT}</string>
  <key>DWBuiltAt</key>                    <string>${BUILT_AT}</string>
</dict>
</plist>
PLIST

if [ -f ../assets/AppIcon.icns ]; then
  cp ../assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature. Without it macOS nags on every launch; with it the app runs
# on the machine that built it. Not a substitute for a Developer ID for
# distribution, and the README says so.
# Sign with the local certificate if there is one, ad-hoc otherwise.
#
# Ad-hoc is the default because it needs nothing. But an ad-hoc signature is
# a hash of the binary, and macOS remembers privacy grants against the
# signature — so every rebuild re-triggers "would like to access your
# Documents folder". scripts/make-signing-cert.sh creates a stable local
# identity that fixes it; see that script for why and how to undo.
IDENTITY="Project Coldfall Local"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1 \
   && codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "  signed with \"$IDENTITY\" — permissions will persist across rebuilds"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (unsigned — Gatekeeper will ask once)"
  echo "  ad-hoc signed — macOS will re-ask for permissions after each rebuild."
  echo "  run ./scripts/make-signing-cert.sh once to stop that."
fi

rm -rf "$DEST"
mv "$APP" "$DEST"
APP="$DEST"
echo "built $APP"
echo "  open it:    open '$APP'"
echo "  cli:        '$APP/Contents/MacOS/coldfall-cli' usage"
