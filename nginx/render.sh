#!/usr/bin/env bash
# Prints the nginx site for the monitoring stack, filled in from claude-otel.conf.template.
# Usage: nginx/render.sh DOMAIN COLLECTOR_UPSTREAM GRAFANA_UPSTREAM CERT_DIR
#   e.g. nginx/render.sh claude.example.com 127.0.0.1:14317 127.0.0.1:13000 \
#          /etc/letsencrypt/live/claude-otel
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 DOMAIN COLLECTOR_UPSTREAM GRAFANA_UPSTREAM CERT_DIR" >&2
  exit 2
fi
# The values go into sed replacements and nginx directives, so allow only plain characters.
for value in "$@"; do
  if [[ ! $value =~ ^[A-Za-z0-9./:_-]+$ ]]; then
    echo "unexpected characters in: $value" >&2
    exit 2
  fi
done

sed -e "s|{{DOMAIN}}|$1|g" -e "s|{{COLLECTOR_UPSTREAM}}|$2|g" \
  -e "s|{{GRAFANA_UPSTREAM}}|$3|g" -e "s|{{CERT_DIR}}|$4|g" \
  "$(dirname "$0")/claude-otel.conf.template"
