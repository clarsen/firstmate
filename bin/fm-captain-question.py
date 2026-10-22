#!/usr/bin/env python3
"""Keep captain-opened Bearings questions in the active home's private data.

Usage: fm-captain-question.py open --question-file FILE [--status-file FILE]
       fm-captain-question.py status ID --status-file FILE [--link LABEL=HTTPS_URL ...] [--clear-links]
       fm-captain-question.py close ID (--captain-words-file FILE | --board-result FILE)

The data/captain-questions.json record has schema fm-captain-questions.v1 and a
questions array. Each row has an immutable q-YYYYMMDD-xxxxxxxx id, the exact
question text, opened and last_updated UTC timestamps, a current status
summary, HTTPS evidence links ({label,url}), an open/closed state, and a
closed_by_captain object or null. A close object preserves its UTC time,
source (captain-chat or board), exact words, and evidence path. This record is
separate from backlog tasks and captain holds.

Only an explicit captain close, preserved verbatim or captured by the Bearings
board answer adapter, can change state to closed. Status updates never close a
row. A status update retains earlier links unless --link or --clear-links is
passed. Opening the exact text of an existing open question returns its id
without creating a duplicate; a --status-file passed with that repeat refreshes
its status and last_updated. A missing record means zero questions.
bin/fm-captain-question-list.sh reads the open rows, marking each stale after
24 hours without a status update, with jq alone so Bearings needs no python3.
"""

import argparse
import contextlib
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
HOME = Path(os.environ.get("FM_HOME") or ROOT)
RECORD = HOME / "data" / "captain-questions.json"
SCHEMA = "fm-captain-questions.v1"
ID_RE = re.compile(r"^q-[0-9]{8}-[0-9a-f]{8}$")
STAMP_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
HTTPS_RE = re.compile(r"^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#]\S*)?$")


def now():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def stamp(value):
    return value.isoformat().replace("+00:00", "Z")


def read_text(path):
    target = Path(path)
    if target.is_symlink() or not target.is_file():
        raise ValueError(f"not a regular file: {path}")
    value = target.read_text(encoding="utf-8")
    if not value.strip():
        raise ValueError(f"empty text file: {path}")
    return value


def valid_url(value):
    return HTTPS_RE.fullmatch(value) is not None and not any(c.isspace() for c in value)


def validate(doc):
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA or not isinstance(doc.get("questions"), list):
        raise ValueError("invalid captain question record")
    seen = set()
    for row in doc["questions"]:
        if not isinstance(row, dict) or not isinstance(row.get("id"), str) \
                or not ID_RE.fullmatch(row["id"]) or row["id"] in seen:
            raise ValueError("invalid or duplicate captain question id")
        seen.add(row["id"])
        if row.get("state") not in ("open", "closed"):
            raise ValueError("invalid captain question state")
        if not isinstance(row.get("question"), str) or not row["question"].strip():
            raise ValueError("captain question text is missing")
        if not isinstance(row.get("status"), str) or not row["status"].strip():
            raise ValueError("captain question status is missing")
        for field in ("opened", "last_updated"):
            if not isinstance(row.get(field), str) or not STAMP_RE.fullmatch(row[field]):
                raise ValueError(f"captain question {field} is invalid")
            try:
                dt.datetime.fromisoformat(row[field].replace("Z", "+00:00"))
            except ValueError as error:
                raise ValueError(f"invalid captain question {field}") from error
        if not isinstance(row.get("links"), list) or any(
            not isinstance(link, dict) or not isinstance(link.get("label"), str)
            or not link["label"] or not isinstance(link.get("url"), str)
            or not valid_url(link["url"]) for link in row["links"]
        ):
            raise ValueError("invalid captain question links")
        if row["state"] == "closed":
            close = row.get("closed_by_captain")
            if not isinstance(close, dict) or close.get("source") not in ("captain-chat", "board") \
                    or not isinstance(close.get("at"), str) or not STAMP_RE.fullmatch(close["at"]) \
                    or not isinstance(close.get("words"), str) \
                    or not close["words"].strip():
                raise ValueError("closed question lacks captain provenance")
        elif row.get("closed_by_captain") is not None:
            raise ValueError("open question has close provenance")


