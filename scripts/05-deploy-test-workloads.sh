#!/usr/bin/env bash
# 部署 payment namespace 測試 workload，驗證：
# 1. OPA Gatekeeper 四層 Constraint 生效
# 2. SPIRE Controller Manager 自動建立 entry
# 3. Envoy sidecar 透過 SPIFFE CSI Driver 取得 SPIRE 簽發憑證
# 4. AuthorizationPolicy + STRICT mTLS 正確做存取控制
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

kubectl create namespace payment --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace payment spiffe-managed=true istio-injection=enabled --overwrite

kubectl apply -f "$REPO_ROOT/test/good-sa-deployment.yaml"
kubectl apply -f "$REPO_ROOT/test/payment-core-deployment.yaml"
kubectl apply -f "$REPO_ROOT/test/peer-authentication.yaml"
kubectl apply -f "$REPO_ROOT/test/payment-core-authz-policy.yaml"

kubectl wait pod -n payment -l app=payment-gateway --for=condition=ready --timeout=120s
kubectl wait pod -n payment -l app=payment-core --for=condition=ready --timeout=120s

echo "=== SPIRE entries（應自動建立，1 SA = 1 entry）==="
"${SPIRE_HOME:-$HOME/.local/share/spire}/bin/spire-server" entry show -socketPath /tmp/spire-server/private/api.sock

echo "=== 驗證 Envoy 憑證由 SPIRE 簽發 ==="
POD=$(kubectl get pod -n payment -l app=payment-gateway -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config secret -n payment "$POD"

echo "=== 驗證 mTLS + AuthorizationPolicy（允許的呼叫應為 200）==="
kubectl exec -n payment deploy/payment-gateway -c app -- \
  curl -sS -o /dev/null -w "gateway->core: HTTP %{http_code}\n" \
  http://payment-core.payment.svc.cluster.local/get --max-time 5
