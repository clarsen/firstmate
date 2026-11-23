# Wake daily outcome record

Owner: Firstmate maintainers.
Applies to Firstmate homes using `fm-wake-daily.v1`; reviewed 2026-11-22.

`bin/fm-wake-daily.py` writes one JSON record for a completed day in `data/wake/daily/` of the selected Firstmate home.
The existing watcher starts a finite `--catch-up` run on its check cadence, five minutes by default, so no operator step is required.
The run covers every Pacific day since Wake began on 2026-11-21 once the following day has also completed, so records lag one day and late backlog edits made just after midnight are included.
It writes each missing day, including days missed while supervision was offline, and rebuilds an existing record while any of its `coverage.inputs` is `not_measurable` and the day is at most three days old, so a brief forge or file outage does not freeze a record; after that window the record is final as written.
Concurrent runs share a home-local lock, a failed day does not stop later days, and the watcher appends one error line per failing day to `wake-daily.log` in its state directory, keeping only its last 1000 lines once it exceeds 1 MB.
For a selected historical day, run the collector with a Pacific date and optionally `--home HOME`; `FM_HOME` is the default home override.
A selected-day run always rebuilds that day from current sources.
The script refuses today and future dates in `America/Los_Angeles`.
It replaces the output atomically and leaves a byte-identical file alone on a repeat run with unchanged inputs.

The `fm-wake-daily.v1` record has `day`, `timezone`, `contributions`, `links`, `rework`, `hostupdate_mr_pipeline_wall_time`, `production_evidence`, `hostupdate_deploy_receipts`, `firstmate_updates`, and `coverage` sections.
`contributions.projects` groups ships, scouts, and closed decisions by recorded project, using `none recorded` when a project was not recorded.
Rows with no recorded kind appear in `unclassified` under their recorded project or `none recorded`.
`coverage.signals.unclassified` reports their day count alongside ships, so a ship count can be read with its classification gap.
A row with no recorded kind that counts as a scout under the reported-task rule below is not also unclassified.
A ship includes its task, title, evidence, merge time, and time precision; a backlog-only merge has day precision.
A backlog or archive ship row counts only when it is a delivery under the Recently Landed rule in `bin/fm-landed-lib.sh`: `(merged D)` with its PR or MR URL, `(done D)` with a `local main` note in its title or as its last body line (unless the body records an `fm-captain-hold` or `fm-decision-hold` resolution), or a row with no PR or MR URL, report path, or `local main` note; other links such as issue URLs are not artifacts; a `(reported D)` row, a closed row whose artifact does not match its verb, and a row retaining `hold-kind: captain` are not merges.
A scout includes its task, title, report path, and reported day; a scout with no recorded report path counts only when `data/<task>/report.md` exists.
A reported task with an existing report also counts as a scout regardless of its stored kind, covering an investigation archived under the wrong kind.
A decision includes its task, title, exact recorded question and answer, evidence, and closing day or time.
These are contributions to assess in a retrospective, not claims that a change is active or valuable in production.

