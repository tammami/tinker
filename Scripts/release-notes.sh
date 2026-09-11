#!/usr/bin/env bash
# Scripts/release-notes.sh — one version's CHANGELOG section, as release notes.
#
#   Scripts/release-notes.sh <version> [--html | --markdown] [changelog]
#
#   --html      (default) for Sparkle's update window: headings, bullet lists, paragraphs,
#               **bold** and `code`, with the lines of each bullet or paragraph joined.
#               The changelog is hard-wrapped near 90 columns; shown verbatim in a <pre>,
#               those breaks and the Markdown punctuation reached the window as they were.
#   --markdown  the section as written, for the GitHub release page.
#
# The section is the one headed "## [<version>]", wherever it sits, so an empty
# "## [Unreleased]" above it changes nothing. Link reference lines ("[x]: url") are left
# out. Exits 1 when the changelog has no such section.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ $# -ge 1 ]] || { echo "usage: Scripts/release-notes.sh <version> [--html | --markdown] [changelog]" >&2; exit 2; }
VERSION="$1"
shift
FORMAT="html"
CHANGELOG="$ROOT/CHANGELOG.md"
for argument in "$@"; do
    case "$argument" in
        --html) FORMAT="html" ;;
        --markdown) FORMAT="markdown" ;;
        -*) echo "unknown argument: $argument" >&2; exit 2 ;;
        *) CHANGELOG="$argument" ;;
    esac
done
[[ -f "$CHANGELOG" ]] || { echo "no changelog at $CHANGELOG" >&2; exit 2; }

awk -v version="$VERSION" -v format="$FORMAT" '
    function escape(s) {
        gsub(/&/, "\\&amp;", s)
        gsub(/</, "\\&lt;", s)
        gsub(/>/, "\\&gt;", s)
        return s
    }
    # Code spans first, with their asterisks made inert, then bold.
    function markup(s,    out, code) {
        s = escape(s)
        out = ""
        while (match(s, /`[^`]+`/)) {
            code = substr(s, RSTART + 1, RLENGTH - 2)
            gsub(/\*/, "\\&#42;", code)
            out = out substr(s, 1, RSTART - 1) "<code>" code "</code>"
            s = substr(s, RSTART + RLENGTH)
        }
        s = out s
        out = ""
        while (match(s, /\*\*[^*]+\*\*/)) {
            out = out substr(s, 1, RSTART - 1) "<b>" substr(s, RSTART + 2, RLENGTH - 4) "</b>"
            s = substr(s, RSTART + RLENGTH)
        }
        return out s
    }
    function flush_block() {
        if (text != "") {
            if (kind == "li") print "<li>" markup(text) "</li>"
            else print "<p>" markup(text) "</p>"
        }
        text = ""
    }
    function close_list() {
        flush_block()
        if (in_list) { print "</ul>"; in_list = 0 }
    }
    function trimmed(s) {
        sub(/^[ \t]+/, "", s)
        sub(/[ \t]+$/, "", s)
        return s
    }

    /^## / {
        if (found) exit
        if (index($0, "## [" version "]") == 1) {
            found = 1
            if (format == "html") {
                print "<style>body{font:13px -apple-system,sans-serif;line-height:1.4}" \
                    "h1,h2,h3,h4{font-size:13px;margin:12px 0 4px}p{margin:0 0 8px}" \
                    "ul{margin:0 0 8px;padding-left:18px}li{margin:0 0 6px}" \
                    "code{font:12px ui-monospace,Menlo,monospace}</style>"
            }
        }
        next
    }
    !found { next }
    /^\[[^]]+\]: / { next }
    format == "markdown" { print; next }

    /^[ \t]*$/ { close_list(); next }
    /^#+ / {
        close_list()
        level = index($0, " ") - 1
        tag = "h" (level > 4 ? 4 : level)
        print "<" tag ">" markup(trimmed(substr($0, level + 2))) "</" tag ">"
        next
    }
    /^[-*] / {
        flush_block()
        if (!in_list) { print "<ul>"; in_list = 1 }
        kind = "li"
        text = trimmed(substr($0, 3))
        next
    }
    # An indented line carries on the bullet or paragraph above it.
    /^[ \t]+/ && text != "" { text = text " " trimmed($0); next }
    {
        if (kind == "p" && text != "") { text = text " " trimmed($0); next }
        close_list()
        kind = "p"
        text = trimmed($0)
    }

    END {
        if (!found) exit 1
        close_list()
    }
' "$CHANGELOG" || { echo "CHANGELOG has no \"## [$VERSION]\" section" >&2; exit 1; }
