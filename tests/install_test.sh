#!/usr/bin/env bash
# Tests for install.sh (Device setup script).
# TEST_SETTINGS_FILE, TEST_SERIAL and TEST_HOSTNAME point the script at a temp dir and fake
# Device identity, so no root is needed and the real managed-settings file is never touched.
# Must stay bash 3.2 compatible: /usr/bin/env bash is /bin/bash 3.2 on stock macOS.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=$PWD/install.sh
REAL_SETTINGS="/Library/Application Support/ClaudeCode/managed-settings.json"
TOKEN=s3cr3t-T0ken_abc.123
SERIAL=C02TEST123
HOST=dev-mac-01
failures=0

WORK=$(mktemp -d)
LISTENER_PID=
cleanup() {
  if [[ -n $LISTENER_PID ]]; then kill "$LISTENER_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; failures=$((failures + 1)); }
check() { # check DESCRIPTION COMMAND...
  local desc=$1
  shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

# Each case gets a fresh settings path inside a directory that does not exist yet.
new_case() {
  CASE_DIR=$WORK/case$((++case_no))/ClaudeCode
  SETTINGS=$CASE_DIR/managed-settings.json
}
case_no=0

# run_install ARGS...: sets OUT (stdout+stderr) and STATUS; never aborts the test run.
run_install() {
  STATUS=0
  OUT=$(env TEST_SETTINGS_FILE="$SETTINGS" TEST_SERIAL="$SERIAL" TEST_HOSTNAME="$HOST" \
    "$INSTALL" "$@" 2>&1) || STATUS=$?
}

expected_env() { # expected_env ENDPOINT
  jq -n --arg endpoint "$1" --arg token "$TOKEN" --arg serial "$SERIAL" --arg host "$HOST" '{
    CLAUDE_CODE_ENABLE_TELEMETRY: "1",
    OTEL_METRICS_EXPORTER: "otlp",
    OTEL_EXPORTER_OTLP_PROTOCOL: "grpc",
    OTEL_EXPORTER_OTLP_ENDPOINT: $endpoint,
    OTEL_EXPORTER_OTLP_HEADERS: ("Authorization=Bearer " + $token),
    OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE: "cumulative",
    OTEL_LOGS_EXPORTER: "none",
    OTEL_RESOURCE_ATTRIBUTES: ("device.id=" + $serial + ",host.name=" + $host)
  }'
}

env_matches() { # env_matches ENDPOINT
  [[ $(jq -S .env "$SETTINGS" 2>/dev/null) == "$(expected_env "$1" | jq -S .)" ]]
}
only_env_key() { [[ $(jq -c 'keys' "$SETTINGS" 2>/dev/null) == '["env"]' ]]; }
succeeded() { [[ $STATUS == 0 ]]; }
failed() { [[ $STATUS != 0 ]]; }
output_has() { [[ $OUT == *"$1"* ]]; }
output_lacks() { [[ $OUT != *"$1"* ]]; }
nothing_written() { [[ ! -e $CASE_DIR ]]; }
file_mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1" 2>/dev/null || true; }
# OTEL_LOG_* (OTEL_LOG_USER_PROMPTS, OTEL_LOG_TOOL_DETAILS, ...) turn on content logging.
no_logging_options() {
  [[ $(jq '[.env | keys[] | select(test("^OTEL_LOG_"))] | length' "$SETTINGS" 2>/dev/null) == 0 ]] &&
    [[ $(jq -r .env.OTEL_LOGS_EXPORTER "$SETTINGS" 2>/dev/null) == none ]]
}
no_temp_files_left() { [[ $(find "$CASE_DIR" -type f 2>/dev/null | wc -l | tr -d ' ') == 1 ]]; }

echo "Install with a domain:"
new_case
run_install --token "$TOKEN" --domain example.com
check "succeeds" succeeded
check "file is JSON with only an env key" only_env_key
check "env holds exactly the telemetry settings" env_matches https://otel.example.com:443
check "no prompt/response/tool-detail logging is enabled" no_logging_options
check "creates the missing settings directory" test -d "$CASE_DIR"
check "file mode is 0644" test "$(file_mode "$SETTINGS")" = 644
check "leaves no temp files behind" no_temp_files_left

echo "Install with an explicit endpoint:"
new_case
run_install --token "$TOKEN" --endpoint http://localhost:4317
check "succeeds" succeeded
check "uses the endpoint as given" env_matches http://localhost:4317

echo "Re-running:"
new_case
run_install --token "$TOKEN" --domain example.com
cp "$SETTINGS" "$WORK/first.json" 2>/dev/null || true
run_install --token "$TOKEN" --domain example.com
check "second run succeeds" succeeded
check "second run writes a byte-identical file" cmp -s "$SETTINGS" "$WORK/first.json"
run_install --token "$TOKEN" --endpoint http://localhost:4317
check "a later run replaces the old settings" env_matches http://localhost:4317

echo "Bad input writes nothing:"
new_case
run_install --domain example.com
check "no token fails" failed
check "no token says the token is required" output_has "--token is required"
check "no token writes nothing" nothing_written
run_install --token "$TOKEN"
check "no domain or endpoint fails" failed
check "no domain or endpoint writes nothing" nothing_written
run_install --token "$TOKEN" --domain example.com --endpoint http://localhost:4317
check "both domain and endpoint fails" failed
run_install --token 'bad"token,x=y' --domain example.com
check "token with unsafe characters fails" failed
check "token with unsafe characters writes nothing" nothing_written
run_install --token "$TOKEN" --endpoint 'localhost:4317'
check "endpoint without scheme and port fails" failed
run_install --token "$TOKEN" --bogus
check "unknown flag fails" failed
check "unknown flag prints usage" output_has "Usage:"
check "unknown flag writes nothing" nothing_written

echo "Root is required without the test override:"
if [[ $(id -u) == 0 ]]; then
  echo "  skip running as root, would touch the real file"
else
  real_existed=no
  [[ -e $REAL_SETTINGS ]] && real_existed=yes
  STATUS=0
  OUT=$(env -u TEST_SETTINGS_FILE TEST_SERIAL="$SERIAL" TEST_HOSTNAME="$HOST" \
    "$INSTALL" --token "$TOKEN" --domain example.com 2>&1) || STATUS=$?
  check "non-root install fails" failed
  check "non-root install says it needs root" output_has "must be run as root"
  if [[ $real_existed == no ]]; then
    check "non-root install writes nothing" test ! -e "$REAL_SETTINGS"
  fi
  STATUS=0
  OUT=$(env -u TEST_SETTINGS_FILE "$INSTALL" --uninstall 2>&1) || STATUS=$?
  check "non-root uninstall fails" failed
  check "non-root uninstall says it needs root" output_has "must be run as root"
fi

echo "Device identity detection:"
if [[ $(uname) == Darwin ]]; then
  new_case
  STATUS=0
  OUT=$(env TEST_SETTINGS_FILE="$SETTINGS" "$INSTALL" --token "$TOKEN" --domain example.com 2>&1) || STATUS=$?
  check "succeeds with detected serial and hostname" succeeded
  attrs=$(jq -r .env.OTEL_RESOURCE_ATTRIBUTES "$SETTINGS" 2>/dev/null || true)
  check "device.id is the detected serial number" \
    test "$attrs" = "device.id=$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/"IOPlatformSerialNumber"/ {print $4}'),host.name=$(scutil --get LocalHostName)"
else
  echo "  skip not macOS"
fi

echo "Check:"
new_case
run_install --check
check "check with nothing installed fails" failed
check "check with nothing installed says so" output_has "not installed"

# A local listener stands in for a reachable Collector.
port=$((40000 + RANDOM % 20000))
nc -lk 127.0.0.1 "$port" >/dev/null 2>&1 &
LISTENER_PID=$!
sleep 1
run_install --token "$TOKEN" --endpoint "http://127.0.0.1:$port"
run_install --check
check "check succeeds when the endpoint is reachable" succeeded
check "check prints the current settings" output_has "\"OTEL_EXPORTER_OTLP_ENDPOINT\": \"http://127.0.0.1:$port\""
check "check masks the token" output_lacks "$TOKEN"
check "check shows the token is masked" output_has "Authorization=Bearer ****"
check "check reports the endpoint as reachable" output_has "127.0.0.1:$port is reachable"
kill "$LISTENER_PID" 2>/dev/null || true
wait "$LISTENER_PID" 2>/dev/null || true
LISTENER_PID=
run_install --check
check "check fails when the endpoint is unreachable" failed
check "check reports the endpoint as unreachable" output_has "127.0.0.1:$port is NOT reachable"

echo "Uninstall:"
new_case
run_install --token "$TOKEN" --domain example.com
run_install --uninstall
check "uninstall succeeds" succeeded
check "uninstall removes the file" test ! -e "$SETTINGS"
run_install --uninstall
check "uninstall succeeds when already gone" succeeded

if ((failures > 0)); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "All install assertions passed"
