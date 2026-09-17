#!/usr/bin/env bash
# bootstrap.sh — set up local-forks on a fresh machine.
#
# Run after `git clone <remote> ~/.claude/local-forks`.
#
# What it does:
#   1. Symlink each ~/.claude/local-forks/skills/<skill>/*.md (SKILL.md + method.md
#      + any other reference files) into ~/.claude/skills/<skill>/ so the system
#      skills are fully invocable AND any edit through the live path flows back
#      to the source of truth without a second copy to keep in sync. Only skills
#      this machine and agent are targeted by are installed — resolved from
#      skills/<name>/install.json by _system/scripts/skill-targets.sh (schema:
#      _system/_shared/install-manifest.md). Pass --prune to also remove skills
#      this repo installed earlier and no longer targets.
#   2. Restore top-level ~/.claude/ files from _tracked/: CLAUDE.md and RTK.md
#      are copied if the live file is missing (existing live file preserved —
#      use /sync-upstream or manual reconciliation to merge); statusline.sh is
#      symlinked instead so live edits flow back to source-of-truth.
#   3. For every forked plugin artefact under <marketplace>/<plugin>/...:
#        - read baseline_upstream_version from <plugin>/_meta.json
#        - check ~/.claude/plugins/installed_plugins.json for the installed version
#        - if versions match → copy our forked file into the plugin cache (edit-in-place)
#        - if installed version differs → record in NEEDS_SYNC and skip
#   4. Print a summary; tell the user to run /reload-plugins and (if needed) /sync-upstream.
#
# Constraints:
#   - Idempotent. Re-running with no changes does nothing destructive. The one
#     exception is opt-in: --prune removes skills this repo installed earlier and
#     no longer targets at this machine/agent (symlinks only; backups survive).
#   - Writes only under ~/.claude/ and, when a Codex home exists, under
#     $CODEX_HOME (skills/<name>/ and AGENTS.md — the latter never over a
#     hand-written file; see build-agents-md.sh).
#   - Never touches ~/.gitconfig or any global config.
#   - Pre-existing regular-file ~/.claude/skills/<name>/SKILL.md (or other .md)
#     is backed up to <file>.bak.<UTC> only if its content differs from the
#     symlink target; matching copies are silently upgraded to symlinks.

set -euo pipefail

LOCAL_FORKS="${LOCAL_FORKS:-${HOME}/.claude/local-forks}"

# Where the machinery lives, as opposed to where the DATA lives. The two used to
# be the same directory — bootstrap cloned the whole repo into ~/.claude/local-forks
# — but a plugin install keeps the scripts in the plugin and leaves only rules,
# skills and session logs in the data repo. Resolving siblings by LOCAL_FORKS
# then looks for them in a directory that no longer has them, so they are found
# next to this script instead, and LOCAL_FORKS means data from here on.
SYS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SYS_DIR}/scripts"
MACHINERY_ROOT="$(dirname "${SYS_DIR}")"

SKILLS_DIR="${HOME}/.claude/skills"
CODEX_SKILLS_DIR="${CODEX_HOME:-${HOME}/.codex}/skills"
PLUGINS_CACHE="${HOME}/.claude/plugins/cache"
INSTALLED_JSON="${HOME}/.claude/plugins/installed_plugins.json"
TRACKED_DIR="${LOCAL_FORKS}/_tracked"
LIVE_CLAUDE_DIR="${HOME}/.claude"

# The machinery pointer. Skills, sub-agent prompts and generated hooks all need
# the machinery root, and none of them can rediscover it: CLAUDE_PLUGIN_ROOT is
# unset in a skill's own shell, a sub-agent never reads the SKILL.md that would
# carry a resolver, and a cache directory is version-numbered. So bootstrap —
# the one process that knows where it was run from — writes the answer down at a
# path that never moves, and everything else reads one line. Per-machine state:
# gitignored, rewritten on every bootstrap.
write_machinery_pointer() {
  mkdir -p "${LOCAL_FORKS}/_meta"
  printf '%s\n' "${MACHINERY_ROOT}" > "${LOCAL_FORKS}/_meta/machinery-root"
}

# Summary arrays — declared early so the ERR trap can print whatever state
# accumulated before the failure.
declare -a APPLIED=()
declare -a NEEDS_SYNC=()
declare -a UNKNOWN_PLUGIN=()
declare -a JSON_ERROR=()
declare -a BACKED_UP=()
declare -a SKIPPED=()
declare -a STALE=()
declare -a PRUNED=()
declare -a UNMANAGED=()
declare -a UNJUDGED=()
declare -a UNJUDGED_RESOLVE=()

# Set by the machine-layer step below when _meta/machine-id (hand-written and
# gitignored) actually names an existing profile. A typo there resolves to a
# non-empty id with no profile: skills still resolve, every machine-scoped one
# skips, and the sweep must not read that as evidence for deletion.
MACHINE_PROFILE_OK=0

# --prune: remove skills that this repo installed earlier but no longer targets
# at this machine/agent. Off by default — bootstrap stays non-destructive.
PRUNE=0
for arg in "$@"; do
  case "${arg}" in
    --prune) PRUNE=1 ;;
    *) echo "bootstrap: unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

