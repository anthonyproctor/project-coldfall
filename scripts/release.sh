#!/usr/bin/env bash
# The whole release, in order, stopping at the first thing that fails.
#
#   scripts/release.sh 0.3.54 "One line for the top of the changelog entry"
#   scripts/release.sh 0.3.54 "..." --dry-run      # checks, then shows the edits; changes nothing
#   scripts/release.sh 0.3.54 "..." --skip-soak    # without the 10-minute soak run
#
# 1. preflight   main, up to date with origin, clean tree, version not tagged,
#                something under ## [Unreleased], gh and vercel present
# 2. checks      what CI runs (.github/workflows/ci.yml), then scripts/soak.py
# 3. commit      changelog entry, compare links, the site's softwareVersion;
#                "Release X.Y.Z" and the tag vX.Y.Z
# 4. push        main and the tag; waits for CI on that commit
# 5. build       scripts/build-app.sh, then scripts/release-zip.sh
# 6. publish     the GitHub release, notes from the changelog entry
# 7. verify      the published zip as a stranger gets it
# 8. site        vercel deploy, then the live page says X.Y.Z
#
# It never POSTs to the site's /api/check (each POST counts as an install),
# and it never restarts Coldfall: that is the person's call.
set -euo pipefail

say()  { printf '\n== %s\n' "$*"; }
fail() { printf '\nrelease: %s\n' "$*" >&2; exit 1; }

VERSION="${1:-}"; SUMMARY="${2:-}"
[ -n "$VERSION" ] && [ -n "$SUMMARY" ] || fail 'usage: scripts/release.sh X.Y.Z "One-line summary" [--skip-soak] [--dry-run]'
shift 2
SKIP_SOAK=0; DRY=0
for a in "$@"; do
  case "$a" in
    --skip-soak) SKIP_SOAK=1 ;;
    --dry-run)   DRY=1 ;;
    *) fail "unknown option: $a" ;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must look like 0.3.54, not $VERSION"
TAG="v$VERSION"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TODAY="$(date +%Y-%m-%d)"
SITE="https://project-coldfall.vercel.app/"
TRAILER="Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Mcgo7ufTDwjrTogDtnVcfd"

# ---------------------------------------------------------------- 1. preflight
say "1. preflight"
for t in git gh vercel swift npm python3 codesign; do
  command -v "$t" >/dev/null || fail "$t isn't on PATH"
done
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail "not on main"
[ -z "$(git status --porcelain)" ] || fail "the working tree has changes; commit your work first (git status)"
git fetch -q origin main --tags
[ "$(git rev-list --count HEAD..origin/main)" = 0 ] || fail "main is behind origin/main; pull first"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "$TAG is already tagged"
PREV="$(git describe --tags --abbrev=0 --match 'v[0-9]*')" || fail "no earlier release tag found"
python3 - <<'EOF' || fail "CHANGELOG.md has nothing under ## [Unreleased]"
import re, sys
s = open("CHANGELOG.md").read()
m = re.search(r"^## \[Unreleased\]\n(.*?)(?=^## \[)", s, re.S | re.M)
sys.exit(0 if m and m.group(1).strip() else 1)
EOF
echo "releasing $TAG after $PREV"

# ---------------------------------------------------------------- 2. checks (as CI)
say "2. checks"
( cd app && swift build -c release ) || fail "build failed"
( cd app && ./.build/release/coldfall-test ) || fail "tests failed"
( cd server && npm ci --silent && npm test ) || fail "server tests failed"
if (cd app && grep -rlE '^import (AppKit|SwiftUI|UIKit|PDFKit|SwiftTerm)' Sources/ColdfallCore/); then
  fail "ColdfallCore imported a UI framework"
fi
echo "core: Foundation only"
(
  cd app
  allowed='Sources/ColdfallCore/Bridge.swift Sources/ColdfallCore/Fanout.swift'
  found=$(grep -rlnE '\.argv[[:space:]]*\(|"-p",' Sources/ | grep -v 'Sources/ColdfallTests/' | sort || true)
  for f in $found; do
    case " $allowed " in
      *" $f "*) ;;
      *) echo "$f runs a vendor CLI with a prompt; only agent mail and fan out may"; exit 1 ;;
    esac
  done
  echo "spend guard: clean"
) || fail "spend guard"
hits=$(git ls-files -z '*.swift' '*.toml' '*.md' '*.yml' '*.sh' \
       | xargs -0 grep -InE '/Users/[a-z]' 2>/dev/null \
       | grep -v '/Users/<' || true)
[ -z "$hits" ] || { echo "$hits"; fail "an absolute home path is committed"; }
echo "privacy guard: clean"
if [ "$SKIP_SOAK" = 0 ]; then
  scripts/soak.py || fail "soak run failed (see above)"
else
  echo "soak: skipped (--skip-soak)"
fi

