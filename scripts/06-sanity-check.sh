#!/usr/bin/env bash
# 06-sanity-check.sh
# PoC 架構整體健康檢查 — 驗證 make 執行後所有元件是否正確建立
set -uo pipefail

SPIRE_HOME="${SPIRE_HOME:-$HOME/.local/share/spire}"
SPIRE_SOCK="/tmp/spire-server/private/api.sock"
SPIRE_BIN="$SPIRE_HOME/bin/spire-server"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}✓${NC} $1"; ((PASS++)); }
fail() { echo -e "  ${RED}✗${NC} $1"; ((FAIL++)); }
section() { echo -e "\n${BOLD}$1${NC}"; }

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

check_output() {
  local desc="$1"; local pattern="$2"; shift 2
  if "$@" 2>/dev/null | grep -q "$pattern"; then pass "$desc"; else fail "$desc"; fi
}

# ─── 1. Kind cluster ───────────────────────────────────────────────────────
section "1. Kind cluster"
check   "cluster 'spire-istio-poc' 存在" \
        bash -c "kind get clusters 2>/dev/null | grep -q '^spire-istio-poc$'"
check   "kubectl 可連線 kind-spire-istio-poc" \
        kubectl cluster-info --context kind-spire-istio-poc

# ─── 2. SPIRE Server (host process) ───────────────────────────────────────
section "2. SPIRE Server（host）"
check   "spire-server process 執行中" \
        pgrep -f 'spire-server run'
check   "SPIRE Server socket 存在 ($SPIRE_SOCK)" \
        test -S "$SPIRE_SOCK"
check   "SPIRE Server healthcheck 通過" \
        "$SPIRE_BIN" healthcheck -socketPath "$SPIRE_SOCK"

# ─── 3. SPIRE Controller Manager (host Docker) ────────────────────────────
section "3. SPIRE Controller Manager（host Docker）"
check   "spire-controller-manager container 執行中" \
        bash -c "docker ps --filter name=spire-controller-manager \
                            --filter status=running -q 2>/dev/null | grep -q ."

# ─── 4. SPIRE Agent + CSI Driver (in-cluster) ─────────────────────────────
section "4. SPIRE Agent + SPIFFE CSI Driver（Kind in-cluster）"
check   "spire namespace 存在" \
        kubectl get namespace spire
check_output "spire-agent DaemonSet 至少 1 個 node ready" \
        "[1-9]" \
        kubectl -n spire get daemonset spire-agent \
          -o jsonpath='{.status.numberReady}'
check   "SPIFFE CSI Driver DaemonSet 存在" \
        bash -c "kubectl -n spire get daemonset 2>/dev/null | grep -qi csi"

# ─── 5. OPA Gatekeeper ────────────────────────────────────────────────────
section "5. OPA Gatekeeper"
check   "gatekeeper-system namespace 存在" \
        kubectl get namespace gatekeeper-system
check   "gatekeeper-controller-manager pod Ready" \
        bash -c "kubectl -n gatekeeper-system get pods \
          -l gatekeeper.sh/operation=webhook \
          --field-selector=status.phase=Running 2>/dev/null | grep -q Running"
check   "gatekeeper-audit pod Ready" \
        bash -c "kubectl -n gatekeeper-system get pods \
          -l gatekeeper.sh/operation=audit \
          --field-selector=status.phase=Running 2>/dev/null | grep -q Running"

# ─── 6. Gatekeeper Constraint Templates ───────────────────────────────────
section "6. Gatekeeper Constraint Templates"
for ct in k8sforbiddefaultserviceaccount k8srequiredspiffelabel \
          k8svalidserviceaccountname k8svalidspiffeprincipal; do
  check "ConstraintTemplate $ct" kubectl get constrainttemplate "$ct"
done

# ─── 7. Gatekeeper Constraints ────────────────────────────────────────────
section "7. Gatekeeper Constraints"
check "K8sValidServiceAccountName / enforce-sa-naming" \
      kubectl get k8svalidserviceaccountname enforce-sa-naming
check "K8sForbidDefaultServiceAccount / no-default-sa" \
      kubectl get k8sforbiddefaultserviceaccount no-default-sa
check "K8sRequiredSpiffeLabel / require-spiffe-label" \
      kubectl get k8srequiredspiffelabel require-spiffe-label
check "K8sValidSpiffePrincipal / valid-spiffe-principal" \
      kubectl get k8svalidspiffeprincipal valid-spiffe-principal

# ─── 8. ClusterSPIFFEID ───────────────────────────────────────────────────
section "8. ClusterSPIFFEID"
check "ClusterSPIFFEID 'istio-workloads' 存在" \
      kubectl get clusterspiffeid istio-workloads

# ─── 9. Payment namespace + workloads ─────────────────────────────────────
section "9. Payment namespace + test workloads"
check "payment namespace 存在" \
      kubectl get namespace payment
check_output "payment namespace label spiffe-managed=true" \
      "true" \
      kubectl get namespace payment -o jsonpath='{.metadata.labels.spiffe-managed}'
check_output "payment namespace label istio-injection=enabled" \
      "enabled" \
      kubectl get namespace payment -o jsonpath='{.metadata.labels.istio-injection}'
check "payment-gateway pod Ready" \
      bash -c "kubectl -n payment get pods -l app=payment-gateway \
        --field-selector=status.phase=Running 2>/dev/null | grep -q Running"
check "payment-core pod Ready" \
      bash -c "kubectl -n payment get pods -l app=payment-core \
        --field-selector=status.phase=Running 2>/dev/null | grep -q Running"

# ─── 10. SPIRE entries ────────────────────────────────────────────────────
section "10. SPIRE entries（Controller Manager 自動建立）"
check_output "payment-gateway-sa 的 SPIRE entry 存在" \
      "payment-gateway-sa" \
      "$SPIRE_BIN" entry show -socketPath "$SPIRE_SOCK"
check_output "payment-core-sa 的 SPIRE entry 存在" \
      "payment-core-sa" \
      "$SPIRE_BIN" entry show -socketPath "$SPIRE_SOCK"

# ─── 11. Envoy SVID（SPIRE 簽發）─────────────────────────────────────────
section "11. Envoy SVID（SPIRE 簽發驗證）"
if ! kubectl -n istio-system get pods -l app=istiod --field-selector=status.phase=Running \
     2>/dev/null | grep -q Running; then
  echo -e "  ${YELLOW}－${NC} istiod 未安裝，略過 SVID 驗證（Istio 為選配元件）"
elif ! command -v istioctl >/dev/null 2>&1; then
  echo -e "  ${YELLOW}－${NC} istioctl 未安裝，略過 SVID 驗證"
else
  POD=$(kubectl get pod -n payment -l app=payment-gateway \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [[ -n "$POD" ]]; then
    check_output "payment-gateway Envoy 持有 SPIRE 簽發的 SVID" \
        "poc.internal" \
        istioctl proxy-config secret -n payment "$POD"
  else
    echo -e "  ${YELLOW}－${NC} payment-gateway pod 未找到，略過 SVID 驗證"
  fi
fi

# ─── 結果摘要 ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}══════════════════════════════${NC}"
TOTAL=$((PASS + FAIL))
echo -e "${BOLD}結果：${GREEN}$PASS${NC}/${TOTAL} 通過"
if [[ $FAIL -gt 0 ]]; then
  echo -e "${RED}失敗：$FAIL 項${NC}"
  echo -e "${BOLD}══════════════════════════════${NC}"
  exit 1
else
  echo -e "${GREEN}所有檢查通過 ✓${NC}"
  echo -e "${BOLD}══════════════════════════════${NC}"
fi
