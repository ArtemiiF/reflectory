#!/usr/bin/env bash
# validate-manifests.sh — schema gate for skills/<name>/install.json.
#
# Checks, per manifest:
#   1. valid JSON, object at top level;
#   2. `machines` is a non-empty array of strings — each either "all" or an
#      existing _tracked/machines/<id>/ directory;
#   3. `agents` is a non-empty array drawn from the known agent set;
#   4. no unknown top-level keys (a typo like "machine" would otherwise read as
#      "no machines key" and silently fall back to the default).
#
# Schema: _system/_shared/install-manifest.md. Run from the pre-commit hook
# alongside validate-frontmatter.sh — the prose instructions are advisory, this
# fires on every commit.

set -euo pipefail

LOCAL_FORKS="${LOCAL_FORKS:-${HOME}/.claude/local-forks}"
cd "${LOCAL_FORKS}"

KNOWN_AGENTS='["claude","codex"]'

# Known machines = the profile directories that actually exist. `current` is a
# gitignored per-machine symlink, not a profile.
# `|| true`: a missing _tracked/machines must produce an empty list, not kill
# the script under `set -e` and leave the pre-commit hook reporting a blocked
# commit with no reason printed.
known_machines="$(
  { find _tracked/machines -mindepth 1 -maxdepth 1 -type d -not -name current \
      -exec basename {} \; 2>/dev/null || true; } | jq -R . | jq -s -c .
)"
[[ -n "${known_machines}" ]] || known_machines='[]'

errors=0
checked=0

while IFS= read -r m; do
  checked=$((checked + 1))
  rel="${m}"

  if [[ ! -f "${m}" ]]; then
    # Tracked in the index but gone from the working tree (unstaged deletion,
    # partial checkout). That is a different fact from malformed JSON.
    echo "${rel}: tracked but missing on disk" >&2
    errors=$((errors + 1))
    continue
  fi

  if ! jq -e 'type == "object"' "${m}" >/dev/null 2>&1; then
    echo "${rel}: not a JSON object" >&2
    errors=$((errors + 1))
    continue
  fi

  bad_keys="$(jq -r 'keys - ["machines","agents"] | join(", ")' "${m}")"
  if [[ -n "${bad_keys}" ]]; then
    echo "${rel}: unknown key(s): ${bad_keys}" >&2
    errors=$((errors + 1))
  fi

  if ! jq -e '(.machines | type == "array") and (.machines | length > 0)' "${m}" >/dev/null; then
    echo "${rel}: \`machines\` must be a non-empty array" >&2
    errors=$((errors + 1))
  else
    unknown="$(
      jq -r --argjson known "${known_machines}" '
        .machines | map(select(. != "all" and (. as $x | $known | index($x) | not)))
        | join(", ")
      ' "${m}"
    )"
    if [[ -n "${unknown}" ]]; then
      echo "${rel}: unknown machine id(s): ${unknown} (known: $(echo "${known_machines}" | jq -r 'join(", ")'))" >&2
      errors=$((errors + 1))
    fi
  fi

  if ! jq -e '(.agents | type == "array") and (.agents | length > 0)' "${m}" >/dev/null; then
    echo "${rel}: \`agents\` must be a non-empty array" >&2
    errors=$((errors + 1))
  else
    unknown="$(
      jq -r --argjson known "${KNOWN_AGENTS}" '
        .agents | map(select(. as $x | $known | index($x) | not)) | join(", ")
      ' "${m}"
    )"
    if [[ -n "${unknown}" ]]; then
      echo "${rel}: unknown agent(s): ${unknown} (known: claude, codex)" >&2
      errors=$((errors + 1))
    fi
  fi
done < <(git ls-files 'skills/*/install.json' 2>/dev/null | sort -u)

if (( errors > 0 )); then
  echo "${errors} manifest error(s) in ${checked} checked file(s)." >&2
  exit 1
fi

# Count the manifests against the skills that exist. "One per skill" is what the
# schema doc promises and what the installer assumes; a skill with no manifest
# silently inherits defaults, which is how a Codex-only skill would quietly end
# up installed for Claude instead.
# Tracked skills only. An untracked skill directory (someone else dropped a
# skill in, or a work-in-progress) must not block every commit in the repo;
# git is the boundary of what this repo promises to install.
skill_count="$(git ls-files 'skills/*/SKILL.md' 2>/dev/null | sort -u | wc -l | tr -d ' ')"

if (( checked == 0 && skill_count == 0 )); then
  # No skills tracked at all: an empty repo, or one whose skills live elsewhere.
  # Nothing to validate is not the same as a failed validation.
  echo "manifests ok: no tracked skills to check."
  exit 0
fi

if (( checked == 0 )); then
  echo "no install.json found under skills/ — expected one per skill (${skill_count} skill(s) present)." >&2
  echo "Either the manifests are missing or the layout moved; see _system/_shared/install-manifest.md." >&2
  exit 1
fi

# Totals can cancel out: one skill without a manifest plus one manifest without
# a skill sum to equal counts while both defects are live. Compare the directory
# sets instead, and name each side.
skill_dirs="$(git ls-files 'skills/*/SKILL.md' 2>/dev/null | sed 's|/SKILL.md$||' | LC_ALL=C sort -u)"
manifest_dirs="$(git ls-files 'skills/*/install.json' 2>/dev/null | sed 's|/install.json$||' | LC_ALL=C sort -u)"

# LC_ALL=C on both sides: comm warns and exits non-zero when its inputs are not
# sorted in its own collation, and under set -e that surfaces as "validation
# FAILED" with a sort warning as the only explanation.
missing_manifest="$(LC_ALL=C comm -23 <(echo "${skill_dirs}") <(echo "${manifest_dirs}"))"
orphan_manifest="$(LC_ALL=C comm -13 <(echo "${skill_dirs}") <(echo "${manifest_dirs}"))"

if [[ -n "${missing_manifest}" || -n "${orphan_manifest}" ]]; then
  if [[ -n "${missing_manifest}" ]]; then
    echo "Skills without install.json:" >&2
    echo "${missing_manifest}" | sed 's/^/  /' >&2
  fi
  if [[ -n "${orphan_manifest}" ]]; then
    echo "install.json without a tracked SKILL.md:" >&2
    echo "${orphan_manifest}" | sed 's/^/  /' >&2
  fi
  echo "Schema: _system/_shared/install-manifest.md" >&2
  exit 1
fi

echo "manifests ok: ${checked} checked, one per skill (${skill_count})."
