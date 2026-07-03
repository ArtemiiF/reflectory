#!/usr/bin/env bash
# list-sessions.sh — pick the largest Claude Code session transcripts for /reflect-archive.
#
# Lists top-level session .jsonl files (the ones the user actually drives), largest first,
# after dropping the noise:
#   - /subagents/ transcripts        (parts of a parent session, not standalone sessions)
#   - the live/current session        (newest mtime — it is still being appended; drop unless
#                                       --include-current, or override with --exclude)
#   - already-studied sessions         (uuids recorded in `source_sessions:` of _sessions/*.md)
#   - anything listed via --exclude
#
# Selection: top N by size (default 3), optionally floored at --min-bytes.
#
# Output (one row per session, tab-separated, largest first):
#   <bytes>\t<uuid>\t<absolute-path>
#
# Deterministic given the filesystem state. Pure bash + awk + find. No network.
#
# Usage:
#   list-sessions.sh [--top N] [--min-bytes BYTES] [--exclude UUID]...
#                    [--include-current] [--projects-dir DIR]

set -euo pipefail

LOCAL_FORKS="${LOCAL_FORKS:-${HOME}/.claude/local-forks}"
PROJECTS_DIR="${HOME}/.claude/projects"

top=3
min_bytes=0
include_current=0
declare -a excludes=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --top)             top="$2"; shift 2 ;;
    --min-bytes)       min_bytes="$2"; shift 2 ;;
    --exclude)         excludes+=("$2"); shift 2 ;;
    --include-current) include_current=1; shift ;;
    --projects-dir)    PROJECTS_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "list-sessions: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -d "${PROJECTS_DIR}" ]]; then
  echo "list-sessions: no projects dir: ${PROJECTS_DIR}" >&2
  exit 2
fi

# --- uuids already analysed in a previous /reflect-* run --------------------
# Parse the `source_sessions:` YAML block list from every session log.
declare -A studied=()
if [[ -d "${LOCAL_FORKS}/_sessions" ]]; then
  while IFS= read -r u; do
    [[ -n "${u}" ]] && studied["${u}"]=1
  done < <(
    awk '
      /^source_sessions:[[:space:]]*$/ { inblock=1; next }
      inblock && /^[[:space:]]*-[[:space:]]*/ {
        line=$0
        sub(/^[[:space:]]*-[[:space:]]*/, "", line)
        gsub(/[[:space:]]/, "", line)
        if (line != "") print line
        next
      }
      inblock { inblock=0 }
    ' "${LOCAL_FORKS}/_sessions"/*.md 2>/dev/null
  )
fi

# explicit --exclude uuids
for e in "${excludes[@]:-}"; do
  [[ -n "${e}" ]] && studied["${e}"]=1
done

# --- gather top-level session files: projects/<project>/<uuid>.jsonl --------
# mindepth/maxdepth 2 keeps us at the session level and skips /subagents/.
# Collect "mtime<TAB>size<TAB>path" so we can both find the newest (current) and sort by size.
mapfile -t rows < <(
  find "${PROJECTS_DIR}" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' \
       -printf '%T@\t%s\t%p\n' 2>/dev/null
)

if [[ ${#rows[@]} -eq 0 ]]; then
  echo "list-sessions: no session transcripts under ${PROJECTS_DIR}" >&2
  exit 0
fi

# newest mtime = current/live session (unless caller opts in to include it)
current_path=""
if [[ "${include_current}" -eq 0 ]]; then
  current_path="$(printf '%s\n' "${rows[@]}" | sort -t$'\t' -k1,1 -rn | head -1 | cut -f3)"
fi

# --- filter + sort by size desc + take top N --------------------------------
printf '%s\n' "${rows[@]}" \
  | sort -t$'\t' -k2,2 -rn \
  | awk -F'\t' \
        -v top="${top}" -v minb="${min_bytes}" -v cur="${current_path}" \
        -v studied_list="$(printf '%s ' "${!studied[@]}")" '
    BEGIN {
      n = split(studied_list, a, " ")
      for (i = 1; i <= n; i++) if (a[i] != "") skip[a[i]] = 1
    }
    {
      size = $2; path = $3
      if (path == cur) next                 # live session
      uuid = path
      sub(/.*\//, "", uuid); sub(/\.jsonl$/, "", uuid)
      if (uuid in skip) next                 # already studied / explicit exclude
      if (size + 0 < minb + 0) next          # below floor
      print size "\t" uuid "\t" path
      kept++
      if (top > 0 && kept >= top) exit
    }
  '
