#!/usr/bin/env bash
# 07-sanity-check.sh
# PoC 架構整體健康檢查 — 驗證 make 執行後所有元件是否正確建立
#
# 設計原則：
#   - 每個 section 對應一個部署層，依啟動依賴順序排列
#   - 只驗證「元件是否正確銜接」，不重複測試 Helm/Docker 自身的健康機制
#   - exit 1 讓 CI / make 能感知失敗
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
# 為何檢查：所有後續步驟都依賴 Kind cluster 存在且可被 kubectl 連線。
# cluster 名稱是 PoC 的固定值；若 context 不對，後續所有 kubectl 指令都會打錯叢集。
section "1. Kind cluster"
check   "cluster 'spire-istio-poc' 存在" \
        bash -c "kind get clusters 2>/dev/null | grep -q '^spire-istio-poc$'"
# cluster-info 同時驗證 kubeconfig context 正確且 API server 可達
check   "kubectl 可連線 kind-spire-istio-poc" \
        kubectl cluster-info --context kind-spire-istio-poc

# ─── 2. SPIRE Server (host process) ───────────────────────────────────────
# 為何檢查：SPIRE Server 以 host process 執行（非 k8s pod），不在 kubectl 管控範圍內。
# 需分三層確認：process 存在 → socket 建立（代表 Server 已完成初始化）→ healthcheck 通過。
# 只確認 process 存在不夠，因為 Server 可能啟動中但 socket 尚未建立，
# 此時 SPIRE Agent 會無法完成 node attestation。
section "2. SPIRE Server（host）"
# pgrep -f 比對完整 command line，區分 spire-server 的 run 子指令（而非其他 spire 指令）
check   "spire-server process 執行中" \
        pgrep -f 'spire-server run'
# socket 是 SPIRE Agent 和 Controller Manager 與 Server 通訊的唯一入口
check   "SPIRE Server socket 存在 ($SPIRE_SOCK)" \
        test -S "$SPIRE_SOCK"
# healthcheck 透過 socket 發 gRPC 請求，確認 Server 內部狀態正常（不只是 process 存活）
check   "SPIRE Server healthcheck 通過" \
        "$SPIRE_BIN" healthcheck -socketPath "$SPIRE_SOCK"

# ─── 3. SPIRE Controller Manager (host Docker) ────────────────────────────
# 為何檢查：Controller Manager 以 Docker container 執行（非 k8s pod），
# 負責監控 ClusterSPIFFEID / pod 並自動向 SPIRE Server 建立 entry。
# 若 container 未啟動或 crash，新部署的 workload 都取不到 SPIFFE identity。
section "3. SPIRE Controller Manager（host Docker）"
# --filter status=running 確認 container 確實在執行，排除 created/exited 狀態
check   "spire-controller-manager container 執行中" \
        bash -c "docker ps --filter name=spire-controller-manager \
                            --filter status=running -q 2>/dev/null | grep -q ."

# ─── 4. SPIRE Agent + CSI Driver (in-cluster) ─────────────────────────────
# 為何檢查：SPIRE Agent 是 workload 取得 SVID 的直接來源（Workload API socket）。
# SPIFFE CSI Driver 把 Agent socket bind mount 進每個 workload pod。
# 兩者缺一，workload pod 啟動時會卡在 ContainerCreating（CSI volume provision 失敗）。
section "4. SPIRE Agent + SPIFFE CSI Driver（Kind in-cluster）"
check   "spire namespace 存在" \
        kubectl get namespace spire
# numberReady 驗證至少有一個 node 上的 Agent 完成了 node attestation 並進入 Ready 狀態；
# 數字檢查用 regex [1-9] 而非 == 1，因為多 node 叢集 ready 數可能 > 1
check_output "spire-agent DaemonSet 至少 1 個 node ready" \
        "[1-9]" \
        kubectl -n spire get daemonset spire-agent \
          -o jsonpath='{.status.numberReady}'
# CSI Driver DaemonSet 名稱包含 "csi"（Helm chart 自動命名），用 grep -qi 做 case-insensitive 匹配
check   "SPIFFE CSI Driver DaemonSet 存在" \
        bash -c "kubectl -n spire get daemonset 2>/dev/null | grep -qi csi"

# ─── 5. OPA Gatekeeper ────────────────────────────────────────────────────
# 為何檢查：Gatekeeper 的 webhook 必須在線，任何 Deployment apply 才能通過 admission。
# 需分別確認 webhook controller（負責 admission）和 audit（負責審計已存在資源）兩個 pod。
# 只確認 namespace 存在不夠，pod crash 時 namespace 仍在但 webhook 已失效。
section "5. OPA Gatekeeper"
check   "gatekeeper-system namespace 存在" \
        kubectl get namespace gatekeeper-system