`links.items` has one task entry for each task recorded on the day and one MR entry for each merge or pull request URL recorded for those tasks.
Each entry carries its explicit `blocked_by` task IDs, `id_family` and other `family_tasks`, `story_refs` and `epic_refs` from the task title, `origin_tasks` from `Captain hold origin: <task>` note lines on captain decisions and their follow-ups, and earlier `scout_reports` and `scout_tasks` named by the task.
An ID family is the shortest shared task-ID prefix of at least three hyphen-separated parts, or a shorter prefix that is itself a recorded task ID; family members are limited to the day's tasks, so every member of a family carries the same `id_family` and lists all the others.
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
`rework.reverts` lists commits whose subject begins `Revert` in local project clone history, with the commit time and a commit URL where the clone's origin provides one, otherwise `projects/<clone>@<sha>`.
`rework.closed_unmerged` lists observed fleet task PRs and MRs currently closed without a merge, on the Pacific day of their forge close time.
`rework.failed_pipelines` lists failed GitLab MR pipelines and failed GitHub pull request workflow runs on the Pacific day of their reported finish or update time, with the pipeline or run URL and task PR or MR URL.
The collector reads task delivery URLs from ship rows, fleet ledger entries, and task metadata, then uses read-only GitLab and GitHub API requests.
Each PR or MR URL is reduced to its canonical form, so a trailing path, fragment, or punctuation does not change which PR is read.
For a given day the collector reads only PRs and MRs whose task was in flight that day: from its earliest `since` row date or ledger dispatch through its latest done date or ledger merge or cleanup, or still open.
A done task with no recorded start is assumed to start 14 days before its done day; `coverage.forge_candidates` reports the day's candidate count and how many used that assumed start.
A PR or MR already recorded as merged is not read for `closed_unmerged`, only for its pipelines.
It does not refresh project clones or change forge state.
`coverage.signals` reports a rework count as `not_measurable` when a required clone or forge read fails or reaches a page limit; its `observed` value is only the partial count.
`closed_unmerged` always has partial candidate coverage because the collector cannot see replaced PRs or MRs absent from the recorded task URLs, so its `count` is null and its `observed` value is a lower bound even when every candidate forge read succeeds.
When a candidate read also fails, its reason adds the missing or unreadable input cause.
`coverage.inputs` names the affected clone or forge URL, so an unreachable forge cannot appear as a measured zero.
`hostupdate_mr_pipeline_wall_time` lists successful `lblnet/lblnet_hostupdate` merge request pipelines whose `finished_at` falls on the requested Pacific day.
Each row records the GitLab pipeline ID and URL, the merge request IID and source branch, creation and finish times in UTC, and creation-to-finish wall time in seconds.
The `kind` is `generated_followup` when the pipeline has a `generated-followup-verify` job, and `initial` otherwise.
`job_signals` records the presence of `build-lblnet_hostupdate` and `test-unit-checkout` jobs.
`change_class` is `image_build` when `build-lblnet_hostupdate` ran, otherwise `full_unit` when `test-unit-checkout` ran, otherwise `other`.
`summary` gives the count, median, nearest-rank 90th percentile, and share under 60 seconds for all listed pipelines; `initial_summary` gives those figures for initial pipelines only, and `initial_by_change_class` gives them for initial pipelines of each change class.
Summaries use seconds and return null median, percentile, and share when their count is zero.
The collector uses read-only GitLab API calls through `glab` against `lsg-git.lbl.gov`, listing successful merge request pipelines updated since the start of the requested day, so a pipeline whose record was updated on a later day still counts on its finish day; listed pipelines created after the requested day are skipped without further requests.
If the forge is unreachable or its response is invalid, the section has no rows, summary values are null, and `coverage.signals.hostupdate_mr_pipeline_wall_time` is `not_measurable` rather than a zero count; its `error` names the failed check and `pipeline_id` names the pipeline being read, or is null.
`production_evidence.deployed` lists MRs whose successful production job reached production on the selected Pacific day, with the source MR, any matching fleet task, measurement path, UTC deploy time, and numeric GitLab `deploy_job_id`.
The source is gitlab_watch's `deploy_lead_time` measurement in the `lsg_deploy_metrics` InfluxDB bucket, limited to the production paths in its [measurement contract](https://lsg-git.lbl.gov/lblnet/gitlab_watch/-/blob/main/docs/modules/ROOT/pages/deployment-lead-time.adoc#measurement-contract).
The bucket has `path`, `project`, and `iid` tags and `mr_url`, `deployed`, `deployed_at_ms`, and `deploy_job_id` fields, but no deploy job URL field.
The numeric ID is the join key for a later hostupdate receipt's GitLab job URL.
The bucket query considers MRs merged within 120 days before the selected day, matching the source collector's look-back window.
`production_evidence.not_shown` lists MRs merged on the selected day without such evidence by day end, with merge time and reason; this includes generate_nagios_cfg MRs because its production reload has no GitLab-visible receipt.
The section reports source observations and never judges whether a deliverable is active.
The collector reads `INFLUXDB_DEPLOY_METRICS_TOKEN` only from the selected home's gitignored `.env`, never from the process environment, using the same one-key parsing rules as `bin/fm-env-lib.sh`.
The InfluxDB URL, organization `LSG`, and bucket are fixed; the token is never written to the daily record or logs.
If the token is absent or the query fails, `coverage.inputs.influxdb:lsg_deploy_metrics/deploy_lead_time` and `coverage.signals.production_evidence` are `not_measurable`, with a null count.
`hostupdate_deploy_receipts.events` lists retained `deploy-event.json` events whose end time falls on the selected Pacific day, with UTC time, numeric GitLab deploy job ID and job URL, host, role, outcome, associated MRs, and matching fleet tasks.
The collector reads the artifacts from the [hostupdate receipt source of truth](https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/blob/master/docs/modules/ROOT/pages/reference_deploy_receipts.adoc) through read-only GitLab API requests.
The artifact retention is 45 days except jobs with shorter retention; the collector does not backfill expired artifacts.
The numeric job ID joins this section to `production_evidence.deployed` without counting an overlapping deploy twice.
`firstmate_updates.updates` lists this home's Git reflog fast forwards on the selected Pacific day, with UTC time, before and after commits, and merged GitHub PRs associated with commits brought in by each update.
Both sections report observations and make no claim that a deliverable is active.
An unavailable or invalid source makes its `coverage.inputs` and `coverage.signals` entries `not_measurable`, with a null count.

The collector reads the fleet ledger, backlog, done archive, captain question store, task metadata, local project clone histories, and GitLab pipeline, job, and merge request records.
It changes no source file and writes only beneath `data/wake/`.
Sessions outside Firstmate are invisible to this record.
