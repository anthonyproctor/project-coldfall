#!/usr/bin/env bash
# Builds libghostty (GhosttyKit.xcframework) into app/Vendor/, so the next
# `swift build` includes Ghostty's terminal. Without it, Coldfall builds with
# SwiftTerm only, exactly as before.
#
#   scripts/ghostty-kit.sh            # the pinned commit below
#
# Needs Zig (0.17 or later: `brew install zig`) and Apple's Metal toolchain
# (`xcodebuild -downloadComponent MetalToolchain`, about 840 MB, once).
#
# Pinned to one commit. Ghostty's embedding API (ghostty.h) is what its own
# Mac app uses and is not promised stable, so moving the pin is a change to
# test, not something that happens on its own.
set -euo pipefail

GHOSTTY_COMMIT=46f1cea1a10a19bef97a8a0f5948e660d0b74fe2
here="$(cd "$(dirname "$0")/.." && pwd)"
vendor="$here/app/Vendor"
src="$vendor/ghostty-src"

command -v zig >/dev/null || { echo "needs zig 0.17+ (brew install zig)"; exit 1; }
xcrun -f metal >/dev/null 2>&1 || { echo "needs the Metal toolchain (xcodebuild -downloadComponent MetalToolchain)"; exit 1; }

mkdir -p "$vendor"
if [ ! -d "$src/.git" ]; then
  git init -q "$src"
  git -C "$src" remote add origin https://github.com/ghostty-org/ghostty
fi
if [ "$(git -C "$src" rev-parse HEAD 2>/dev/null || true)" != "$GHOSTTY_COMMIT" ]; then
  git -C "$src" fetch -q --depth 1 origin "$GHOSTTY_COMMIT"
  git -C "$src" checkout -q --detach FETCH_HEAD
fi

( cd "$src" && zig build -Demit-xcframework=true -Demit-macos-app=false \
    -Dxcframework-target=native -Doptimize=ReleaseFast )

rm -rf "$vendor/GhosttyKit.xcframework"
cp -R "$src/macos/GhosttyKit.xcframework" "$vendor/"
echo "built $vendor/GhosttyKit.xcframework ($GHOSTTY_COMMIT)"
