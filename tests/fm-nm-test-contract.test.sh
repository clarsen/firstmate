#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty,
# and must not publish test evidence to an evidence branch of this public repository.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_has_no_deterministic_test_command() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
puts (val.nil? || val == false || val == "") ? "" : val.inspect
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$val" ]; then
    fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val"
  fi
  pass "no-mistakes does not configure commands.test"
}

test_nm_keeps_evidence_off_the_repository() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
test = doc["test"].is_a?(Hash) ? doc["test"] : {}
ev = test["evidence"].is_a?(Hash) ? test["evidence"] : {}
puts ev["store_in_repo"].inspect
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  case "$val" in
    nil|false) ;;
    *) fail "test.evidence.store_in_repo must be absent or false so evidence never reaches a public evidence branch; got: $val" ;;
  esac
  pass "no-mistakes keeps test evidence off the repository"
}

test_nm_has_no_deterministic_test_command
test_nm_keeps_evidence_off_the_repository
