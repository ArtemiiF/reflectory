#!/usr/bin/env bash
# build-agents-md.sh — project the tracked rule layers into Codex's AGENTS.md.
#
# Claude Code loads the layers through @-imports in ~/.claude/CLAUDE.md, so the
# files stay separate there. Codex has no import mechanism: a `@file.md` line in
# AGENTS.md is not substituted — the model merely sees the reference and may
# decide to `cat` it (measured 2026-09-16: the token behind an `@`-line was only
# found after the model ran `cat` itself; text written directly in AGENTS.md
# came back with no command run). Rules that load "if the model feels like it"
# are not rules, so the layers are concatenated into one generated file.
#
# Usage:
#   build-agents-md.sh              # write $CODEX_HOME/AGENTS.md
#   build-agents-md.sh --check      # exit 1 if the generated file is missing or stale
#   build-agents-md.sh --stdout     # print, write nothing
#   build-agents-md.sh --force      # overwrite a hand-written AGENTS.md (backed up first)
#
# The generated file carries the source list and a sha256 of the concatenated
# inputs, which is what --check compares against — so a layer edited in the repo
# and never re-projected is caught mechanically, not by memory.
#
# Byte budget: Codex truncates the project doc at `project_doc_max_bytes`
# (default 32768 — measured: a 63KB AGENTS.md lost its tail silently, and the
# same file read whole once the limit was raised). The script fails when the
# projection exceeds the effective limit, because a silently truncated rule
# layer is worse than none: the rules look installed and are not there.

set -euo pipefail

LOCAL_FORKS="${LOCAL_FORKS:-${HOME}/.claude/local-forks}"
CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
TRACKED="${LOCAL_FORKS}/_tracked"
OUT="${CODEX_HOME}/AGENTS.md"

# Layers, in the load order the thin ~/.claude/CLAUDE.md imports them.
LAYERS=(
  "${TRACKED}/general-rules.md"
  "${TRACKED}/shared.md"
  "${TRACKED}/machines/current/CLAUDE.md"
)

DEFAULT_BUDGET=32768

mode="write"
FORCE=0
while (( $# > 0 )); do
  case "$1" in
    --check)  mode="check"; shift ;;
    --stdout) mode="stdout"; shift ;;
    --force)  FORCE=1; shift ;;   # write mode only; checked after the loop
    *) echo "build-agents-md: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ "${mode}" != "write" && ${FORCE} -eq 1 ]]; then
  echo "build-agents-md: --force only means anything when writing (not with --${mode})." >&2
  exit 2
fi

# Checked before anything else in write mode: complaining about the byte budget
# on a machine that has no Codex at all points the reader at the wrong problem.
if [[ "${mode}" == "write" && ! -d "${CODEX_HOME}" ]]; then
  echo "build-agents-md: ${CODEX_HOME} does not exist — no Codex on this machine." >&2
  echo "Nothing was written." >&2
  exit 1
fi

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else shasum -a 256 | awk '{print $1}'; fi
}

# Effective budget: the key from config.toml if present, else Codex's default.
# Read with a plain grep rather than a TOML parser — the key is top-level and
# scalar, and no TOML parser is guaranteed on these machines.
effective_budget() {
  local cfg="${CODEX_HOME}/config.toml" v=""
  if [[ -f "${cfg}" ]]; then
    # `|| true`: with no such key grep exits 1, and under `set -euo pipefail`
    # that would abort the script instead of falling back to the default.
    v="$(grep -E '^[[:space:]]*project_doc_max_bytes[[:space:]]*=' "${cfg}" 2>/dev/null \
         | head -1 | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/' || true)"
  fi
  echo "${v:-${DEFAULT_BUDGET}}"
}

missing=()
for f in "${LAYERS[@]}"; do
  [[ -f "${f}" ]] || missing+=("${f}")
