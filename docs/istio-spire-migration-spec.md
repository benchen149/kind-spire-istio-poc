# Istio × SPIRE 整合切換規格

從 **架構一：Istio 自管 CA（cacerts）** 切換至 **架構二：SPIRE 作為 CA** 的 Istio 維護者操作規格。

本文件以 **Istio 維護者視角**出發，假設 SPIRE 基礎設施由獨立團隊建置，Istio 側需要知道「要向 SPIRE 拿什麼資訊」、「要改哪些設定」、以及「現有元件的影響範圍」。

## 目錄

- [一、SPIRE 團隊需提供的資訊與元件](#一spire-團隊需提供的資訊與元件)
- [二、Istio 安裝層變更](#二istio-安裝層變更)
  - [2.1 移除 cacerts Secret](#21-移除-cacerts-secret)
  - [2.2 IstioOperator 必要變更](#22-istiooperator-必要變更)
  - [2.3 變更對照表](#23-變更對照表)
- [三、元件影響清單](#三元件影響清單)
  - [3.1 istio-ingressgateway（istiod 管理）](#31-istio-ingressgatewayistiod-管理)
  - [3.2 User Namespace IngressGateway（Helm 安裝）](#32-user-namespace-ingressgatewayhel-安裝)
  - [3.3 有 Sidecar 的 Workload](#33-有-sidecar-的-workload)
- [四、AuthorizationPolicy Principal 格式變更（Breaking Change）](#四authorizationpolicy-principal-格式變更breaking-change)
- [五、PeerAuthentication 必須為 STRICT](#五peerauthentication-必須為-strict)
- [六、切換流程](#六切換流程)
- [七、App 使用者需知](#七app-使用者需知)
- [八、Istio 維護者驗證清單](#八istio-維護者驗證清單)
- [九、切換後的維護成本考量](#九切換後的維護成本考量)

---

## 一、SPIRE 團隊需提供的資訊與元件

在開始改動 Istio 前，需先向 SPIRE 維護團隊確認以下項目全部就緒：

| 項目 | 說明 | Istio 側用途 |
|---|---|---|
| **Trust Domain** | 例如 `poc.internal` | 必須與 `meshConfig.trustDomain` 完全一致 |
| **SPIFFE CSI Driver** | k8s 叢集上已安裝（`csi.spiffe.io`） | 讓 Envoy 透過 CSI volume 取得 agent.sock |
| **SPIRE Agent DaemonSet** | 每個 node 跑一個 Agent | 提供 SDS socket，Envoy 連此取 SVID |
| **agent.sock 路徑** | 例如 `/run/secrets/workload-spiffe-uds/socket` | CSI volume mountPath，寫入 IstioOperator |
| **ClusterSPIFFEID** | 含 Istio workload 與 ingressgateway 的規則 | SPIRE 依此自動為 pod 建立 SPIFFE entry |
| **SPIFFE ID 格式確認** | 必須為 `spiffe://<trustDomain>/ns/<ns>/sa/<sa>` | Istio 強制格式，不可客製化 path |

> **⚠️ Trust Domain 確認優先**：一旦 Istio 安裝後 `trustDomain` 不可更改，若之後與 SPIRE 的 trust domain 不一致，所有 mTLS 驗證會全部失敗。

---

## 二、Istio 安裝層變更

### 2.1 移除 cacerts Secret

架構二中，Istio **不再需要** `cacerts` Secret。SPIRE Server 扮演 CA 角色，istiod 不再簽發 workload cert。

```bash
# 架構一安裝時通常會建立此 Secret，切換後可移除
kubectl delete secret cacerts -n istio-system
```

> 移除後 istiod 會以 self-signed cert 處理 xDS TLS，這是正常行為（xDS TLS 與 workload cert 是兩條獨立路徑）。

---

### 2.2 IstioOperator 必要變更

以下為架構二所需的最小 IstioOperator 異動（對照本 PoC 的 `istio/istio-operator.yaml`）：

```yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  meshConfig:
    # [必改] 必須與 SPIRE trust domain 完全一致
    trustDomain: <spire-trust-domain>          # 例：poc.internal

  components:
    ingressGateways:
      - name: istio-ingressgateway
        enabled: true
        k8s:
          overlays:
            - kind: Deployment
              name: istio-ingressgateway
              patches:
                # [必改] 將預設 emptyDir workload-socket 換成 SPIFFE CSI volume
                - path: spec.template.spec.volumes[name:workload-socket]
                  value:
                    name: workload-socket
                    csi:
                      driver: csi.spiffe.io
                      readOnly: true
                # [必改] cert 來源指向 SPIRE Agent socket
                - path: spec.template.spec.containers[name:istio-proxy].env[name:CA_ADDR].value
                  value: "unix:///run/secrets/workload-spiffe-uds/socket"
                # [必改] 告知 pilot-agent cert provider 為 spiffe
                - path: spec.template.spec.containers[name:istio-proxy].env[name:PILOT_CERT_PROVIDER].value
                  value: "spiffe"

  values:
    sidecarInjectorWebhook:
      # [必加] 自訂 spire injection template
      # 只有帶 annotation inject.istio.io/templates: "sidecar,spire" 的 workload 才會掛載
      templates:
        spire: |
          spec:
            initContainers:
            - name: istio-proxy
              env:
              - name: CA_ADDR
                value: unix:///run/secrets/workload-spiffe-uds/socket
              - name: PILOT_CERT_PROVIDER
                value: spiffe
              volumeMounts:
              - name: workload-socket
                mountPath: /run/secrets/workload-spiffe-uds
                readOnly: true
            volumes:
              - name: workload-socket
                csi:
                  driver: "csi.spiffe.io"
                  readOnly: true
```

> **Native Sidecar（Istio 1.23+）**：若啟用 `ENABLE_NATIVE_SIDECARS=true`，sidecar 以 `initContainer` 形式注入，template 需修改 `initContainers[name:istio-proxy]`，而非 `containers`。本 PoC 即為此模式。

---

### 2.3 變更對照表

| 設定項目 | 架構一 | 架構二 |
|---|---|---|
| `meshConfig.trustDomain` | `cluster.local`（預設）| 與 SPIRE trust domain 一致 |
| `cacerts` Secret | 需要建立 | 不需要 |
| `workload-socket` volume | `emptyDir`（預設）| `csi: driver: csi.spiffe.io` |
| `CA_ADDR` env | istiod 內建 SDS | `unix:///run/secrets/workload-spiffe-uds/socket` |
| `PILOT_CERT_PROVIDER` | `istiod`（預設）| `spiffe` |
| Sidecar injection template | 無需額外 template | 需加 `spire` template |

---

## 三、元件影響清單

### 3.1 istio-ingressgateway（istiod 管理）

**異動方式**：IstioOperator overlay（2.2 節），**不需修改 Deployment YAML**，`istioctl apply` 後自動生效。

**特殊行為**：Gateway pod 的 Envoy 採用 **Lazy SVID**，不會在啟動時立即向 SPIRE 取得 SVID，而是在有 TLS 流量（Gateway 資源 + 憑證）設定後才觸發。切換後驗證方式：

```bash
# 確認 CSI volume 已掛載
kubectl exec -n istio-system deploy/istio-ingressgateway \
  -- ls /run/secrets/workload-spiffe-uds/

# 確認 SPIRE entry 已建立（需對應的 ClusterSPIFFEID）
spire-server entry show | grep ingressgateway
```

---

### 3.2 User Namespace IngressGateway（Helm 安裝）

Istio Gateway Helm chart 預設**不含** CSI volume，需透過 **post-renderer** 在 Helm render 後注入 patch。

**post-renderer 檔案**（`patch-csi-volume.yaml`）：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <gateway-deployment-name>
spec:
  template:
    spec:
      volumes:
      - name: workload-socket
        csi:
          driver: csi.spiffe.io
          readOnly: true
```

**Helm 安裝指令**：

```bash
helm upgrade --install <release> istio/gateway \
  --namespace <namespace> \
  --post-renderer ./post-renderer.sh \
  -f values.yaml
```

**ArgoCD 環境**：ArgoCD 不支援 `--post-renderer`，替代方案：
- **方案 A（建議）**：Kustomize + `helmCharts` + JSON 6902 patch
- **方案 B**：Config Management Plugin（CMP）
- **方案 C**：預先 render 成靜態 manifest 納入 git

---

### 3.3 有 Sidecar 的 Workload

**Pod 需要兩項標記**，缺一不可：

| 標記 | 位置 | 用途 |
|---|---|---|
| `spiffe-managed: "true"` | Pod `labels` | ClusterSPIFFEID podSelector 條件，讓 SPIRE 建立 entry |
| `inject.istio.io/templates: "sidecar,spire"` | Pod `annotations` | 觸發 spire injection template，掛載 CSI volume |

Namespace 也需要有 `spiffe-managed: "true"` label（ClusterSPIFFEID 的 namespaceSelector 條件）：

```bash
kubectl label namespace <ns> spiffe-managed=true
```

**最小 Pod 範例**：

```yaml
metadata:
  labels:
    spiffe-managed: "true"       # SPIRE entry 觸發
  annotations:
    inject.istio.io/templates: "sidecar,spire"  # CSI volume 注入
spec:
  serviceAccountName: <sa>       # SPIFFE ID 路徑的一部分
```

---

## 四、AuthorizationPolicy Principal 格式變更（Breaking Change）

這是切換架構時**最容易造成 403 的地方**。

### 4.1 格式差異

| | 架構一（Istio 自管 CA） | 架構二（SPIRE 作為 CA） |
|---|---|---|
| Principal 格式 | `cluster.local/ns/<ns>/sa/<sa>` | `<trustDomain>/ns/<ns>/sa/<sa>` |
| 範例 | `cluster.local/ns/default/sa/frontend-sa` | `poc.internal/ns/default/sa/frontend-sa` |
| `spiffe://` 前綴 | 不加 | 不加（加了反而 403） |

> **實測坑**：Istio AuthorizationPolicy 的 `principals` 欄位不含 `spiffe://` 前綴。即使 Envoy 已持有 SPIRE 簽發的 SVID 且 SAN URI 完全相符，用完整 `spiffe://poc.internal/...` URI 仍會被 RBAC 判為 `matched_policy[none]`（403）。

### 4.2 需要更新的資源

切換後需全面搜尋所有 AuthorizationPolicy，將 `cluster.local` 替換為新的 trust domain：

```bash
# 找出所有含 principal 的 AuthorizationPolicy
kubectl get authorizationpolicy -A -o yaml | grep "principals" -A 3

# 批次確認需要更新的資源
kubectl get authorizationpolicy -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
```

---

## 五、PeerAuthentication 必須為 STRICT

**重要**：在 SPIRE 架構下，PeerAuthentication 必須設定為 `STRICT` 模式。

`PERMISSIVE` 模式下，即使 Envoy 已持有 SPIRE 簽發的 cert 且 TLS handshake 成功，Istio RBAC 引擎不會將連線視為已驗證的 authenticated principal，導致 AuthorizationPolicy 的 `from.source.principals` 規則無法生效（403）。

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: <namespace>
spec:
  mtls:
    mode: STRICT    # PERMISSIVE 無法讓 RBAC 識別 SPIRE principal
```

---

## 六、切換流程

### Phase 1：確認前置條件

- [ ] SPIRE 團隊確認 trust domain、CSI Driver、Agent DaemonSet 已就緒
- [ ] 確認 SPIFFE ID 格式：`spiffe://<trustDomain>/ns/<ns>/sa/<sa>`
- [ ] 向 SPIRE 取得 ClusterSPIFFEID 範本（或確認 SPIRE 已建立對應 entry）

### Phase 2：更新 Istio 安裝設定

- [ ] 更新 IstioOperator（`meshConfig.trustDomain`、`workload-socket` patch、CA_ADDR、PILOT_CERT_PROVIDER）
- [ ] 加入 `spire` sidecar injection template
- [ ] 套用：`istioctl apply -f istio-operator.yaml`
- [ ] 確認 `istio-ingressgateway` pod 重啟後 CSI volume 已掛載

### Phase 3：更新 AuthorizationPolicy

- [ ] 找出所有 `cluster.local/ns/...` principal，替換為新 trust domain
- [ ] 確認不含 `spiffe://` 前綴

### Phase 4：逐 Namespace 遷移 Workload

對每個 namespace 依序執行：

- [ ] `kubectl label namespace <ns> spiffe-managed=true`
- [ ] 更新 Pod template：加 `spiffe-managed: "true"` label 與 `inject.istio.io/templates: "sidecar,spire"` annotation
- [ ] 確認 namespace 下有 `PeerAuthentication STRICT`
- [ ] Rolling restart workload：`kubectl rollout restart deployment -n <ns>`
- [ ] 驗證 SVID 已由 SPIRE 簽發：
  ```bash
  kubectl exec -n <ns> <pod> -c istio-proxy -- \
    openssl x509 -in /run/secrets/workload-spiffe-uds/socket -noout -issuer 2>/dev/null || \
  istioctl proxy-config secret <pod> -n <ns>
  ```

### Phase 5：移除 cacerts Secret

- [ ] 確認所有 namespace 遷移完成
- [ ] `kubectl delete secret cacerts -n istio-system`

---

## 七、App 使用者需知

| 項目 | 架構一（原本） | 架構二（切換後）|
|---|---|---|
| Pod label | 無需額外 label | 需加 `spiffe-managed: "true"` |
| Pod annotation | 無需額外 annotation | 需加 `inject.istio.io/templates: "sidecar,spire"` |
| ServiceAccount | 正常使用 | 正常使用（SA 名稱會出現在 SPIFFE ID 中） |
| AuthorizationPolicy principal | `cluster.local/ns/<ns>/sa/<sa>` | `<trustDomain>/ns/<ns>/sa/<sa>` |
| PeerAuthentication | PERMISSIVE 可運作 | 必須 STRICT |
| mTLS 行為 | 自動（無感知） | 自動（無感知，cert 由 SPIRE 簽發） |
| cert 輪替 | 無感知，istiod 自動 | 無感知，SPIRE Agent 自動 |

> **對 app 使用者影響最大的是**：Pod 需加兩個標記，以及 AuthorizationPolicy principal 格式變更。其餘 mTLS 行為對 app 程式碼完全透明。

---

## 八、Istio 維護者驗證清單

切換完成後逐項確認：

```bash
# 1. istio-ingressgateway CSI volume 已掛載
kubectl get pod -n istio-system -l app=istio-ingressgateway \
  -o jsonpath='{.items[0].spec.volumes}' | jq '.[] | select(.name=="workload-socket")'

# 2. Workload SVID 由 SPIRE 簽發（issuer 應含 SPIRE 字樣）
istioctl proxy-config secret <pod> -n <ns> -o json | \
  jq '.dynamicActiveSecrets[].name'

# 3. mTLS 連線正常（確認 STRICT 模式下可互通）
kubectl exec -n <ns> <client-pod> -- curl -s http://<service>.<ns>.svc.cluster.local

# 4. AuthorizationPolicy 生效（正確 principal 可通，錯誤應 403）
# 參考 Envoy access log：rbac_access_denied_matched_policy[none] 代表 principal 不對

# 5. 確認 cacerts Secret 已不存在（或已廢棄）
kubectl get secret cacerts -n istio-system 2>/dev/null && echo "尚未移除" || echo "已移除"
```

---

## 九、切換後的維護成本考量

切換完成後，需要決定 **Istio 維護團隊的責任範圍**：

- **模式一**：Istio 團隊只維護 Istio，SPIRE 由獨立的 Platform / Security 團隊負責
- **模式二**：Istio 團隊同時維護 Istio 與 SPIRE

### Production 元件邊界

```
Istio 範疇                   SPIRE 範疇
───────────────────          ────────────────────────────────
istiod（2～3 replica）        SPIRE Server（3 replica，HA）
istio-ingressgateway          SPIRE Agent（DaemonSet，每 node）
sidecar injection template    SPIRE Controller Manager（1～2 replica）
PeerAuthentication            SPIFFE CSI Driver（DaemonSet，每 node）
AuthorizationPolicy           PostgreSQL（HA，SPIRE datastore）
Gateway resources             ClusterSPIFFEID CRD
```

### 責任範圍

| 維護項目 | 模式一（Istio 團隊）| 模式一（SPIRE 團隊）| 模式二（Istio 團隊全包）|
|---|---|---|---|
| istiod 升級與健康 | ✅ | — | ✅ |
| IstioOperator / Helm values | ✅ | — | ✅ |
| Sidecar injection template | ✅ | — | ✅ |
| PeerAuthentication / AuthorizationPolicy | ✅ | — | ✅ |
| Gateway 部署（含 post-renderer）| ✅ | — | ✅ |
| SPIRE Server 升級與健康 | — | ✅ | ✅ |
| SPIRE Agent DaemonSet | — | ✅ | ✅ |
| SPIFFE CSI Driver | — | ✅ | ✅ |
| ClusterSPIFFEID 維護 | 🟡 協調 | ✅ | ✅ |
| Trust domain 設定 | 🟡 協調 | ✅ | ✅ |
| PostgreSQL 備份與 HA | — | ✅（或 DBA）| 🟡 依賴 DBA |
| mTLS 全鏈路 on-call | 🔴 受限 | 🔴 受限 | ✅ 完整 |

### 模式一：Istio 只維護 Istio

**Istio 團隊日常：** istiod 升級、sidecar injection template 管理、PeerAuthentication / AuthorizationPolicy、Gateway 部署（含 post-renderer）。

**依賴 SPIRE 團隊：** ClusterSPIFFEID 異動、trust domain 管理、SPIRE 升級計畫通知、SPIRE 掛掉的 SLA。

**風險點：**

| 風險 | 說明 |
|---|---|
| **mTLS 中斷根因在 SPIRE 側** | Istio 團隊排查數層後才確認是 SPIRE 問題，延誤恢復 |
| **SPIRE 升級未提前通知** | CSI Driver 介面或 SPIFFE ID 格式異動，Istio 層 cert 取得失敗 |
| **SLA 不對齊** | SPIRE 掛掉 1h 後 mTLS 全斷，但 SPIRE 團隊 SLA 是 4h 恢復 |
| **ClusterSPIFFEID 漏建** | 新 namespace 上線但 SPIRE 未建 entry，SVID 拿不到，難以判斷責任歸屬 |
| **跨團隊 Debug 效率低** | On-call 凌晨需喚醒另一個團隊才能繼續排查 |

**最低防護：**
```
① 定義清楚 Runbook：Istio 層確認完後如何 escalate 給 SPIRE 團隊
② SPIRE 升級需提前通知 Istio 團隊（至少 1 sprint 前）
③ 共用監控 dashboard：Istio 團隊可看到 SPIRE Agent 健康狀態
④ SPIRE SLA：Server 掛掉的 RTO 需 < SVID TTL（1h）
```

### 模式二：Istio 團隊同時維護 Istio + SPIRE

**額外需要維護：** SPIRE Server / Agent / Controller Manager 升級（三者版本需一致）、SPIFFE CSI Driver、ClusterSPIFFEID 全生命週期、SPIRE on-call、trust bundle 備份、PostgreSQL 監控。

**額外需要的知識：**
```
SPIFFE / SPIRE 核心概念（trust domain、SVID、ClusterSPIFFEID、SDS）
SPIRE Server 操作（entry 管理、bundle 匯出、healthcheck）
SPIRE Agent 行為（lazy SVID、attestation、socket lifecycle）
PostgreSQL 基本維運（連線監控、備份驗證、HA failover）
```

**優勢：** 完整 end-to-end debug，不需跨團隊等待；升級計畫完全掌控。

**風險點：**

| 風險 | 說明 |
|---|---|
| **人力稀釋** | 兩個複雜系統由同一團隊維護，知識廣度要求極高 |
| **知識孤島** | SPIRE 知識集中少數成員，人員異動造成斷層 |
| **On-call 範圍擴大** | SPIRE Server 掛掉也是自己的 on-call |
| **SPIRE 問題擠佔 Istio 維護時間** | Incident 頻繁時排擠 Istio 日常改善 |

**最低防護：**
```
① 建立 SPIRE 知識文件與 Runbook，避免知識孤島
② SPIRE on-call 輪班納入正式排班
③ PostgreSQL 備份與 DR 演練至少每季一次
④ SPIRE / Istio 升級前在 staging 完整驗證版本相容性
```

### Debug 路徑比較

**模式一** 接到 mTLS 告警：

```
mTLS 失敗 → Istio 層確認 → SVID 確認 → CSI volume 確認
  ⛔ 到此轉交 SPIRE 團隊 → Agent log → entry 確認 → PostgreSQL 連線
```

**模式二** 接到 mTLS 告警：

```
mTLS 失敗 → Istio 層確認 → SVID 確認 → CSI volume → CSI Driver
  → Agent log → entry 確認 → ClusterSPIFFEID 匹配 → PostgreSQL 連線
  ✅ 全程自行排查
```

### 成本總覽

| 面向 | 模式一：Istio 專責 | 模式二：Istio + SPIRE 統一 |
|---|---|---|
| 日常維運範圍 | 🟢 小 | 🔴 大（+SPIRE、+PostgreSQL）|
| 知識深度要求 | 🟢 Istio 專精 | 🔴 Istio + SPIRE + DB |
| On-call 責任範圍 | 🟢 Istio 層 | 🔴 全鏈路 |
| 升級複雜度 | 🟢 低 | 🔴 高（三元件版本協調）|
| Debug 完整性 | 🔴 受限（需轉交）| 🟢 完整 |
| mTLS incident 恢復速度 | 🔴 慢（跨團隊）| 🟢 快 |
| 跨團隊依賴風險 | 🔴 高 | 🟢 低 |
| 人力稀釋風險 | 🟢 低 | 🔴 高 |
| 知識孤島風險 | 🟢 低 | 🔴 高 |
