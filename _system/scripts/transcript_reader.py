#!/usr/bin/env python3
"""transcript_reader.py — one record stream out of two transcript formats.

Claude Code writes ~/.claude/projects/<project>/<uuid>.jsonl, one record per
line, shaped {"type": "user"|"assistant", "message": {"role", "content"}}.
Codex writes ~/.codex/sessions/<Y>/<M>/<D>/rollout-<ts>-<uuid>.jsonl, shaped
{"type": "event_msg"|"response_item", "payload": {"type": ...}}.

Rather than teach every consumer both shapes, Codex records are translated into
the Claude shape here, so session-digest.py, reflect-reminder.py and anything
else keep one parser. The translation is deliberately lossy in the same way the
consumers already are: it carries user text, assistant text and tool calls, and
drops reasoning blobs, token counters and image events.

Codex changed its transcript shape between versions, so both are handled:

    codex-cli 0.154.0 (current)
      event_msg / item_completed, item.type UserMessage  -> {"type": "user"}
      event_msg / item_completed, item.type AgentMessage -> {"type": "assistant"}

    codex-cli 0.145.0 and older rollouts still on disk
      event_msg / user_message   -> {"type": "user"}
      event_msg / agent_message  -> {"type": "assistant"}

    both versions
      response_item / function_call     -> assistant [tool_use]
      response_item / custom_tool_call  -> assistant [tool_use]
      *_call_output                     -> user [tool_result]

response_item / message is deliberately ignored: in 0.154.0 it carries the
developer prompt and harness-injected blocks alongside the user turn, and the
real user text is already in item_completed. item_completed / CommandExecution is
ignored for the same reason — it duplicates the custom_tool_call it describes.

Usage:
    from transcript_reader import iter_records, detect_format
    for rec in iter_records(path):   # Claude-shaped dicts, either source
        ...
"""

import json
import os

CLAUDE = "claude"
CODEX = "codex"

_PROBE_LINES = 40


