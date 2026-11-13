#!/usr/bin/env bash
# Front door test for servers that already run nginx: renders the nginx site with
# nginx/render.sh, runs it in front of the stack with a self-signed certificate, and checks
# that OTLP over TLS and Grafana over HTTPS work through it, and that the stack itself only
# listens on localhost.
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT=claude-otel-frontdoor-nginx
COMPOSE=(docker compose -p "$PROJECT" -f compose.yaml -f compose.nginx.yaml -f tests/compose.frontdoor-nginx.yaml)
TELEMETRYGEN_IMAGE=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.130.0
PORT=28444
export DOMAIN=localtest.me
# Off the defaults so the test doesn't collide with a stack already running on this machine.
export COLLECTOR_PORT=38317 GRAFANA_PORT=38300
OTEL_AUTH_TOKEN=$(openssl rand -hex 32)
GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 16)
export OTEL_AUTH_TOKEN GRAFANA_ADMIN_PASSWORD
export COMPANY_ACCOUNTS=company-one@example.com
mkdir -p .scratch
NGINX_TEST_DIR=$(mktemp -d "$PWD/.scratch/frontdoor-nginx.XXXXXX")
export NGINX_TEST_DIR
failures=0

cleanup() {
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$NGINX_TEST_DIR"
}
trap cleanup EXIT

# The test nginx runs on the compose network, so it reaches the services by name. On the
# server, nginx reaches the same services through the localhost ports.
mkdir -p "$NGINX_TEST_DIR/conf.d" "$NGINX_TEST_DIR/certs"
nginx/render.sh "$DOMAIN" otel-collector:4317 grafana:3000 /certs >"$NGINX_TEST_DIR/conf.d/claude-otel.conf"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$DOMAIN" \
  -addext "subjectAltName=DNS:otel.$DOMAIN,DNS:grafana.$DOMAIN" \
  -keyout "$NGINX_TEST_DIR/certs/privkey.pem" -out "$NGINX_TEST_DIR/certs/fullchain.pem" >/dev/null 2>&1

# https_get HOST PATH [curl args...]: GET through nginx; -k because the certificate is self-signed.
https_get() {
  local host=$1 path=$2
  shift 2
  curl -sk --resolve "$host.$DOMAIN:$PORT:127.0.0.1" "$@" "https://$host.$DOMAIN:$PORT$path"
}

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; failures=$((failures + 1)); }

echo "Starting the stack behind nginx..."
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
    --otlp-attributes 'device.id="NGINX-DEVICE"' --otlp-attributes 'host.name="nginx-host"' \
    --telemetry-attributes "user.email=\"$COMPANY_ACCOUNTS\"" >/dev/null 2>&1 && break
  sleep 1
done

echo "Assertions:"
if [[ $(https_get grafana /login -o /dev/null -w '%{http_code}') == 200 ]]; then
  pass "Grafana login page loads over HTTPS"
else
  fail "Grafana login page loads over HTTPS"
fi
if [[ $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$GRAFANA_PORT/api/health") == 200 ]]; then
  pass "Grafana answers on its localhost port for the server's nginx"
else
  fail "Grafana answers on its localhost port for the server's nginx"
fi
stored=0
for _ in $(seq 30); do
  if https_get grafana /api/datasources/proxy/uid/prometheus/api/v1/query -G \
    -u "admin:$GRAFANA_ADMIN_PASSWORD" --data-urlencode 'query=count({device_id="NGINX-DEVICE"})' |
    jq -e '(.data.result[0].value[1] // "0") != "0"' >/dev/null 2>&1; then
    stored=1
    break
  fi
  sleep 1
done
if ((stored)); then
  pass "Metric sent over TLS to otel.$DOMAIN through nginx is stored"
else
  fail "Metric sent over TLS to otel.$DOMAIN through nginx is stored"
fi
if [[ $(https_get grafana /api/dashboards/uid/claude-code-usage -o /dev/null -w '%{http_code}') == 401 ]]; then
  pass "Grafana through nginx refuses anonymous access"
else
  fail "Grafana through nginx refuses anonymous access"
fi
exposed=$("${COMPOSE[@]}" ps --format json |
  jq -r 'select(.Service != "nginx") | .Publishers[]? | select(.PublishedPort > 0 and .URL != "127.0.0.1") | "\(.URL):\(.PublishedPort)"')
if [[ -z $exposed ]]; then
  pass "The stack publishes ports on localhost only"
else
  fail "The stack publishes ports on localhost only (also: $exposed)"
fi

if ((failures > 0)); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "All nginx front door assertions passed"
