#!/usr/bin/env bash
# Front door test: runs the production setup with Caddy's internal CA and checks that
# OTLP over TLS and Grafana over HTTPS work through Caddy, and that nothing else is exposed.
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT=claude-otel-frontdoor
COMPOSE=(docker compose -p "$PROJECT" -f compose.yaml -f compose.prod.yaml -f tests/compose.frontdoor.yaml)
TELEMETRYGEN_IMAGE=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.130.0
PORT=28443
export DOMAIN=localtest.me
OTEL_AUTH_TOKEN=$(openssl rand -hex 32)
GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 16)
export OTEL_AUTH_TOKEN GRAFANA_ADMIN_PASSWORD
export COMPANY_ACCOUNTS=company-one@example.com
failures=0

cleanup() { "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

# https_get HOST PATH [curl args...]: GET through Caddy; -k because the CA is Caddy's own.
https_get() {
  local host=$1 path=$2
  shift 2
  curl -sk --resolve "$host.$DOMAIN:$PORT:127.0.0.1" "$@" "https://$host.$DOMAIN:$PORT$path"
}

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; failures=$((failures + 1)); }

echo "Starting production stack..."
if ! output=$("${COMPOSE[@]}" up -d --quiet-pull 2>&1); then
  echo "$output"
  exit 1
fi
for _ in $(seq 60); do
  https_get grafana /api/health -f >/dev/null 2>&1 && break
  sleep 1
done

echo "Sending a metric over TLS..."
for _ in $(seq 20); do
  docker run --rm --add-host "otel.$DOMAIN:host-gateway" "$TELEMETRYGEN_IMAGE" metrics \
    --otlp-endpoint "otel.$DOMAIN:$PORT" --otlp-insecure-skip-verify \
    --otlp-header "Authorization=\"Bearer $OTEL_AUTH_TOKEN\"" \
    --metric-type Sum --metrics 1 \
    --otlp-attributes 'device.id="FRONTDOOR-DEVICE"' --otlp-attributes 'host.name="frontdoor-host"' \
    --telemetry-attributes "user.email=\"$COMPANY_ACCOUNTS\"" >/dev/null 2>&1 && break
  sleep 1
done

echo "Assertions:"
if [[ $(https_get grafana /login -o /dev/null -w '%{http_code}') == 200 ]]; then
  pass "Grafana login page loads over HTTPS"
else
  fail "Grafana login page loads over HTTPS"
fi
stored=0
for _ in $(seq 30); do
  if https_get grafana /api/datasources/proxy/uid/prometheus/api/v1/query -G \
    -u "admin:$GRAFANA_ADMIN_PASSWORD" --data-urlencode 'query=count({device_id="FRONTDOOR-DEVICE"})' |
    jq -e '(.data.result[0].value[1] // "0") != "0"' >/dev/null 2>&1; then
    stored=1
    break
  fi
  sleep 1
done
if ((stored)); then
  pass "Metric sent over TLS to otel.$DOMAIN is stored"
else
  fail "Metric sent over TLS to otel.$DOMAIN is stored"
fi
published=$("${COMPOSE[@]}" ps --format json |
  jq -r 'select(.Service != "caddy" and any(.Publishers[]?; .PublishedPort > 0)) | .Service')
if [[ -z $published ]]; then
  pass "Only Caddy publishes host ports"
else
  fail "Only Caddy publishes host ports (also: $published)"
fi

if ((failures > 0)); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "All front door assertions passed"
