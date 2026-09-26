#!/usr/bin/env bash
# validate-manifests.sh — schema gate for skill/plugin targeting manifests.
#
# Transition mode, by presence of `_tracked/registry.json`:
#   - present  → validate it (schema: _system/_shared/registry-schema.md) and
#                skip the legacy per-skill check below entirely.
#   - absent   → validate skills/<name>/install.json exactly as before
#                (schema: _system/_shared/install-manifest.md). Unchanged code
#                path — a data repo that has not migrated keeps the same gate.
#
# Legacy checks, per install.json manifest:
#   1. valid JSON, object at top level;
#   2. `machines` is a non-empty array of strings — each either "all" or an
#      existing _tracked/machines/<id>/ directory;
#   3. `agents` is a non-empty array drawn from the known agent set;
#   4. no unknown top-level keys (a typo like "machine" would otherwise read as
#      "no machines key" and silently fall back to the default).
#
# Registry checks, on `_tracked/registry.json`:
#   1. valid JSON object; only top-level key is `entries`, an array of objects;
#   2. no unknown keys per entry (name, kind, layer, machines, agents, import);
#   3. `kind` is "plugin" or "skill"; `layer` is "root", "machine", or "agent";
#   4. `machines`/`agents` same rules as legacy manifests;
#   5. `import` present only when `kind == "plugin"`;
#   6. `(name, kind)` unique across entries;
#   7. every `kind: "skill"` entry names a tracked `skills/<name>/SKILL.md`,
#      and every tracked skill has exactly one `kind: "skill"` entry (same
#      one-per-skill parity the legacy check already enforced).
#
# Run from the pre-commit hook alongside validate-frontmatter.sh — the prose
# instructions are advisory, this fires on every commit.

set -euo pipefail

LOCAL_FORKS="${LOCAL_FORKS:-${HOME}/.claude/local-forks}"
cd "${LOCAL_FORKS}"

KNOWN_AGENTS='["claude","codex"]'
KNOWN_KINDS='["plugin","skill"]'
KNOWN_LAYERS='["root","machine","agent"]'

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

