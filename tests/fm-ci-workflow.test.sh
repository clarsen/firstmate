#!/usr/bin/env bash
# Contract tests for .github/workflows/ci.yml's runner-spend safeguards.
#
# Origin: the 2026-09-12 GitHub Actions starvation incident. firstmate CI had no
# concurrency deduplication, so every superseded PR head kept its full job
# fan-out, and four jobs carried no timeout at all. These tests hold both
# safeguards: PR runs supersede within one PR while main pushes are never
# cancelled, and every CI job carries a finite hang tripwire drawn from the
# three-tier timeout policy that docs/fm-test-portable-shards.md "Timeouts"
# owns (fast, normal, heavy), so no job drifts back to a one-off number.
#
# The workflow is parsed as YAML and its concurrency expressions are resolved
# against simulated pull_request and push contexts, so the assertions describe
# what GitHub would do, not how the file happens to be spelled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"

assert_present "$CI_WORKFLOW" ".github/workflows/ci.yml is missing"
command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse .github/workflows/ci.yml as YAML"

# Resolve the workflow's concurrency contract under one simulated event and
# print "<group><TAB><cancel-in-progress>". Only the two expression constructs
# this workflow uses are resolved: an `a || b` fallback and an `==` comparison.
resolve_concurrency() {
  local event=$1 pr_number=$2 run_id=$3
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
concurrency = doc.fetch("concurrency")
context = {
  "github.workflow" => doc.fetch("name"),
  "github.event_name" => ARGV[1],
  "github.event.pull_request.number" => ARGV[2],
  "github.run_id" => ARGV[3],
}

value = lambda do |token|
  token = token.strip
  next token[1..-2] if token.start_with?("\x27") && token.end_with?("\x27")
  raise "unresolvable context reference: #{token}" unless context.key?(token)
  context.fetch(token)
end

evaluate = lambda do |expression|
  expression = expression.strip
  if expression.include?("==")
    left, right = expression.split("==", 2)
    next value.call(left) == value.call(right) ? "true" : "false"
  end
  resolved = expression.split("||").map { |token| value.call(token) }.find { |v| !v.empty? }
  resolved.to_s
end

interpolate = lambda do |raw|
  raw.to_s.gsub(/\$\{\{(.+?)\}\}/) { evaluate.call(Regexp.last_match(1)) }
end

puts [interpolate.call(concurrency.fetch("group")),
      interpolate.call(concurrency.fetch("cancel-in-progress"))].join("\t")
' "$CI_WORKFLOW" "$event" "$pr_number" "$run_id"
}

job_timeout() {
  ruby -ryaml -e '
puts YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" "$1"
}

# Tier membership is the executable inventory of the timeout policy: a new job
# must join a tier, and a job-level value outside these tiers is exactly the
# one-off number the policy removed.
FAST_TIER_JOBS='test-coverage invariants tests-timing-aggregate'
NORMAL_TIER_JOBS='lint tests-portable-parallel-1 tests-portable-parallel-2 tests-portable-serial macos-stock-bash'
HEAVY_TIER_JOBS='tests-herdr'

# Print the one timeout every listed job shares; fail on any disagreement.
tier_timeout() {  # <tier> <job>...
  local tier=$1 job first actual
  shift
  first=
  for job in "$@"; do
    actual=$(job_timeout "$job") || fail "could not read the $job timeout"
    case "$actual" in ''|*[!0-9]*) fail "$job ($tier tier) has no integer timeout, got $actual" ;; esac
    if [ -z "$first" ]; then
      first=$actual
    elif [ "$actual" != "$first" ]; then
      fail "$tier tier jobs must share one timeout, got $first and $actual ($job)"
    fi
  done
  printf '%s\n' "$first"
}

REPOSITORY=clarsen/firstmate
# shellcheck disable=SC2089
LAPTOP_RUNNER='["self-hosted","macOS","ARM64","mac-laptop-arm64"]'

