# Registry schema — `_tracked/registry.json`

One registry per data repo. It replaces two things that used to be separate:
the per-skill `skills/<name>/install.json` manifest (schema:
`install-manifest.md`) and the plugin roster that did not exist before — which
plugin's own rule file (a marketplace plugin's `CLAUDE.md`, say) gets attached
to the assembled rule layer, on which machine, for which agent.

Same two independent axes as `install.json`: **machine** and **agent**. A third
field, `layer`, records *why* the entry is attached (root/machine/agent-level)
for readers and for the schema gate; it does not itself filter resolution —
`machines` and `agents` do that, exactly as they did for skills.

## Location

`${LOCAL_FORKS}/_tracked/registry.json` (default `~/.claude/local-forks/_tracked/registry.json`).

## Presence gates the layout

- **Absent** — transition mode. Every script in this repo falls back to the
  layout that predates the registry: `skills/<name>/install.json` per skill,
  `general-rules.md`, `shared.md`, `machines/current/CLAUDE.md`, no plugin
  roster. A data repo that has not migrated yet keeps working exactly as
  before — nothing here is a breaking change until `registry.json` is created.
- **Present** — read instead of the per-skill manifests. Its plugin entries
  feed `bootstrap.sh`'s Claude-root writer and `build-agents-md.sh`'s Codex
  projection.

## Schema

```json
{
  "entries": [
    { "name": "reflect-session", "kind": "skill", "layer": "root",
      "machines": ["all"], "agents": ["claude", "codex"] },
    { "name": "neuro-matrix", "kind": "plugin", "layer": "agent",
      "machines": ["mbp-filanovskii", "home-wsl"], "agents": ["claude"],
      "import": "CLAUDE.md" }
  ]
}
```

## Fields

| Field | Values | Required | Meaning |
|---|---|---|---|
| `name` | string | yes | For `kind: "skill"` — the directory name under `skills/<name>/`. For `kind: "plugin"` — the plugin's own name (the part before `@marketplace` in `installed_plugins.json`, or the directory name under a Codex plugin cache marketplace folder). Unique per `(name, kind)` pair. |
| `kind` | `"plugin"` \| `"skill"` | yes | What is being attached. |
| `layer` | `"root"` \| `"machine"` \| `"agent"` | yes | Descriptive only: `root` = every machine (mirrors `machines: ["all"]`), `machine` = specific machines, `agent` = specific machine × agent combination. Validated as an enum; not consumed by the resolver's install/skip decision. |
| `machines` | `["all"]` or a list of ids from `_tracked/machines/<id>/` | yes | Same meaning as `install.json`'s `machines`. |
| `agents` | subset of `claude`, `codex` | yes | Same meaning as `install.json`'s `agents`. |
| `import` | string (plugin-relative path) | only for `kind: "plugin"` | The file inside the plugin's own install directory to attach to the assembled rule layer (e.g. `"CLAUDE.md"`). Omit when the plugin is only being recorded as present, with nothing to concatenate. A `kind: "skill"` entry MUST NOT carry this field — a skill is resolved by its own directory, not an imported file. |

Both `machines` and `agents` are required, same as `install.json`. An unknown
machine id, unknown agent name, unknown `kind`/`layer` value, an `import` on a
skill entry, or an unrecognised top-level key fails `validate-manifests.sh`
(and therefore the pre-commit hook).

## Resolution

`_system/scripts/skill-targets.sh` resolves entries for a `(machine, agent)`
pair. Three decisions, same contract as before — `install` / `skip` / `unknown`
— because "does not belong here" and "could not be judged" are different facts
and the caller must never delete or attach on an `unknown` row.

- **`kind: "skill"`** — unchanged output shape, `<name>\t<install|skip|unknown>\t<agents-csv>\t<reason>`.
  Invoked the same way as before (`--machine`, `--agents`); a skill directory
  with no matching registry entry falls back to the `install.json`-absent
  defaults (`machines: ["all"]`, `agents: ["claude"]`) — same default a
  pre-registry skill got when its manifest was missing.
- **`kind: "plugin"`** — invoked with `--kind plugin --for-agent <claude|codex>`
  (a plugin's resolved path differs per agent, so one agent is resolved at a
  time, never mixed into one row). Output: `<name>\t<install|skip|unknown>\t<agent>\t<path-or-reason>`.
  On `install` with an `import` field, the 4th column is the resolved absolute
  path to that file; on `install` with no `import`, it is `-`. If the machine
  and agent axes say `install` but the plugin cannot actually be located, the
  row reads `unknown` (not `install` with a dangling path, and not `skip` — a
  targeting match that fails to resolve is not the same as "does not belong
  here").

### Plugin path resolution — never hand-written

Per machine, the plugin's install directory is read from the agent's own
plugin-manager state, not typed into the registry:

- **Claude** — `~/.claude/plugins/installed_plugins.json`, matching a key
  whose part before `@` equals the entry's `name`; the resolved directory is
  that key's `installPath`. Zero or more-than-one match → unresolved.
- **Codex** — `${CODEX_HOME:-~/.codex}/plugins/cache/<marketplace>/<name>/`,
  found by name across marketplace directories (no marketplace field in the
  registry). Zero or more-than-one marketplace match → unresolved. Within a
  matched plugin directory, if more than one version directory exists, the
  lexicographically last name is used (best-effort; not a semver comparison —
  documented limitation, since no registry entry currently targets `codex`).

This mirrors why the old per-machine `@…/plugins/marketplaces/neuro-matrix/CLAUDE.md`
import line differed between `mbp-filanovskii` and `home-wsl`: two hand-typed
absolute paths for the same plugin. The resolver computes the path instead, so
one registry entry works unmodified on every machine that has the plugin
installed — though the path itself differs from what the old hand-typed line
pointed at. The resolved path is the plugin-manager's own install/cache copy
(`installed_plugins.json`'s `installPath`, e.g.
`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/...`), while at
least one machine's old hand-typed line named a `marketplaces/` path instead
— the marketplace's own clone, which is a different file on disk from the
cache copy actually installed and used. The two held identical content when
checked (2026-09-26), but nothing here guarantees they always
do — the cache copy is what is actually installed at a given version; the
marketplace clone tracks the marketplace's own HEAD and can drift ahead of it.

## Who reads it

- `_system/scripts/skill-targets.sh` — resolves each entry to install / skip / unknown, and, for plugins, an absolute import path.
- `_system/bootstrap.sh` — installs the resolved skill set (unchanged step) and, in registry mode, writes the Claude-root import chain from the resolved plugin set for `claude`.
- `_system/scripts/build-agents-md.sh` — in registry mode, appends the resolved plugin set for `codex` to the Codex projection.
- `_system/scripts/validate-manifests.sh` — schema gate, run from pre-commit.

## Relationship to `install-manifest.md`

`install-manifest.md` still documents the per-skill `install.json` schema,
which stays authoritative for a data repo that has not created
`registry.json` yet (transition mode). Once a data repo migrates, its
per-skill `install.json` files are superseded by `skill`-kind entries here —
that migration is a data-repo change, not part of this schema doc or this
engine.

## Why JSON and not YAML

Same reason as `install.json` and `_meta.json`: `jq` is already a hard
dependency of `bootstrap.sh`, `yq` is not installed on every machine.
