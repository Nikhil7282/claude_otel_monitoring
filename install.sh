#!/usr/bin/env bash
# Device setup: points Claude Code's OpenTelemetry metrics at the monitoring server.
# Writes Claude Code's managed-settings file, which developers cannot override.
set -euo pipefail

SETTINGS_FILE=${TEST_SETTINGS_FILE:-/Library/Application Support/ClaudeCode/managed-settings.json}

usage() {
  cat <<'EOF'
Usage:
  sudo ./install.sh --token TOKEN --domain DOMAIN     endpoint becomes https://otel.DOMAIN:443
  sudo ./install.sh --token TOKEN --endpoint URL      e.g. http://localhost:4317
  ./install.sh --check                                show settings (token masked), test endpoint
  sudo ./install.sh --uninstall                       remove the settings file
EOF
}

die() { echo "Error: $1" >&2; exit 1; }
usage_error() { echo "Error: $1" >&2; usage >&2; exit 2; }

require_root() {
  # The test override writes to a temp path, so root is not needed there.
  if [[ -z ${TEST_SETTINGS_FILE:-} && $(id -u) != 0 ]]; then
    die "must be run as root (use sudo)"
  fi
}

detect_serial() {
  if [[ -n ${TEST_SERIAL:-} ]]; then echo "$TEST_SERIAL"; return; fi
  ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/"IOPlatformSerialNumber"/ {print $4}'
}

detect_hostname() {
  if [[ -n ${TEST_HOSTNAME:-} ]]; then echo "$TEST_HOSTNAME"; return; fi
  scutil --get LocalHostName
}

# Values go into JSON strings and into comma/equals separated OTEL env values, so only
# allow characters that need no escaping in either place.
require_safe() { # require_safe NAME VALUE PATTERN
  [[ $2 =~ $3 ]] || die "$1 has unexpected characters: $2"
}

install_settings() {
  local token=$1 endpoint=$2 serial hostname dir tmp
  require_root
  serial=$(detect_serial) || die "could not read the hardware serial number"
  hostname=$(detect_hostname) || die "could not read LocalHostName"
  [[ -n $serial ]] || die "could not read the hardware serial number"
  [[ -n $hostname ]] || die "could not read LocalHostName"
  require_safe "serial number" "$serial" '^[A-Za-z0-9._-]+$'
  require_safe "LocalHostName" "$hostname" '^[A-Za-z0-9._-]+$'

  dir=$(dirname "$SETTINGS_FILE")
  mkdir -p "$dir"
  # Temp file in the same directory so mv is an atomic rename.
  tmp=$(mktemp "$dir/.managed-settings.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  printf '%s\n' \
    '{' \
    '  "env": {' \
    '    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",' \
    '    "OTEL_METRICS_EXPORTER": "otlp",' \
    '    "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",' \
    "    \"OTEL_EXPORTER_OTLP_ENDPOINT\": \"$endpoint\"," \
    "    \"OTEL_EXPORTER_OTLP_HEADERS\": \"Authorization=Bearer $token\"," \
    '    "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE": "cumulative",' \
    '    "OTEL_LOGS_EXPORTER": "none",' \
    "    \"OTEL_RESOURCE_ATTRIBUTES\": \"device.id=$serial,host.name=$hostname\"" \
    '  }' \
    '}' >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$SETTINGS_FILE"
  trap - EXIT
  echo "Wrote $SETTINGS_FILE (device.id=$serial, host.name=$hostname, endpoint=$endpoint)"
}

check_settings() {
  local endpoint hostport host port
  [[ -f $SETTINGS_FILE ]] || die "not installed: $SETTINGS_FILE does not exist"
  echo "Settings file: $SETTINGS_FILE"
  sed 's/Bearer [^"]*/Bearer ****/' "$SETTINGS_FILE"

  endpoint=$(sed -n 's/.*"OTEL_EXPORTER_OTLP_ENDPOINT": *"\([^"]*\)".*/\1/p' "$SETTINGS_FILE")
  [[ -n $endpoint ]] || die "no OTEL_EXPORTER_OTLP_ENDPOINT in $SETTINGS_FILE"
  hostport=${endpoint#*://}
  hostport=${hostport%%/*}
  host=${hostport%:*}
  port=${hostport##*:}
  if [[ $host == "$hostport" ]]; then
    if [[ $endpoint == https://* ]]; then port=443; else port=80; fi
  fi
  if nc -z -w 3 "$host" "$port" >/dev/null 2>&1; then
    echo "Endpoint $host:$port is reachable"
  else
    echo "Endpoint $host:$port is NOT reachable"
    return 1
  fi
}

uninstall_settings() {
  require_root
  rm -f "$SETTINGS_FILE"
  echo "Removed $SETTINGS_FILE"
}

main() {
  local token="" domain="" endpoint="" mode=install
  while [[ $# -gt 0 ]]; do
    case $1 in
      --token) [[ $# -ge 2 ]] || usage_error "--token needs a value"; token=$2; shift 2 ;;
      --domain) [[ $# -ge 2 ]] || usage_error "--domain needs a value"; domain=$2; shift 2 ;;
      --endpoint) [[ $# -ge 2 ]] || usage_error "--endpoint needs a value"; endpoint=$2; shift 2 ;;
      --check) mode=check; shift ;;
      --uninstall) mode=uninstall; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "unknown argument: $1" ;;
    esac
  done

  case $mode in
    check) check_settings ;;
    uninstall) uninstall_settings ;;
    install)
      [[ -n $token ]] || usage_error "--token is required"
      if [[ -n $domain && -n $endpoint ]]; then usage_error "give --domain or --endpoint, not both"; fi
      if [[ -z $domain && -z $endpoint ]]; then usage_error "--domain or --endpoint is required"; fi
      require_safe "--token" "$token" '^[A-Za-z0-9._~+/-]+=*$'
      if [[ -n $domain ]]; then
        require_safe "--domain" "$domain" '^[A-Za-z0-9.-]+$'
        endpoint="https://otel.$domain:443"
      fi
      require_safe "--endpoint" "$endpoint" '^https?://[A-Za-z0-9.-]+:[0-9]+$'
      install_settings "$token" "$endpoint"
      ;;
  esac
}

main "$@"