done
if (( ${#missing[@]} > 0 )); then
  # machines/current is a per-machine symlink created by bootstrap; a missing
  # layer means the machine is not wired yet, which is a setup error, not a
  # reason to project a half-empty rule set.
  echo "build-agents-md: missing layer(s):" >&2
  for f in "${missing[@]}"; do echo "  ${f}" >&2; done
  echo "The machine layer is not wired: _tracked/machines/current should point at" >&2
  echo "this machine profile. Write the id to _meta/machine-id and re-run bootstrap.sh" >&2
  echo "(inside bootstrap, that means this run had no profile to project)." >&2
  exit 1
fi

# The stamp covers the EXPANDED text, so an edit inside an imported file (the
# neuro-matrix protocol layer, say) marks the projection stale as well.
INPUT_SHA=""            # expand_layer is defined below; filled in once it exists

# Expand a layer, inlining its @-imports the way Claude Code resolves them:
# a line that is exactly `@<path>` is replaced by the file it names (~ and
# relative paths resolve against the importing file's directory), recursively,
# with the same 4-hop ceiling Claude Code applies. Without this the machine
# layer reaches Codex as a bare `@/…/neuro-matrix/CLAUDE.md` line — a reference
# the model may or may not read, which is the failure this whole script exists
# to avoid. Cycles are cut by the seen-list, and a missing import is left as a
# visible marker rather than silently dropped.
expand_layer() {
  local file="$1" depth="${2:-0}" seen="${3:-}"
  if (( depth > 4 )); then
    echo "<!-- import depth limit reached at ${file} -->"
    return 0
  fi
  case ":${seen}:" in
    *":${file}:"*) echo "<!-- circular import skipped: ${file} -->"; return 0 ;;
  esac
  local dir; dir="$(dirname "${file}")"
  local line target
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^@([^[:space:]]+)[[:space:]]*$ ]]; then
      target="${BASH_REMATCH[1]}"
      case "${target}" in
        "~/"*) target="${HOME}/${target#\~/}" ;;
        /*) ;;
        *) target="${dir}/${target}" ;;
      esac
      if [[ -f "${target}" ]]; then
        # Markers carry the raw path. Abbreviating the prefix to ~ substitutes
        # against the CURRENT value of $HOME, so the rendered body — and with it
        # inputs-sha256 — changes when $HOME does: a bootstrap run with $HOME
        # pointed elsewhere (a sandbox, another account) wrote one hash, and the
        # next --check computed another, reporting a freshly written file as
        # stale. Observed exactly that way before this line changed.
        printf '<!-- begin import: %s -->\n' "${target}"
        expand_layer "${target}" "$((depth + 1))" "${seen}:${file}"
        printf '<!-- end import: %s -->\n' "${target}"
      else
        printf '<!-- MISSING import (left unresolved): %s -->\n' "${line}"
      fi
    else
      printf '%s\n' "${line}"
    fi
  done < "${file}"
}

render() {
  cat <<HEADER
<!-- GENERATED FILE — DO NOT EDIT.
     Produced by reflectory _system/scripts/build-agents-md.sh (path in
     _meta/machinery-root) from the tracked
     rule layers, with @-imports expanded inline (Codex has no import syntax).
     Edit the sources, then re-run the script; edits made here are overwritten
     without warning.

     Sources (in load order):
HEADER
  for f in "${LAYERS[@]}"; do
    echo "       - ${f/#${HOME}/\~}"
  done
  cat <<HEADER
     inputs-sha256: ${INPUT_SHA}
     generated-by: build-agents-md.sh
-->

HEADER
  for f in "${LAYERS[@]}"; do
    printf '<!-- ===== layer: %s ===== -->\n\n' "$(basename "$(dirname "${f}")")/$(basename "${f}")"
    expand_layer "${f}"
    printf '\n\n'
  done
}

# Body first (imports expanded), then the stamp over that body.
BODY="$(for f in "${LAYERS[@]}"; do expand_layer "${f}"; done)"
INPUT_SHA="$(printf '%s' "${BODY}" | sha_of)"

if [[ "${mode}" == "check" ]]; then
  if [[ ! -f "${OUT}" ]]; then
    echo "build-agents-md: ${OUT} does not exist — Codex has no rule layer." >&2
    exit 1
  fi
  stored="$(grep -m1 'inputs-sha256:' "${OUT}" | sed -E 's/.*inputs-sha256:[[:space:]]*([0-9a-f]+).*/\1/' || true)"
  if [[ "${stored}" != "${INPUT_SHA}" ]]; then
    echo "build-agents-md: ${OUT} is stale (stored ${stored:-none}, sources ${INPUT_SHA})." >&2
    echo "Re-run: ${BASH_SOURCE[0]}" >&2
    exit 1
  fi
  # Freshness is not the only way this file can be wrong: the user may have
  # lowered project_doc_max_bytes since it was written, in which case Codex is
  # already truncating a projection that looks current.
  live_size="$(wc -c < "${OUT}" | tr -d ' ')"
  live_budget="$(effective_budget)"
  if (( live_size > live_budget )); then
    echo "build-agents-md: ${OUT} is ${live_size} bytes, over the current budget of ${live_budget}." >&2
    echo "Codex is truncating it. Raise project_doc_max_bytes in ${CODEX_HOME}/config.toml." >&2
    exit 1
  fi
  echo "AGENTS.md current (inputs-sha256 ${INPUT_SHA}, ${live_size} bytes, budget ${live_budget})."
  exit 0
