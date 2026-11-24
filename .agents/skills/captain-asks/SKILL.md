---
name: captain-asks
description: Load when an explicit captain request to merge, deploy to production or dev, or prioritize ongoing progress on a project is received, and on a captain-ask check wake.
user-invocable: false
metadata:
  internal: true
---

# Captain ask receipts

This skill applies to an explicit delivery order or priority designation, not to a status question.
[`docs/configuration.md`](../../../docs/configuration.md#captain-ask-ledger-datacaptain-asksjson) owns the ledger schema and verification rules.

Record the exact chat or board words with `bin/fm-captain-asks.py add` during the intake turn.
Use a stable source-and-target key so a repeated turn returns the same ask.
Name the project, linked task, and requested target; when there is no task yet, record a short `--no-task-reason` and create or dispatch the work through the normal task lifecycle.
For a broad request with no SHA yet, record the requested outcome as the initial target, then use `update` with evidence to add the resolved target and verifier when they are known.
The receipt tracks an obligation and grants no deploy, merge, or approval authority.

After a `check: captain ask` wake, inspect the current ledger item and its linked task, drive the next permitted step, and give it an owner or a recorded wait.
Run `verify` against the declared read-only predicate when evidence may have changed.
A worker's completion, a green pipeline, or a successful no-change deploy job is progress evidence and does not close a delivery ask.
Only a passing verifier closes a deploy or merge ask; archive requires an explicit reason that remains in the record.
Keep priority items open until the priority designation is explicitly withdrawn.
The watcher repeats due checks; a live task does not prevent target verification.
