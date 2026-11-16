#!/usr/bin/env bash
# End-to-end smoke test for the server stack.
# Sends synthetic OTLP metrics as fake Devices and asserts on what Prometheus stores.
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT=claude-otel-smoke
COMPOSE=(docker compose -p "$PROJECT" -f compose.yaml -f tests/compose.smoke.yaml)
TELEMETRYGEN_IMAGE=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.130.0
PROM_URL=http://127.0.0.1:29090
GRAFANA_URL=http://127.0.0.1:23000
DASHBOARD_UID=claude-code-usage
# Throwaway token so the tests never need the real secret.
OTEL_AUTH_TOKEN=$(openssl rand -hex 32)
export OTEL_AUTH_TOKEN
# Test Company Account allowlist; the real one lives only in the server's .env.
export COMPANY_ACCOUNTS=company-one@example.com,company-two@example.org
GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 16)
export GRAFANA_ADMIN_PASSWORD
failures=0

cleanup() { "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

# send_metric DEVICE_ID EMAIL [TOKEN]
# Sends one cumulative Sum data point, with the shared token unless TOKEN is given
# ("" sends no token). device.id/host.name are resource attributes and user.email is
# a data point attribute, matching what Claude Code sends.
send_metric() {
  local device=$1 email=$2 token=${3-$OTEL_AUTH_TOKEN}
  local args=(metrics --otlp-endpoint otel-collector:4317 --otlp-insecure
    --metric-type Sum --metrics 1
    --otlp-attributes "device.id=\"$device\""
    --otlp-attributes "host.name=\"$device-host\"")
  if [[ -n $email ]]; then args+=(--telemetry-attributes "user.email=\"$email\""); fi
  if [[ -n $token ]]; then args+=(--otlp-header "Authorization=\"Bearer $token\""); fi
  docker run --rm --network "${PROJECT}_default" "$TELEMETRYGEN_IMAGE" "${args[@]}" >/dev/null 2>&1
}

series_count() {
  curl -fsG "$PROM_URL/api/v1/query" --data-urlencode "query=count($1)" |
    jq -r '.data.result[0].value[1] // "0"'
}

# wait_for_series SELECTOR: poll until Prometheus has it, up to 30s.
wait_for_series() {
  for _ in $(seq 30); do
    [[ $(series_count "$1") != 0 ]] && return 0
    sleep 1
  done
  return 1
}

# http_status URL [curl args...]: prints the HTTP status code of a GET.
http_status() {
  local url=$1
  shift
  curl -s -o /dev/null -w '%{http_code}' "$@" "$url"
}

grafana_admin() { http_status "$1" -u "admin:$GRAFANA_ADMIN_PASSWORD"; }

# panel_query TITLE REFID: a dashboard panel's PromQL with every filter set to All and a
# 1h range, so panels can be checked against known data.
# shellcheck disable=SC2016 # $device etc. are literal Grafana variables, not shell expansions
panel_query() {
  jq -r --arg title "$1" --arg ref "$2" \
    '.panels[] | select(.title == $title) | .targets[] | select(.refId == $ref) | .expr' \
    grafana/dashboards/claude-code-usage.json |
    sed -e 's/\$device/.*/g' -e 's/\$account/.*/g' -e 's/\$__range/1h/g'
}

# query_values QUERY: one "user_email value" line per result (just the value if no email).
query_values() {
  curl -sG "$PROM_URL/api/v1/query" --data-urlencode "query=$1" |
    jq -r '.data.result[]? | [(.metric.user_email // empty), .value[1]] | join(" ")' 2>/dev/null | sort || true
}

# query_rows QUERY [TIME]: one "name user_email value" line per result, evaluated at
# TIME (unix seconds, default now). The name is host_name, or device_label for the charts
# that show "<host_name> · <serial>". A missing name prints as an empty first field.
query_rows() {
  local args=(--data-urlencode "query=$1")
  if [[ -n ${2:-} ]]; then args+=(--data-urlencode "time=$2"); fi
  curl -sG "$PROM_URL/api/v1/query" "${args[@]}" |
    jq -r '.data.result[]? | [(.metric.host_name // .metric.device_label // ""), (.metric.user_email // ""), .value[1]] | join(" ")' 2>/dev/null | sort || true
}

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; failures=$((failures + 1)); }

echo "Starting stack..."
if ! output=$("${COMPOSE[@]}" up -d --quiet-pull 2>&1); then
  echo "$output"
  exit 1
fi
for _ in $(seq 60); do
  curl -fs "$PROM_URL/-/ready" >/dev/null 2>&1 && curl -fs "$GRAFANA_URL/api/health" >/dev/null 2>&1 && break
  sleep 1
done

