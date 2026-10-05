#!/usr/bin/env bash
# tests/fm-claude-account-fakes.sh - shared fakes for the Claude account
# switching suites: a file-backed `security` Keychain stub, a `quota-axi`
# tripwire that proves selection never makes a live call with a slot's token
# (the misattribution hazard the recorder/selection redesign removed), and a
# writer for a slot's recorded usage reading.
#
# fm_claude_account_fake_security <fakebin> <store-dir>
# Drops a `security` shim at <fakebin>/security backed by one file per
# "<service>.<account>" under <store-dir>. Supports exactly the
# `security -i` stdin add-generic-password/-U/-A/-w<value> line,
# find-generic-password/-w(bare), and delete-generic-password shapes
# bin/fm-claude-account.sh uses; an absent item exits 44 like the real tool's
# "item not found". Every invocation's argv is appended to <store-dir>/argv.log
# so a test can prove no secret ever crossed a process argument list.
fm_claude_account_fake_security() {
  local fakebin=$1 store=$2
  mkdir -p "$store"
  cat > "$fakebin/security" <<SH
#!/usr/bin/env bash
set -u
store="$store"
SH
  cat >> "$fakebin/security" <<'SH'
mkdir -p "$store"
printf '%s\n' "$*" >> "$store/argv.log"
if [ "${1:-}" = -i ]; then
  IFS= read -r line || exit 1
  eval "set -- $line"
fi
cmd=${1:-}
shift || true
service=""
account=""
password=""
have_password_value=0
print_password=0
while [ $# -gt 0 ]; do
  case "$1" in
    -s) service=$2; shift 2 ;;
    -a) account=$2; shift 2 ;;
    -w)
      if [ "$cmd" = add-generic-password ]; then
        password=$2
        have_password_value=1
        shift 2
      else
        print_password=1
        shift
      fi
      ;;
    -U | -A) shift ;;
    *) shift ;;
  esac
done
file="$store/$service.$account"
case "$cmd" in
  add-generic-password)
    [ -n "$service" ] && [ "$have_password_value" = 1 ] || exit 1
    printf '%s' "$password" > "$file"
    exit 0
    ;;
  find-generic-password)
    [ -f "$file" ] || exit 44
    [ "$print_password" = 1 ] && cat "$file"
    exit 0
    ;;
  delete-generic-password)
    rm -f "$file"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/security"
}

# fm_claude_account_fake_quota_axi_forbidden <fakebin> <call-log>
# Drops a `quota-axi` shim that only ever appends its invocation (argv plus
# the CLAUDE_CODE_OAUTH_TOKEN it was handed, if any) to <call-log> and exits
# 1. Selection and the usage recorder never call quota-axi with a slot's
# token (that live call was the misattribution hazard: a non-definitive env
# failure made quota-axi fall through to the ambient Keychain login and
# credit its reading to the wrong account), so a passing test asserts
# <call-log> stays absent or empty.
fm_claude_account_fake_quota_axi_forbidden() {
  local fakebin=$1 log=$2
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
set -u
log="$log"
SH
  cat >> "$fakebin/quota-axi" <<'SH'
{
  printf 'argv: %s\n' "$*"
  printf 'token: %s\n' "${CLAUDE_CODE_OAUTH_TOKEN:-}"
} >> "$log"
exit 1
SH
  chmod +x "$fakebin/quota-axi"
}

# fm_claude_account_usage_reading <state-dir> <slot> <five-hour-used%> <seven-day-used%> [<five-hour-resets-in-seconds>] [<seven-day-resets-in-seconds>]
# Writes a slot's recorded usage reading file directly, in the schema
# bin/fm-claude-usage-record.sh produces, for a test to seed without running
# the recorder. The two "resets-in-seconds" offsets default to comfortably in
# the future (18000s / 5h); pass a negative offset to simulate an already-past
# reset.
fm_claude_account_usage_reading() {
  local state_dir=$1 slot=$2 five_used=$3 seven_used=$4 five_offset=${5:-18000} seven_offset=${6:-604800}
  local now five_resets seven_resets
  mkdir -p "$state_dir"
  now=$(date +%s)
  five_resets=$((now + five_offset))
  seven_resets=$((now + seven_offset))
  printf '{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s},"observed_at":%s}\n' \
    "$five_used" "$five_resets" "$seven_used" "$seven_resets" "$now" \
    > "$state_dir/.claude-account-usage-$slot"
}