# Resolve a job's runs-on under one simulated event and print the runner as
# JSON. Arguments after the head repository set repository variables as
# NAME=VALUE. Only the expression constructs runs-on uses are resolved:
# parentheses, ||, &&, ==, !=, string literals, context references, and
# fromJSON, with GitHub's truthiness and short-circuit value semantics.
resolve_runner() {  # <job> <event> <head-repo> [VAR=VALUE]...
  ruby -ryaml -rjson - "$CI_WORKFLOW" "$REPOSITORY" "$@" <<'RUBY'
workflow, repository, job, event, head_repo, *assignments = ARGV
context = {
  "github.event_name" => event,
  "github.repository" => repository,
  "github.event.pull_request.head.repo.full_name" => (event == "pull_request" ? head_repo : nil),
}
assignments.each do |a|
  name, val = a.split("=", 2)
  context["vars.#{name}"] = val
end
runs_on = YAML.load_file(workflow).fetch("jobs").fetch(job).fetch("runs-on")
match = runs_on.is_a?(String) && runs_on.match(/\A\$\{\{(.+)\}\}\z/m)
unless match
  puts JSON.generate(runs_on)
  exit
end
tokens = match[1].scan(/\s*(\x27(?:[^\x27]|\x27\x27)*\x27|\|\||&&|==|!=|[()]|[A-Za-z_][\w.-]*)/).flatten
raise "unparsed runs-on: #{runs_on}" unless tokens.join.gsub(/\s/, "") == match[1].gsub(/\s/, "")
truthy = ->(v) { !(v.nil? || v == false || v == "" || v == 0) }
pos = 0
peek = -> { tokens[pos] }
take = ->(want = nil) do
  t = tokens[pos]
  raise "expected #{want}, got #{t.inspect}" if want && t != want
  pos += 1
  t
end
parse_or = nil
primary = lambda do
  t = take.call
  if t == "("
    v = parse_or.call
    take.call(")")
    v
  elsif t.start_with?("\x27")
    t[1..-2].gsub("\x27\x27", "\x27")
  elsif peek.call == "("
    raise "unsupported function #{t}" unless t == "fromJSON"
    take.call("(")
    arg = parse_or.call
    take.call(")")
    JSON.parse(arg.to_s)
  else
    raise "unresolvable context reference: #{t}" unless context.key?(t) || t.start_with?("vars.")
    context[t]
  end
end
comparison = lambda do
  left = primary.call
  while %w[== !=].include?(peek.call)
    op = take.call
    right = primary.call
    left = (left == right) == (op == "==")
  end
  left
end
parse_and = lambda do
  left = comparison.call
  while peek.call == "&&"
    take.call
    right = comparison.call
    left = truthy.call(left) ? right : left
  end
  left
end
parse_or = lambda do
  left = parse_and.call
  while peek.call == "||"
    take.call
    right = parse_and.call
    left = truthy.call(left) ? left : right
  end
  left
end
result = parse_or.call
raise "trailing tokens in runs-on: #{tokens[pos..].inspect}" unless pos == tokens.length
puts JSON.generate(result)
RUBY
}

# Print "<variable><TAB><hosted fallback>" for a job: the fallback is the
# runner a main push gets with no variables set, and the variable is the one
# repository variable that moves a main push onto the laptop runner.
job_runner() {
  local job=$1 fallback var found=
  fallback=$(resolve_runner "$job" push "$REPOSITORY") || return 1
  for var in FIRSTMATE_CI_RUNNER FIRSTMATE_CI_LINUX_RUNNER; do
    if [ "$(resolve_runner "$job" push "$REPOSITORY" "$var=$LAPTOP_RUNNER")" = "$LAPTOP_RUNNER" ]; then
      [ -z "$found" ] || { echo "$job follows both $found and $var" >&2; return 1; }
      found=$var
    fi
  done
  [ -n "$found" ] || { echo "$job ignores every runner variable" >&2; return 1; }
  printf '%s\t%s\n' "$found" "$(printf '%s' "$fallback" | ruby -rjson -e 'v = JSON.parse(STDIN.read); raise "fallback must be one hosted runner label" unless v.is_a?(String); print v')"
}

# Print every job id in the workflow, one per line.
workflow_jobs() {
  ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("jobs").keys' "$CI_WORKFLOW"
}

group_of() { printf '%s\n' "$1" | cut -f1; }
cancel_of() { printf '%s\n' "$1" | cut -f2; }

