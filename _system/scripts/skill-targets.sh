#!/usr/bin/env bash
# skill-targets.sh — resolve which skills (and, in registry mode, which
# plugins) install on this machine, for which agent.
#
# Two manifest sources, chosen by presence, not by flag — transition mode:
#   - ${LOCAL_FORKS}/_tracked/registry.json exists  → registry mode (schema:
#     _system/_shared/registry-schema.md). Both skills and plugins are
#     entries there.
#   - it does not                                    → legacy mode, unchanged:
#     skills/<name>/install.json per skill (schema: install-manifest.md), no
#     plugin roster at all (kind=plugin resolves to nothing, same as today
#     where the mechanism does not exist).
# A skill directory with no matching entry in either source falls back to the
# same defaults either way: machines: ["all"], agents: ["claude"].
#
# Usage:
#   skill-targets.sh [--machine <id>] [--agents <csv>]
#     kind=skill (default, and the only kind legacy mode ever answers for).
#
#   skill-targets.sh --kind plugin --for-agent <claude|codex> [--machine <id>]
#     Registry-only. A plugin's resolved install path differs per agent, so
#     one agent is resolved at a time — never mixed into one row.
#
#   --machine   machine id to resolve against (default: _meta/machine-id)
#   --agents    agents present on this machine (default: probed from
#               ~/.claude, ~/.codex) — kind=skill only
#   --kind      skill (default) | plugin
#   --for-agent claude | codex — required, and only meaningful, with --kind plugin
#
# Output, kind=skill (unchanged shape):
#   <name>\t<install|skip|unknown>\t<agents-csv-or-->\t<reason>
#
# Output, kind=plugin:
#   <name>\t<install|skip|unknown>\t<agent>\t<resolved-path-or-reason>
#   On install with the entry's `import` field set, the 4th column is the
#   resolved absolute path to that file. On install with no `import`, it is
#   `-` (the plugin is attached with nothing to concatenate). A targeting
#   match that cannot actually be located (plugin not installed here, or
#   ambiguous) reads `unknown`, never `install` with a dangling path.
#
# Three decisions, not two, because "does not belong on this machine" and
# "could not be judged" are different facts and the caller acts on them
# differently:
#
#   install  put it here (skill), or attach it (plugin), for this agent
#   skip     it belongs elsewhere — safe to report as stale, safe to prune
#   unknown  the manifest is unreadable, the machine is unresolved, or (plugin
#            only) the targeting matched but the plugin could not be located.
#            NOT evidence of anything: a caller must never delete on this row.
#
# Collapsing unknown into skip is how a malformed file in one skill directory
# would have got that skill deleted by `bootstrap.sh --prune`.
#
# Exit 0 even when everything is skipped or unknown; a resolution is not an
# error. Exit 2 on bad arguments, and also when registry.json exists but
# cannot be trusted (malformed JSON, no `entries` array, or a non-object
# element in `entries`) — see REGISTRY_PRESENT below: falling back to legacy
# scanning on an unreadable registry would silently misjudge every entry,
# which is worse than refusing outright.

set -euo pipefail

# jq parses every manifest below. Without it each filter reads as "no match" and
# manifest-less skills would resolve to `skip` — a decision the caller is
# entitled to delete on. Refuse instead of answering wrongly.
if ! command -v jq >/dev/null 2>&1; then
  echo "skill-targets: jq not found on PATH; cannot read manifests." >&2
  exit 2
fi

LOCAL_FORKS="${LOCAL_FORKS:-${HOME}/.claude/local-forks}"
SKILLS_SRC="${LOCAL_FORKS}/skills"
REGISTRY="${LOCAL_FORKS}/_tracked/registry.json"

# Plugin-manager state read for plugin path resolution (kind=plugin only).
# Never hand-written per machine — see registry-schema.md "Plugin path
# resolution". Overridable indirectly via HOME/CODEX_HOME for fixture testing.
CLAUDE_INSTALLED_JSON="${HOME}/.claude/plugins/installed_plugins.json"
CODEX_PLUGIN_CACHE="${CODEX_HOME:-${HOME}/.codex}/plugins/cache"

