#!/usr/bin/env python3
"""Ensure Herdr's shared config.toml disables native agent auto-resume.

See docs/herdr-backend.md's "Native resume safety" section for why this
matters and what calls this script; this file owns only the edit mechanics.

This is a narrow, deliberately hand-rolled TOML edit rather than a full
parse/serialize round trip: the only stdlib TOML support (tomllib) is
read-only, and pulling in a third-party TOML writer for one boolean key in a
file Firstmate does not otherwise own is disproportionate. tomllib still
validates both the starting file and the computed replacement before
anything is written, so a change is applied only when it is proven correct,
and a file this script cannot parse is left untouched.

Usage: fm-herdr-resume-config.py <config-path>

Exit status:
  0  resume_agents_on_restore is now (or already was) explicitly false;
     stdout is exactly "changed" or "unchanged".
  1  <config-path> exists but could not be parsed as TOML, or the computed
     replacement failed its own re-parse; the file is left untouched.
  2  bad arguments.
"""

import os
import re
import sys
import tomllib

SESSION_HEADER_RE = re.compile(r"^\s*\[session\]\s*(#.*)?$")
ANY_TABLE_HEADER_RE = re.compile(r"^\s*\[[^\[\]]+\]\s*(#.*)?$")
RESUME_KEY_RE = re.compile(r"^\s*resume_agents_on_restore\s*=")
KEY = "resume_agents_on_restore"


def _session_already_false(doc):
    session = doc.get("session")
    return isinstance(session, dict) and session.get(KEY) is False


def _insert_into_session_table(lines):
    """Return lines with resume_agents_on_restore = false set inside an
    existing [session] table, preserving every other line verbatim.

    An existing active assignment is replaced in place; otherwise the key is
    inserted immediately after the [session] header, before any other key in
    that table (so a session with no other keys never gains a stray blank
    line, and the diff against a real config.toml stays minimal).
    """
    header_index = None
    replace_index = None
    in_session = False
    for i, line in enumerate(lines):
        if ANY_TABLE_HEADER_RE.match(line):
            in_session = bool(SESSION_HEADER_RE.match(line))
            if in_session and header_index is None:
                header_index = i
            continue
        if in_session and RESUME_KEY_RE.match(line):
            replace_index = i
            break
    if header_index is None:
        return list(lines)
    out = list(lines)
    if replace_index is not None:
        out[replace_index] = "resume_agents_on_restore = false"
    else:
        out.insert(header_index + 1, "resume_agents_on_restore = false")
    return out


def compute_new_text(original_text):
    """Return the new file text, or None if no change is needed."""
    if SESSION_HEADER_RE.search(original_text) or re.search(
        r"^\s*\[session\]", original_text, re.MULTILINE
    ):
        lines = original_text.split("\n")
        new_lines = _insert_into_session_table(lines)
        return "\n".join(new_lines)
    if original_text and not original_text.endswith("\n"):
        original_text += "\n"
    if original_text and not original_text.endswith("\n\n"):
        original_text += "\n"
    return original_text + "[session]\nresume_agents_on_restore = false\n"


def main(argv):
    if len(argv) != 2:
        print("usage: fm-herdr-resume-config.py <config-path>", file=sys.stderr)
        return 2
    config_path = argv[1]

    original_text = ""
    if os.path.exists(config_path):
        with open(config_path, "r", encoding="utf-8") as handle:
            original_text = handle.read()
        try:
            original_doc = tomllib.loads(original_text)
        except tomllib.TOMLDecodeError as exc:
            print(
                f"error: {config_path} is not valid TOML ({exc}); refusing to touch it",
                file=sys.stderr,
            )
            return 1
        if _session_already_false(original_doc):
            print("unchanged")
            return 0

    new_text = compute_new_text(original_text)

    try:
        new_doc = tomllib.loads(new_text)
    except tomllib.TOMLDecodeError as exc:
        print(
            f"error: computed replacement for {config_path} is not valid TOML ({exc}); leaving the file untouched",
            file=sys.stderr,
        )
        return 1
    if not _session_already_false(new_doc):
        print(
            f"error: computed replacement for {config_path} did not set resume_agents_on_restore to false; leaving the file untouched",
            file=sys.stderr,
        )
        return 1

    parent = os.path.dirname(config_path) or "."
    os.makedirs(parent, exist_ok=True)
    tmp_path = f"{config_path}.fm-herdr-resume-config.tmp{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as handle:
        handle.write(new_text)
    os.replace(tmp_path, config_path)
    print("changed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