test_pr_pushes_supersede_within_one_pr() {
  local first second
  first=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  second=$(resolve_concurrency pull_request 108 900002) || fail "could not resolve PR concurrency"
  [ "$(group_of "$first")" = "$(group_of "$second")" ] \
    || fail "two runs of one PR must share a concurrency group, got $(group_of "$first") and $(group_of "$second")"
  [ "$(cancel_of "$first")" = true ] \
    || fail "PR runs must cancel the in-progress run, got $(cancel_of "$first")"
  pass "a newer push to one PR supersedes that PR's in-flight CI"
}

test_separate_prs_do_not_cancel_each_other() {
  local one two
  one=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  two=$(resolve_concurrency pull_request 109 900003) || fail "could not resolve PR concurrency"
  [ "$(group_of "$one")" != "$(group_of "$two")" ] \
    || fail "distinct PRs must not share a concurrency group ($(group_of "$one"))"
  pass "distinct PRs get distinct concurrency groups"
}

test_main_pushes_are_never_cancelled() {
  local first second
  first=$(resolve_concurrency push '' 900010) || fail "could not resolve push concurrency"
  second=$(resolve_concurrency push '' 900011) || fail "could not resolve push concurrency"
  [ "$(group_of "$first")" != "$(group_of "$second")" ] \
    || fail "each main push must get its own concurrency group, got $(group_of "$first") twice"
  [ "$(cancel_of "$first")" = false ] \
    || fail "push runs must never cancel an in-progress run, got $(cancel_of "$first")"
  pass "every main push keeps its own group and is never cancelled"
}

