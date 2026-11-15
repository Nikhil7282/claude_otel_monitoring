#!/usr/bin/env bash
# End-to-end test for the Kubernetes path (make test-k8s; not part of make test, it takes a
# few minutes). Creates a throwaway kind cluster with ingress-nginx and cert-manager, applies
# the kustomization the way the README does, and checks that OTLP over TLS through the
# Ingress reaches Prometheus for a Company Account only, and that Grafana answers over HTTPS.
# Needs Docker and kubectl; downloads a pinned kind into .scratch/bin if it isn't installed.
set -euo pipefail
cd "$(dirname "$0")/.."

KIND_VERSION=v0.27.0
KIND_NODE_IMAGE=kindest/node:v1.32.2
INGRESS_NGINX_MANIFEST=https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/kind/deploy.yaml
CERT_MANAGER_MANIFEST=https://github.com/cert-manager/cert-manager/releases/download/v1.17.1/cert-manager.yaml
TELEMETRYGEN_IMAGE=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.130.0
CLUSTER=claude-otel-e2e
PORT=28543
DOMAIN=localtest.me
COMPANY=company-one@example.com
OTEL_AUTH_TOKEN=$(openssl rand -hex 32)
GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 16)
failures=0

mkdir -p .scratch
WORK=$(mktemp -d "$PWD/.scratch/k8s-e2e.XXXXXX")
export KUBECONFIG=$WORK/kubeconfig

kind_bin() {
  if command -v kind >/dev/null 2>&1; then
    command -v kind
    return
  fi
  local os arch bin
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  case $(uname -m) in arm64 | aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
  bin=$PWD/.scratch/bin/kind-$KIND_VERSION
  if [[ ! -x $bin ]]; then
    mkdir -p "$(dirname "$bin")"
    curl -fsSLo "$bin" "https://kind.sigs.k8s.io/dl/$KIND_VERSION/kind-$os-$arch"
    chmod +x "$bin"
  fi
  echo "$bin"
}
KIND=$(kind_bin)

cleanup() {
  "$KIND" delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; failures=$((failures + 1)); }
https_get() { # https_get HOST PATH [curl args...]: through the Ingress; -k, the issuer is self-signed
  local host=$1 path=$2
  shift 2
  curl -sk --resolve "$host.$DOMAIN:$PORT:127.0.0.1" "$@" "https://$host.$DOMAIN:$PORT$path"
}
# send_metric DEVICE_ID EMAIL [TOKEN]: one cumulative Sum, over TLS through the Ingress.
send_metric() {
  local device=$1 email=$2 token=${3-$OTEL_AUTH_TOKEN}
  local args=(metrics --otlp-endpoint "otel.$DOMAIN:$PORT" --otlp-insecure-skip-verify
    --metric-type Sum --metrics 1
    --otlp-attributes "device.id=\"$device\"" --otlp-attributes "host.name=\"$device-host\""
    --telemetry-attributes "user.email=\"$email\"")
  if [[ -n $token ]]; then args+=(--otlp-header "Authorization=\"Bearer $token\""); fi
  docker run --rm --add-host "otel.$DOMAIN:host-gateway" "$TELEMETRYGEN_IMAGE" "${args[@]}" >/dev/null 2>&1
}
series_count() { # series_count SELECTOR: through Grafana's datasource proxy, over the Ingress
  https_get grafana /api/datasources/proxy/uid/prometheus/api/v1/query -G \
    -u "admin:$GRAFANA_ADMIN_PASSWORD" --data-urlencode "query=count($1)" |
    jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || echo 0
}

echo "Creating the kind cluster..."
cat >"$WORK/kind.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    labels:
      ingress-ready: "true"
    extraPortMappings:
      - {containerPort: 443, hostPort: $PORT, listenAddress: 127.0.0.1}
EOF
"$KIND" create cluster --quiet --name "$CLUSTER" --image "$KIND_NODE_IMAGE" --config "$WORK/kind.yaml" \
  --kubeconfig "$KUBECONFIG" --wait 120s >/dev/null

