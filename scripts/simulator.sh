#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
app_dir="$repo_dir/external-metering/simulator"
app_name=external-metering-simulator
collector_name=external-metering-collector
namespace=external-metering
go_bin=${GO:-go}
oc_bin=${OC:-oc}
base_url=${BASE_URL:-http://127.0.0.1:8080}
port=8080

usage() {
  cat <<'HELP'
Usage: ./scripts/simulator.sh [COMMAND] [OPTIONS]

  build          Create build resources and build the image in OpenShift (no local Go).
  deploy         Default: ensure Logging, deploy simulator/collector, configure/restart clients.
                 Reuse the existing image; build it only when missing.
  dashboard      Enable the Perses console integration and apply the Usage dashboard.
  teardown       Delete the external-metering namespace and simulator cluster RBAC.
  test           Run the small Go API test locally (requires Go 1.25+).
  run            Run locally (requires Go 1.25+).
  smoke          Check the HTTP API and post a sample event (requires curl).
  port-forward   Forward the deployed Service to localhost.
  status         Show the simulator Deployment, collector DaemonSet, and forwarder.

Options:
  --go PATH      Go executable for test/run; default: go on PATH (or GO).
  --oc PATH      OpenShift CLI executable; default: oc on PATH (or OC).
  --url URL      HTTP base URL for smoke; default: http://127.0.0.1:8080 (or BASE_URL).
  --port PORT    Local port for run/port-forward; default: 8080.
  -h, --help     Show this help.

Cluster commands use the current oc login. Deploy also updates the payload processor
configuration and restarts payload-pre-processing/payload-processing in openshift-ingress.
Teardown leaves the shared operator, LokiStack, and payload processor configuration intact.
HELP
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" > /dev/null 2>&1 || die "Required command not found: $1"; }
need_go() {
  command -v "$go_bin" > /dev/null 2>&1 || die \
    "Local test/run requires Go 1.25+. Install Go and add it to PATH, or use --go /path/to/go. OpenShift build/deploy does not require local Go."
}
need_cluster() {
  need "$oc_bin"
  "$oc_bin" whoami > /dev/null || die "Log in to the intended cluster with oc login, then retry."
}

ensure_logging() {
  if ! "$oc_bin" get deployment cluster-logging-operator -n openshift-logging > /dev/null 2>&1; then
    printf 'Installing the Logging Operator (stable-6.7).\n'
    "$oc_bin" apply -k "$repo_dir/deploy/logging-operator"
  fi
  # OLM creates the Deployment asynchronously after the Subscription is applied.
  "$oc_bin" wait --for=create deployment/cluster-logging-operator -n openshift-logging --timeout=300s
  "$oc_bin" rollout status deployment/cluster-logging-operator -n openshift-logging --timeout=300s
  "$oc_bin" wait --for=create crd/clusterlogforwarders.observability.openshift.io --timeout=120s
  "$oc_bin" wait --for=condition=Established crd/clusterlogforwarders.observability.openshift.io --timeout=120s
  "$oc_bin" wait --for=create clusterrole/collect-application-logs --timeout=120s
}

build_image() {
  need cp
  need mktemp
  build_context=$(mktemp -d)
  trap 'rm -rf "$build_context"' EXIT
  cp "$app_dir/Dockerfile" "$app_dir/go.mod" "$build_context/"
  cp -R "$app_dir/cmd" "$app_dir/internal" "$build_context/"
  "$oc_bin" start-build "$app_name" -n "$namespace" \
    --from-dir="$build_context" --follow --wait
}

command_name=deploy
if [[ $# -gt 0 && "$1" != -* ]]; then
  command_name=$1
  shift
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --go|--oc|--url|--port)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 requires a value."
      case "$1" in
        --go) go_bin=$2 ;;
        --oc) oc_bin=$2 ;;
        --url) base_url=$2 ;;
        --port) port=$2 ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1. Use --help for usage." ;;
  esac
done

