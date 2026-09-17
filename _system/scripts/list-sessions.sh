#!/usr/bin/env bash
# list-sessions.sh — pick the largest agent session transcripts for /reflect-archive.
#
# Covers both agents: Claude Code under ~/.claude/projects/<project>/<uuid>.jsonl and
# Codex under ~/.codex/sessions/<Y>/<M>/<D>/rollout-<ts>-<uuid>.jsonl. Select with
# --agent claude|codex|all (default: every agent whose session directory exists).
# The row carries the agent so the caller knows which format the file is in —
# session-digest.py detects it anyway, but a reflection report should say.
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
#   <bytes>\t<uuid>\t<absolute-path>\t<agent>
#
# Deterministic given the filesystem state. Pure bash + awk + find. No network.
#
# Usage:
#   list-sessions.sh [--top N] [--min-bytes BYTES] [--exclude UUID]...
#                    [--include-current] [--projects-dir DIR] [--codex-dir DIR]
#                    [--agent claude|codex|all]

set -euo pipefail

LOCAL_FORKS="${LOCAL_FORKS:-${HOME}/.claude/local-forks}"
PROJECTS_DIR="${HOME}/.claude/projects"
CODEX_DIR="${CODEX_HOME:-${HOME}/.codex}/sessions"
agent="all"

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
    --codex-dir)       CODEX_DIR="$2"; shift 2 ;;
    --agent)           agent="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "list-sessions: unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "${agent}" in
  claude|codex|all) ;;
  *) echo "list-sessions: --agent must be claude, codex or all (got '${agent}')" >&2; exit 2 ;;
esac

# A machine may run either agent or both; only the absence of EVERY requested
# source is an error.
have_claude=0; [[ -d "${PROJECTS_DIR}" ]] && have_claude=1
have_codex=0;  [[ -d "${CODEX_DIR}" ]] && have_codex=1
case "${agent}" in
  claude) (( have_claude )) || { echo "list-sessions: no projects dir: ${PROJECTS_DIR}" >&2; exit 2; } ;;
  codex)  (( have_codex ))  || { echo "list-sessions: no codex sessions dir: ${CODEX_DIR}" >&2; exit 2; } ;;
  all)    (( have_claude || have_codex )) || {
            echo "list-sessions: neither ${PROJECTS_DIR} nor ${CODEX_DIR} exists" >&2; exit 2; } ;;
esac

# --- selection core -----------------------------------------------------------
# Implemented in python3 (present on every target machine): bash 3.2 on macOS has no
# `declare -A` / `mapfile`, and BSD `find` has no `-printf`, so the previous pure-bash
# core failed on this machine with `declare: -A: invalid option` before printing a row.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" \
PROJECTS_DIR="${PROJECTS_DIR}" CODEX_DIR="${CODEX_DIR}" AGENT="${agent}" LOCAL_FORKS="${LOCAL_FORKS}" \
TOP="${top}" MIN_BYTES="${min_bytes}" INCLUDE_CURRENT="${include_current}" \
EXCLUDES="${excludes[*]:-}" python3 -c '
# -*- coding: utf-8 -*-
import io, os, re, sys

projects = os.environ["PROJECTS_DIR"]
codexdir = os.environ.get("CODEX_DIR") or ""
agent    = os.environ.get("AGENT") or "all"
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

# Claude: top-level session files only, projects/<project>/<uuid>.jsonl (never /subagents/).
# Codex:  sessions/<Y>/<M>/<D>/rollout-<timestamp>-<uuid>.jsonl — the uuid is the tail of
# the name, which is what a session log records and what --exclude matches on.
rows = []

sys.path.insert(0, os.environ["SCRIPT_DIR"])   # next to this script, not wherever LOCAL_FORKS points
from transcript_reader import session_id_from_path as codex_uuid   # one definition, not two

if agent in ("claude", "all") and os.path.isdir(projects):
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
            rows.append((st.st_mtime, st.st_size, path, fn[:-6], "claude"))

if agent in ("codex", "all") and os.path.isdir(codexdir):
    for root, _dirs, files in os.walk(codexdir):
        for fn in files:
            if not (fn.startswith("rollout-") and fn.endswith(".jsonl")):
                continue
            path = os.path.join(root, fn)
            try:
                st = os.stat(path)
            except OSError:
                continue
            rows.append((st.st_mtime, st.st_size, path, codex_uuid(fn), "codex"))

if not rows:
    sys.stderr.write("list-sessions: no session transcripts found (agent=%s)\n" % agent)
    sys.exit(0)

# Newest mtime per agent = the live session of that agent. One global max would
# leave the live transcript of the other agent in the list.
current = set()
if not inc_cur:
    for a in ("claude", "codex"):
        same = [r for r in rows if r[4] == a]
        if same:
            current.add(max(same)[2])

kept = 0
for mtime, size, path, uuid, a in sorted(rows, key=lambda r: -r[1]):
    if path in current:      continue
    if uuid in skip:         continue
    if size < min_b:         continue
    sys.stdout.write("%d\t%s\t%s\t%s\n" % (size, uuid, path, a))
    kept += 1
    if top > 0 and kept >= top:
        break
'