echo "Sending metrics..."
# The Collector can take a moment to accept connections, so retry the first send.
for _ in $(seq 20); do
  send_metric SMOKE-PERSONAL someone@gmail.com && break
  sleep 1
done
send_metric SMOKE-LOOKALIKE company-one@example.com.evil.io
send_metric SMOKE-NO-EMAIL ""
# Rejected sends exit non-zero, which is expected here.
send_metric SMOKE-NO-TOKEN company-one@example.com "" || true
send_metric SMOKE-WRONG-TOKEN company-one@example.com "$(openssl rand -hex 32)" || true
# Company Account Devices go last: once they are stored, everything sent before
# them has been through the Collector, so an absent Device was really dropped.
send_metric SMOKE-COMPANY-ONE company-one@example.com
send_metric SMOKE-COMPANY-TWO company-two@example.org

# Real-shaped Claude Code series for dashboard checks, written straight to Prometheus.
"${COMPOSE[@]}" run --rm --no-deps -v "$PWD/tests/fixtures:/fixtures:ro" --entrypoint promtool \
  prometheus push metrics http://prometheus:9090/api/v1/write \
  /fixtures/account-switch.prom /fixtures/desktop-app.prom /fixtures/models-and-cache.prom \
  /fixtures/same-hostname.prom /fixtures/unowned-device.prom >/dev/null 2>&1

echo "Assertions:"
for device in SMOKE-COMPANY-ONE SMOKE-COMPANY-TWO; do
  if wait_for_series "{device_id=\"$device\"}"; then
    pass "Company Account Device $device is stored"
  else
    fail "Company Account Device $device is stored"
  fi
done
if [[ $(series_count '{device_id="SMOKE-COMPANY-ONE", host_name="SMOKE-COMPANY-ONE-host", user_email="company-one@example.com"}') != 0 ]]; then
  pass "Device carries device_id, host_name and user_email labels"
else
  fail "Device carries device_id, host_name and user_email labels"
fi

# Concurrent Claude Code sessions on one Device share their resource attributes, so a
# target_info series would get interleaved samples, and Prometheus drops the whole batch.
if [[ $(series_count 'target_info') == 0 ]]; then
  pass "No target_info series is written (it made concurrent sessions drop batches)"
else
  fail "No target_info series is written (it made concurrent sessions drop batches)"
fi
for device in SMOKE-PERSONAL SMOKE-LOOKALIKE SMOKE-NO-EMAIL; do
  if [[ $(series_count "{device_id=\"$device\"}") == 0 ]]; then
    pass "Personal Account Device $device is dropped"
  else
    fail "Personal Account Device $device is dropped"
  fi
done
for device in SMOKE-NO-TOKEN SMOKE-WRONG-TOKEN; do
  if [[ $(series_count "{device_id=\"$device\"}") == 0 ]]; then
    pass "Device $device without the shared token is rejected"
  else
    fail "Device $device without the shared token is rejected"
  fi
done

if [[ $(grafana_admin "$GRAFANA_URL/api/datasources/uid/prometheus") == 200 ]]; then
  pass "Grafana has the Prometheus datasource"
else
  fail "Grafana has the Prometheus datasource"
fi
# Through Grafana's datasource proxy, so this proves Grafana can reach Prometheus.
if curl -fsG -u "admin:$GRAFANA_ADMIN_PASSWORD" \
  "$GRAFANA_URL/api/datasources/proxy/uid/prometheus/api/v1/query" \
  --data-urlencode 'query=count({device_id="SMOKE-COMPANY-ONE"})' 2>/dev/null |
  jq -e '(.data.result[0].value[1] // "0") != "0"' >/dev/null 2>&1; then
  pass "Grafana reads Company Account data from Prometheus"
else
  fail "Grafana reads Company Account data from Prometheus"
fi
if [[ $(grafana_admin "$GRAFANA_URL/api/dashboards/uid/$DASHBOARD_UID") == 200 ]]; then
  pass "Grafana loads the usage dashboard"
else
  fail "Grafana loads the usage dashboard"
fi
for path in "api/dashboards/uid/$DASHBOARD_UID" api/search api/datasources; do
  status=$(http_status "$GRAFANA_URL/$path")
  if [[ $status == 401 ]]; then
    pass "Grafana refuses anonymous access to /$path"
  else
    fail "Grafana refuses anonymous access to /$path (got $status)"
  fi
done

sessions_total=$(query_values "$(panel_query 'Sessions used' A)")
if [[ $sessions_total == 3 ]]; then
  pass "Sessions used counts only sessions with model requests"
else
  fail "Sessions used counts only sessions with model requests (got '${sessions_total}', want 3)"