print_summary() {
  echo
  echo "==> Summary"
  # Counted from the decision file, not from `ls`: the live directory also holds
  # skills this repo never installed (plugin- or hand-made), and counting those
  # would contradict the targeted-install model the next lines report.
  # Per agent: a row can resolve to codex only, in which case nothing appears
  # in ~/.claude/skills and a single number would misdescribe the run.
  echo "  Skills installed from this repo: $(awk -F'\t' '$2=="install" && $3 ~ /claude/' "${TARGETS_FILE:-/dev/null}" 2>/dev/null | wc -l | tr -d ' ') for claude, $(awk -F'\t' '$2=="install" && $3 ~ /codex/' "${TARGETS_FILE:-/dev/null}" 2>/dev/null | wc -l | tr -d ' ') for codex"
  echo "  Forks applied to cache:    ${#APPLIED[@]}"
  if (( ${#APPLIED[@]} > 0 )); then
    for x in "${APPLIED[@]}"; do echo "    - ${x}"; done
  fi
  if (( ${#SKIPPED[@]} > 0 )); then
    echo "  Skills not targeted at this machine/agent: ${#SKIPPED[@]}"
    for x in "${SKIPPED[@]}"; do echo "    - ${x}"; done
  fi
  if (( ${#UNJUDGED_RESOLVE[@]} > 0 )); then
    echo "  Not installed because the manifest could not be read: ${#UNJUDGED_RESOLVE[@]}"
    for x in "${UNJUDGED_RESOLVE[@]}"; do echo "    - ${x}"; done
  fi
  if (( ${#STALE[@]} > 0 )); then
    echo "  Installed but no longer targeted (re-run with --prune to remove):"
    for x in "${STALE[@]}"; do echo "    - ${x}"; done
  fi
  if (( ${#UNJUDGED[@]} > 0 )); then
    echo "  Installed, but the resolver could not judge them (left alone):"
    for x in "${UNJUDGED[@]}"; do echo "    - ${x}"; done
  fi
  if (( ${#UNMANAGED[@]} > 0 )); then
    echo "  Skill directories with a plain SKILL.md (copy, or someone else's) not targeted here — left untouched:"
    for x in "${UNMANAGED[@]}"; do echo "    - ${x}"; done
  fi
  if (( ${#PRUNED[@]} > 0 )); then
    echo "  Pruned: ${#PRUNED[@]}"
    for x in "${PRUNED[@]}"; do echo "    - ${x}"; done
  fi
  if (( ${#BACKED_UP[@]} > 0 )); then
    echo "  Files backed up before overwrite: ${#BACKED_UP[@]}"
    for x in "${BACKED_UP[@]}"; do echo "    - ${x}"; done
  fi
  if (( ${#NEEDS_SYNC[@]} > 0 )); then
    echo "  Forks needing /sync-upstream:"
    for x in "${NEEDS_SYNC[@]}"; do echo "    - ${x}"; done
  fi
  if (( ${#UNKNOWN_PLUGIN[@]} > 0 )); then
    echo "  Plugins not installed locally (forks ignored):"
    for x in "${UNKNOWN_PLUGIN[@]}"; do echo "    - ${x}"; done
  fi
  if (( ${#JSON_ERROR[@]} > 0 )); then
    echo "  Malformed JSON encountered (manual fix required):"
    for x in "${JSON_ERROR[@]}"; do echo "    - ${x}"; done
  fi
}

on_error() {
  local lineno="$1"
  echo >&2
  echo "==> ERROR at line ${lineno}. Bootstrap aborted mid-flight; partial state below." >&2
  print_summary >&2
  exit 1
}

trap 'on_error $LINENO' ERR

# Back up dst → dst.bak.<UTC> if it exists and differs from src. Idempotent: re-running
# with identical files is a no-op. Timestamp-suffixed: every bootstrap that finds a
# differing file creates a new backup rather than overwriting the previous one. This
# protects manual user edits across multiple bootstrap runs (the single .bak slot
# would have silently overwritten the previous backup, losing the user's customisation).
# Backups are gitignored (see .gitignore: *.bak.*) and intended for ad-hoc recovery —
# the canonical source-of-truth is still the local-forks repo.
#
# Used for plugin-cache restoration only (the cache layout expects regular files);
# skills go through install_skill_symlink() instead, which avoids the dual-copy problem.
backup_if_differs() {
  local src="$1" dst="$2"
  if [[ -f "${dst}" ]] && ! cmp -s "${src}" "${dst}"; then
    local stamp
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    local bak="${dst}.bak.${stamp}"
    cp "${dst}" "${bak}"
    BACKED_UP+=("${bak#${HOME}/}")
  fi
}

# Install a single skill .md as a symlink pointing into local-forks/skills/<n>/.
# Single source of truth: editing ~/.claude/skills/<n>/<file>.md is the same as
# editing local-forks/skills/<n>/<file>.md — no second copy to keep in sync,
# no drift detection needed.
#
# Migration from the previous copy-based bootstrap: if dst is a regular file
# (or a stale symlink pointing elsewhere) with content different from the
# source, the previous content is preserved as <dst>.bak.<UTC> before the
# replacement. If the content already matches, no backup is created — the
# copy was already in sync, replacing it with a symlink is a silent upgrade.
install_skill_symlink() {
  local src="$1" dst="$2"
  # Already a symlink to the right target? No-op.
  if [[ -L "${dst}" ]] && [[ "$(readlink -f -- "${dst}")" == "$(readlink -f -- "${src}")" ]]; then
    return 0
  fi
  # dst exists with different content → preserve the previous content.
  if [[ -e "${dst}" ]] && ! cmp -s "${src}" "${dst}"; then
    local stamp
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    local bak="${dst}.bak.${stamp}"
    cp -- "${dst}" "${bak}"
    BACKED_UP+=("${bak#${HOME}/}")
  fi
  # `ln -sfn` forces replacement of any existing regular file or symlink at dst,
  # and the -n flag prevents the "create-symlink-inside-existing-dir-symlink" trap.
  ln -sfn -- "${src}" "${dst}"
}

# Detect which machine we are on, to point the machine-specific layer symlink
# (_tracked/machines/current) at the right profile. Resolution order:
#   1. explicit override in _meta/machine-id (gitignored, per-machine) — wins
#   2. marker-file probes (robust to hostname churn)
# Prints the machine id, or empty string if undetected. Extend the probe list
# here when adding a new machine profile under _tracked/machines/<id>/.
detect_machine() {
  local idfile="${LOCAL_FORKS}/_meta/machine-id" id=""
  if [[ -f "${idfile}" ]]; then
    id="$(head -n1 "${idfile}" | tr -d '[:space:]')"
  fi
  # An existing but empty file is not an answer: fall through to the symlink,
  # the way skill-targets.sh does, or the two disagree about this machine.
  if [[ -n "${id}" ]]; then
    echo "${id}"
    return 0
  fi
  # Same second source skill-targets.sh uses. Without it the resolver could
  # answer "home-wsl" from the symlink while this function answered "none", and
  # a single run would act on two different machines.
  local cur="${LOCAL_FORKS}/_tracked/machines/current"
  if [[ -L "${cur}" ]]; then
    basename "$(readlink "${cur}")"
    return 0
  fi
  # Add marker-file probes for your machines here, e.g.:
  #   if [[ -f /some/machine-marker ]]; then echo "my-laptop"; return 0; fi
  echo ""
}

if [[ ! -d "${LOCAL_FORKS}" ]]; then
  echo "error: ${LOCAL_FORKS} does not exist. Clone the remote first:" >&2
  echo "  git clone <remote-url> ${LOCAL_FORKS}" >&2
  exit 1
fi

if [[ ! -f "${INSTALLED_JSON}" ]]; then
  echo "warning: ${INSTALLED_JSON} not found — plugin cache step will be skipped."
fi

mkdir -p "${SKILLS_DIR}"

# Step 0.5 — write the machinery pointer before anything reads it.
write_machinery_pointer
echo "==> Machinery root: ${MACHINERY_ROOT} (recorded in _meta/machinery-root)"

# Step 1 — point the machine-specific layer at the detected machine.
# This runs BEFORE skill install so the id it resolves can be handed to the
# resolver directly (--machine), keeping one answer for "which machine is this"
# instead of two implementations that can disagree. The fresh-clone abort itself
# is fixed by the non-fatal resolver call below, not by this ordering.
# The thin ~/.claude/CLAUDE.md imports @…/machines/current/CLAUDE.md; `current`
# is a per-machine symlink (gitignored, see .gitignore) we set here. A relative
# target keeps it self-contained inside machines/.
MACHINES_DIR="${TRACKED_DIR}/machines"
if [[ -d "${MACHINES_DIR}" ]]; then
  MACHINE_ID="$(detect_machine)"
  if [[ -n "${MACHINE_ID}" && -d "${MACHINES_DIR}/${MACHINE_ID}" ]]; then
    MACHINE_PROFILE_OK=1
    ln -sfn -- "${MACHINE_ID}" "${MACHINES_DIR}/current"
    echo "==> Machine layer: current → machines/${MACHINE_ID}"
  else
    echo "==> NOTE: machine layer not set (detected: '${MACHINE_ID:-none}')."
    echo "    Create _tracked/machines/<id>/ and write the id to _meta/machine-id, then re-run."
  fi
fi


echo "==> Installing system skills as symlinks into ${SKILLS_DIR}"

# Which skills belong on this machine, for which agent, is resolved by
# skill-targets.sh from skills/<name>/install.json (schema:
# _system/_shared/install-manifest.md). /pull-forks is told to call the same
# resolver — prose, so it teaches rather than guarantees; this script is the
# enforced half. A skill already present in SKILLS_DIR but no
# longer targeted here is reported, never deleted — removal is --prune, opt-in,
# because the live directory may hold skills this repo does not own.
TARGETS_FILE="$(mktemp)"
trap 'rm -f "${TARGETS_FILE}"' EXIT
resolver_args=()
[[ -n "${MACHINE_ID:-}" ]] && resolver_args+=(--machine "${MACHINE_ID}")
TARGETS_OK=1
if ! "${SCRIPTS_DIR}/skill-targets.sh" "${resolver_args[@]+"${resolver_args[@]}"}" \
     > "${TARGETS_FILE}"; then
  TARGETS_OK=0
  echo "==> ERROR: skill targeting could not be resolved (message above)." >&2
  echo "    No skill installed, and the stale sweep is disarmed — with no decision" >&2
  echo "    file every installed skill would read as 'not targeted' and --prune" >&2
  echo "    would delete all of them. Everything else below still runs." >&2
  : > "${TARGETS_FILE}"
fi

while IFS=$'\t' read -r skill_name decision _agents reason; do
  [[ -n "${skill_name}" ]] || continue
  if [[ "${decision}" == "unknown" ]]; then
    UNJUDGED_RESOLVE+=("${skill_name} (${reason})")
    continue
  fi
  if [[ "${decision}" != "install" ]]; then
    SKIPPED+=("${skill_name} (${reason})")
    continue
  fi

  skill_dir="${LOCAL_FORKS}/skills/${skill_name}/"

  # Belt and braces: the resolver already emits rows only for directories that
  # have a SKILL.md, so this never fires today — it keeps the loop honest if the
  # resolver's contract ever loosens.
  src_skill="${skill_dir}SKILL.md"
  if [[ ! -f "${src_skill}" ]]; then continue; fi

  # One skill can target both agents; _agents is the resolved intersection of
  # the manifest and what this machine has.
  #
  # The two agents disagree about symlinks, measured on this machine against
  # codex-cli 0.154.0: Claude Code reads a directory of per-file symlinks, while
  # Codex ignores a symlinked SKILL.md in CODEX_HOME/skills and only sees the
  # skill when the DIRECTORY itself is the symlink. (Project-level .codex/skills
  # does follow per-file links — generalising from that to the global root is
  # what produced a Codex install the agent could not see.) So each agent gets
  # the shape it actually reads; both keep a single source of truth in the repo.
  for target_agent in ${_agents//,/ }; do
    case "${target_agent}" in
      claude)
        dst_dir="${SKILLS_DIR}/${skill_name}"
        mkdir -p "${dst_dir}"
        for src in "${skill_dir}"*.md; do
          [[ -f "${src}" ]] || continue
          dst="${dst_dir}/$(basename "${src}")"
          install_skill_symlink "${src}" "${dst}"
          echo "  linked[claude]: ${skill_name}/$(basename "${src}") → ${src#${HOME}/}"
        done
        ;;
      codex)
        mkdir -p "${CODEX_SKILLS_DIR}"
        dst_dir="${CODEX_SKILLS_DIR}/${skill_name}"
        # A directory left by an older bootstrap holds only symlinks into this
        # repo; replacing it loses nothing. Anything else is not ours to remove.
        if [[ -d "${dst_dir}" && ! -L "${dst_dir}" ]]; then
          if [[ -z "$(find "${dst_dir}" -mindepth 1 ! -type l -print -quit 2>/dev/null)" ]]; then
            rm -rf -- "${dst_dir}"
          else
            echo "  skipped[codex]: ${skill_name} — ${dst_dir} holds files we did not put there"
            continue
          fi
        fi
        ln -sfn -- "${skill_dir%/}" "${dst_dir}"
        echo "  linked[codex]: ${skill_name} → ${skill_dir#${HOME}/} (directory)"
        ;;
      *) continue ;;
    esac
  done
done < "${TARGETS_FILE}"

# Skills installed earlier that this machine no longer targets — in either agent
# root. Reported by default; removed only under --prune.
#
# Three install shapes exist in the wild and all three are recognised, because
# reporting only one made the README promise false for the other two:
#   a) directory of per-file symlinks into this repo   (this script)
#   b) a whole-directory symlink into this repo        (/pull-forks)
#   c) plain copies from the pre-symlink bootstrap     (legacy)
# Only (a) and (b) are provably ours, so only those are ever deleted; (c) is
# reported as unmanaged and left alone.
#
# --prune never uses `rm -rf` on a directory wholesale: install_skill_symlink
# writes <file>.bak.<UTC> beside a file it replaces to preserve manual edits,
# those backups are gitignored, and a blanket delete would destroy the only copy.
# Symlinks go, real files stay, and the directory is removed only once empty.
prune_skill_dir() {
  local dir="$1" kept=0
  local entry
  while IFS= read -r entry; do
    # Ownership is per file, not per directory: a symlink pointing somewhere
    # else in the same directory belongs to whoever put it there.
    if [[ -L "${entry}" ]] && [[ "$(readlink -- "${entry}")" == "${LOCAL_FORKS}/"* ]]; then
      rm -f -- "${entry}"
    else
      kept=$((kept + 1))
    fi
  done < <(find "${dir}" -mindepth 1 -maxdepth 1 2>/dev/null)
  if (( kept == 0 )); then
    rmdir -- "${dir}" 2>/dev/null || true
  fi
  echo "${kept}"
}

# Both guards are about the same failure: a decision file that does not actually
# say "these skills do not belong here". An empty one (resolver failed) makes
# every skill look untargeted; an unresolved machine makes every machine-scoped
# skill look untargeted. Neither is evidence for deletion.
SWEEP_OK=1
if (( ! TARGETS_OK )); then
  SWEEP_OK=0
elif [[ ! -s "${TARGETS_FILE}" ]]; then
  # The resolver can exit 0 with no rows at all — a skills/ directory that is
  # missing, renamed or empty produces exactly that. Judging by exit code alone
  # left every installed skill reading as "not targeted", which is the deletion
  # this guard exists to stop; the file being non-empty is the real condition.
  SWEEP_OK=0
  echo "==> Stale sweep skipped: the resolver returned no rows at all."
  echo "    Check that ${LOCAL_FORKS}/skills exists and holds skill directories."
elif (( ! MACHINE_PROFILE_OK )); then
  # Belt to the resolver's braces: with no profile every machine-scoped skill
  # already comes back as `unknown`, which the sweep refuses to act on. Stopping
  # the whole sweep as well keeps a run that cannot name its own machine from
  # deleting anything at all.
  SWEEP_OK=0
  echo "==> Stale sweep skipped: machine profile unresolved (id '${MACHINE_ID:-none}')."
  echo "    Machine-scoped skills cannot be judged; fix _meta/machine-id or add"
  echo "    _tracked/machines/<id>/ and re-run."
fi
if (( PRUNE && ! SWEEP_OK )); then
  echo "==> --prune REFUSED: nothing here proves a skill does not belong." >&2
fi

for install_root in "${SKILLS_DIR}" "${CODEX_SKILLS_DIR}"; do
  (( SWEEP_OK )) || break
  [[ -d "${install_root}" ]] || continue
  root_agent="claude"; [[ "${install_root}" == "${CODEX_SKILLS_DIR}" ]] && root_agent="codex"
  while IFS= read -r live_entry; do
    live_name="$(basename "${live_entry}")"
    # A skill deleted from the repo leaves its symlinks dangling; those are ours
    # to report and prune as well, so absence from skills/ is not a skip — the
    # symlink-target check below is what proves ownership.

    # Three outcomes, and only one of them licenses deletion:
    #   install for this agent  → belongs here, leave alone
    #   unknown                 → the resolver could not judge it; not evidence
    #   skip / no row           → it belongs elsewhere
    decision="$(awk -F'\t' -v n="${live_name}" '$1==n { print $2; exit }' "${TARGETS_FILE}")"
    if [[ "${decision}" == "unknown" ]]; then
      reason="$(awk -F'\t' -v n="${live_name}" '$1==n { print $4; exit }' "${TARGETS_FILE}")"
      UNJUDGED+=("${live_name} (${root_agent}) — ${reason}")
      continue
    fi
    if awk -F'\t' -v n="${live_name}" -v a="${root_agent}" \
         '$1==n && $2=="install" { split($3, xs, ","); for (i in xs) if (xs[i]==a) found=1 }
          END { exit !found }' "${TARGETS_FILE}"; then
      continue
    fi

    if [[ -L "${live_entry}" ]]; then
      # shape (b): whole-directory symlink
      case "$(readlink -- "${live_entry}")" in
        "${LOCAL_FORKS}/"*) ;;
        *) continue ;;
      esac
      if (( PRUNE )); then
        rm -f -- "${live_entry}"
        PRUNED+=("${live_name} (${root_agent}, dir symlink)")
      else
        STALE+=("${live_name} (${root_agent})")
      fi
      continue
    fi

    live_md="${live_entry}/SKILL.md"
    if [[ -L "${live_md}" ]]; then
      # shape (a): per-file symlinks
      case "$(readlink -- "${live_md}")" in
        "${LOCAL_FORKS}/"*) ;;
        *) continue ;;
      esac
      if (( PRUNE )); then
        kept="$(prune_skill_dir "${live_entry}")"
        if (( kept > 0 )); then
          PRUNED+=("${live_name} (${root_agent}, ${kept} entr(y|ies) kept — backups or files we do not own)")
        else
          PRUNED+=("${live_name} (${root_agent})")
        fi
      else
        STALE+=("${live_name} (${root_agent})")
      fi
    elif [[ -f "${live_md}" ]]; then
      # shape (c): legacy copy — ours by name only, so never deleted
      UNMANAGED+=("${live_name} (${root_agent}, plain copy — remove by hand if unwanted)")
    fi
  done < <(find "${install_root}" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) 2>/dev/null)
done

# Step 2 — restore tracked top-level files (CLAUDE.md and anything it @-imports)
# alongside it in ~/.claude/. A file is restored only if the live copy is missing;
# an existing live file is preserved (it may be a workspace-managed symlink or a
# manually-edited copy — reconcile via /reflect-session / /sync-upstream).
#
# Why RTK.md is here: ~/.claude/CLAUDE.md ends with `@RTK.md`, an import that
# resolves relative to CLAUDE.md's directory. Without the import target on disk
# the live CLAUDE.md restores cleanly but the RTK block is silently dropped on
# a fresh machine. Track both files together to keep cross-machine restore whole.
restore_tracked_file() {
  local tracked="$1" live="$2" name="$3"
  [[ -f "${tracked}" ]] || return 0
  if [[ ! -e "${live}" ]]; then
    cp "${tracked}" "${live}"
    echo "==> Restored ${live} from _tracked/${name}"
  elif ! cmp -s "${tracked}" "${live}"; then
    echo "==> NOTE: ${live} exists and differs from _tracked/${name}."
    echo "    Live file preserved. Reconcile manually or via /reflect-session."
  fi
}

mkdir -p "${LIVE_CLAUDE_DIR}"
restore_tracked_file "${TRACKED_DIR}/CLAUDE.md" "${LIVE_CLAUDE_DIR}/CLAUDE.md" "CLAUDE.md"
restore_tracked_file "${TRACKED_DIR}/RTK.md"    "${LIVE_CLAUDE_DIR}/RTK.md"    "RTK.md"

# statusline.sh is referenced by settings.json:statusLine.command as an absolute
# ~/.claude/ path. Unlike CLAUDE.md/RTK.md it is symlinked (not copied), so live
# edits flow back to _tracked/ source-of-truth without a re-copy step — same
# single-source-of-truth contract as the system skills above.
if [[ -f "${TRACKED_DIR}/statusline.sh" ]]; then
  chmod +x "${TRACKED_DIR}/statusline.sh"
  install_skill_symlink "${TRACKED_DIR}/statusline.sh" "${LIVE_CLAUDE_DIR}/statusline.sh"
  echo "==> Linked statusline.sh → _tracked/statusline.sh"
fi

# Step 2.4 — project the tracked rule layers into Codex's AGENTS.md. Claude Code
# gets the layers through @-imports in ~/.claude/CLAUDE.md; Codex has no import
# mechanism, so the same layers are concatenated into one generated file (see
# build-agents-md.sh for the measurements behind that). Runs only when a Codex
# home exists — a machine without Codex gets nothing written.
CODEX_HOME_DIR="${CODEX_HOME:-${HOME}/.codex}"
if [[ -d "${CODEX_HOME_DIR}" ]]; then
  if ! "${SCRIPTS_DIR}/build-agents-md.sh"; then
    echo "==> NOTE: Codex rule layer NOT installed (see the message above)."
    echo "    Claude Code is unaffected; fix the cause and re-run bootstrap."
  fi
fi

# Step 2.5 — install the repo's deterministic pre-commit gate. Git hooks are not
# cloneable, so something has to be placed in .git/hooks on every machine.
#
# What goes there is a small resolver, not a symlink to this checkout. A symlink
# would pin the hook to wherever bootstrap happened to run from — under a plugin
# install that is a VERSIONED cache path (…/reflectory/0.3.1/…), so the next
# plugin update leaves the link dangling and every gate silently stops firing.
# The resolver looks the scripts up at commit time instead, in order of
# specificity, and says so loudly if it finds nothing.
#
# See _system/scripts/pre-commit for what the gate checks and why prose alone is
# not enough (dual-circuit enforcement).
if [[ -f "${SCRIPTS_DIR}/pre-commit" && -d "${LOCAL_FORKS}/.git/hooks" ]]; then
  chmod +x "${SCRIPTS_DIR}/pre-commit"
  # Unlink first: an earlier bootstrap left a SYMLINK here, and `cat >` follows
  # it — the write lands in the link's target, which is the gate script itself.
  # That is how a run of this step destroyed the very file the hook calls.
  rm -f "${LOCAL_FORKS}/.git/hooks/pre-commit"
  cat > "${LOCAL_FORKS}/.git/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
# GENERATED by reflectory bootstrap.sh — do not edit.
# Finds the gate at commit time so a plugin update cannot leave it dangling.
set -uo pipefail

# The skills' resolver plus one candidate they cannot have: git runs this hook
# from the repo root, so a full-clone layout carries the machinery right there.
# No version-numbered glob — sorting cache directories by mtime picks whichever
# was touched last, not the installed one.
root_file="${LOCAL_FORKS:-${HOME}/.claude/local-forks}/_meta/machinery-root"
candidates=()
[[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]] && candidates+=("${CLAUDE_PLUGIN_ROOT}/_system/scripts/pre-commit")
[[ -r "${root_file}" ]] && candidates+=("$(head -1 "${root_file}")/_system/scripts/pre-commit")
# The pointer is absent until the first bootstrap, and a git hook has no
# CLAUDE_PLUGIN_ROOT, so the stable install roots stay in the chain: without them
# a fresh plugin-install machine could not commit into the data repo at all.
candidates+=("${HOME}/.claude/plugins/marketplaces/reflectory/_system/scripts/pre-commit")
candidates+=("${HOME}/.codex/.tmp/marketplaces/reflectory/_system/scripts/pre-commit")
candidates+=("$(git rev-parse --show-toplevel 2>/dev/null)/_system/scripts/pre-commit")

for c in "${candidates[@]}"; do
  if [[ -f "${c}" ]]; then
    exec bash "${c}" "$@"
  fi
done

echo "pre-commit: reflectory gate not found — checked:" >&2
printf '  %s\n' "${candidates[@]}" >&2
echo "Re-run bootstrap.sh, or remove this hook if reflectory is gone." >&2
exit 1
HOOK
  chmod +x "${LOCAL_FORKS}/.git/hooks/pre-commit"
  echo "==> Installed pre-commit hook (resolves the gate at commit time)"
fi

# Step 2.6 — settings.json is machine-local (not in this repo): verify the
# hook registrations survived the machine move; registration itself is a
# one-time manual step (see each script's header for the settings.json shape).
if [[ -f "${LIVE_CLAUDE_DIR}/settings.json" ]]; then
  # Presence of the name is not enough: a registration may point at a path that
  # no longer exists (a machine that used to carry a second copy of the machinery,
  # a plugin version directory that was cleaned up). A hook whose script is gone
  # fails silently — nothing in the session says the reminder stopped firing.
  check_hook_registration() {
    local name="$1" event="$2" registered
    if ! grep -q "${name}" "${LIVE_CLAUDE_DIR}/settings.json"; then
      echo "==> NOTE: ${name} ${event} hook is not registered in settings.json."
      echo "    Add to hooks.${event}: python3 ${SCRIPTS_DIR}/${name}.py"
      echo "    (absolute path — the hook runner expands neither ~ nor \$HOME. If that path"
      echo "     carries a version number, re-run bootstrap after a plugin update: this check"
      echo "     reports the registration as dead once the version directory is gone.)"
      return
    fi
    # Address-then-block, not `| head -1`: under `set -o pipefail` the closed pipe
    # kills the whole assignment on a large file, taking bootstrap with it. And
    # `{` is not a valid `s///` flag — it has to hang off an address match.
    registered="$(sed -n "/${name}\.py/{s|.*\"command\"[^\"]*\"[^\"]*python3 \([^\"]*${name}\.py\).*|\1|p;q;}" \
      "${LIVE_CLAUDE_DIR}/settings.json")"
    # A hand-written registration may carry ~ or $HOME; `-f` expands neither, and
    # reporting such a path as dead would be a false alarm.
    registered="${registered/#\~/${HOME}}"
    registered="${registered//\$HOME/${HOME}}"
    if [[ -n "${registered}" && ! -f "${registered}" ]]; then
      echo "==> WARNING: ${name} ${event} hook points at a path that does not exist:"
      echo "      ${registered}"
      echo "    The hook is dead and fails silently. Repoint it at:"
      echo "      python3 ${SCRIPTS_DIR}/${name}.py"
    fi
  }
  check_hook_registration reflect-reminder Stop
  check_hook_registration capture-corrections UserPromptSubmit
  if [[ -f "${TRACKED_DIR}/statusline.sh" ]] && ! grep -q "statusline.sh" "${LIVE_CLAUDE_DIR}/settings.json"; then
    echo "==> NOTE: statusLine is not registered in settings.json."
    echo "    Add: statusLine.command = bash ${LIVE_CLAUDE_DIR}/statusline.sh"
  fi
fi

# Step 2.7 — Codex hook registration is machine-local too (~/.codex/hooks.json),
# and Codex additionally records a trusted_hash per hook in config.toml: editing
# a registered hook invalidates that hash until the user re-trusts it. So this is
# a check-and-report step, exactly like settings.json above — bootstrap never
# writes hooks.json.
#
# The two hook scripts are agent-agnostic by payload: Codex sends `prompt` and
# `session_id` on UserPromptSubmit and `transcript_path`/`stop_hook_active` on
# Stop, the same field names Claude Code uses (schemas read out of the codex
# binary, 0.154.0), and transcript_reader.py absorbs the transcript-format
# difference.
CODEX_HOOKS_JSON="${CODEX_HOME:-${HOME}/.codex}/hooks.json"
if [[ -d "${CODEX_HOME:-${HOME}/.codex}" ]]; then
  for hook_script in capture-corrections reflect-reminder; do
    if [[ ! -f "${CODEX_HOOKS_JSON}" ]] || ! grep -q "${hook_script}" "${CODEX_HOOKS_JSON}"; then
      case "${hook_script}" in
        capture-corrections) hook_event="UserPromptSubmit" ;;
        reflect-reminder)    hook_event="Stop" ;;
      esac
      echo "==> NOTE: ${hook_script} is not registered in ${CODEX_HOOKS_JSON} (${hook_event})."
      echo "    hooks.json has its own shape — add an entry under hooks.${hook_event}:"
      echo "      { \"hooks\": [ { \"type\": \"command\","
      echo "          \"command\": \"python3 ${SCRIPTS_DIR}/${hook_script}.py\" } ] }"
      echo "    The file already carries Superset entries — merge, do not replace."
      echo "    Codex pins a trusted_hash per hook in config.toml; after editing,"
      echo "    Codex asks to re-trust the hook before it runs again."
    fi
  done
fi

if [[ -f "${INSTALLED_JSON}" ]]; then
  echo "==> Restoring forked artefacts into plugin cache"

  while IFS= read -r meta_file; do
    plugin_dir="$(dirname "${meta_file}")"
    rel_path="${plugin_dir#${LOCAL_FORKS}/}"
    marketplace="$(echo "${rel_path}" | cut -d/ -f1)"
    plugin_name="$(echo "${rel_path}" | cut -d/ -f2)"

    # Skip system / tracking dirs that happen to live at the same depth.
    # _local is gitignored personal scratch (see .gitignore, README Layout).
    # _archived holds forks whose upstream artefact was removed (see RETIRE.md
    # and /sync-upstream Failure handling) — they are not applied to plugin cache.
    case "${marketplace}" in
      _system|_meta|_sessions|_tracked|_local|_archived) continue ;;
    esac

    # Differentiate "no key" from "malformed JSON" by probing the file once.
    if ! jq -e '.' "${meta_file}" >/dev/null 2>&1; then
      JSON_ERROR+=("${rel_path}/_meta.json (malformed JSON)")
      continue
    fi
    baseline_upstream_version="$(jq -r '.baseline_upstream_version // empty' "${meta_file}")"
    if [[ -z "${baseline_upstream_version}" ]]; then
      echo "  skip: ${rel_path} (no baseline_upstream_version in _meta.json)"
      continue
    fi

    if ! jq -e '.' "${INSTALLED_JSON}" >/dev/null 2>&1; then
      JSON_ERROR+=("${INSTALLED_JSON} (malformed JSON)")
      break
    fi
    installed_version="$(
      jq -r --arg key "${plugin_name}@${marketplace}" \
        '.plugins[$key][0].version // empty' "${INSTALLED_JSON}"
    )"

    if [[ -z "${installed_version}" ]]; then
      UNKNOWN_PLUGIN+=("${plugin_name}@${marketplace}")
      continue
    fi

    if [[ "${installed_version}" != "${baseline_upstream_version}" ]]; then
      NEEDS_SYNC+=("${plugin_name}@${marketplace}: baseline ${baseline_upstream_version} → installed ${installed_version}")
      continue
    fi

    plugin_cache_root="${PLUGINS_CACHE}/${marketplace}/${plugin_name}/${installed_version}"
    if [[ ! -d "${plugin_cache_root}" ]]; then
      NEEDS_SYNC+=("${plugin_name}@${marketplace}: cache dir missing")
      continue
    fi

    while IFS= read -r fork_file; do
      case "${fork_file}" in
        *.intent.md|*/_meta.json) continue ;;
      esac
      rel_within_plugin="${fork_file#${plugin_dir}/}"
      dst="${plugin_cache_root}/${rel_within_plugin}"
      mkdir -p "$(dirname "${dst}")"
      backup_if_differs "${fork_file}" "${dst}"
      cp "${fork_file}" "${dst}"
      APPLIED+=("${plugin_name}/${rel_within_plugin}")
    done < <(find "${plugin_dir}" -type f \( -name "*.md" -o -name "*.json" \) ! -name "_meta.json")

  done < <(find "${LOCAL_FORKS}" -mindepth 3 -maxdepth 3 -name "_meta.json" 2>/dev/null)
fi

# Sanity guard against silent installed_plugins.json schema drift.
# If every fork we tried to look up landed in UNKNOWN_PLUGIN, the parser
# (`.plugins[$key][0].version`) is no longer compatible with Claude Code's
# format. Surface this so the user investigates before treating bootstrap
# output as ground truth.
total_forks=$(( ${#APPLIED[@]} + ${#NEEDS_SYNC[@]} + ${#UNKNOWN_PLUGIN[@]} ))
# Schema guard fires only if we actually walked every fork without aborting
# on malformed JSON. With JSON_ERROR non-empty we may have broken out of the
# main loop early — the all-UNKNOWN observation would then be a parsing
# artefact, not a schema-change signal.
if (( ${#JSON_ERROR[@]} == 0 && total_forks > 0 && ${#APPLIED[@]} == 0 && ${#NEEDS_SYNC[@]} == 0 && ${#UNKNOWN_PLUGIN[@]} == total_forks )); then
  echo
  echo "==> WARNING: every fork resolved to UNKNOWN_PLUGIN."
  echo "    This usually means installed_plugins.json schema has changed and"
  echo "    the parser in bootstrap.sh (.plugins[\$key][0].version) is out of date."
  echo "    Inspect ${INSTALLED_JSON} and update the jq path if needed."
fi

# Plugin-rename hint. If the schema guard above didn't fire but UNKNOWN_PLUGIN
# is still non-empty, the most common cause is an upstream rename: the plugin
# now lives under <new_name>@<marketplace> in installed_plugins.json while our
# fork directory still uses <old_name>. The user has to mv the directory manually.
if (( ${#UNKNOWN_PLUGIN[@]} > 0 )) \
   && ! (( total_forks > 0 && ${#APPLIED[@]} == 0 && ${#NEEDS_SYNC[@]} == 0 && ${#UNKNOWN_PLUGIN[@]} == total_forks )); then
  echo
  echo "==> HINT: ${#UNKNOWN_PLUGIN[@]} fork(s) point at plugin(s) not installed locally."
  echo "    Common cause: upstream renamed the plugin. To recover:"
  echo "    1) Inspect the current keys in ${INSTALLED_JSON}"
  echo "    2) git mv ~/.claude/local-forks/<marketplace>/<old_plugin> ~/.claude/local-forks/<marketplace>/<new_plugin>"
  echo "    3) Re-run bootstrap"
fi

print_summary

echo
echo "Next steps in Claude Code:"
echo "  /reload-plugins                 # pick up freshly written plugin files"
if (( ${#NEEDS_SYNC[@]} > 0 )); then
  echo "  /sync-upstream                  # re-apply intent logs to mismatched plugin versions"
fi
