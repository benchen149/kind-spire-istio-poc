#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="spire"
SPIRE_SERVER_PORT="8082"

helm repo add spiffe https://spiffe.github.io/helm-charts-hardened >/dev/null 2>&1 || true
helm repo update >/dev/null

# Step 1：CRD chart 需先安裝
helm upgrade --install --create-namespace -n "$NAMESPACE" spire-crds spiffe/spire-crds --version 0.5.0

# Step 2：找出 Kind docker network 的 gateway IP，讓 Kind 內的 Agent 連到 host 上的 SPIRE Server
KIND_GATEWAY=$(docker network inspect kind --format '{{(index .IPAM.Config 1).Gateway}}')
echo "SPIRE Server 位址：${KIND_GATEWAY}:${SPIRE_SERVER_PORT}"

# Step 3：將 SPIRE Server 的 trust bundle 寫成 ConfigMap，讓 Agent bootstrap 時信任外部 Server
/opt/spire/bin/spire-server bundle show -socketPath /tmp/spire-server/private/api.sock -format pem > /tmp/spire-bundle.crt
kubectl create configmap spire-bundle -n "$NAMESPACE" \
  --from-file=bundle.crt=/tmp/spire-bundle.crt \
  --dry-run=client -o yaml | kubectl apply -f -

# Step 4：安裝 SPIRE Agent（DaemonSet），spire-server.enabled=false 因為 Server 在外部
helm upgrade --install -n "$NAMESPACE" spire-agent spiffe/spire --version 0.21.0 \
  -f "$REPO_ROOT/spire/values-agent.yaml" \
  --set spire-agent.server.address="${KIND_GATEWAY}" \
  --set spire-agent.server.port="${SPIRE_SERVER_PORT}"

kubectl -n "$NAMESPACE" rollout status daemonset/spire-agent --timeout=120s
