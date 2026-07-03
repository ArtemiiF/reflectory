#!/usr/bin/env bash
# validate-frontmatter.sh — sanity-check YAML frontmatter in every *.md file.
#
# Walks the repo, finds every .md file that starts with `---`, and verifies:
#   1. The opening `---` is followed by a closing `---` on its own line.
#   2. Every non-empty line in between is either a comment (#...), a
#      key: value entry, an indented continuation, a list item (- ...), or
#      a YAML block delimiter (`>-`, `|`, `>`).
#
# Pure bash + awk — no PyYAML or other deps required. Not a full YAML
# parser; catches the common defects (missing close delimiter, lines that
# accidentally lost their colon).
#
# Called as the second pre-commit gate (after build-index.sh) from
# /reflect-session Step 6 and /sync-upstream Step 7. Also safe to run
# manually before any ad-hoc commit.

set -euo pipefail

LOCAL_FORKS="${LOCAL_FORKS:-${HOME}/.claude/local-forks}"
cd "${LOCAL_FORKS}"

errors=0
checked=0

while IFS= read -r f; do
  case "${f}" in
    ./.git/*|./_local/*) continue ;;
  esac

  [[ "$(head -1 "${f}")" == "---" ]] || continue
  checked=$((checked + 1))

  if ! awk '
    NR == 1 { next }
    /^---[[:space:]]*$/ { found_close = 1; exit }
    /^[[:space:]]*$/    { next }
    /^[[:space:]]*#/    { next }
    /^[[:space:]]+/     { next }      # indented continuation
    /^-[[:space:]]/     { next }      # list item
    /^[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*:/ { next }  # key: value
    {
      printf "  line %d: unexpected frontmatter content: %s\n", NR, $0 > "/dev/stderr"
      bad = 1
    }
    END {
      if (!found_close) {
        print "  missing closing --- delimiter" > "/dev/stderr"
        exit 1
      }
      if (bad) exit 1
    }
  ' "${f}"; then
    echo "${f}: frontmatter validation failed" >&2
    errors=$((errors + 1))
  fi
done < <(find . -name "*.md" -type f 2>/dev/null)

if (( errors > 0 )); then
  echo "${errors} frontmatter error(s) in ${checked} checked file(s)." >&2
  exit 1
fi

echo "OK — ${checked} markdown file(s) with frontmatter validated."
