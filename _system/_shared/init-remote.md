# init-remote — pre-flight check and one-time GitHub setup

Shared library used by `/reflect-session` and `/sync-upstream`. Not a standalone slash-command. Both skills run the pre-flight algorithm below at step 0 and, if needed, walk the user through the init wizard before continuing.

> **Access pattern.** This file lives at `~/.claude/local-forks/_system/_shared/init-remote.md` and is **not copied** into `~/.claude/skills/` by `bootstrap.sh` — it has no `SKILL.md`, so the skill-installation loop skips it. Skills reference it by **absolute path** rather than relative path, because the relative path would resolve against `~/.claude/skills/<skill>/` post-bootstrap (or against the plugin cache, for marketplace installs) and break. The canonical local-forks location (`~/.claude/local-forks/`) is guaranteed to exist after wizard step 0 below, so the absolute path always resolves.

## When to run

At the very start of every `/reflect-session` and `/sync-upstream` invocation. Result is cached at `~/.claude/local-forks/_meta/.preflight-cache.json` (gitignored). The skill reads this file first: if `state == "READY"` and `checked_at` is within the last 10 minutes, the pre-flight is skipped. On any non-`READY` outcome the file is deleted so the next call re-runs the full algorithm.

## Inputs

- None from the user. The state of `~/.claude/local-forks/` and its `origin` remote is enough.

## Pre-flight algorithm

Run in order. The first branch that matches wins.

1. **Does `~/.claude/local-forks/` exist as a directory?**
   - No → state `NOT_INITIALIZED` → call init wizard (§ Init wizard below).
2. **Is it a git repository?** (`git -C ~/.claude/local-forks rev-parse --git-dir`)
   - No → state `BROKEN`. Ask the user: re-initialise (run `git init`) or move the directory aside and start fresh? Stop until answered.
3. **Does `origin` remote exist?** (`git -C ~/.claude/local-forks remote get-url origin`)
   - No → state `NO_REMOTE` → call init wizard.
4. **Does `git ls-remote origin` succeed within 10s?**
   - No → state `REMOTE_UNREACHABLE`. Run diagnostics (§ Diagnostics below), surface the cause, ask the user how to proceed. Do not silently proceed.
5. Otherwise → state `READY`. Cache the result for this session and return.

## Init wizard

Step 0 seeds the working tree if needed; then three sequential questions via `AskUserQuestion`. Each question is independent; do not bundle decisions.

### Step 0 — Seed the working tree (only when state is `NOT_INITIALIZED`)

`~/.claude/local-forks/` does not exist yet — clone the template repo to seed the scripts, shared libraries, and layout the skills depend on:

```bash
git clone https://github.com/ArtemiiF/reflectory.git ~/.claude/local-forks
```

After the clone, `origin` still points at the **template** repo, which the user cannot push to. Questions 1–3 below MUST end with `git remote set-url origin <user's own repo>` (create-or-attach), never with the template URL left in place. Skip this step entirely when the directory already exists (states `NO_REMOTE`, `BROKEN`).

### Question 1 — Mode

| Option | Action |
|---|---|
| Auto-create a new private GitHub repo | Use `gh repo create <name> --private` (see Question 3 for the name). `--private` already makes the command non-interactive; the `--confirm` flag was removed in `gh` ≥ 2.28. |
| Attach an existing empty GitHub repo | Ask the user for the HTTPS or SSH URL; verify the repo is empty with `git ls-remote <url>` (no refs returned). If non-empty, ask whether to `git pull` (assuming this is a previously initialised machine) or pick a different repo. |

### Question 2 — Authentication

Run automatic checks first; only ask the user when something is missing.

1. **`gh` installed?** `command -v gh` — if missing, tell the user how to install (`sudo apt install gh`, or [docs](https://cli.github.com/)), then stop and wait.
2. **`gh auth status`** — if not authenticated, ask the user to run `gh auth login` (web flow). Wait for confirmation, re-check.
3. **`repo` scope present?** Parse `gh auth status` output; if scope is missing, suggest `gh auth refresh -s repo`.
4. **Git credential helper configured?** Run `gh auth setup-git` automatically after a successful `gh auth login`. Without this the first `git push` fails with an auth error even though `gh` itself works. Idempotent — safe to run on every init.
5. **SSH vs HTTPS** — if the user prefers SSH, check `~/.ssh/id_ed25519.pub` (or any public key) and `gh ssh-key list`. If no key is added to GitHub, walk the user through `ssh-keygen -t ed25519 -C "<email>"` and `gh ssh-key add ~/.ssh/id_ed25519.pub`. Default is HTTPS — the URL stored in `_meta/remote.json` matches whichever transport was chosen here; keep it consistent across both files (HTTPS or SSH, not mixed).

Personal Access Token is only needed for CI/automation, not for interactive push from this machine — do not suggest a PAT unless the user explicitly asks for one.

**No secrets land in this repository.** All credentials stay in `gh` keyring, `~/.git-credentials`, SSH agent.

### Question 3 — Repo name and final confirmation

- Default name: `claude-local-forks`.
- Show the final summary to the user: «`<user>/<name>`, private, will be created/attached, first commit and `git push -u origin main` will follow. Proceed?»
- On confirm: execute the create or attach, set the remote, write `_meta/remote.json` (see below), make an initial commit if the repo is empty, push.

## `_meta/remote.json`

After a successful init, write:

```json
{
  "provider": "github",
  "url": "git@github.com:<user>/<name>.git",
  "visibility": "private",
  "initialized_at": "<ISO-8601 UTC>",
  "last_push_ok_at": "<ISO-8601 UTC>"
}
```

`/reflect-session` and `/sync-upstream` bump `last_push_ok_at` via `_system/scripts/update-last-push.sh` immediately **before** composing the commit, so the new timestamp ships in the same commit that gets pushed (no amend or force-push needed — see SKILL.md Step 6/7 step «Bump the push timestamp»). The timestamp is therefore «moment we were about to push» rather than «moment the push completed»; the offset is seconds. The bootstrap script on a fresh machine reads this file to know where to clone from.

## Diagnostics for `REMOTE_UNREACHABLE`

Probe in this order and report the first matching cause to the user:

| Check | Likely cause | Action |
|---|---|---|
| `gh auth status` fails | `gh` logged out / token expired | Re-run `gh auth login`. |
| `ssh -T git@github.com` returns auth error | SSH key missing or not added to GitHub | Add the public key via `gh ssh-key add`. |
| `curl -s https://api.github.com` times out | Network / proxy issue | Surface to user; do not retry blindly. |
| Repo URL returns 404 | Repo deleted or renamed | Ask the user: re-create, point to a different URL, or detach the remote. |

Do not retry destructive operations more than once. Two consecutive failures of the same step = stop and hand control back to the user.

## Anti-patterns

- **Do not modify `~/.gitconfig`** or any global git settings. All changes are local to `~/.claude/local-forks/`.
- **Do not force-push** ever. If the remote diverges, ask the user — never overwrite.
- **Do not create public repos.** Always `--private`.
- **Do not store tokens in the repo.** Not in commit messages, not in metadata files.
- **Do not silently retry** failing pushes. One retry maximum, then escalate.
