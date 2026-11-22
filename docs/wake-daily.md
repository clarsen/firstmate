# Wake daily outcome record

Owner: Firstmate maintainers.
Applies to Firstmate homes using `fm-wake-daily.v1`; reviewed 2026-11-21.

`bin/fm-wake-daily.py` writes one JSON record for a completed day in `data/wake/daily/` of the selected Firstmate home.
Run it with a Pacific date and optionally `--home HOME`; `FM_HOME` is the default home override.
The script refuses today and future dates in `America/Los_Angeles`.
It replaces the output atomically and leaves a byte-identical file alone on a repeat run with unchanged inputs.

The `fm-wake-daily.v1` record has `day`, `timezone`, `contributions`, `links`, and `coverage` sections.
`contributions.projects` groups ships, scouts, and closed decisions by recorded project, using `none recorded` when a project was not recorded.
Rows with no recorded kind appear in `unclassified` under their recorded project or `none recorded`.
A ship includes its task, title, evidence, merge time, and time precision; a backlog-only merge has day precision.
A backlog or archive ship row counts only when it is a delivery under the Recently Landed rule in `bin/fm-landed-lib.sh`: `(merged D)` with its PR or MR URL, `(done D)` with a `local main` note in its title or as its last body line (unless the body records an `fm-captain-hold` or `fm-decision-hold` resolution), or a row with no PR or MR URL, report path, or `local main` note; other links such as issue URLs are not artifacts; a `(reported D)` row, a closed row whose artifact does not match its verb, and a row retaining `hold-kind: captain` are not merges.
A scout includes its task, title, report path, and reported day; a scout with no recorded report path counts only when `data/<task>/report.md` exists.
A decision includes its task, title, exact recorded question and answer, evidence, and closing day or time.
These are contributions to assess in a retrospective, not claims that a change is active or valuable in production.

`links.items` has one task entry for each task recorded on the day and one MR entry for each merge or pull request URL recorded for those tasks.
Each entry carries its explicit `blocked_by` task IDs, `id_family` and other `family_tasks`, `story_refs` and `epic_refs` from the task title, `origin_tasks` recorded on captain decision or follow-up notes, and earlier `scout_reports` and `scout_tasks` named by the task.
An ID family is the longest shared task-ID prefix of at least three hyphen-separated parts, or a shorter prefix that is itself a recorded task ID; family members are limited to the day's tasks.
The scout fields include only named reports or tasks whose scout task was recorded no later than this day, and exclude a scout's own report.
The links are evidence for a retrospective to interpret; the collector does not group tasks into deliverables.
Pin MRs discovered as production deployment evidence belong to the production signal, not to these task-record links.

`coverage.inputs` names each source and whether it was readable.
`coverage.signals` gives each contribution count, or `not_measurable` with the missing sources and an observed partial count.
Its `links` count covers task and MR entries and requires the ledger from 2026-11-21 onward.
`coverage.ledger_duplicates_dropped` counts repeated ledger records timestamped on this day and repeated merge outcomes removed from this record.
Before 2026-11-21, done-archive and backlog dates are authoritative for ships, each at day precision, and the ledger is not read.
From 2026-11-21 onward, the ledger is a required input and its `task.merged` time is preferred over a backlog or archive row for the same task, counting each task once; ledger merges stamped before 2026-11-21 are ignored; `coverage.merge_time_source` names which applies.
Backlog decision blocks have no answer timestamp, so a decision counts on its task's Done date with `date_source` marking that close date.
Answered decisions on still-open tasks count on no day; `coverage.uncounted_decisions` reports how many, with the reason "answer time unknown (task still open)".
Other Wake signal sections are absent until their stories add them.

The collector reads the fleet ledger, backlog, done archive, and captain question store.
It changes no source file and writes only beneath `data/wake/`.
Sessions outside Firstmate are invisible to this record.
