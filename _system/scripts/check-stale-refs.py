#!/usr/bin/env python3
"""check-stale-refs.py — deterministic stale-reference audit for rule files.

Rules accumulate pointers to the environment: script paths, skill names,
`~/.claude/...` files. When the referenced artefact moves or dies, the rule
keeps paying attention rent while silently pointing at nothing — exactly the
kind of drift a model self-audit misses and a script cannot. This is the
verification-circuit half of /reflect-compress Phase X: the script finds the
dead pointers, the reflect-compress run decides (with per-item approval) what
to do about each.

Scans the given rule files (default: _tracked/*.md) for path-like tokens:

  - absolute/home paths:  ~/.claude/..., /Users/..., /home/...
  - repo-relative paths:  _system/..., _tracked/..., skills/..., _sessions/...

and tests each against the filesystem. Home-style tokens are expanded;
repo-relative tokens resolve against ${LOCAL_FORKS:-~/.claude/local-forks}.
Tokens containing glob/placeholder characters (*, <, >, …, $, {) are skipped —
a template is not a reference.

Output: one TSV line per dead reference, `file<TAB>lineno<TAB>token`,
sorted by file then line. Exit 0 always (report, not gate) — the consumer
decides severity. Deterministic: no clock, no randomness, no network.

Usage:
    check-stale-refs.py [rule-file.md ...]
"""

import glob
import os
import re
import sys

LOCAL_FORKS = os.environ.get("LOCAL_FORKS") or os.path.expanduser(
    "~/.claude/local-forks"
)

# Path-like tokens worth checking. Trailing punctuation that markdown prose
# glues onto a path (`...md`, `...sh:`, backticks, parens) is stripped below.
TOKEN = re.compile(
    r"(?:~|/Users|/home)[\w./~-]+"      # home / absolute paths
    r"|(?<![\w./-])(?:_system|_tracked|_sessions|skills)/[\w./-]+"  # repo-relative
)

# A token containing any of these is a template/example, not a reference.
PLACEHOLDER = re.compile(r"[*<>{}$…]|\.\.\.")

STRIP = ".,;:`)('\""


def candidates(line):
    for m in TOKEN.finditer(line):
        tok = m.group(0).rstrip(STRIP)
        if PLACEHOLDER.search(tok):
            continue
        # A bare directory mention like `_system/` carries no target to verify.
        if tok.endswith("/"):
            continue
        yield tok


def resolve(tok):
    if tok.startswith("~"):
        return os.path.expanduser(tok)
    if tok.startswith("/"):
        return tok
    return os.path.join(LOCAL_FORKS, tok)


def main(argv):
    files = argv or sorted(glob.glob(os.path.join(LOCAL_FORKS, "_tracked", "*.md")))
    rows = []
    for path in files:
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                for lineno, line in enumerate(fh, 1):
                    for tok in candidates(line):
                        if not os.path.exists(resolve(tok)):
                            rows.append((path, lineno, tok))
        except OSError as e:
            print(f"check-stale-refs: cannot read {path}: {e}", file=sys.stderr)
    for path, lineno, tok in rows:
        print(f"{path}\t{lineno}\t{tok}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
