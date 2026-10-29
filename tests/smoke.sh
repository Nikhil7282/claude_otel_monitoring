#!/usr/bin/env bash
# End-to-end smoke test for the server stack.
# Sends synthetic OTLP metrics as fake Devices and asserts on what Prometheus stores.
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT=claude-otel-smoke
COMPOSE=(docker compose -p "$PROJECT" -f compose.yaml -f compose.test.yaml)
TELEMETRYGEN_IMAGE=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.120.0
PROM_URL=http://127.0.0.1:19090
failures=0

cleanup() { "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

# send_metric DEVICE_ID EMAIL [extra telemetrygen flags...]
# Sends one cumulative Sum data point. device.id/host.name are resource attributes and
# user.email is a data point attribute, matching what Claude Code sends.
send_metric() {
  local device=$1 email=$2
  shift 2
  local args=(metrics --otlp-endpoint otel-collector:4317 --otlp-insecure
    --metric-type Sum --metrics 1
    --otlp-attributes "device.id=\"$device\""
    --otlp-attributes "host.name=\"$device-host\"")
  if [[ -n $email ]]; then args+=(--telemetry-attributes "user.email=\"$email\""); fi
  docker run --rm --network "${PROJECT}_default" "$TELEMETRYGEN_IMAGE" "${args[@]}" "$@" >/dev/null 2>&1
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

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; failures=$((failures + 1)); }

echo "Starting stack..."
"${COMPOSE[@]}" up -d --quiet-pull >/dev/null 2>&1
for _ in $(seq 60); do
  curl -fs "$PROM_URL/-/ready" >/dev/null 2>&1 && break
  sleep 1
done

echo "Sending metrics..."
# The Collector can take a moment to accept connections, so retry the first send.
for _ in $(seq 20); do
  send_metric SMOKE-COMPANY-COM company-one@example.com && break
  sleep 1
done

echo "Assertions:"
if wait_for_series '{device_id="SMOKE-COMPANY-COM"}'; then
  pass "Company Account Device is stored"
else
  fail "Company Account Device is stored"
fi
if [[ $(series_count '{device_id="SMOKE-COMPANY-COM", host_name="SMOKE-COMPANY-COM-host", user_email="company-one@example.com"}') != 0 ]]; then
  pass "Device carries device_id, host_name and user_email labels"
else
  fail "Device carries device_id, host_name and user_email labels"
fi

if ((failures > 0)); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "All smoke assertions passed"