test_every_job_has_a_finite_timeout() {
  local reported
  reported=$(ruby -ryaml -e '
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  timeout = job["timeout-minutes"]
  next if timeout.is_a?(Integer) && timeout > 0
  puts "#{name}: #{timeout.inspect}"
end
' "$CI_WORKFLOW") || fail "could not read job timeouts from ci.yml"
  [ -z "$reported" ] || fail "these CI jobs have no finite hang tripwire:"$'\n'"$reported"
  pass "every ci.yml job carries a finite timeout"
}

# Every job sits in exactly one tier, and the workflow carries exactly three
# distinct job-level timeouts: one per tier, no one-off numbers.
test_every_job_belongs_to_exactly_one_timeout_tier() {
  local expected actual distinct
  # shellcheck disable=SC2086
  expected=$(printf '%s\n' $FAST_TIER_JOBS $NORMAL_TIER_JOBS $HEAVY_TIER_JOBS | LC_ALL=C sort)
  [ "$(printf '%s\n' "$expected" | LC_ALL=C sort -u)" = "$expected" ] \
    || fail "a job is listed in more than one timeout tier:"$'\n'"$expected"
  actual=$(workflow_jobs | LC_ALL=C sort) || fail "could not list ci.yml jobs"
  [ "$actual" = "$expected" ] \
    || fail "ci.yml jobs and the timeout tiers disagree; every job must join one tier"$'\n'"workflow: $(printf '%s' "$actual" | tr '\n' ' ')"$'\n'"tiers: $(printf '%s' "$expected" | tr '\n' ' ')"
  distinct=$(for job in $expected; do job_timeout "$job"; done | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$distinct" = 3 ] \
    || fail "ci.yml must carry exactly three distinct job timeouts (fast, normal, heavy), got $distinct"
  pass "every ci.yml job belongs to one of the three timeout tiers"
}

# Fast tier: seconds-long checks share one short tripwire in the 5-10 minute band.
test_fast_tier_shares_one_short_tripwire() {
  local fast
  # shellcheck disable=SC2086
  fast=$(tier_timeout fast $FAST_TIER_JOBS) || exit 1
  [ "$fast" -ge 5 ] && [ "$fast" -le 10 ] \
    || fail "fast tier must be a 5-10 minute hang tripwire, got $fast"
  pass "fast tier jobs share one $fast minute tripwire"
}

# Normal tier: every test or lint lane shares ONE fixed 30-minute budget,
# above the fast tier. That budget is a hang tripwire, not a packing estimate.
test_normal_tier_shares_one_budget() {
  local fast normal
  # shellcheck disable=SC2086
  fast=$(tier_timeout fast $FAST_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  [ "$normal" -gt "$fast" ] \
    || fail "normal tier ($normal) must exceed the fast tier ($fast)"
  [ "$normal" = 30 ] \
    || fail "normal tier must be the single 30-minute shared budget, got $normal"
  pass "normal tier jobs share one $normal minute budget"
}

# Heavy tier: Herdr alone carries a job-level last-resort backstop above the
# normal tier, while its family-run step owns a tighter tripwire so the
# always() cleanup and timing upload still run after a hang.
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop() {
  local normal heavy step
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  heavy=$(tier_timeout heavy $HEAVY_TIER_JOBS) || exit 1
  [ "$heavy" -gt "$normal" ] \
    || fail "heavy tier backstop ($heavy) must exceed the normal tier ($normal)"
  [ "$heavy" -ge 60 ] && [ "$heavy" -le 75 ] \
    || fail "heavy tier backstop must stay a 60-75 minute last resort, got $heavy"
  step=$(ruby -ryaml -e '
steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("steps")
index = steps.index { |s| s["id"] == "run-real-herdr-family" }
raise "no run-real-herdr-family step" unless index
teardown = steps.index { |s| s["id"] == "cleanup-herdr-lab-sessions" }
raise "no cleanup-herdr-lab-sessions step" unless teardown
raise "teardown must follow the family-run step" unless teardown > index
raise "teardown must run under always()" unless steps[teardown]["if"].to_s.strip == "always()"
puts steps[index].fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" tests-herdr) || fail "could not read the Herdr family-run step"
  case "$step" in ''|*[!0-9]*) fail "the Herdr family-run step needs its own timeout-minutes, got $step" ;; esac
  [ "$step" = 20 ] \
    || fail "the Herdr family-run step must be the 20-minute tripwire, got $step"
  [ "$step" -lt "$heavy" ] \
    || fail "the Herdr step tripwire ($step) must stay below the job backstop ($heavy)"
  pass "Herdr keeps a $step minute step tripwire under a $heavy minute job backstop"
}

test_ci_matrices_match_executable_partitions() {
  ruby -ryaml -ropen3 - "$CI_WORKFLOW" "$ROOT" <<'RUBY' || fail "CI partition contract"
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
root = ARGV[1]
serial = jobs.fetch("tests-portable-serial").fetch("strategy")
raise "serial failures must not cancel other shards" unless serial.fetch("fail-fast") == false
matrix = serial.fetch("matrix")
raise "unexpected serial dimensions" unless matrix.keys == ["shard"]
shards = matrix.fetch("shard")
lanes, status = Open3.capture2(File.join(root, "bin/fm-test-run.sh"), "--list-lanes")
raise "cannot list runner lanes" unless status.success?
actual = lanes.lines.map(&:strip).select { |l| l.match?(/\Aportable-serial-\d+of\d+\z/) }
expected = shards.map { |s| "portable-serial-#{s}of#{shards.length}" }
raise "CI matrix and runner disagree" unless actual.sort == expected.sort
lint = jobs.fetch("lint").fetch("strategy")
raise "lint failures must not cancel another partition" unless lint.fetch("fail-fast") == false
matrix = lint.fetch("matrix")
raise "unexpected lint dimensions" unless matrix.keys == ["partition"]
parts = matrix.fetch("partition")
roots = parts.flat_map do |p|
  output, result = Open3.capture2(File.join(root, "bin/fm-lint.sh"), "--partition", "#{p}of#{parts.length}", "--list-files")
  raise "unsupported lint partition" unless result.success?
  output.lines.map(&:strip)
end
canonical, result = Open3.capture2({"CI" => "true"}, File.join(root, "bin/fm-lint.sh"), "--list-files")
raise "lint matrix loses or duplicates canonical roots" unless result.success? && roots.sort == canonical.lines.map(&:strip).sort
RUBY
  pass "CI matrices cover every executable serial lane and canonical lint root exactly once"
}

# Runner contract: docs/fm-test-portable-shards.md "Runner override" owns it.
# Unset variables keep every job on the GitHub-hosted runner it always used, so
# forks that never set a variable are unaffected. Only the jobs not yet proven
# on macOS (serial shards and real Herdr) sit behind the separate Linux variable.
test_every_job_runner_is_overridable_with_hosted_defaults() {
  local job got
  for job in $(workflow_jobs); do
    got=$(job_runner "$job") || fail "$job runs-on: could not resolve the runner"
    case "$job" in
      tests-portable-serial|tests-herdr)
        [ "$got" = "$(printf 'FIRSTMATE_CI_LINUX_RUNNER\tubuntu-latest')" ] \
          || fail "$job must use FIRSTMATE_CI_LINUX_RUNNER with an ubuntu-latest fallback, got $got" ;;
      macos-stock-bash)
        [ "$got" = "$(printf 'FIRSTMATE_CI_RUNNER\tmacos-latest')" ] \
          || fail "$job must use FIRSTMATE_CI_RUNNER with a macos-latest fallback, got $got" ;;
      *)
        [ "$got" = "$(printf 'FIRSTMATE_CI_RUNNER\tubuntu-latest')" ] \
          || fail "$job must use FIRSTMATE_CI_RUNNER with an ubuntu-latest fallback, got $got" ;;
    esac
  done
  pass "every ci.yml job runner is a repository-variable override with its hosted default"
}