fi
sessions_per_account=$(query_rows "$(panel_query 'Usage per Device' D)" | tr '\n' ';')
# fixture-host appears twice for company-two: FIXTURE-DEVICE and TWIN-DEVICE share the name.
if [[ $sessions_per_account == "Desktop app (cyberminds) company-one@example.com 1;fixture-host company-one@example.com 2;fixture-host company-two@example.org 1;fixture-host company-two@example.org 1;" ]]; then
  pass "Sessions used per account follows /login account switches"
else
  fail "Sessions used per account follows /login account switches (got '${sessions_per_account}')"
fi

# Desktop app usage has no serial number or hostname; it is named after the Mac's user.
desktop_cost=$(query_rows "$(panel_query 'Usage per Device' A)")
if grep -Fxq "Desktop app (cyberminds) company-one@example.com 2.5" <<<"$desktop_cost"; then
  pass "Usage per Device names Desktop app usage after the Mac's user"
else
  fail "Usage per Device names Desktop app usage after the Mac's user (got '${desktop_cost//$'\n'/;}')"
fi
# Every per-Device query, at now (summary ranges) and an hour ago (daily trends look
# forward a day), must name each row: no "–" Device. Prometheus's own clock, with
# fractions, so samples pushed a moment ago are not in the future.
now=$(curl -sG "$PROM_URL/api/v1/query" --data-urlencode 'query=time()' | jq -r '.data.result[1]')
hour_ago=$(jq -n "$now - 3600")
while IFS=$'\t' read -r title ref; do
  rows=$( (query_rows "$(panel_query "$title" "$ref")" "$now"; query_rows "$(panel_query "$title" "$ref")" "$hour_ago"))
  if grep -q '^ ' <<<"$rows"; then
    fail "'$title' $ref names every Device (got a nameless row)"
  else
    pass "'$title' $ref names every Device"
  fi
done < <(jq -r '.panels[] | .title as $t | .targets[]? | select(.expr | test("host_name")) | [$t, .refId] | @tsv' \
  grafana/dashboards/claude-code-usage.json)
desktop_daily=$(query_rows "$(panel_query "Estimated cost (API-equivalent) per Device per day" A)" "$hour_ago")
if grep -q '^Desktop app (cyberminds) ' <<<"$desktop_daily"; then
  pass "Daily cost per Device includes Desktop app usage"
else
  fail "Daily cost per Device includes Desktop app usage (got '${desktop_daily//$'\n'/;}')"
fi
active_devices=$(query_values "$(panel_query 'Active Devices' A)")
if [[ $active_devices == 1 ]]; then
  pass "Active Devices counts serial numbers only"
else
  fail "Active Devices counts serial numbers only (got '${active_devices}', want 1)"
fi

# query_series QUERY LABEL: one "<label value> <value>" line per result, in Prometheus's order.
query_series() {
  curl -sG "$PROM_URL/api/v1/query" --data-urlencode "query=$1" |
    jq -r --arg label "$2" '.data.result[]? | [(.metric[$label] // ""), .value[1]] | join(" ")' 2>/dev/null || true
}
by_model=$(query_series "$(panel_query 'Estimated cost by model' A)" model | sort | tr '\n' ';')
if [[ $by_model == "claude-opus-5-5 4.61;claude-sonnet-5-5 0.05;" ]]; then
  pass "Estimated cost by model has one slice per model"
else
  fail "Estimated cost by model has one slice per model (got '${by_model}')"
fi
top_devices=$(query_series "$(panel_query 'Top Devices by estimated cost' A)" device_label | tr '\n' ';')
if [[ $top_devices == "Desktop app (cyberminds) 2.5;fixture-host · FIXTURE-DEVICE 1.86;fixture-host · TWIN-DEVICE 0.3;" ]]; then
  pass "Top Devices by estimated cost is ordered by cost, keeps same-named Devices apart and names Desktop app usage"
else
  fail "Top Devices by estimated cost is ordered by cost, keeps same-named Devices apart and names Desktop app usage (got '${top_devices}')"
fi
# The daily chart looks a day forward, so it is checked from an hour ago.
daily_twins=$(query_rows "$(panel_query "Estimated cost (API-equivalent) per Device per day" A)" "$hour_ago" |
  grep -c '^fixture-host · ' || true)
if [[ $daily_twins == 2 ]]; then
  pass "Daily cost per Device keeps same-named Devices apart, by serial"
else
  fail "Daily cost per Device keeps same-named Devices apart, by serial (got $daily_twins fixture-host rows, want 2)"
fi
# Device owners come from tests/fixtures/owners (Prometheus recording rules).
# owner_rows QUERY: one "device_id|host_name|user_email|owner|owner_email" line per result.
owner_rows() {
  curl -sG "$PROM_URL/api/v1/query" --data-urlencode "query=$1" |
    jq -r '.data.result[]? | .metric | [(.device_id // ""), (.host_name // ""), (.user_email // ""), (.owner // ""), (.owner_email // "")] | join("|")' 2>/dev/null | sort || true
}
if wait_for_series cmw_device_owner_info; then
  pass "Prometheus loads the Device owner rules"
