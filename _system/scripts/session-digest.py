#!/usr/bin/env python3
"""session-digest.py — deterministic, compact projection of a Claude Code .jsonl transcript.

A raw session transcript (`~/.claude/projects/<project>/<uuid>.jsonl`) can be tens of
megabytes — far past what any single agent context can hold. This script strips it to a
turn-indexed, greppable text that preserves the signals the reflection method needs:

  - genuine user prose (the gold signal for Cluster-A friction / preference / idiolect),
  - assistant visible text (plan statements, "done" claims — Cluster B5/B6),
  - tool routing: `tool_use` name + key args (Cluster B1/B2/B7/B13 thrashing),
  - tool results collapsed to ok/err + a short head (Cluster B1/B11/B13).

It is NOT the raw transcript and does NOT pretend to be: thinking blocks are reduced to a
char count by default, and long content is truncated. The /reflect-archive critic re-scans
the RAW .jsonl independently (it does not trust this projection). This file is both the
reflector's input AND the human-readable "dump" of what was analysed.

Deterministic: no clock, no randomness, no network. Same input → same output.

Usage:
    session-digest.py <path-to.jsonl> [--out FILE]
                      [--user-max N] [--asst-max N] [--tool-max N] [--result-max N]
                      [--thinking-chars N]

Defaults are tuned so a ~20 MB session lands in a few hundred KB — readable by a sub-agent
in one or two chunked Read calls.
"""

import argparse
import json
import sys

# --- key fields we surface from a tool_use input, in priority order ---------
# (most tools carry exactly one of these as the "what it operates on")
TOOL_INPUT_KEYS = (
    "command", "file_path", "path", "pattern", "query", "url",
    "subagent_type", "description", "prompt", "old_string", "skill",
)


def collapse(s, n):
    """One-line, length-capped rendering of a (possibly multi-line) string."""
    if not isinstance(s, str):
        s = json.dumps(s, ensure_ascii=False)
    s = " ".join(s.split())  # collapse all whitespace runs incl. newlines
    if len(s) > n:
        s = s[:n] + " …[+%d]" % (len(s) - n)
    return s


def compact_tool_input(inp, cap):
    """Render the salient part of a tool_use input as `k=v` for the key field(s)."""
    if not isinstance(inp, dict):
        return collapse(inp, cap)
    parts = []
    for k in TOOL_INPUT_KEYS:
        if k in inp and inp[k] not in (None, "", []):
            parts.append("%s=%s" % (k, collapse(inp[k], cap)))
            break  # one salient field is enough to identify the call
    if not parts:
        # no recognised key — show the key names so routing is still visible
        return "{" + ",".join(sorted(inp.keys())) + "}"
    return parts[0]


def classify_user_string(s):
    """Return (tag, text) for a string-typed user message.

    tag ∈ {"", "local-cmd", "reminder"} — "" means genuine user prose.
    Injected wrappers (slash-command runs, system reminders) are tagged and trimmed
    so the reflector does not mistake harness noise for the user's own words.
    """
    stripped = s.lstrip()
    if stripped.startswith("<local-command") or "<command-name>" in s[:200]:
        # extract the command name if present
        name = ""
        a = s.find("<command-name>")
        if a != -1:
            b = s.find("</command-name>", a)
            if b != -1:
                name = s[a + len("<command-name>"):b].strip()
        return "local-cmd", name or "(local command)"
    if stripped.startswith("<system-reminder"):
        return "reminder", ""
    return "", s


def iter_records(path):
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except (ValueError, UnicodeDecodeError):
                continue


def build(path, args):
    out = []
    n_user = n_asst = n_tool = n_err = n_think = 0
    ev = 0

    def emit(s):
        nonlocal ev
        ev += 1
        out.append("[E%05d] %s" % (ev, s))

    for rec in iter_records(path):
        if rec.get("type") not in ("user", "assistant"):
            continue
        msg = rec.get("message")
        if not isinstance(msg, dict):
            continue
        role = msg.get("role")
        content = msg.get("content")

        if role == "user":
            if isinstance(content, str):
                tag, text = classify_user_string(content)
                if tag == "reminder":
                    continue  # injected harness noise — drop entirely
                if tag == "local-cmd":
                    emit("USER[cmd]: %s" % text)
                else:
                    n_user += 1
                    emit("USER: %s" % collapse(text, args.user_max))
            elif isinstance(content, list):
                for b in content:
                    if not isinstance(b, dict):
                        continue
                    bt = b.get("type")
                    if bt == "tool_result":
                        is_err = bool(b.get("is_error"))
                        if is_err:
                            n_err += 1
                        c = b.get("content")
                        if isinstance(c, list):
                            c = " ".join(
                                x.get("text", "") for x in c
                                if isinstance(x, dict) and x.get("type") == "text"
                            )
                        emit("  RSLT[%s]: %s" % (
                            "err" if is_err else "ok", collapse(c, args.result_max)))
                    elif bt == "text":
                        n_user += 1
                        emit("USER: %s" % collapse(b.get("text", ""), args.user_max))
                    elif bt == "image":
                        emit("  [user image]")

        elif role == "assistant":
            if not isinstance(content, list):
                continue
            for b in content:
                if not isinstance(b, dict):
                    continue
                bt = b.get("type")
                if bt == "text":
                    txt = b.get("text", "").strip()
                    if txt:
                        n_asst += 1
                        emit("ASST: %s" % collapse(txt, args.asst_max))
                elif bt == "tool_use":
                    n_tool += 1
                    emit("  TOOL %s(%s)" % (
                        b.get("name", "?"),
                        compact_tool_input(b.get("input"), args.tool_max)))
                elif bt == "thinking":
                    n_think += 1
                    th = b.get("thinking", "") or ""
                    if args.thinking_chars > 0:
                        emit("  THINK: %s" % collapse(th, args.thinking_chars))
                    else:
                        emit("  THINK[%d chars]" % len(th))

    uuid = path.rsplit("/", 1)[-1]
    if uuid.endswith(".jsonl"):
        uuid = uuid[:-len(".jsonl")]
    header = [
        "# session digest: %s" % uuid,
        "# source: %s" % path,
        "# events: user=%d assistant=%d tool_use=%d tool_result_err=%d thinking=%d"
        % (n_user, n_asst, n_tool, n_err, n_think),
        "# NOTE: deterministic projection, NOT the raw transcript. Thinking bodies and",
        "#       long content are truncated. The critic re-scans the raw .jsonl.",
        "#",
    ]
    return "\n".join(header + out) + "\n"


def main(argv):
    p = argparse.ArgumentParser(description="Compact projection of a Claude Code .jsonl session.")
    p.add_argument("jsonl", help="path to the .jsonl transcript")
    p.add_argument("--out", help="write to this file instead of stdout")
    p.add_argument("--user-max", type=int, default=1500, help="max chars per user message")
    p.add_argument("--asst-max", type=int, default=800, help="max chars per assistant text block")
    p.add_argument("--tool-max", type=int, default=200, help="max chars per tool input field")
    p.add_argument("--result-max", type=int, default=200, help="max chars per tool result")
    p.add_argument("--thinking-chars", type=int, default=0,
                   help="chars of thinking to keep (0 = char-count only)")
    args = p.parse_args(argv)

    try:
        text = build(args.jsonl, args)
    except FileNotFoundError:
        sys.stderr.write("session-digest: no such file: %s\n" % args.jsonl)
        return 2

    if args.out:
        with open(args.out, "w") as fh:
            fh.write(text)
        sys.stderr.write("session-digest: wrote %d bytes to %s\n" % (len(text), args.out))
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
