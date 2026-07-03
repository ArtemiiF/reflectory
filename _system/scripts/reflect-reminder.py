#!/usr/bin/env python3
# Stop hook: reminds to run /reflect-session after a correction-heavy session.
#
# Why: VISION.md ("наработки не пропадают") — the skill only fires manually;
# a session full of user corrections that ends without a reflect run loses
# exactly the observations the skill exists to capture. This hook is the
# deterministic half: prose can be forgotten, the hook fires on every Stop.
#
# Mechanics: counts user messages in the session transcript that contain
# correction markers (the A1-friction vocabulary from method.md Phase 1).
# At >= THRESHOLD distinct correcting messages it blocks the stop once
# (exit 2 + stderr), so Claude relays the suggestion to the user. A marker
# file per session guarantees the block happens at most once — no loops
# (belt and suspenders on top of the stop_hook_active flag).
#
# Side product — the objective misunderstanding metric (VISION.md): on every
# Stop the hook upserts one TSV line per session into
# _sessions/friction-metrics.tsv (date, session_id, friction_hits, user_msgs).
# Machine-counted, no model self-assessment — the verification-circuit
# counterpart to the model-graded decay audit. rule-stats.py reads the trend.
# The file is tracked; accumulated lines ship with the next reflect commit.
#
# Never blocks on its own failure: any parse/IO error -> exit 0.

import datetime
import json
import os
import re
import sys

THRESHOLD = 3
METRICS = os.path.expanduser("~/.claude/local-forks/_sessions/friction-metrics.tsv")
MARKERS = re.compile(
    r"\b(не так|не туда|не надо|не делай|не то|стоп|вернись|убери|откати"
    r"|that's wrong|not what i)\b"
    r"|\[Request interrupted by user",
    re.IGNORECASE,
)

def upsert_metrics(session_id: str, hits: int, user_msgs: int) -> None:
    """One TSV line per session; the latest Stop wins."""
    try:
        today = datetime.date.today().isoformat()
        row = f"{today}\t{session_id}\t{hits}\t{user_msgs}\n"
        lines = []
        if os.path.isfile(METRICS):
            with open(METRICS, encoding="utf-8") as fh:
                lines = [
                    l for l in fh
                    if l.strip() and f"\t{session_id}\t" not in l
                ]
        with open(METRICS, "w", encoding="utf-8") as fh:
            fh.writelines(lines)
            fh.write(row)
    except Exception:
        pass  # metrics are best-effort, never interfere with the hook


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    if payload.get("stop_hook_active"):
        return 0  # we already blocked once this stop-cycle

    transcript = payload.get("transcript_path") or ""
    session_id = payload.get("session_id") or "unknown"
    if not transcript or not os.path.isfile(transcript):
        return 0

    hits = 0
    user_msgs = 0
    try:
        with open(transcript, encoding="utf-8") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get("type") != "user" or rec.get("isSidechain"):
                    continue
                msg = rec.get("message") or {}
                content = msg.get("content")
                if isinstance(content, list):
                    text = " ".join(
                        c.get("text", "") for c in content if isinstance(c, dict)
                    )
                elif isinstance(content, str):
                    text = content
                else:
                    continue
                # tool_result-bearing user records are harness echoes, not the user
                if "tool_use_id" in text or "tool_result" in str(
                    [c.get("type") for c in content if isinstance(c, dict)]
                    if isinstance(content, list) else ""
                ):
                    continue
                user_msgs += 1
                if MARKERS.search(text):
                    hits += 1
    except Exception:
        return 0

    upsert_metrics(session_id, hits, user_msgs)

    guard = os.path.join("/tmp", f"reflect-reminder-{session_id}")
    if os.path.exists(guard):
        return 0  # reminded already in this session

    if hits < THRESHOLD:
        return 0

    try:
        open(guard, "w").close()
    except Exception:
        pass

    print(
        f"reflect-reminder: в сессии {hits} сообщений с исправлениями от пользователя "
        f"(порог {THRESHOLD}). Предложи пользователю одной строкой прогнать /reflect-session, "
        f"чтобы наработки сессии не пропали. Не запускай скилл сам — только предложи. "
        f"Затем заверши ответ.",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
