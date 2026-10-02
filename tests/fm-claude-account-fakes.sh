#!/usr/bin/env bash
# tests/fm-claude-account-fakes.sh - shared fakes for the Claude account
# switching suites: a file-backed `security` Keychain stub and a
# `quota-axi` stub whose answer is keyed by the CLAUDE_CODE_OAUTH_TOKEN it
# was called with, so a test can assign each fake token a distinct
# remaining-allowance percentage.
#
# fm_claude_account_fake_security <fakebin> <store-dir>
# Drops a `security` shim at <fakebin>/security backed by one file per
# "<service>.<account>" under <store-dir>. Supports exactly the
# add-generic-password/-U/-A/-w<value>, find-generic-password/-w(bare), and
# delete-generic-password shapes bin/fm-claude-account.sh uses; an absent item
# exits 44 like the real tool's "item not found".
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

# fm_claude_account_fake_quota_axi <fakebin> <map-file>
# Drops a `quota-axi` shim that only understands
# `--provider claude --json --no-credential-refresh`. <map-file> holds
# "<token> <percent>" lines. A token with no matching line gets the default
# answer a real `claude setup-token` token gets: the usage endpoint refuses
# the inference-only bearer, so quota-axi (0.1.52 README, "inference opt-in")
# reports the provider as unavailable with no effectiveAvailability.
fm_claude_account_fake_quota_axi() {
  local fakebin=$1 map=$2
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
set -u
map="$map"
SH
  cat >> "$fakebin/quota-axi" <<'SH'
token="${CLAUDE_CODE_OAUTH_TOKEN:-}"
pct=$(awk -v t="$token" '$1 == t { print $2; exit }' "$map" 2>/dev/null)
if [ -z "$pct" ]; then
  cat <<JSON
{"providers":[{"provider":"claude","state":{"status":"unavailable","reason":"inference_opt_in_required"},"quotaSemantics":{}}]}
JSON
  exit 0
fi
cat <<JSON
{"providers":[{"provider":"claude","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","effectivePercentRemaining":$pct}]}}]}
JSON
SH
  chmod +x "$fakebin/quota-axi"
}