# ---------------------------------------------------------------- 3. release commit
# The edits, written to the paths given (the real files, or copies for --dry-run).
edit() {
  python3 - "$1" "$2" "$VERSION" "$SUMMARY" "$TODAY" "$PREV" <<'EOF'
import sys
cl_path, ix_path, ver, summary, today, prev = sys.argv[1:]
def once(s, old, new, what):
    n = s.count(old)
    if n != 1: sys.exit(f"release: {what}: expected one match, found {n}")
    return s.replace(old, new)
s = open(cl_path).read()
s = once(s, "## [Unreleased]\n", f"## [Unreleased]\n\n## [{ver}] - {today}\n\n{summary}\n", "changelog heading")
s = s.replace(f"## [{ver}] - {today}\n\n{summary}\n\n\n", f"## [{ver}] - {today}\n\n{summary}\n\n")
base = "https://github.com/anthonyproctor/project-coldfall/compare/"
s = once(s, f"[Unreleased]: {base}{prev}...HEAD",
         f"[Unreleased]: {base}v{ver}...HEAD\n[{ver}]: {base}{prev}...v{ver}", "changelog links")
open(cl_path, "w").write(s)
import re
t = open(ix_path).read()
found = re.findall(r'"softwareVersion":"[^"]*"', t)
if len(found) != 1: sys.exit(f"release: softwareVersion: expected one match, found {len(found)}")
t = t.replace(found[0], f'"softwareVersion":"{ver}"')
open(ix_path, "w").write(t)
EOF
}

if [ "$DRY" = 1 ]; then
  say "3. the edits (dry run: nothing changed)"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  cp CHANGELOG.md "$tmp/CHANGELOG.md"; cp server/public/index.html "$tmp/index.html"
  edit "$tmp/CHANGELOG.md" "$tmp/index.html"
  diff -u CHANGELOG.md "$tmp/CHANGELOG.md" || true
  diff -u server/public/index.html "$tmp/index.html" || true
  echo; echo "dry run done: checks passed, nothing was committed, tagged, pushed or published."
  exit 0
fi

say "3. release commit"
edit CHANGELOG.md server/public/index.html
git add CHANGELOG.md server/public/index.html
git commit -q -m "Release $VERSION" -m "$TRAILER"
git tag "$TAG"
SHA="$(git rev-parse HEAD)"
echo "committed ${SHA:0:7}, tagged $TAG"

# ---------------------------------------------------------------- 4. push, wait for CI
say "4. push and CI"
git push -q origin main "$TAG"
RUN=""
for _ in $(seq 1 30); do
  RUN="$(gh run list --workflow ci.yml --commit "$SHA" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
  [ -n "$RUN" ] && break
  sleep 5
done
[ -n "$RUN" ] || fail "no CI run appeared for ${SHA:0:7}"
gh run watch "$RUN" --exit-status >/dev/null || fail "CI failed: gh run view $RUN --log-failed"
echo "CI passed (run $RUN)"

# ---------------------------------------------------------------- 5. build and zip
say "5. build"
scripts/build-app.sh
APP="$HOME/Applications/Project Coldfall.app"
got="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
[ "$got" = "$TAG" ] || fail "the bundle says $got, not $TAG"
scripts/release-zip.sh
ZIP="dist/Project-Coldfall.app.zip"
[ -f "$ZIP" ] || fail "no $ZIP"

# ---------------------------------------------------------------- 6. publish
say "6. GitHub release"
NOTES="$(mktemp)"
python3 - "$VERSION" > "$NOTES" <<'EOF'
import sys
v = sys.argv[1]; s = open("CHANGELOG.md").read()
a = s.index(f"## [{v}]"); b = s.index("\n## [", a + 1)
print(s[a:b].split("\n", 1)[1].strip())
EOF
[ -s "$NOTES" ] || fail "empty release notes"
gh release create "$TAG" "$ZIP" --title "$VERSION" --notes-file "$NOTES"
rm -f "$NOTES"

# ---------------------------------------------------------------- 7. verify the download
say "7. verify the published zip"
V="$(mktemp -d)"
(
  cd "$V"
  gh release download "$TAG" -R anthonyproctor/project-coldfall -p "Project-Coldfall.app.zip"
  unzip -q Project-Coldfall.app.zip
  codesign --verify --deep --strict "Project Coldfall.app"
  if grep -rlF "$HOME" "Project Coldfall.app" >/dev/null || grep -rlF "$USER" "Project Coldfall.app" >/dev/null; then
    echo "the download contains $HOME or $USER"; exit 1
  fi
  dv="$(defaults read "$V/Project Coldfall.app/Contents/Info.plist" CFBundleShortVersionString)"
  [ "$dv" = "$TAG" ] || { echo "the download says $dv"; exit 1; }
) || fail "the published zip didn't verify (left in $V)"
rm -rf "$V"
latest="$(gh api repos/anthonyproctor/project-coldfall/releases/latest -q .tag_name)"
[ "$latest" = "$TAG" ] || fail "GitHub's latest release is $latest, not $TAG"
echo "download: signature ok, no home path or user name, version $TAG, marked latest"

# ---------------------------------------------------------------- 8. site
say "8. site"
site_ok() { curl -fsS "$SITE" | grep -q "\"softwareVersion\":\"$VERSION\""; }
( cd server && vercel deploy --prod --yes >/dev/null )
ok=0
for _ in $(seq 1 6); do site_ok && { ok=1; break; }; sleep 10; done
if [ "$ok" = 0 ]; then
  echo "the site doesn't say $VERSION yet; deploying once more"
  ( cd server && vercel deploy --prod --yes >/dev/null )
  for _ in $(seq 1 6); do site_ok && { ok=1; break; }; sleep 10; done
fi
[ "$ok" = 1 ] || fail "the site still doesn't say $VERSION"
echo "site says $VERSION"

# ---------------------------------------------------------------- 9. done
say "released $TAG"
echo "  https://github.com/anthonyproctor/project-coldfall/releases/tag/$TAG"
echo "  local bundle: $APP"
echo "Coldfall was NOT restarted. The running app keeps the old version until"
echo "whoever runs it quits and reopens it (held desks keep running through that)."