fi

TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT
render > "${TMP}"

size="$(wc -c < "${TMP}" | tr -d ' ')"
budget="$(effective_budget)"

if (( size > budget )); then
  cat >&2 <<EOM
build-agents-md: projection is ${size} bytes, over Codex's project-doc budget of ${budget}.
Codex truncates the project doc at that limit silently — the tail of the rule
layer would simply not exist while looking installed. Raise the limit in
${CODEX_HOME}/config.toml (top level, before the first [table]):

    project_doc_max_bytes = $(( ((size / 65536) + 1) * 65536 ))

then re-run. Nothing was written.
EOM
  exit 1
fi

if [[ "${mode}" == "stdout" ]]; then
  cat "${TMP}"
  exit 0
fi

# AGENTS.md is Codex's hand-written global instruction file — the same class as
# ~/.claude/CLAUDE.md, which bootstrap.sh refuses to overwrite. So: a file this
# script did not write is never clobbered. It is recognised by the generated-by
# stamp in its header; anything else is the user's, and needs an explicit --force
# (which still keeps a timestamped backup).
# Authorship is proven by the header carrying either the generated-by line or
# the banner TOGETHER WITH an inputs-sha256 stamp. The banner alone would be too
# weak a signature: a hand-written file that happens to quote it (a note to self
# about this very mechanism, say) would be overwritten without a backup.
stamped=0
if [[ -f "${OUT}" ]]; then
  # The header lists one line per layer, so a fixed 20-line window would push
  # the stamp out of sight as layers are added and the script would start
  # refusing to overwrite its own output. Read to the end of the header comment.
  # Bounded: without a closing --> the range would run to end of file, and a
  # hand-written AGENTS.md quoting the stamp anywhere in it would be treated as
  # ours and overwritten with no backup.
  header="$(sed -n '1,/^-->/p' "${OUT}" | head -60)"
  grep -q 'generated-by: build-agents-md\.sh' <<<"${header}" && stamped=1
  if (( ! stamped )) \
     && grep -q 'GENERATED FILE — DO NOT EDIT' <<<"${header}" \
     && grep -q 'inputs-sha256:' <<<"${header}"; then
    stamped=1
  fi
fi

if [[ -f "${OUT}" ]] && (( ! stamped )); then
  if (( FORCE )); then
    bak="${OUT}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    cp "${OUT}" "${bak}"
    echo "==> Existing ${OUT} was not written by this script; backed up to ${bak}"
  else
    cat >&2 <<EOM
build-agents-md: ${OUT} exists and carries no generated-by stamp, so it was
written by hand (or by something else). Refusing to overwrite it.

Merge what you want to keep into the tracked layers, then re-run with --force
(the current file is backed up alongside it), or move it aside yourself.
Nothing was written.
EOM
    exit 1
  fi
fi

cp "${TMP}" "${OUT}"
echo "wrote ${OUT} (${size} bytes, budget ${budget}, inputs-sha256 ${INPUT_SHA})"