def load():
    if not RECORD.exists():
        return {"schema": SCHEMA, "questions": []}
    if RECORD.is_symlink():
        raise ValueError("captain question record is a symlink")
    doc = json.loads(RECORD.read_text(encoding="utf-8"))
    validate(doc)
    return doc


def save(doc):
    validate(doc)
    RECORD.parent.mkdir(parents=True, exist_ok=True)
    fd, staged = tempfile.mkstemp(prefix=".captain-questions.", dir=RECORD.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(doc, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(staged, RECORD)
    finally:
        if os.path.exists(staged):
            os.unlink(staged)


@contextlib.contextmanager
def locked():
    import fcntl
    RECORD.parent.mkdir(parents=True, exist_ok=True)
    lock = RECORD.with_suffix(".lock")
    if lock.is_symlink():
        raise ValueError("captain question lock is a symlink")
    with lock.open("a+") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def row_for(doc, question_id):
    for row in doc["questions"]:
        if row["id"] == question_id:
            return row
    raise ValueError(f"captain question does not exist: {question_id}")


def board_close(result_file, question_id):
    if not Path(result_file).is_file() or Path(result_file).is_symlink():
        raise ValueError("board result must be a regular file")
    adapter = ROOT / "bin" / "fm-procevent-lavish.sh"
    result = subprocess.run([str(adapter), "answers", result_file], capture_output=True, text=True, check=True)
    rows = [line.split("\t") for line in result.stdout.splitlines()]
    key = f"captain-question.{question_id}"
    if not any(len(row) >= 2 and row[0] == key and row[1] == "close" for row in rows):
        raise ValueError(f"board result has no captain Close answer for {question_id}")
    return "close", "board"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    opened = sub.add_parser("open", help="record the captain's exact question")
    opened.add_argument("--question-file", required=True)
    opened.add_argument("--status-file")
    status = sub.add_parser("status", help="refresh an open question from current evidence")
    status.add_argument("id")
    status.add_argument("--status-file", required=True)
    status.add_argument("--link", action="append", default=[], metavar="LABEL=HTTPS_URL")
    status.add_argument("--clear-links", action="store_true")
    closed = sub.add_parser("close", help="record the captain's explicit close")
    closed.add_argument("id")
    provenance = closed.add_mutually_exclusive_group(required=True)
    provenance.add_argument("--captain-words-file")
    provenance.add_argument("--board-result")
    args = parser.parse_args()
    with locked():
        doc = load()
        if args.command == "open":
            question = read_text(args.question_file)
            existing = next((row for row in doc["questions"]
                if row["state"] == "open" and row["question"] == question), None)
            if existing:
                if args.status_file:
                    existing["status"] = read_text(args.status_file)
                    existing["last_updated"] = stamp(now())
                    save(doc)
                print(existing["id"])
                return
            summary = read_text(args.status_file) if args.status_file else "Investigation pending."
            moment = now()
            question_id = f"q-{moment:%Y%m%d}-{uuid.uuid4().hex[:8]}"
            doc["questions"].append({"id": question_id, "question": question, "opened": stamp(moment),
                "status": summary, "last_updated": stamp(moment), "links": [], "state": "open",
                "closed_by_captain": None})
            save(doc)
            print(question_id)
        elif args.command == "status":
            row = row_for(doc, args.id)
            if row["state"] != "open":
                raise ValueError("closed captain question cannot be updated")
            links = []
            for raw in args.link:
                label, sep, url = raw.partition("=")
                if not sep or not label or not valid_url(url):
                    raise ValueError(f"invalid evidence link: {raw}")
                links.append({"label": label, "url": url})
            row["status"] = read_text(args.status_file)
            row["last_updated"] = stamp(now())
            if args.clear_links or args.link:
                row["links"] = links
            save(doc)
        elif args.command == "close":
            row = row_for(doc, args.id)
            if row["state"] != "open":
                raise ValueError("captain question is already closed")
            if args.board_result:
                words, source = board_close(args.board_result, args.id)
            else:
                words, source = read_text(args.captain_words_file), "captain-chat"
            row["state"] = "closed"
            row["closed_by_captain"] = {"at": stamp(now()), "source": source, "words": words,
                "evidence": args.board_result if args.board_result else args.captain_words_file}
            save(doc)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"fm-captain-question: {error}", file=sys.stderr)
        sys.exit(1)
