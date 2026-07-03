#!/usr/bin/env bash
# update-last-push.sh — bump _meta/remote.json:last_push_ok_at to <now UTC>.
#
# Called from /reflect-session Step 6 and /sync-upstream Step 7 BEFORE the
# commit that ships the run's changes. The bumped remote.json is included
# in that commit (one commit per pipeline), so the timestamp persists to
# the remote on the same push it documents. No second commit, no amend,
# no force-push.
#
# Semantic: the timestamp = «moment we were about to push», not «moment
# the push completed». Offset is seconds; if push fails the timestamp is
# slightly optimistic and gets corrected on the next successful run.
#
# Atomic write via tmp+mv. Idempotent: re-running with no other changes
# just bumps the field again. Exits non-zero if remote.json is missing
# or malformed — callers should treat that as a pre-commit failure.

set -euo pipefail

LOCAL_FORKS="${LOCAL_FORKS:-${HOME}/.claude/local-forks}"
REMOTE_JSON="${LOCAL_FORKS}/_meta/remote.json"

if [[ ! -f "${REMOTE_JSON}" ]]; then
  echo "error: ${REMOTE_JSON} not found — has init-remote.md been run?" >&2
  exit 1
fi

if ! jq -e '.' "${REMOTE_JSON}" >/dev/null 2>&1; then
  echo "error: ${REMOTE_JSON} is malformed JSON" >&2
  exit 1
fi

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="${REMOTE_JSON}.tmp"
jq --arg now "${now}" '.last_push_ok_at = $now' "${REMOTE_JSON}" > "${tmp}"
mv "${tmp}" "${REMOTE_JSON}"

echo "Bumped ${REMOTE_JSON}:last_push_ok_at = ${now}"