else
  fail "Prometheus loads the Device owner rules"
fi
while read -r ref; do
  rows=$(owner_rows "$(panel_query 'Usage per Device' "$ref")")
  problems=""
  fixture=$(grep '^FIXTURE-DEVICE|' <<<"$rows" || true)
  # FIXTURE-DEVICE has cost, tokens and sessions (A-D) but no lines, commits or active time.
  if [[ $ref =~ ^[ABCD]$ && -z $fixture ]]; then
    problems+="no FIXTURE-DEVICE rows; "
  elif [[ -n $fixture ]] && grep -qv '|Fixture Owner|fixture.owner@example.com$' <<<"$fixture"; then
    problems+="FIXTURE-DEVICE rows lack its owner; "
  fi
  if [[ -n $(cut -d'|' -f1-3 <<<"$rows" | sort | uniq -d) ]]; then
    problems+="a Device and Company Account appear twice; "
  fi
  if grep -q '^GHOST-DEVICE|' <<<"$rows"; then problems+="an owner without usage added a row; "; fi
  if [[ -n $(awk -F'|' '$1 == "" && $4 != ""' <<<"$rows") ]]; then problems+="a row without a serial got an owner; "; fi
  if [[ -z $problems ]]; then
    pass "Usage per Device $ref shows each Device's owner, once per row"
  else
    fail "Usage per Device $ref shows each Device's owner, once per row ($problems got '${rows//$'\n'/;}')"
  fi
done < <(jq -r '.panels[] | select(.title == "Usage per Device") | .targets[].refId' grafana/dashboards/claude-code-usage.json)
# Every query must pick the same one of the two owners, or the table's merge would split the row.
twin=$(while read -r ref; do owner_rows "$(panel_query 'Usage per Device' "$ref")" | grep '^TWIN-DEVICE|' || true; done < <(
  jq -r '.panels[] | select(.title == "Usage per Device") | .targets[].refId' grafana/dashboards/claude-code-usage.json) | sort -u)
if [[ $twin == "TWIN-DEVICE|fixture-host|company-two@example.org|Twin Owner A|twin.a@example.com" ||
  $twin == "TWIN-DEVICE|fixture-host|company-two@example.org|Twin Owner B|twin.b@example.com" ]]; then
  pass "A serial listed twice in the owner file still gives one row with one owner"
else
  fail "A serial listed twice in the owner file still gives one row with one owner (got '${twin//$'\n'/;}')"
fi
unowned=$(query_rows "$(panel_query 'Usage per Device' G)")
unowned_owner=$(owner_rows "$(panel_query 'Usage per Device' G)" | grep '^UNOWNED-DEVICE|' || true)
if grep -Fxq "unowned-host company-one@example.com 1" <<<"$unowned" &&
  [[ $unowned_owner == "UNOWNED-DEVICE|unowned-host|company-one@example.com||" ]]; then
  pass "A Device with no owner entry still shows, with the owner empty"
else
  fail "A Device with no owner entry still shows, with the owner empty (got '${unowned//$'\n'/;}' / '${unowned_owner}')"
fi
cache_hit=$(query_values "$(panel_query 'Cache hit rate' A)")
if [[ $cache_hit == 0.75 ]]; then
  pass "Cache hit rate is cache reads over all input tokens"
else
  fail "Cache hit rate is cache reads over all input tokens (got '${cache_hit}', want 0.75)"
fi
silent=$(query_values "$(panel_query 'Active Devices' B)")
if [[ $silent == 1 ]]; then
  pass "Active Devices counts a Device with sessions but no active time as silent"
else
  fail "Active Devices counts a Device with sessions but no active time as silent (got '${silent}', want 1)"
fi
# Every query on the dashboard, including the change against the previous period, is valid
# PromQL that Prometheus runs without an error.
bad_queries=""
while IFS=$'\t' read -r title ref; do
  status=$(curl -sG "$PROM_URL/api/v1/query" --data-urlencode "query=$(panel_query "$title" "$ref")" | jq -r .status 2>/dev/null)
  [[ $status == success ]] || bad_queries+="'$title' $ref; "
done < <(jq -r '.panels[] | .title as $t | .targets[]? | [$t, .refId] | @tsv' grafana/dashboards/claude-code-usage.json)
if [[ -z $bad_queries ]]; then
  pass "Every dashboard query runs"
else
  fail "Every dashboard query runs (failed: $bad_queries)"
fi

if ((failures > 0)); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "All smoke assertions passed"