def detect_format(path: str) -> str:
    """Sniff the first records. A file that shows neither marker reads as Claude,
    the historical default — callers that care should check explicitly."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh):
                if i >= _PROBE_LINES:
                    break
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                t = rec.get("type")
                if t in ("session_meta", "event_msg", "response_item", "turn_context"):
                    return CODEX
                if t in ("user", "assistant", "summary", "system"):
                    return CLAUDE
    except OSError:
        pass
    return CLAUDE


def _blocks_text(blocks):
    """Join the text of a content block list. Codex spells the block type
    "text" under UserMessage and "Text" under AgentMessage; both carry `text`,
    so the type is not what decides."""
    if isinstance(blocks, str):
        return blocks
    if not isinstance(blocks, list):
        return ""
    return "".join(
        b["text"] for b in blocks
        if isinstance(b, dict) and isinstance(b.get("text"), str)
    )


def _codex_text_shape(path):
    """Where this rollout keeps user and assistant text, decided per SIDE.

    One file can mix them: a compacted sub-agent thread carries its assistant
    turns as item_completed/AgentMessage while the user turns exist only as
    response_item/message. Deciding per file picked one shape and lost the other
    side entirely, so each side is resolved on its own:

        items          item_completed/UserMessage | AgentMessage   (0.154)
        events         event_msg/user_message | agent_message      (<=0.145)
        response_items response_item/message role user | agent_message
    """
    have = {
        "user": {"items": False, "events": False, "response_items": False},
        "assistant": {"items": False, "events": False, "response_items": False},
    }
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                payload = rec.get("payload")
                if not isinstance(payload, dict):
                    continue
                rtype, ptype = rec.get("type"), payload.get("type")
                if ptype == "item_completed":
                    itype = (payload.get("item") or {}).get("type")
                    if itype == "UserMessage":
                        have["user"]["items"] = True
                    elif itype == "AgentMessage":
                        have["assistant"]["items"] = True
                elif rtype == "event_msg" and ptype == "user_message":
                    have["user"]["events"] = True
                elif rtype == "event_msg" and ptype == "agent_message":
                    have["assistant"]["events"] = True
                elif rtype == "response_item" and ptype == "message" \
                        and payload.get("role") == "user":
                    have["user"]["response_items"] = True
                elif rtype == "response_item" and (
                    ptype == "agent_message"
                    or (ptype == "message" and payload.get("role") == "assistant")
                ):
                    # The translator accepts both spellings; the detector has to
                    # recognise both or a file using only the second resolves to
                    # "items" and yields no assistant text at all.
                    have["assistant"]["response_items"] = True
    except OSError:
        pass

    def pick(side):
        for shape in ("items", "events", "response_items"):
            if have[side][shape]:
                return shape
        return "items"

    return {"user": pick("user"), "assistant": pick("assistant")}


def _codex_to_claude(rec, shape=None):
    """Translate one Codex rollout record. Returns a Claude-shaped dict or None."""
    shape = shape or {"user": "items", "assistant": "items"}
    rtype = rec.get("type")
    payload = rec.get("payload")
    if not isinstance(payload, dict):
        return None
    ptype = payload.get("type")

    if rtype == "event_msg":
        if ptype == "item_completed" and (
            shape["user"] == "items" or shape["assistant"] == "items"
        ):
            item = payload.get("item")
            if not isinstance(item, dict):
                return None
            itype = item.get("type")
            if itype == "UserMessage":
                text = _blocks_text(item.get("content"))
                if not text:
                    return None
                return {"type": "user", "message": {"role": "user", "content": text}}
            if itype == "AgentMessage":
                text = _blocks_text(item.get("content"))
                if not text:
                    return None
                return {
                    "type": "assistant",
                    "message": {
                        "role": "assistant",
                        "content": [{"type": "text", "text": text}],
                    },
                }
            return None
        if ptype == "user_message" and shape["user"] == "events":
            msg = payload.get("message")
            if not isinstance(msg, str):
                return None
            return {"type": "user", "message": {"role": "user", "content": msg}}
        if ptype == "agent_message" and shape["assistant"] == "events":
            msg = payload.get("message")
            if not isinstance(msg, str):
                return None
            return {
                "type": "assistant",
                "message": {
                    "role": "assistant",
                    "content": [{"type": "text", "text": msg}],
                },
            }
        return None

    if rtype != "response_item":
        return None

    # Reached only for the side whose text lives nowhere else; developer and
    # system roles are harness content, never conversation.
    if shape["user"] == "response_items":
        if ptype == "message" and payload.get("role") == "user":
            text = _blocks_text(payload.get("content"))
            if not text:
                return None
            return {"type": "user", "message": {"role": "user", "content": text}}
    if shape["assistant"] == "response_items":
        if ptype in ("agent_message", "message") and payload.get("role") in (None, "assistant"):
            text = payload.get("message")
            if not isinstance(text, str):
                text = _blocks_text(payload.get("content"))
            if text:
                return {
                    "type": "assistant",
                    "message": {
                        "role": "assistant",
                        "content": [{"type": "text", "text": text}],
                    },
                }
            return None

    if ptype in ("function_call", "custom_tool_call"):
        name = payload.get("name") or payload.get("tool_name") or "tool"
        raw = payload.get("arguments")
        if raw is None:
            raw = payload.get("input")
        if isinstance(raw, str):
            try:
                inp = json.loads(raw)
            except Exception:
                # custom_tool_call carries `input` as a code-mode snippet, not
                # JSON. It is what the tool actually ran, so it goes under
                # "command" — the key consumers already surface.
                inp = {"command": raw}
        elif isinstance(raw, dict):
            inp = raw
        else:
            inp = {}
        return {
            "type": "assistant",
            "message": {
                "role": "assistant",
                "content": [
                    {
                        "type": "tool_use",
                        "id": payload.get("call_id") or payload.get("id") or "",
                        "name": name,
                        "input": inp,
                    }
                ],
            },
        }

    if ptype in ("function_call_output", "custom_tool_call_output"):
        # `output` is a list of blocks ({"type": "input_text"|"input_image", ...}),
        # not a string — an early probe that stringified it said otherwise, and
        # the translated results came out empty until this was measured.
        out = payload.get("output")
        if isinstance(out, list):
            out = "".join(
                b.get("text", "") for b in out
                if isinstance(b, dict) and isinstance(b.get("text"), str)
            )
        elif isinstance(out, dict):
            out = out.get("content") or json.dumps(out, ensure_ascii=False)
        return {
            "type": "user",
            "message": {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": payload.get("call_id") or "",
                        "content": out if isinstance(out, str) else "",
                    }
                ],
            },
        }

    return None


def iter_records(path: str, fmt: str = None):
    """Yield Claude-shaped records from either transcript format."""
    fmt = fmt or detect_format(path)
    shape = _codex_text_shape(path) if fmt == CODEX else None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if fmt == CLAUDE:
                yield rec
            else:
                out = _codex_to_claude(rec, shape)
                if out is not None:
                    yield out


def session_id_from_path(path: str) -> str:
    """Codex names files rollout-<timestamp>-<uuid>.jsonl; Claude names them <uuid>.jsonl."""
    base = os.path.basename(path)
    if base.endswith(".jsonl"):
        base = base[: -len(".jsonl")]
    if base.startswith("rollout-"):
        parts = base.split("-")
        if len(parts) >= 5:
            return "-".join(parts[-5:])
    return base