echo "Installing ingress-nginx and cert-manager..."
kubectl apply -f "$INGRESS_NGINX_MANIFEST" >/dev/null
kubectl apply -f "$CERT_MANAGER_MANIFEST" >/dev/null
kubectl -n ingress-nginx wait --for=condition=Available deployment/ingress-nginx-controller --timeout=180s >/dev/null
kubectl -n cert-manager wait --for=condition=Available deployment --all --timeout=180s >/dev/null
# The cert-manager webhook can refuse requests for a few seconds after it reports Available.
for _ in $(seq 30); do
  kubectl apply -f - >/dev/null 2>&1 <<EOF && break
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
EOF
  sleep 2
done

echo "Applying the kustomization..."
copy_dir=$WORK/repo
# shellcheck source=tests/k8s_common.sh
. tests/k8s_common.sh
copy_repo "$copy_dir"
cat >"$copy_dir/.env" <<EOF
OTEL_AUTH_TOKEN=$OTEL_AUTH_TOKEN
COMPANY_ACCOUNTS=$COMPANY
GRAFANA_ADMIN_PASSWORD=$GRAFANA_ADMIN_PASSWORD
EOF
cat >"$copy_dir/k8s/settings.env" <<EOF
DOMAIN=$DOMAIN
CLUSTER_ISSUER=selfsigned
EOF
# The ingress-nginx admission webhook also needs a moment before it accepts Ingresses.
for _ in $(seq 30); do
  kubectl apply -k "$copy_dir" >/dev/null 2>&1 && break
  sleep 2
done
kubectl apply -k "$copy_dir" >/dev/null
kubectl -n claude-otel wait --for=condition=Ready certificate --all --timeout=120s >/dev/null
kubectl -n claude-otel rollout status deployment/otel-collector --timeout=180s >/dev/null
kubectl -n claude-otel rollout status deployment/grafana --timeout=180s >/dev/null
kubectl -n claude-otel rollout status statefulset/prometheus --timeout=180s >/dev/null
for _ in $(seq 60); do
  https_get grafana /api/health -f >/dev/null 2>&1 && break
  sleep 2
done

echo "Sending metrics through the Ingress..."
# Personal and token-less first: once the Company Account metric sent after them is stored,
# they would have been stored too if the filter or the token check let them through.
send_metric K8S-PERSONAL someone@gmail.com || true
send_metric K8S-NO-TOKEN "$COMPANY" "" || true
for _ in $(seq 20); do
  send_metric K8S-COMPANY "$COMPANY" && break
  sleep 2
done

echo "Assertions:"
if [[ $(https_get grafana /api/health -o /dev/null -w '%{http_code}') == 200 ]]; then
  pass "Grafana answers over HTTPS through its Ingress"
else
  fail "Grafana answers over HTTPS through its Ingress"
fi
stored=0
for _ in $(seq 45); do
  if [[ $(series_count '{device_id="K8S-COMPANY"}') != 0 ]]; then
    stored=1
    break
  fi
  sleep 2
done
if ((stored)); then
  pass "Company Account metric sent over TLS to otel.$DOMAIN through the Ingress is stored"
else
  fail "Company Account metric sent over TLS to otel.$DOMAIN through the Ingress is stored"
fi
if [[ $(series_count '{device_id="K8S-PERSONAL"}') == 0 ]]; then
  pass "Personal Account metric is dropped"
else
  fail "Personal Account metric is dropped"
fi
if [[ $(series_count '{device_id="K8S-NO-TOKEN"}') == 0 ]]; then
  pass "Metric without the token is rejected"
else
  fail "Metric without the token is rejected"
fi
if [[ $(https_get grafana /api/dashboards/uid/claude-code-usage -u "admin:$GRAFANA_ADMIN_PASSWORD" -o /dev/null -w '%{http_code}') == 200 ]]; then
  pass "Grafana has the provisioned dashboard"
else
  fail "Grafana has the provisioned dashboard"
fi
if [[ $(https_get grafana /api/dashboards/uid/claude-code-usage -o /dev/null -w '%{http_code}') == 401 ]]; then
  pass "Grafana through the Ingress refuses anonymous access"
else
  fail "Grafana through the Ingress refuses anonymous access"
fi

if ((failures > 0)); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "All Kubernetes end-to-end assertions passed"