# gatekeeper.sh/operation=webhook 是 Helm chart 為 webhook controller pod 設定的 label
check   "gatekeeper-controller-manager pod Ready" \
        bash -c "kubectl -n gatekeeper-system get pods \
          -l gatekeeper.sh/operation=webhook \
          --field-selector=status.phase=Running 2>/dev/null | grep -q Running"
check   "gatekeeper-audit pod Ready" \
        bash -c "kubectl -n gatekeeper-system get pods \
          -l gatekeeper.sh/operation=audit \
          --field-selector=status.phase=Running 2>/dev/null | grep -q Running"

# ─── 6. Gatekeeper Constraint Templates ───────────────────────────────────
# 為何檢查：ConstraintTemplate 是 Constraint 的 CRD schema，必須先於 Constraint apply。
# 若 Template 不存在，apply Constraint 時 k8s 找不到對應的 CRD kind 而失敗，
# 且 Gatekeeper 不會主動報錯，只是靜默不攔截。
# 逐一確認四個 Template 確保沒有漏裝。
section "6. Gatekeeper Constraint Templates"
for ct in k8sforbiddefaultserviceaccount k8srequiredspiffelabel \
          k8svalidserviceaccountname k8svalidspiffeprincipal; do
  check "ConstraintTemplate $ct" kubectl get constrainttemplate "$ct"
done

# ─── 7. Gatekeeper Constraints ────────────────────────────────────────────
# 為何檢查：Constraint 是實際生效的 policy 物件。Template 存在但 Constraint 不存在，
# Gatekeeper 不會執行任何攔截，整個 admission 控制實質上失效。
# 逐一確認四條規則（SA 命名、spiffe label、禁 default SA、principal 格式）。
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
# 為何檢查：ClusterSPIFFEID 定義了「哪些 pod 要有 SPIFFE identity、ID 格式是什麼」。
# Controller Manager 監聽這個 CRD 並據此向 SPIRE Server 建立 entry。
# 若 ClusterSPIFFEID 不存在，Controller Manager 不會建立任何 entry，
# workload 的 Envoy 永遠取不到 SVID（靜默失敗，難以診斷）。
section "8. ClusterSPIFFEID"
check "ClusterSPIFFEID 'istio-workloads' 存在" \
      kubectl get clusterspiffeid istio-workloads

# ─── 9. Payment namespace + workloads ─────────────────────────────────────
# 為何檢查：payment namespace 是本 PoC 的測試業務命名空間。
# 兩個 label 是 PoC 的核心機制：
#   spiffe-managed=true → ClusterSPIFFEID selector 條件，缺少則 Controller Manager 不建 entry
#   istio-injection=enabled → istiod mutating webhook 注入 Envoy sidecar 的條件
# pod Ready 狀態確認 CSI volume mount 成功（pod 卡在 ContainerCreating 表示 CSI Driver 有問題）
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
# 為何檢查：SPIRE entry 是 Server 核對 workload 身份的依據。
# 沒有 entry，Envoy 的 SDS 請求會被 SPIRE Server 拒絕，Envoy 取不到任何 cert。
# 此項檢查同時驗證了「Controller Manager → SPIRE Server」這條鏈路正常：
# entry 存在 = Controller Manager 成功讀到 ClusterSPIFFEID 並建立 entry。
# 用 SA 名稱而非 SPIFFE ID 全路徑比對，容許 trust domain 日後調整。
section "10. SPIRE entries（Controller Manager 自動建立）"
check_output "payment-gateway-sa 的 SPIRE entry 存在" \
      "payment-gateway-sa" \
      "$SPIRE_BIN" entry show -socketPath "$SPIRE_SOCK"
check_output "payment-core-sa 的 SPIRE entry 存在" \
      "payment-core-sa" \
      "$SPIRE_BIN" entry show -socketPath "$SPIRE_SOCK"

# ─── 11. Envoy SVID（SPIRE 簽發）─────────────────────────────────────────
# 為何檢查：這是整個 PoC 的核心驗證，確認 cert 路徑是「Envoy → SPIRE Agent（CSI socket）
# → SPIRE Server」，而非走 istiod CA。
# istiod 負責注入 sidecar 和 xDS 設定，但不參與 cert 簽發；
# 若 CA_ADDR / PILOT_CERT_PROVIDER 設定錯誤，Envoy 會靜默地改用 istiod cert，
# 憑證 Issuer 從 "O=SPIFFE" 變成 "O=cluster.local"，mTLS 身份驗證失效。
#
# 實作說明：istioctl proxy-config secret 純文字表格不含 cert SAN，
# 需加 -o json 後用 openssl x509 解析 cert chain 才能確認 Issuer 和 URI SAN。
ISTIO_HOME="${ISTIO_HOME:-$HOME/.local/share/istio}"
ISTIO_VERSION="${ISTIO_VERSION:-1.29.4}"
ISTIOCTL="$ISTIO_HOME/istio-${ISTIO_VERSION}/bin/istioctl"
# PATH 上的 istioctl 優先（使用者可能已全域安裝）
command -v istioctl >/dev/null 2>&1 && ISTIOCTL="$(command -v istioctl)"

