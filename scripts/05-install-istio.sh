#!/usr/bin/env bash
# 安裝 Istio（SPIFFE CSI Driver + SDS 整合）
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISTIO_VERSION="${ISTIO_VERSION:-1.29.4}"
ISTIO_HOME="${ISTIO_HOME:-$HOME/.local/share/istio}"
ISTIO_DIR="$ISTIO_HOME/istio-${ISTIO_VERSION}"

# 下載 istioctl（已存在則跳過）
if [ ! -x "$ISTIO_DIR/bin/istioctl" ]; then
  echo ">>> 下載 Istio ${ISTIO_VERSION} ..."
  mkdir -p "$ISTIO_HOME"
  curl -sL \
    "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-amd64.tar.gz" \
    | tar -xz -C "$ISTIO_HOME"
fi

export PATH="$ISTIO_DIR/bin:$PATH"
echo ">>> istioctl version: $(istioctl version --remote=false 2>/dev/null)"

echo ">>> 安裝 Istio（SPIRE CSI Driver + SDS 整合設定）..."
istioctl install -f "$REPO_ROOT/istio/istio-operator.yaml" -y

echo ">>> 等待 istiod ready..."
kubectl wait deployment -n istio-system istiod \
  --for=condition=available --timeout=120s

echo ">>> Istio 安裝完成。"
kubectl get pods -n istio-system
