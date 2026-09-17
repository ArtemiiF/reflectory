#!/usr/bin/env bash
# skill-targets.sh — resolve which skills install on this machine, for which agent.
#
# Two independent axes live in skills/<name>/install.json (schema:
# _system/_shared/install-manifest.md): `machines` and `agents`. bootstrap.sh
# calls this resolver, and /pull-forks is instructed to call it — instructions
# teach, the script enforces, so treat the bootstrap path as the authority.
#
# Usage:
#   skill-targets.sh [--machine <id>] [--agents <csv>]
#
#   --machine  machine id to resolve against (default: _meta/machine-id)
#   --agents   agents present on this machine (default: probed from ~/.claude,
#              ~/.codex)
#
# Output: one TSV line per skill —
#   <name>\t<install|skip|unknown>\t<agents-csv-or-->\t<reason>
#
# Three decisions, not two, because "does not belong on this machine" and "could
# not be judged" are different facts and the caller acts on them differently:
#
#   install  put it here, for these agents
#   skip     it belongs elsewhere — safe to report as stale, safe to prune
#   unknown  the manifest is unreadable, or the machine is unresolved. NOT
#            evidence of anything: a caller must never delete on this row.
#
# Collapsing unknown into skip is how a malformed file in one skill directory
# would have got that skill deleted by `bootstrap.sh --prune`.
#
# Exit 0 even when everything is skipped or unknown; a resolution is not an
# error. Exit 2 only on bad arguments.

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

DEFAULT_MACHINES='["all"]'
DEFAULT_AGENTS='["claude"]'

machine=""
agents_csv=""

while (( $# > 0 )); do
  case "$1" in
    --machine) machine="${2:-}"; [[ -n "${machine}" ]] || { echo "skill-targets: --machine needs a value" >&2; exit 2; }; shift 2 ;;
    --agents)  agents_csv="${2:-}"; [[ -n "${agents_csv}" ]] || { echo "skill-targets: --agents needs a value" >&2; exit 2; }; shift 2 ;;
    *) echo "skill-targets: unknown argument: $1" >&2; exit 2 ;;
  esac
done

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
  echo "Installing machine-agnostic skills only. Write the id to _meta/machine-id" >&2
  echo "(or pass --machine <id>) and re-run to get the machine-scoped ones." >&2
fi

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

for skill_dir in "${SKILLS_SRC}"/*/; do
  name="$(basename "${skill_dir}")"
  [[ -f "${skill_dir}SKILL.md" ]] || continue

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

    # Type-check before the filters below index into them. A valid-JSON but
    # wrong-typed field ("agents": "codex") would make jq error out mid-loop and,
    # under set -e, take the whole resolver down — one bad file in one untracked
    # skill directory would then stop every skill from installing. Skip the
    # offender loudly instead; validate-manifests.sh is where tracked manifests
    # get their schema verdict.
    # Arrays of STRINGS, both axes: a nested array or object passes a bare
    # type check and then blows up in the join below, taking the resolver with
    # it — the same fatal path this check exists to close.
    # Non-empty arrays of strings. An empty array is what validate-manifests.sh
    # calls an error, and it would otherwise resolve to `skip` — a decision the
    # caller may delete on. Invalid input must read as unknown, never as a
    # judgement.
    if ! echo "${m_machines}" | jq -e 'type == "array" and length > 0 and (map(type == "string") | all)' >/dev/null 2>&1 \
       || ! echo "${m_agents}" | jq -e 'type == "array" and length > 0 and (map(type == "string") | all)' >/dev/null 2>&1; then
      printf '%s\tunknown\t-\tmalformed manifest (machines/agents must be non-empty arrays of strings)\n' "${name}"
      continue
    fi
  else
    m_machines="${DEFAULT_MACHINES}"
    m_agents="${DEFAULT_AGENTS}"
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