DEFAULT_MACHINES='["all"]'
DEFAULT_AGENTS='["claude"]'

machine=""
agents_csv=""
kind="skill"
for_agent=""

while (( $# > 0 )); do
  case "$1" in
    --machine)   machine="${2:-}"; [[ -n "${machine}" ]] || { echo "skill-targets: --machine needs a value" >&2; exit 2; }; shift 2 ;;
    --agents)    agents_csv="${2:-}"; [[ -n "${agents_csv}" ]] || { echo "skill-targets: --agents needs a value" >&2; exit 2; }; shift 2 ;;
    --kind)      kind="${2:-}"; [[ -n "${kind}" ]] || { echo "skill-targets: --kind needs a value" >&2; exit 2; }; shift 2 ;;
    --for-agent) for_agent="${2:-}"; [[ -n "${for_agent}" ]] || { echo "skill-targets: --for-agent needs a value" >&2; exit 2; }; shift 2 ;;
    *) echo "skill-targets: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "${kind}" in
  skill|plugin) ;;
  *) echo "skill-targets: --kind must be 'skill' or 'plugin' (got '${kind}')" >&2; exit 2 ;;
esac

# Machine resolution mirrors bootstrap.sh: the explicit _meta/machine-id wins,
# then the machines/current symlink bootstrap points at this machine. Reading
# only machine-id would strand a fresh clone — that file is gitignored, so on a
# new machine every machine-scoped skill would resolve to "skip" without saying
# why.
if [[ -z "${machine}" && -f "${LOCAL_FORKS}/_meta/machine-id" ]]; then
  machine="$(head -n1 "${LOCAL_FORKS}/_meta/machine-id" | tr -d '[:space:]')"
fi
if [[ -z "${machine}" && -L "${LOCAL_FORKS}/_tracked/machines/current" ]]; then
  machine="$(basename "$(readlink "${LOCAL_FORKS}/_tracked/machines/current")")"
fi
# Unresolved machine is not fatal: a first-run bootstrap has not created
# machines/current yet, and refusing outright meant the installer aborted with
# advice to run the very script that was running. Machine-agnostic skills
# ("machines": ["all"]) still install; machine-scoped ones skip with a reason,
# and the warning says what to do about it.
if [[ -z "${machine}" ]]; then
  echo "skill-targets: machine unresolved (no _meta/machine-id, no machines/current symlink)." >&2
  echo "Installing machine-agnostic entries only. Write the id to _meta/machine-id" >&2
  echo "(or pass --machine <id>) and re-run to get the machine-scoped ones." >&2
fi

# Non-empty arrays of strings, both axes. An empty array is what
# validate-manifests.sh calls an error, and it would otherwise resolve to
# `skip` — a decision the caller may delete on. Invalid input must read as
# unknown, never as a judgement. Shared by legacy install.json rows and
# registry entries (skill and plugin) so the type check lives in one place.
axes_type_ok() {
  local machines="$1" agents="$2"
  echo "${machines}" | jq -e 'type == "array" and length > 0 and (map(type == "string") | all)' >/dev/null 2>&1 \
    && echo "${agents}" | jq -e 'type == "array" and length > 0 and (map(type == "string") | all)' >/dev/null 2>&1
}

