# Wake daily outcome record

Owner: Firstmate maintainers.
Applies to Firstmate homes using `fm-wake-daily.v1`; reviewed 2026-11-21.

`bin/fm-wake-daily.py` writes one JSON record for a completed day in `data/wake/daily/` of the selected Firstmate home.
Run it with a Pacific date and optionally `--home HOME`; `FM_HOME` is the default home override.
The script refuses today and future dates in `America/Los_Angeles`.
It replaces the output atomically and leaves a byte-identical file alone on a repeat run with unchanged inputs.

The `fm-wake-daily.v1` record has `day`, `timezone`, `contributions`, and `coverage` sections.
`contributions.projects` groups ships, scouts, and closed decisions by recorded project, using `none recorded` when a project was not recorded.
Rows with no recorded kind appear in `unclassified` under their recorded project or `none recorded`.
A ship includes its task, title, evidence, merge time, and time precision; a backlog-only merge has day precision.
A scout includes its task, title, report path, and reported day.
A decision includes its task, title, exact recorded question and answer, evidence, and closing day or time.
These are contributions to assess in a retrospective, not claims that a change is active or valuable in production.

`coverage.inputs` names each source and whether it was readable.
`coverage.signals` gives each contribution count, or `not_measurable` with the missing sources and an observed partial count.
`coverage.ledger_duplicates_dropped` counts repeated ledger records timestamped on this day and repeated merge outcomes removed from this record.
Before 2026-11-21, done-archive and backlog dates are authoritative for ships, each at day precision, and the ledger is not read.
From 2026-11-21 onward, the ledger is a required input and its `task.merged` time is preferred over a backlog or archive row for the same task, counting each task once; ledger merges stamped before 2026-11-21 are ignored; `coverage.merge_time_source` names which applies.
Backlog decision blocks have no answer timestamp, so a decision counts on its task's Done date with `date_source` marking that close date.
Answered decisions on still-open tasks count on no day; `coverage.uncounted_decisions` reports how many, with the reason "answer time unknown (task still open)".
Other Wake signal sections are absent until their stories add them.

The collector reads the fleet ledger, backlog, done archive, and captain question store.
It changes no source file and writes only beneath `data/wake/`.
Sessions outside Firstmate are invisible to this record.
