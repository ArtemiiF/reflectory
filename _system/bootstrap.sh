#!/usr/bin/env bash
# bootstrap.sh — set up local-forks on a fresh machine.
#
# Run after `git clone <remote> ~/.claude/local-forks`.
#
# What it does:
#   1. Symlink each ~/.claude/local-forks/skills/<skill>/*.md (SKILL.md + method.md
#      + any other reference files) into ~/.claude/skills/<skill>/ so the system
#      skills are fully invocable AND any edit through the live path flows back
#      to the source of truth without a second copy to keep in sync.
#   2. Restore ~/.claude/CLAUDE.md from _tracked/CLAUDE.md if the tracked copy
#      exists and the live file is missing. Existing live file is preserved —
#      use /sync-upstream or manual reconciliation to merge.
#   3. For every forked plugin artefact under <marketplace>/<plugin>/...:
#        - read baseline_upstream_version from <plugin>/_meta.json
#        - check ~/.claude/plugins/installed_plugins.json for the installed version
#        - if versions match → copy our forked file into the plugin cache (edit-in-place)
#        - if installed version differs → record in NEEDS_SYNC and skip
#   4. Print a summary; tell the user to run /reload-plugins and (if needed) /sync-upstream.
#
# Constraints:
#   - Idempotent. Re-running with no changes does nothing destructive.
#   - Never writes outside ~/.claude/ .
#   - Never touches ~/.gitconfig or any global config.
#   - Pre-existing regular-file ~/.claude/skills/<name>/SKILL.md (or other .md)
#     is backed up to <file>.bak.<UTC> only if its content differs from the
#     symlink target; matching copies are silently upgraded to symlinks.

set -euo pipefail

LOCAL_FORKS="${HOME}/.claude/local-forks"
SKILLS_DIR="${HOME}/.claude/skills"
PLUGINS_CACHE="${HOME}/.claude/plugins/cache"
INSTALLED_JSON="${HOME}/.claude/plugins/installed_plugins.json"
TRACKED_DIR="${LOCAL_FORKS}/_tracked"
LIVE_CLAUDE_DIR="${HOME}/.claude"

# Summary arrays — declared early so the ERR trap can print whatever state
# accumulated before the failure.
declare -a APPLIED=()
declare -a NEEDS_SYNC=()
declare -a UNKNOWN_PLUGIN=()
declare -a JSON_ERROR=()
declare -a BACKED_UP=()

print_summary() {
  echo
  echo "==> Summary"
  echo "  System skills linked:      $(ls "${SKILLS_DIR}" 2>/dev/null | wc -l) skill(s)"
  echo "  Forks applied to cache:    ${#APPLIED[@]}"
  if (( ${#APPLIED[@]} > 0 )); then
    for x in "${APPLIED[@]}"; do echo "    - ${x}"; done
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

# Install a single skill .md as a symlink pointing into local-forks/_system/<n>/.
# Single source of truth: editing ~/.claude/skills/<n>/<file>.md is the same as
# editing local-forks/_system/<n>/<file>.md — no second copy to keep in sync,
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
  local idfile="${LOCAL_FORKS}/_meta/machine-id"
  if [[ -f "${idfile}" ]]; then
    head -n1 "${idfile}" | tr -d '[:space:]'
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

echo "==> Installing system skills as symlinks into ${SKILLS_DIR}"

for skill_dir in "${LOCAL_FORKS}/skills"/*/; do
  skill_name="$(basename "${skill_dir}")"

  # Skip helper dirs (no SKILL.md). _shared/, scripts/, etc.
  src_skill="${skill_dir}SKILL.md"
  if [[ ! -f "${src_skill}" ]]; then continue; fi

  dst_dir="${SKILLS_DIR}/${skill_name}"
  mkdir -p "${dst_dir}"

  # Symlink every .md file in the skill directory (SKILL.md, method.md, references).
  # Single source of truth: edits flow back through the symlink into local-forks
  # source-of-truth, then through git. Migration from previous copy-based bootstraps
  # is automatic — see install_skill_symlink() for the backup logic.
  for src in "${skill_dir}"*.md; do
    [[ -f "${src}" ]] || continue
    dst="${dst_dir}/$(basename "${src}")"
    install_skill_symlink "${src}" "${dst}"
    echo "  linked: ${skill_name}/$(basename "${src}") → ${src#${HOME}/}"
  done
done

# Step 1.5 — point the machine-specific layer at the detected machine.
# The thin ~/.claude/CLAUDE.md imports @…/machines/current/CLAUDE.md; `current`
# is a per-machine symlink (gitignored, see .gitignore) we set here. A relative
# target keeps it self-contained inside machines/.
MACHINES_DIR="${TRACKED_DIR}/machines"
if [[ -d "${MACHINES_DIR}" ]]; then
  MACHINE_ID="$(detect_machine)"
  if [[ -n "${MACHINE_ID}" && -d "${MACHINES_DIR}/${MACHINE_ID}" ]]; then
    ln -sfn -- "${MACHINE_ID}" "${MACHINES_DIR}/current"
    echo "==> Machine layer: current → machines/${MACHINE_ID}"
  else
    echo "==> NOTE: machine layer not set (detected: '${MACHINE_ID:-none}')."
    echo "    Create _tracked/machines/<id>/ and write the id to _meta/machine-id, then re-run."
  fi
fi

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

# Step 2.5 — install the repo's deterministic pre-commit gate. Git hooks are not
# cloneable, so the tracked script is linked into .git/hooks on every bootstrap.
# See _system/scripts/pre-commit for why this exists (dual-circuit enforcement:
# the prose instruction in /reflect-session Step 6 is advisory; the hook fires
# on every commit regardless).
if [[ -f "${LOCAL_FORKS}/_system/scripts/pre-commit" && -d "${LOCAL_FORKS}/.git/hooks" ]]; then
  chmod +x "${LOCAL_FORKS}/_system/scripts/pre-commit"
  ln -sfn -- "${LOCAL_FORKS}/_system/scripts/pre-commit" "${LOCAL_FORKS}/.git/hooks/pre-commit"
  echo "==> Installed pre-commit hook (frontmatter verification gate)"
fi

# Step 2.6 — settings.json is machine-local (not in this repo): verify the
# reflect-reminder Stop hook survived the machine move; registration itself
# is a one-time manual step (see _system/scripts/reflect-reminder.py header).
if [[ -f "${LIVE_CLAUDE_DIR}/settings.json" ]] \
   && ! grep -q "reflect-reminder" "${LIVE_CLAUDE_DIR}/settings.json"; then
  echo "==> NOTE: reflect-reminder Stop hook is not registered in settings.json."
  echo "    Add it to hooks.Stop: python3 ${LOCAL_FORKS}/_system/scripts/reflect-reminder.py"
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