# Registry presence + validity, resolved ONCE before branching by kind. A
# registry.json that EXISTS but cannot be trusted (malformed JSON — a
# truncated write, conflict markers — or an `entries` field that is not an
# array) must never read as "absent": that would silently fall back to
# legacy `install.json` scanning (kind=skill) or an empty plugin roster
# (kind=plugin) for a repo that HAS migrated, defaulting every skill to
# `install` with `machines: ["all"], agents: ["claude"]` and dropping every
# plugin with no report at all. Refuse outright instead — the caller (or the
# person running this by hand) needs to fix the file, not receive a quiet
# wrong answer.
REGISTRY_PRESENT=0
if [[ -f "${REGISTRY}" ]]; then
  if ! jq -e '.' "${REGISTRY}" >/dev/null 2>&1; then
    echo "skill-targets: ${REGISTRY} exists but is not valid JSON." >&2
    echo "Refusing to fall back to legacy manifests or an empty plugin roster —" >&2
    echo "that would silently misjudge every entry. Fix the file and re-run." >&2
    exit 2
  fi
  if ! jq -e '(.entries | type) == "array"' "${REGISTRY}" >/dev/null 2>&1; then
    echo "skill-targets: ${REGISTRY} has no \`entries\` array." >&2
    exit 2
  fi
  # A non-object element (a bare string, say) is the same danger as malformed
  # JSON: the per-entry lookups below read `.name`/`.kind`/etc. straight off
  # each element. Against a non-object one, jq errors — silently, since both
  # call sites redirect stderr — and the skill loop's `|| true` swallows it,
  # falling back to defaults for every skill; the plugin stream just stops
  # partway with no later row ever printed. Catch it here instead, once.
  if ! jq -e '(.entries | all(type == "object"))' "${REGISTRY}" >/dev/null 2>&1; then
    echo "skill-targets: ${REGISTRY} has a non-object element in \`entries\`." >&2
    exit 2
  fi
  REGISTRY_PRESENT=1
fi