section "11. Envoy SVID（SPIRE 簽發驗證）"
# istiod 必須在線：負責 sidecar injection webhook，pod 重啟時若 istiod 掛掉，
# 新 pod 不會被注入 Envoy sidecar，後續 SVID 驗證也毫無意義
check "istiod pod 執行中" \
      bash -c "kubectl -n istio-system get pods -l app=istiod \
        --field-selector=status.phase=Running 2>/dev/null | grep -q Running"

if [[ -x "$ISTIOCTL" ]]; then
  POD=$(kubectl get pod -n payment -l app=payment-gateway \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [[ -n "$POD" ]]; then
    # 從 Envoy 的 active secret 中解析 cert chain，確認 URI SAN 包含正確的 trust domain
    # URI SAN 格式：spiffe://<trustDomain>/ns/<ns>/sa/<sa>
    # trust domain 用 poc.internal 而非 cluster.local（istiod 自簽 CA 的預設值）
    SVID_SAN=$("$ISTIOCTL" proxy-config secret -n payment "$POD" -o json 2>/dev/null \
      | python3 -c "
import json,sys,base64,subprocess
d=json.load(sys.stdin)
for s in d.get('dynamicActiveSecrets',[]):
    try:
        pem=base64.b64decode(s['secret']['tlsCertificate']['certificateChain']['inlineBytes']).decode()
        r=subprocess.run(['openssl','x509','-text','-noout'],input=pem,capture_output=True,text=True)
        for line in r.stdout.splitlines():
            if 'URI:spiffe://' in line: print(line.strip())
    except: pass
" 2>/dev/null)
    if echo "$SVID_SAN" | grep -q "poc.internal"; then
      pass "payment-gateway Envoy 持有 SPIRE 簽發的 SVID ($SVID_SAN)"
    else
      fail "payment-gateway Envoy 未持有 SPIRE 簽發的 SVID（SAN: ${SVID_SAN:-empty}）"
    fi
  else
    fail "payment-gateway pod 未找到（無法驗證 SVID）"
  fi
else
  fail "istioctl 未找到（路徑: $ISTIOCTL）"
fi

# ─── 12. Ingress Gateway SPIRE 整合 ──────────────────────────────────────
# 為何檢查：ingress gateway 不走 sidecar injection（sidecar.istio.io/inject: false），
# 必須透過 IstioOperator k8s.overlays 手動替換 workload-socket 為 CSI volume。
# 只驗證 SPIRE entry 存在（不驗 active SVID）：ingress gateway 採 lazy cert 初始化，
# 需有 TLS-configured Gateway resource 且流量通過後才會發 SDS 請求；
# entry 存在代表 Controller Manager → SPIRE Server 這條鏈路已正確建立，
# cert 將在第一筆 TLS 流量時由 SPIRE 即時簽發。
section "12. Ingress Gateway SPIRE 整合"
# 驗證 CSI volume 已取代 emptyDir（socket 存在且是 Unix domain socket 類型）
IGW_POD=$(kubectl get pod -n istio-system -l app=istio-ingressgateway \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$IGW_POD" ]]; then
  check "ingress gateway workload-socket 已掛載 CSI volume（非 emptyDir）" \
        bash -c "kubectl -n istio-system get deploy istio-ingressgateway \
          -o jsonpath='{.spec.template.spec.volumes[?(@.name==\"workload-socket\")].csi.driver}' \
          2>/dev/null | grep -q 'csi.spiffe.io'"
  check_output "ingress gateway CA_ADDR 指向 SPIRE socket（非 istiod）" \
        "workload-spiffe-uds" \
        kubectl -n istio-system get deploy istio-ingressgateway \
          -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CA_ADDR")].value}'
else
  fail "istio-ingressgateway pod 未找到"
fi
# entry 存在 = Controller Manager 已讀到 ClusterSPIFFEID istio-ingressgateway 並建立 entry
check_output "ingress gateway SPIRE entry 存在" \
      "ingressgateway" \
      "$SPIRE_BIN" entry show -socketPath "$SPIRE_SOCK"

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
