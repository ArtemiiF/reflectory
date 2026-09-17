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
excludes=()

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

# --- selection core -----------------------------------------------------------
# Implemented in python3 (present on every target machine): bash 3.2 on macOS has no
# `declare -A` / `mapfile`, and BSD `find` has no `-printf`, so the previous pure-bash
# core failed on this machine with `declare: -A: invalid option` before printing a row.
PROJECTS_DIR="${PROJECTS_DIR}" LOCAL_FORKS="${LOCAL_FORKS}" \
TOP="${top}" MIN_BYTES="${min_bytes}" INCLUDE_CURRENT="${include_current}" \
EXCLUDES="${excludes[*]:-}" python3 -c '
# -*- coding: utf-8 -*-
import io, os, re, sys

projects = os.environ["PROJECTS_DIR"]
forks    = os.environ["LOCAL_FORKS"]
top      = int(os.environ.get("TOP") or 3)
min_b    = int(os.environ.get("MIN_BYTES") or 0)
inc_cur  = os.environ.get("INCLUDE_CURRENT") == "1"
skip     = set(x for x in (os.environ.get("EXCLUDES") or "").split() if x)

# uuids recorded in a previous run: the `source_sessions:` YAML block of each session log
sessions_dir = os.path.join(forks, "_sessions")
if os.path.isdir(sessions_dir):
    for name in sorted(os.listdir(sessions_dir)):
        if not name.endswith(".md"):
            continue
        inblock = False
        for line in io.open(os.path.join(sessions_dir, name), encoding="utf-8", errors="replace"):
            if re.match(r"^source_sessions:\s*$", line):
                inblock = True
                continue
            if inblock:
                m = re.match(r"^\s*-\s*(\S+)", line)
                if m:
                    skip.add(m.group(1))
                else:
                    inblock = False

# top-level session files only: projects/<project>/<uuid>.jsonl (never /subagents/)
rows = []
if not os.path.isdir(projects):
    sys.stderr.write("list-sessions: no projects dir: %s\n" % projects)
    sys.exit(2)
for proj in os.listdir(projects):
    d = os.path.join(projects, proj)
    if not os.path.isdir(d):
        continue
    for fn in os.listdir(d):
        if not fn.endswith(".jsonl"):
            continue
        path = os.path.join(d, fn)
        try:
            st = os.stat(path)
        except OSError:
            continue
        rows.append((st.st_mtime, st.st_size, path, fn[:-6]))

if not rows:
    sys.stderr.write("list-sessions: no session transcripts under %s\n" % projects)
    sys.exit(0)

current = "" if inc_cur else max(rows)[2]   # newest mtime = live session

kept = 0
for mtime, size, path, uuid in sorted(rows, key=lambda r: -r[1]):
    if path == current:      continue
    if uuid in skip:         continue
    if size < min_b:         continue
    sys.stdout.write("%d\t%s\t%s\n" % (size, uuid, path))
    kept += 1
    if top > 0 and kept >= top:
        break
'