case "$command_name" in
  -h|--help|help) usage ;;
  dashboard)
    need_cluster
    "$oc_bin" get lokistack usage -n redhat-ods-monitoring > /dev/null
    "$oc_bin" get configmap usage-gateway-ca-bundle -n redhat-ods-monitoring > /dev/null
    "$oc_bin" get crd persesdashboards.perses.dev persesdatasources.perses.dev \
      uiplugins.observability.openshift.io > /dev/null
    if "$oc_bin" get uiplugin monitoring > /dev/null 2>&1; then
      "$oc_bin" patch uiplugin monitoring --type=merge \
        -p '{"spec":{"monitoring":{"perses":{"enabled":true}}}}'
    else
      "$oc_bin" apply -k "$repo_dir/deploy/console"
    fi
    "$oc_bin" apply -k "$repo_dir/deploy/perses" ;;
  test|run)
    need_go
    cd "$app_dir"
    if [[ "$command_name" == test ]]; then
      exec "$go_bin" test ./...
    else
      PORT="$port" LISTEN_ADDR= exec "$go_bin" run ./cmd/external-metering-simulator
    fi ;;
  build)
    need_cluster
    # BuildConfig must exist before start-build. No logging operator is needed here.
    "$oc_bin" apply -k "$app_dir/build"
    build_image ;;
  deploy)
    need_cluster
    # Fail early when the existing MaaS clients or LokiStack are missing.
    "$oc_bin" get deployment payload-pre-processing payload-processing -n openshift-ingress > /dev/null
    "$oc_bin" get lokistack usage -n redhat-ods-monitoring > /dev/null
    ensure_logging
    "$oc_bin" apply -k "$app_dir/build"
    image_ref=$("$oc_bin" get imagestreamtag "$app_name:latest" -n "$namespace" \
      --ignore-not-found -o jsonpath='{.image.dockerImageReference}')
    if [[ -z "$image_ref" ]]; then
      printf 'No simulator image found; building the local source in OpenShift.\n'
      build_image
    else
      printf 'Reusing simulator image: %s\n' "$image_ref"
    fi
    "$oc_bin" apply -k "$app_dir"
    "$oc_bin" rollout status "deployment/$app_name" -n "$namespace" --timeout=180s
    "$oc_bin" wait --for=condition=Ready "clusterlogforwarder/$collector_name" -n "$namespace" --timeout=180s
    "$oc_bin" wait --for=create "daemonset/$collector_name" -n "$namespace" --timeout=120s
    "$oc_bin" rollout status "daemonset/$collector_name" -n "$namespace" --timeout=180s
    "$oc_bin" apply -f "$repo_dir/external-metering/payload-processing-plugins.yaml"
    "$oc_bin" rollout restart deployment/payload-pre-processing deployment/payload-processing -n openshift-ingress
    "$oc_bin" rollout status deployment/payload-pre-processing -n openshift-ingress --timeout=180s
    "$oc_bin" rollout status deployment/payload-processing -n openshift-ingress --timeout=180s ;;
  teardown)
    need_cluster
    "$oc_bin" delete namespace "$namespace" --ignore-not-found --wait=true --timeout=180s
    # Namespace deletion does not remove cluster-scoped collector permissions.
    "$oc_bin" delete clusterrolebinding external-metering-collect-application-logs \
      external-metering-write-application-logs --ignore-not-found
    "$oc_bin" delete clusterrole external-metering-write-application-logs --ignore-not-found ;;
  port-forward)
    need_cluster
    exec "$oc_bin" port-forward -n "$namespace" "svc/$app_name" "$port:8080" ;;
  status)
    need_cluster
    "$oc_bin" get deployment "$app_name" -n "$namespace"
    "$oc_bin" get daemonset "$collector_name" -n "$namespace"
    "$oc_bin" get clusterlogforwarder "$collector_name" -n "$namespace" ;;
  smoke)
    need curl
    need sed
    base_url=${base_url%/}
    curl -fsS --max-time 10 "$base_url/readyz" > /dev/null
    entitlement=$(curl -fsS --max-time 10 "$base_url/api/v1/customers/alice/entitlements/inference-tokens/value")
    [[ "$entitlement" == *'"hasAccess":true'* ]] || die "GET did not grant access: $entitlement"
    event_id="evt-poc-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
    status=$(sed "s/evt-poc-alice-001/$event_id/" "$app_dir/testdata/usage-event.json" | \
      curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
        --data-binary @- "$base_url/api/v1/events")
    [[ "$status" == 204 ]] || die "POST returned HTTP $status; expected 204."
    printf 'Accepted %s (150 prompt, 80 completion, 230 total tokens). Check this ID in Loki.\n' "$event_id" ;;
  *) die "Unknown command: $command_name. Use --help for usage." ;;
esac