# Fork rule: a fork pull request never reaches a self-hosted runner, even with
# both variables set, while a same-repository pull request and a main push
# follow the variable.
test_fork_pull_requests_always_use_the_hosted_runner() {
  local job runner var fallback got
  for job in $(workflow_jobs); do
    runner=$(job_runner "$job") || fail "$job runs-on: could not resolve the runner"
    var=$(printf '%s\n' "$runner" | cut -f1)
    fallback=$(printf '%s\n' "$runner" | cut -f2)
    got=$(resolve_runner "$job" pull_request someone/firstmate \
      "FIRSTMATE_CI_RUNNER=$LAPTOP_RUNNER" "FIRSTMATE_CI_LINUX_RUNNER=$LAPTOP_RUNNER") || fail "$job: could not resolve a fork PR runner"
    [ "$got" = "\"$fallback\"" ] || fail "$job must run fork PRs on $fallback, got $got"
    got=$(resolve_runner "$job" pull_request "$REPOSITORY" "$var=$LAPTOP_RUNNER") || fail "$job: could not resolve a same-repo PR runner"
    [ "$got" = "$LAPTOP_RUNNER" ] || fail "$job must run same-repo PRs on $var, got $got"
    got=$(resolve_runner "$job" push "$REPOSITORY" "$var=$LAPTOP_RUNNER") || fail "$job: could not resolve a push runner"
    [ "$got" = "$LAPTOP_RUNNER" ] || fail "$job must run main pushes on $var, got $got"
  done
  pass "fork PRs stay hosted while same-repo PRs and main pushes follow the runner variable"
}

# Self-hosted hygiene: no job installs into the runner user's global npm prefix.
test_npm_global_installs_use_a_job_scoped_prefix() {
  local reported
  reported=$(ruby -ryaml -e '
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  steps = job.fetch("steps")
  installs = steps.each_index.select { |i| steps[i]["run"].to_s.include?("npm install -g") }
  next if installs.empty?
  isolate = steps.index { |s| s["run"].to_s.include?("NPM_CONFIG_PREFIX=") }
  puts name if isolate.nil? || isolate > installs.min
end
' "$CI_WORKFLOW") || fail "could not read ci.yml steps"
  [ -z "$reported" ] || fail "these jobs run npm install -g before isolating the npm prefix:"$'\n'"$reported"
  pass "every npm global install runs under a job-scoped prefix"
}

test_ci_matrices_match_executable_partitions
test_every_job_runner_is_overridable_with_hosted_defaults
test_fork_pull_requests_always_use_the_hosted_runner
test_npm_global_installs_use_a_job_scoped_prefix
test_pr_pushes_supersede_within_one_pr
test_separate_prs_do_not_cancel_each_other
test_main_pushes_are_never_cancelled
test_every_job_has_a_finite_timeout
test_every_job_belongs_to_exactly_one_timeout_tier
test_fast_tier_shares_one_short_tripwire
test_normal_tier_shares_one_budget
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop
