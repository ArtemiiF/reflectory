# Skill install manifest — `skills/<name>/install.json`

Targeting metadata for one skill. Two independent axes: **machine** and **agent**.
The file sits beside `SKILL.md`. Under the per-file install shape bootstrap.sh
writes, only `*.md` is linked, so the manifest never reaches a model; under the
whole-directory symlink shape `/pull-forks` can write, the file is inside the
installed directory. Whether an agent ever reads a non-`.md` file sitting in a
skill directory is not something this repo has measured, so keep the manifest
boring on purpose: pure metadata, no prose an agent could act on.

```json
{
  "machines": ["all"],
  "agents": ["claude", "codex"]
}
```

## Fields

| Field | Values | Meaning |
|---|---|---|
| `machines` | `["all"]` or a list of ids from `_tracked/machines/<id>/` | Machines the skill installs on |
| `agents` | subset of `claude`, `codex` | Agents the skill installs for |

Both fields are required. An unknown machine id or agent name fails the
`validate-manifests.sh` gate (and therefore the pre-commit hook).

## Defaults when `install.json` is absent

`machines: ["all"]`, `agents: ["claude"]` — every pre-existing skill was written
for Claude Code, so a missing manifest never silently ships a skill into Codex.

## Why JSON and not YAML

`jq` is already a hard dependency of `bootstrap.sh`; `yq` is not installed on
every machine (mac has neither `yq` nor PyYAML guaranteed). Same reason
`_meta.json` is JSON.

## Coverage boundary

`validate-manifests.sh` checks the skills git tracks. An untracked skill
directory (someone else dropped one in, work in progress) still installs — the
installer walks the filesystem — and does so on the defaults, unchecked. That is
deliberate: the gate enforces what this repo promises to ship, and blocking every
commit over a directory the repo does not own is worse.

## Who reads it

- `_system/scripts/skill-targets.sh` — resolves each skill to install / skip.
- `_system/bootstrap.sh` — installs the resolved set.
- `skills/pull-forks/SKILL.md` — same resolution when installing what arrived.
- `_system/scripts/validate-manifests.sh` — schema gate, run from pre-commit.

## Superseded by the registry, once a data repo migrates

This schema stays authoritative for a data repo that has no `_tracked/registry.json`
(transition mode — every reader above falls back to it exactly as described).
A data repo that creates `registry.json` moves each skill's `machines`/`agents`
pair into a `kind: "skill"` entry there instead — see `registry-schema.md`,
which also covers the plugin roster this file never had a slot for.
