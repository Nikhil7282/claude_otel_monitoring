#!/usr/bin/env bash
# Static checks for the Kubernetes path (part of make lint). Renders the kustomization in a
# throwaway copy of the repo, with settings from the example files, then checks that:
#   - every object is valid against the Kubernetes API schemas (kubeconform)
#   - the ConfigMaps hold exactly the same Collector config and dashboard that Compose uses
#   - nothing is exposed except through the two Ingresses
#   - the domain and ClusterIssuer from the settings file reached every place that needs them
set -euo pipefail
cd "$(dirname "$0")/.."

KUSTOMIZE_IMAGE=registry.k8s.io/kustomize/kustomize:v5.4.3
KUBECONFORM_IMAGE=ghcr.io/yannh/kubeconform:v0.6.7
YQ_IMAGE=mikefarah/yq:4.44.3
K8S_VERSION=1.30.0
failures=0

mkdir -p .scratch
WORK=$(mktemp -d "$PWD/.scratch/k8s-lint.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; failures=$((failures + 1)); }
check() { # check DESCRIPTION COMMAND...
  local desc=$1
  shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

# A copy of the repo plus the two settings files a user would create from the examples.
# shellcheck source=tests/k8s_common.sh
. tests/k8s_common.sh
copy_repo "$WORK/repo"
cp .env.example "$WORK/repo/.env"
cp k8s/settings.env.example "$WORK/repo/k8s/settings.env"
# shellcheck disable=SC1091 # the example file, read for its DOMAIN and CLUSTER_ISSUER
. k8s/settings.env.example

docker run --rm -v "$WORK/repo":/repo:ro "$KUSTOMIZE_IMAGE" build /repo >"$WORK/rendered.yaml"

# yq EXPRESSION: evaluated over all rendered documents at once, output as JSON-ish text.
yq() { docker run --rm -i "$YQ_IMAGE" ea "$1" <"$WORK/rendered.yaml"; }
configmap_data() { # configmap_data NAME_PREFIX KEY
  docker run --rm -i -e PREFIX="$1" -e KEY="$2" "$YQ_IMAGE" ea \
    'select(.kind == "ConfigMap" and (.metadata.name | test("^" + strenv(PREFIX) + "-[a-z0-9]+$"))) | .data[strenv(KEY)]' \
    <"$WORK/rendered.yaml"
}
same_as_file() { # same_as_file NAME_PREFIX KEY FILE
  diff -q <(configmap_data "$1" "$2") <(cat "$3"; echo) >/dev/null ||
    diff -q <(configmap_data "$1" "$2") "$3" >/dev/null
}

echo "Kubernetes manifests:"
check "valid against the Kubernetes $K8S_VERSION schemas" \
  docker run --rm -i "$KUBECONFORM_IMAGE" -strict -summary -kubernetes-version "$K8S_VERSION" - <"$WORK/rendered.yaml"
check "Collector ConfigMap is the shared collector config" \
  same_as_file otel-collector-config config.yaml collector/config.yaml
check "dashboard ConfigMap is the shared dashboard" \
  same_as_file grafana-dashboards claude-code-usage.json grafana/dashboards/claude-code-usage.json
check "datasource ConfigMap is the shared provisioning file" \
  same_as_file grafana-datasources prometheus.yaml grafana/provisioning/datasources/prometheus.yaml

check "everything is in the claude-otel namespace" \
  test "$(yq '[select(.kind != "Namespace") | .metadata.namespace] | unique | join(",")')" == claude-otel
check "Services are named like the Compose services, all ClusterIP" \
  test "$(yq '[select(.kind == "Service") | .metadata.name + ":" + (.spec.type // "ClusterIP")] | sort | join(",")')" \
  == "grafana:ClusterIP,otel-collector:ClusterIP,prometheus:ClusterIP"
check "no container publishes a host port" \
  test "$(yq '[.. | select(has("hostPort"))] | length')" == 0
check "every container has memory requests and limits" \
  test "$(yq '[select(.kind == "Deployment" or .kind == "StatefulSet") | .spec.template.spec.containers[] | select(.resources.limits.memory == null or .resources.requests.memory == null)] | length')" == 0

check "Ingress hosts come from the settings file" \
  test "$(yq '[select(.kind == "Ingress") | .spec.rules[].host] | sort | join(",")')" == "grafana.$DOMAIN,otel.$DOMAIN"
check "TLS covers each Ingress host" \
  test "$(yq '[select(.kind == "Ingress") | .spec.tls[].hosts[]] | sort | join(",")')" == "grafana.$DOMAIN,otel.$DOMAIN"
check "Ingresses use the nginx class and the settings file's ClusterIssuer" \
  test "$(yq '[select(.kind == "Ingress") | .spec.ingressClassName + ":" + .metadata.annotations["cert-manager.io/cluster-issuer"]] | unique | join(",")')" \
  == "nginx:$CLUSTER_ISSUER"
check "only the OTLP Ingress talks gRPC to its backend" \
  test "$(yq '[select(.kind == "Ingress") | .spec.rules[0].host + "=" + (.metadata.annotations["nginx.ingress.kubernetes.io/backend-protocol"] // "HTTP")] | sort | join(",")')" \
  == "grafana.$DOMAIN=HTTP,otel.$DOMAIN=GRPC"
check "Grafana's root URL is the Ingress hostname" \
  test "$(yq 'select(.kind == "Deployment" and .metadata.name == "grafana") | .spec.template.spec.containers[0].env[] | select(.name == "GF_SERVER_ROOT_URL") | .value')" \
  == "https://grafana.$DOMAIN"
check "secrets come from the Secret, not from plain values" \
  test "$(yq '[.. | select(has("name") and (.name == "OTEL_AUTH_TOKEN" or .name == "COMPANY_ACCOUNTS" or .name == "GF_SECURITY_ADMIN_PASSWORD")) | select(has("valueFrom") | not)] | length')" == 0

if [[ $failures -gt 0 ]]; then
  echo "$failures Kubernetes check(s) failed"
  exit 1
fi
echo "All Kubernetes checks passed"