# --- registry mode -----------------------------------------------------------
if [[ -f "_tracked/registry.json" ]]; then
  REGISTRY="_tracked/registry.json"
  errors=0

  if ! jq -e 'type == "object"' "${REGISTRY}" >/dev/null 2>&1; then
    echo "${REGISTRY}: not a JSON object" >&2
    exit 1
  fi
  top_bad_keys="$(jq -r 'keys - ["entries"] | join(", ")' "${REGISTRY}")"
  if [[ -n "${top_bad_keys}" ]]; then
    echo "${REGISTRY}: unknown top-level key(s): ${top_bad_keys}" >&2
    errors=$((errors + 1))
  fi
  if ! jq -e '(.entries | type) == "array"' "${REGISTRY}" >/dev/null 2>&1; then
    echo "${REGISTRY}: \`entries\` must be an array" >&2
    exit 1
  fi

  entry_count="$(jq '.entries | length' "${REGISTRY}")"
  i=0
  while (( i < entry_count )); do
    entry="$(jq -c ".entries[${i}]" "${REGISTRY}")"
    label="entry #${i}"

    # Type-checked before any field is read out of it — an entry that is a
    # string, number, or array (not an object) would otherwise make `.name`
    # below fail under jq and, propagating through `set -e`, abort the whole
    # script with a raw jq error instead of a clean per-entry message.
    if ! jq -e 'type == "object"' <<<"${entry}" >/dev/null 2>&1; then
      echo "${REGISTRY}: ${label}: not a JSON object" >&2
      errors=$((errors + 1))
      i=$((i + 1)); continue
    fi

    name="$(jq -r '.name // empty' <<<"${entry}")"
    [[ -n "${name}" ]] && label="${label} (${name})"

    bad_keys="$(jq -r 'keys - ["name","kind","layer","machines","agents","import"] | join(", ")' <<<"${entry}")"
    if [[ -n "${bad_keys}" ]]; then
      echo "${REGISTRY}: ${label}: unknown key(s): ${bad_keys}" >&2
      errors=$((errors + 1))
    fi

    if [[ -z "${name}" ]]; then
      echo "${REGISTRY}: ${label}: missing or empty \`name\`" >&2
      errors=$((errors + 1))
    fi

    kind="$(jq -r '.kind // empty' <<<"${entry}")"
    if [[ -z "${kind}" ]] || ! echo "${KNOWN_KINDS}" | jq -e --arg k "${kind}" 'index($k) != null' >/dev/null 2>&1; then
      echo "${REGISTRY}: ${label}: \`kind\` must be one of plugin, skill (got '${kind}')" >&2
      errors=$((errors + 1))
    fi

    layer="$(jq -r '.layer // empty' <<<"${entry}")"
    if [[ -z "${layer}" ]] || ! echo "${KNOWN_LAYERS}" | jq -e --arg l "${layer}" 'index($l) != null' >/dev/null 2>&1; then
      echo "${REGISTRY}: ${label}: \`layer\` must be one of root, machine, agent (got '${layer}')" >&2
      errors=$((errors + 1))
    fi

    if ! jq -e '(.machines | type == "array") and (.machines | length > 0)' <<<"${entry}" >/dev/null 2>&1; then
      echo "${REGISTRY}: ${label}: \`machines\` must be a non-empty array" >&2
      errors=$((errors + 1))
    else
      unknown="$(
        jq -r --argjson known "${known_machines}" '
          .machines | map(select(. != "all" and (. as $x | $known | index($x) | not)))
          | join(", ")
        ' <<<"${entry}"
      )"
      if [[ -n "${unknown}" ]]; then
        echo "${REGISTRY}: ${label}: unknown machine id(s): ${unknown} (known: $(echo "${known_machines}" | jq -r 'join(", ")'))" >&2
        errors=$((errors + 1))
      fi
    fi

    if ! jq -e '(.agents | type == "array") and (.agents | length > 0)' <<<"${entry}" >/dev/null 2>&1; then
      echo "${REGISTRY}: ${label}: \`agents\` must be a non-empty array" >&2
      errors=$((errors + 1))
    else
      unknown="$(
        jq -r --argjson known "${KNOWN_AGENTS}" '
          .agents | map(select(. as $x | $known | index($x) | not)) | join(", ")
        ' <<<"${entry}"
      )"
      if [[ -n "${unknown}" ]]; then
        echo "${REGISTRY}: ${label}: unknown agent(s): ${unknown} (known: claude, codex)" >&2
        errors=$((errors + 1))
      fi
    fi

    if jq -e 'has("import")' <<<"${entry}" >/dev/null 2>&1; then
      if [[ "${kind}" != "plugin" ]]; then
        echo "${REGISTRY}: ${label}: \`import\` is only valid on a plugin entry (kind: ${kind:-<missing>})" >&2
        errors=$((errors + 1))
      elif ! jq -e '(.import | type) == "string" and (.import | length > 0)' <<<"${entry}" >/dev/null 2>&1; then
        echo "${REGISTRY}: ${label}: \`import\` must be a non-empty string" >&2
        errors=$((errors + 1))
      fi
    fi

    i=$((i + 1))
  done

  # (name, kind) uniqueness across all entries. `select(type == "object")`
  # first: a non-object entry (already reported above) would otherwise make
  # `.name`/`.kind` fail under jq here too, and under `set -e` that aborts the
  # whole script with a raw jq error instead of the accumulated messages above.
  dupes="$(jq -r '[.entries[] | select(type == "object") | select((.name // empty) != "" and (.kind // empty) != "") | "\(.kind)/\(.name)"] | group_by(.) | map(select(length > 1) | .[0]) | join(", ")' "${REGISTRY}")"
  if [[ -n "${dupes}" ]]; then
    echo "${REGISTRY}: duplicate (kind, name) entries: ${dupes}" >&2
    errors=$((errors + 1))
  fi

  # One-per-skill parity: every tracked SKILL.md has exactly one registry
  # entry, and no entry names a skill directory that does not exist. Same
  # defect class the legacy missing_manifest/orphan_manifest check caught.
  skill_dirs="$(git ls-files 'skills/*/SKILL.md' 2>/dev/null | sed 's|/SKILL.md$||' | sed 's|^skills/||' | LC_ALL=C sort -u)"
  registry_skill_names="$(jq -r '.entries[] | select(type == "object") | select(.kind == "skill") | .name // empty' "${REGISTRY}" | LC_ALL=C sort -u)"

  missing_entry="$(LC_ALL=C comm -23 <(echo "${skill_dirs}") <(echo "${registry_skill_names}"))"
  orphan_entry="$(LC_ALL=C comm -13 <(echo "${skill_dirs}") <(echo "${registry_skill_names}"))"
  if [[ -n "${missing_entry}" || -n "${orphan_entry}" ]]; then
    if [[ -n "${missing_entry}" ]]; then
      echo "Tracked skills without a registry entry:" >&2
      echo "${missing_entry}" | sed 's/^/  /' >&2
    fi
    if [[ -n "${orphan_entry}" ]]; then
      echo "Registry skill entries without a tracked SKILL.md:" >&2
      echo "${orphan_entry}" | sed 's/^/  /' >&2
    fi
    echo "Schema: _system/_shared/registry-schema.md" >&2
    errors=$((errors + 1))
  fi

  if (( errors > 0 )); then
    echo "${errors} registry error(s) in ${REGISTRY}." >&2
    exit 1
  fi

  echo "registry ok: $(echo "${registry_skill_names}" | grep -c . || true) skill entries, $(jq -r '[.entries[] | select(type == "object") | select(.kind == "plugin")] | length' "${REGISTRY}") plugin entries."
  exit 0
fi

# --- legacy mode (unchanged) --------------------------------------------------

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