# --- kind=plugin: registry-only, one agent at a time ------------------------
if [[ "${kind}" == "plugin" ]]; then
  case "${for_agent}" in
    claude|codex) ;;
    "") echo "skill-targets: --kind plugin requires --for-agent <claude|codex>" >&2; exit 2 ;;
    *) echo "skill-targets: --for-agent must be 'claude' or 'codex' (got '${for_agent}')" >&2; exit 2 ;;
  esac

  # Legacy mode has no plugin roster mechanism at all — empty output is the
  # correct, non-error answer (mirrors today, where no such resolution exists).
  if (( ! REGISTRY_PRESENT )); then
    exit 0
  fi

  # Resolve <name> to its install directory for <agent>, or print nothing (the
  # caller treats an empty result as "not found"). Read from the agent's own
  # plugin-manager state — see registry-schema.md "Plugin path resolution".
  resolve_plugin_root() {
    local name="$1" agent="$2"
    case "${agent}" in
      claude)
        [[ -f "${CLAUDE_INSTALLED_JSON}" ]] || return 0
        jq -e '.' "${CLAUDE_INSTALLED_JSON}" >/dev/null 2>&1 || return 0
        local matches count
        matches="$(jq -r --arg n "${name}" \
          '(.plugins // {}) | keys[] | select(. == $n or (split("@")[0]) == $n)' \
          "${CLAUDE_INSTALLED_JSON}" 2>/dev/null || true)"
        count="$(printf '%s\n' "${matches}" | grep -c . || true)"
        [[ "${count}" == "1" ]] || return 0
        jq -r --arg k "${matches}" '(.plugins[$k][0].installPath) // empty' "${CLAUDE_INSTALLED_JSON}" 2>/dev/null || true
        ;;
      codex)
        [[ -d "${CODEX_PLUGIN_CACHE}" ]] || return 0
        local dirs=() d
        while IFS= read -r d; do dirs+=("${d}"); done < <(
          find "${CODEX_PLUGIN_CACHE}" -mindepth 2 -maxdepth 2 -type d -name "${name}" \
            -not -path "${CODEX_PLUGIN_CACHE}/.*" 2>/dev/null
        )
        (( ${#dirs[@]} == 1 )) || return 0
        # Best-effort: lexicographically last version dir name (C locale, and
        # excluding dotfiles/dirs such as a `.tmp*` staging directory a plugin
        # manager may leave next to real version dirs), not a semver
        # comparison. Undisputed today because no registry entry targets
        # codex; documented limitation in registry-schema.md.
        find "${dirs[0]}" -mindepth 1 -maxdepth 1 -type d -not -name '.*' 2>/dev/null | LC_ALL=C sort | tail -n1
        ;;
    esac
  }

  while IFS= read -r entry_json; do
    [[ -n "${entry_json}" ]] || continue
    name="$(jq -r '.name // empty' <<<"${entry_json}")"
    [[ -n "${name}" ]] || { printf 'unknown\tunknown\t%s\tmalformed registry entry (missing name)\n' "${for_agent}"; continue; }

    if jq -e 'has("machines")' <<<"${entry_json}" >/dev/null 2>&1; then
      e_machines="$(jq -c '.machines' <<<"${entry_json}")"
    else
      e_machines="${DEFAULT_MACHINES}"
    fi
    if jq -e 'has("agents")' <<<"${entry_json}" >/dev/null 2>&1; then
      e_agents="$(jq -c '.agents' <<<"${entry_json}")"
    else
      e_agents="${DEFAULT_AGENTS}"
    fi

    if ! axes_type_ok "${e_machines}" "${e_agents}"; then
      printf '%s\tunknown\t%s\tmalformed registry entry (machines/agents must be non-empty arrays of strings)\n' \
        "${name}" "${for_agent}"
      continue
    fi

    if ! echo "${e_machines}" | jq -e --arg m "${machine}" \
          'index("all") != null or index($m) != null' >/dev/null; then
      if [[ -z "${machine}" ]]; then
        printf '%s\tunknown\t%s\tmachine unresolved, scope is %s\n' "${name}" "${for_agent}" "${e_machines}"
      else
        printf '%s\tskip\t%s\tmachine %s not in %s\n' "${name}" "${for_agent}" "${machine}" "${e_machines}"
      fi
      continue
    fi

    if ! echo "${e_agents}" | jq -e --arg a "${for_agent}" 'index($a) != null' >/dev/null; then
      printf '%s\tskip\t%s\tagent %s not in %s\n' "${name}" "${for_agent}" "${for_agent}" "${e_agents}"
      continue
    fi

    import_rel="$(jq -r '.import // empty' <<<"${entry_json}")"
    if [[ -z "${import_rel}" ]]; then
      printf '%s\tinstall\t%s\t-\n' "${name}" "${for_agent}"
      continue
    fi

    root="$(resolve_plugin_root "${name}" "${for_agent}")"
    if [[ -z "${root}" ]]; then
      printf '%s\tunknown\t%s\tplugin not installed for %s (or ambiguous)\n' "${name}" "${for_agent}" "${for_agent}"
      continue
    fi
    # The targeting matched and a plugin root resolved, but the declared
    # `import` file might not actually exist there (stale registry entry,
    # typo'd path, a plugin version that renamed/removed the file). Reporting
    # `install` with a dangling path would hand the caller an `@import` line
    # that resolves to nothing — surface `unknown` instead, never a silent
    # broken attach.
    resolved="${root}/${import_rel}"
    if [[ ! -f "${resolved}" ]]; then
      printf '%s\tunknown\t%s\tresolved plugin root but import file is missing: %s\n' \
        "${name}" "${for_agent}" "${resolved}"
      continue
    fi
    printf '%s\tinstall\t%s\t%s\n' "${name}" "${for_agent}" "${resolved}"
  done < <(jq -c '.entries[] | select(.kind == "plugin")' "${REGISTRY}")

  exit 0
fi

# --- kind=skill --------------------------------------------------------------

# Agent probe: an agent counts as present when its home directory exists.
# Explicit --agents wins, so a caller can resolve for a machine it is not on.
if [[ -z "${agents_csv}" ]]; then
  present=()
  [[ -d "${HOME}/.claude" ]] && present+=("claude")
  # Honour CODEX_HOME — bootstrap.sh installs there, so the probe must agree
  # with the installer about which Codex home counts.
  [[ -d "${CODEX_HOME:-${HOME}/.codex}" ]] && present+=("codex")
  agents_csv="$(IFS=,; echo "${present[*]:-}")"
fi

if [[ ! -d "${SKILLS_SRC}" ]]; then
  echo "skill-targets: ${SKILLS_SRC} does not exist — no skills to resolve." >&2
  exit 2
fi

registry_present="${REGISTRY_PRESENT}"

for skill_dir in "${SKILLS_SRC}"/*/; do
  name="$(basename "${skill_dir}")"
  [[ -f "${skill_dir}SKILL.md" ]] || continue

  if (( registry_present )); then
    # Registry mode: look up this skill's entry by name. Absent → same
    # defaults a missing install.json got in legacy mode.
    entry_json="$(jq -c --arg n "${name}" \
      '[.entries[] | select(.kind == "skill" and .name == $n)] | first // empty' \
      "${REGISTRY}" 2>/dev/null || true)"
    if [[ -z "${entry_json}" || "${entry_json}" == "null" ]]; then
      m_machines="${DEFAULT_MACHINES}"
      m_agents="${DEFAULT_AGENTS}"
    elif jq -e 'has("import")' <<<"${entry_json}" >/dev/null 2>&1; then
      printf '%s\tunknown\t-\tmalformed registry entry (a skill entry must not declare "import")\n' "${name}"
      continue
    else
      if jq -e 'has("machines")' <<<"${entry_json}" >/dev/null 2>&1; then
        m_machines="$(jq -c '.machines' <<<"${entry_json}")"
      else
        m_machines="${DEFAULT_MACHINES}"
      fi
      if jq -e 'has("agents")' <<<"${entry_json}" >/dev/null 2>&1; then
        m_agents="$(jq -c '.agents' <<<"${entry_json}")"
      else
        m_agents="${DEFAULT_AGENTS}"
      fi
      if ! axes_type_ok "${m_machines}" "${m_agents}"; then
        printf '%s\tunknown\t-\tmalformed registry entry (machines/agents must be non-empty arrays of strings)\n' "${name}"
        continue
      fi
    fi
  else
    # Legacy mode — unchanged from the pre-registry script.
    manifest="${skill_dir}install.json"
    if [[ -f "${manifest}" ]]; then
      if ! jq -e '.' "${manifest}" >/dev/null 2>&1; then
        # Unparseable JSON (truncated write, conflict markers) is the likeliest
        # breakage of all. Killing the resolver here made bootstrap install
        # nothing at all, so this skill alone becomes unknown.
        printf '%s\tunknown\t-\tmalformed manifest (not valid JSON)\n' "${name}"
        continue
      fi
      # `has()` rather than `// empty`: the latter turns a present-but-false or
      # present-but-null field into "absent" and quietly applies the defaults,
      # which is exactly the silence the type-check below exists to break.
      if jq -e 'has("machines")' "${manifest}" >/dev/null 2>&1; then
        m_machines="$(jq -c '.machines' "${manifest}")"
      else
        m_machines="${DEFAULT_MACHINES}"
      fi
      if jq -e 'has("agents")' "${manifest}" >/dev/null 2>&1; then
        m_agents="$(jq -c '.agents' "${manifest}")"
      else
        m_agents="${DEFAULT_AGENTS}"
      fi

      if ! axes_type_ok "${m_machines}" "${m_agents}"; then
        printf '%s\tunknown\t-\tmalformed manifest (machines/agents must be non-empty arrays of strings)\n' "${name}"
        continue
      fi
    else
      m_machines="${DEFAULT_MACHINES}"
      m_agents="${DEFAULT_AGENTS}"
    fi
  fi

  # --- machine axis ---
  if ! echo "${m_machines}" | jq -e --arg m "${machine}" \
        'index("all") != null or index($m) != null' >/dev/null; then
    if [[ -z "${machine}" ]]; then
      # Machine-scoped skill on a machine we could not name: not a judgement.
      printf '%s\tunknown\t-\tmachine unresolved, scope is %s\n' "${name}" "${m_machines}"
    else
      printf '%s\tskip\t-\tmachine %s not in %s\n' "${name}" "${machine}" "${m_machines}"
    fi
    continue
  fi

  # --- agent axis: intersect the manifest with what this machine has ---
  wanted="$(
    echo "${m_agents}" | jq -r --arg present "${agents_csv}" '
      ($present | split(",") | map(select(length > 0))) as $have
      | map(select(. as $a | $have | index($a))) | join(",")
    '
  )"
  if [[ -z "${wanted}" ]]; then
    printf '%s\tskip\t-\tno target agent (manifest %s, present [%s])\n' \
      "${name}" "${m_agents}" "${agents_csv}"
    continue
  fi

  printf '%s\tinstall\t%s\t-\n' "${name}" "${wanted}"
done
