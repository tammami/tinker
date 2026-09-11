#!/usr/bin/env bash
# Scripts/test-release-notes.sh — checks Scripts/release-notes.sh, which turns a CHANGELOG
# section into the notes Sparkle's update window shows. No network, no build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTES="$ROOT/Scripts/release-notes.sh"
WORK="$(mktemp -d -t tinker-release-notes)"
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { echo "  ok   $1"; }
failed() { echo "  FAIL $1"; failures=$((failures + 1)); }
# name, expected file, actual file
same() {
    if diff -u "$2" "$3" > "$WORK/diff"; then pass "$1"; else failed "$1"; cat "$WORK/diff"; fi
}

cat > "$WORK/CHANGELOG.md" <<'MD'
# Changelog

An intro paragraph that is not part of any release.

## [Unreleased]

## [9.9.9] - 2026-01-01

A short summary that
wraps onto a second line.

### Added
- **Bold that wraps
  across lines.** Then `code that
  wraps` and `a**b` stay code.
- Escapes <tags> & ampersands.

### Fixed
* Star bullets too.

## [9.9.8] - 2025-12-31

- Older entry.

[9.9.9]: https://example.com/9.9.9
[9.9.8]: https://example.com/9.9.8
MD

# A section below an empty [Unreleased]: joined lines, bold and code across line breaks,
# escaping, a paragraph, both bullet markers.
cat > "$WORK/expected-9.9.9.html" <<'HTML'
<p>A short summary that wraps onto a second line.</p>
<h3>Added</h3>
<ul>
<li><b>Bold that wraps across lines.</b> Then <code>code that wraps</code> and <code>a&#42;&#42;b</code> stay code.</li>
<li>Escapes &lt;tags&gt; &amp; ampersands.</li>
</ul>
<h3>Fixed</h3>
<ul>
<li>Star bullets too.</li>
</ul>
HTML
"$NOTES" 9.9.9 --html "$WORK/CHANGELOG.md" > "$WORK/actual-9.9.9.html"
if head -1 "$WORK/actual-9.9.9.html" | grep -q '^<style>.*</style>$'; then
    pass "html starts with its stylesheet"
else
    failed "html starts with its stylesheet"
fi
tail -n +2 "$WORK/actual-9.9.9.html" > "$WORK/body-9.9.9.html"
same "html: headings, lists, paragraph, inline markup, escaping" "$WORK/expected-9.9.9.html" "$WORK/body-9.9.9.html"

# The last section stops before the link references.
cat > "$WORK/expected-9.9.8.html" <<'HTML'
<ul>
<li>Older entry.</li>
</ul>
HTML
"$NOTES" 9.9.8 "$WORK/CHANGELOG.md" | tail -n +2 > "$WORK/body-9.9.8.html"
same "html is the default; link references are left out" "$WORK/expected-9.9.8.html" "$WORK/body-9.9.8.html"

# Markdown is the section as written.
cat > "$WORK/expected-9.9.9.md" <<'MD'

A short summary that
wraps onto a second line.

### Added
- **Bold that wraps
  across lines.** Then `code that
  wraps` and `a**b` stay code.
- Escapes <tags> & ampersands.

### Fixed
* Star bullets too.

MD
"$NOTES" 9.9.9 --markdown "$WORK/CHANGELOG.md" > "$WORK/actual-9.9.9.md"
same "markdown is the section verbatim" "$WORK/expected-9.9.9.md" "$WORK/actual-9.9.9.md"

# A version without a section fails, and says which.
if "$NOTES" 1.2.3 "$WORK/CHANGELOG.md" > "$WORK/missing.out" 2> "$WORK/missing.err"; then
    failed "a missing section exits non-zero"
elif grep -q '1\.2\.3' "$WORK/missing.err" && [[ ! -s "$WORK/missing.out" ]]; then
    pass "a missing section exits non-zero, names the version, prints nothing"
else
    failed "a missing section names the version and prints nothing"
fi

# Every section of the real changelog converts cleanly.
versions="$(grep -oE '^## \[[0-9][^]]*\]' "$ROOT/CHANGELOG.md" | sed -E 's/^## \[(.*)\]$/\1/')"
[[ -n "$versions" ]] || failed "the real changelog has release sections"
count() { grep -o "$1" <<< "$2" | wc -l | tr -d ' '; }
for version in $versions; do
    html="$("$NOTES" "$version" --html)"
    problems=""
    if grep -q '\*\*' <<< "$html"; then problems+=" leftover-**"; fi
    if grep -q '`' <<< "$html"; then problems+=" leftover-backtick"; fi
    if [[ "$(count '<ul>' "$html")" != "$(count '</ul>' "$html")" ]]; then problems+=" unbalanced-ul"; fi
    if [[ "$(count '<li>' "$html")" != "$(count '</li>' "$html")" ]]; then problems+=" unbalanced-li"; fi
    if [[ "$(count '<b>' "$html")" != "$(count '</b>' "$html")" ]]; then problems+=" unbalanced-b"; fi
    if [[ "$(count '<code>' "$html")" != "$(count '</code>' "$html")" ]]; then problems+=" unbalanced-code"; fi
    if [[ "$(count '<li>' "$html")" == 0 ]]; then problems+=" no-items"; fi
    if [[ -z "$problems" ]]; then pass "CHANGELOG [$version] converts cleanly"; else failed "CHANGELOG [$version]:$problems"; fi
done

if [[ $failures -gt 0 ]]; then
    echo "$failures release-notes check(s) failed" >&2
    exit 1
fi
