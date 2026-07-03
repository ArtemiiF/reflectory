"""friction_markers.py — the shared A1-friction vocabulary (method.md Phase 1).

Single source of truth for the correction-marker regex used by both circuits:
  - reflect-reminder.py (Stop hook) counts marker hits to decide whether to
    suggest /reflect-session at session end;
  - capture-corrections.py (UserPromptSubmit hook) snapshots the marker-bearing
    prompt text into the corrections queue at the moment it is typed.

Both hooks are invoked as `python3 <this dir>/<hook>.py`, so this module is
importable without packaging: the interpreter puts the script's own directory
on sys.path.

Extend the vocabulary here, not in the hooks — one edit updates both circuits.
"""

import re

MARKERS = re.compile(
    r"\b(не так|не туда|не надо|не делай|не то|стоп|вернись|убери|откати"
    r"|that's wrong|not what i)\b"
    r"|\[Request interrupted by user",
    re.IGNORECASE,
)
