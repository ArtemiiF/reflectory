#!/usr/bin/env python3
# UserPromptSubmit hook: snapshot correction-bearing user prompts into a queue
# that /reflect-session consumes as Phase 1 observation candidates.
#
# Why: reflect-reminder.py (the Stop-hook circuit) only COUNTS corrections to
# nudge the user toward a reflect run; the correction text itself stays buried
# in the transcript. Sessions that end without a reflect run — or corrections
# made in sessions the user never reflects on — lose exactly the A1-friction
# signal the method feeds on. This hook is the capture half: the moment a
# prompt matches the friction vocabulary, its text is queued to disk, so the
# next /reflect-session (in ANY session) sees it regardless of which
# conversation it came from.
#
# Mechanics: reads the UserPromptSubmit payload from stdin, matches the prompt
# against the shared MARKERS regex (friction_markers.py — same vocabulary as
# reflect-reminder.py), and appends one JSON line to
#   ${LOCAL_FORKS:-~/.claude/local-forks}/_local/corrections-queue.jsonl
#     {"ts": "<UTC ISO>", "session_id": "...", "prompt": "<first 500 chars>"}
# _local/ is gitignored — raw prompt text never lands in git; the queue is a
# working buffer, drained by /reflect-session after its findings are committed.
#
# Guards:
#   - identical (session_id, prompt) already queued → skip (re-submits, retries);
#   - queue file over ~1 MB → skip append (runaway protection; the reflect run
#     that drains the queue also resets this);
#   - prints nothing to stdout (UserPromptSubmit stdout is injected into the
#     conversation as context — this hook must be invisible);
#   - never blocks: any parse/IO error → exit 0. Capture is best-effort.
#
# Registration (one-time, manual — settings.json is machine-local, mirror of
# the reflect-reminder.py setup; bootstrap.sh only checks and reminds):
#   "hooks": {
#     "UserPromptSubmit": [
#       { "hooks": [ { "type": "command",
#           "command": "python3 ~/.claude/local-forks/_system/scripts/capture-corrections.py" } ] }
#     ]
#   }

import datetime
import json
import os
import sys

from friction_markers import MARKERS

PROMPT_CAP = 500          # chars of prompt kept per entry
QUEUE_CAP_BYTES = 1 << 20 # ~1 MB runaway guard


def queue_path() -> str:
    root = os.environ.get("LOCAL_FORKS") or os.path.expanduser(
        "~/.claude/local-forks"
    )
    return os.path.join(root, "_local", "corrections-queue.jsonl")


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    prompt = payload.get("prompt") or ""
    if not isinstance(prompt, str) or not MARKERS.search(prompt):
        return 0

    session_id = payload.get("session_id") or "unknown"
    entry = {
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(
            timespec="seconds"
        ),
        "session_id": session_id,
        "prompt": prompt[:PROMPT_CAP],
    }

    try:
        path = queue_path()
        if os.path.isfile(path):
            if os.path.getsize(path) > QUEUE_CAP_BYTES:
                return 0
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    try:
                        prev = json.loads(line)
                    except Exception:
                        continue
                    if (
                        prev.get("session_id") == session_id
                        and prev.get("prompt") == entry["prompt"]
                    ):
                        return 0  # duplicate (re-submit / retry) — skip
        else:
            os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:
        pass  # best-effort capture, never interfere with the prompt

    return 0


if __name__ == "__main__":
    sys.exit(main())
