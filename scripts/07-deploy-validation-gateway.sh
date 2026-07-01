#!/usr/bin/env bash
# 08-deploy-validation-gateway.sh
# 在 istio-validation namespace 部署 user-namespace ingress gateway，
# 示範 Helm post-renderer 方式將 workload-socket emptyDir 替換為 SPIFFE CSI Driver volume，
# 讓 user-namespace gateway 也透過 SPIRE 取得 SVID（不修改上游 Helm chart）。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISTIO_HOME="${ISTIO_HOME:-$HOME/.local/share/istio}"
ISTIO_VERSION="${ISTIO_VERSION:-1.29.4}"
CHART_DIR="$ISTIO_HOME/istio-${ISTIO_VERSION}/manifests/charts/gateways/istio-ingress"
VALUES_FILE="$REPO_ROOT/istio/validation-gateway/values.yaml"
POST_RENDERER="$REPO_ROOT/istio/validation-gateway/post-renderer.sh"

echo "=== istio-validation namespace ==="
# spiffe-managed=true  → istio-workloads ClusterSPIFFEID 自動建 SPIRE entry
# istio-injection=enabled → istiod mutating webhook 注入 sidecar
kubectl create namespace istio-validation --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace istio-validation \
  istio-injection=enabled \
  spiffe-managed=true \
  --overwrite

echo "=== Helm install validation-ingressgateway (post-renderer) ==="
helm upgrade --install validation-ingressgateway "$CHART_DIR" \
  --namespace istio-validation \
  --values "$VALUES_FILE" \
  --post-renderer "$POST_RENDERER"

echo "=== 等待 validation-ingressgateway 就緒 ==="
kubectl wait deployment -n istio-validation validation-ingressgateway \
  --for=condition=available --timeout=120s

echo "=== 驗證 CSI volume 已套用（非 emptyDir）==="
VOLUME_TYPE=$(kubectl -n istio-validation get deploy validation-ingressgateway \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="workload-socket")].csi.driver}' 2>/dev/null)
if [[ "$VOLUME_TYPE" == "csi.spiffe.io" ]]; then
  echo "  ✓ workload-socket = csi.spiffe.io"
else
  echo "  ✗ workload-socket 未正確套用（got: ${VOLUME_TYPE:-emptyDir}）" >&2
  exit 1
fi

echo "=== 部署完成 ==="
