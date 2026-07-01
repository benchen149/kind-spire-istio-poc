# Workload Identity 架構說明

SPIFFE ID、SPIRE Entry、ClusterSPIFFEID、agent.sock 的概念與運作方式，以及 Istio 自管 CA 與 SPIRE 作為 CA 兩種架構的比較。

---

## SPIFFE ID

**workload 的身份名稱**，格式是固定的 URI：

```
spiffe://poc.internal/ns/istio-validation/sa/payment-gateway-sa
│         │            └─────────────── path（身份路徑）────────────┘
│         └── trust domain（組織 / 叢集邊界，設定後不可更改）
└── scheme（固定為 spiffe）
```

特性：

- 全域唯一，跨服務、跨叢集皆可辨識
- 以 **URI SAN** 的形式嵌入 X.509 憑證（SVID），mTLS 握手時帶出
- Istio 強制規定格式為 `spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>`，不可客製化

本 PoC 的實際 SPIFFE ID：

```
spiffe://poc.internal/ns/istio-validation/sa/validation-gateway-sa
spiffe://poc.internal/ns/istio-validation/sa/payment-gateway-sa
spiffe://poc.internal/ns/istio-validation/sa/payment-core-sa
```

---

## SPIRE Entry

**SPIRE Server 裡的一筆註冊記錄**，定義「哪個 workload 有資格取得哪個 SPIFFE ID」。

Entry 的核心欄位：

| 欄位 | 說明 | 範例 |
|---|---|---|
| SPIFFE ID | 此 entry 對應的身份 | `spiffe://poc.internal/ns/istio-validation/sa/payment-gateway-sa` |
| Parent ID | 哪個 SPIRE Agent 可代為核發 | `spiffe://poc.internal/spire/agent/k8s_psat/...` |
| Selector | workload 必須符合的條件 | `k8s:ns:istio-validation`, `k8s:sa:payment-gateway-sa` |
| TTL | SVID 有效期（秒） | `3600` |

**沒有 Entry → SPIRE Server 拒絕簽發 → Envoy 拿不到 cert → mTLS 無法建立。**

### 簽發流程

```
Envoy 啟動
  → 透過 CSI socket 向 SPIRE Agent 請求 SVID
    → Agent 向 SPIRE Server 查詢：此 pod 的 namespace / SA 有 entry 嗎？
      → Server 找到符合的 Entry（selector 比對通過）
        → Server 簽發 X.509 cert，URI SAN = SPIFFE ID
          → Envoy 持有 SVID，可進行 mTLS 握手
```

### SVID 輪替

SVID 到期前，SPIRE Agent 主動推送新 cert 給 Envoy（熱換），連線不中斷。

---

## ClusterSPIFFEID

**SPIRE Controller Manager 的 CRD**，宣告式地定義「哪些 pod 要自動建立 SPIRE Entry、SPIFFE ID 如何產生」。

Controller Manager watch 所有 pod 的建立 / 刪除事件，依 ClusterSPIFFEID 的規則自動向 SPIRE Server 新增或清除 Entry，不需要手動管理。

### 本 PoC 的 ClusterSPIFFEID

```yaml
# 一般 workload（spiffe-managed=true 的 namespace + pod）
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: istio-workloads
spec:
  spiffeIDTemplate: "spiffe://poc.internal/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels:
      spiffe-managed: "true"
  namespaceSelector:
    matchExpressions:
      - key: spiffe-managed
        operator: In
        values: ["true"]
---
# istio-system ingress gateway（istio-system 不能加 spiffe-managed label，需獨立宣告）
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: istio-ingressgateway
spec:
  spiffeIDTemplate: "spiffe://poc.internal/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels:
      app: istio-ingressgateway
  namespaceSelector:
    matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: In
        values: ["istio-system"]
```

### 欄位說明

**`spiffeIDTemplate`**

Go template，動態產生 SPIFFE ID。可用的欄位：

| 變數 | 說明 |
|---|---|
| `.PodMeta.Namespace` | pod 所在 namespace |
| `.PodMeta.Name` | pod 名稱 |
| `.PodMeta.Labels` | pod labels（用 `index .PodMeta.Labels "key"` 取值） |
| `.PodSpec.ServiceAccountName` | pod 使用的 ServiceAccount 名稱 |

**`podSelector`**

只有符合條件的 pod 才會被建立 Entry。本 PoC 用 `spiffe-managed: "true"` 作為 opt-in label。

**`namespaceSelector`**

只有符合條件的 namespace 內的 pod 才會被建立 Entry。與 podSelector 是 **AND** 關係，兩者都必須符合。

### 雙層 selector 的用意

防止 namespace 管理員在未授權的 namespace 內為任意 pod 申請 SPIFFE identity：

```
namespace 有 spiffe-managed=true   ← namespace 管理員授權
  AND
pod 有 spiffe-managed=true         ← workload 明確 opt-in
  → Controller Manager 自動建立 SPIRE Entry
```

---

## agent.sock（SPIFFE Workload API Socket）

SPIRE Agent 啟動後建立一個 **Unix Domain Socket（UDS）**，workload 透過它與 Agent 通訊取得 SVID。

### 路徑鏈

```
SPIRE Agent（DaemonSet，每個 node 一個）
  └── 建立 UDS：/run/spire/agent-sockets/spire-agent.sock（hostPath）
        │
        ▼  SPIFFE CSI Driver 將 socket bind mount 進 pod
pod 內路徑：/run/secrets/workload-spiffe-uds/socket
        │
        ▼  Envoy 透過 CA_ADDR 連線
CA_ADDR=unix:///run/secrets/workload-spiffe-uds/socket
```

pod 內看到的檔名是 `socket`（由 CSI Driver spec 決定），不是原始的 `spire-agent.sock`。

### Socket 上跑的協定

Socket 上運行 **SPIFFE Workload API**（gRPC），Envoy 作為 client 呼叫：

| gRPC 方法 | 用途 |
|---|---|
| `FetchX509SVID` | 取得 X.509 格式的 SVID（mTLS 用） |
| `FetchJWTSVID` | 取得 JWT 格式的 SVID（HTTP Bearer token 用） |
| `FetchX509Bundles` | 取得 trust bundle（驗對方 cert 用） |

### SPIRE Agent 如何驗證 caller

Agent 收到請求時，透過 Linux kernel 機制確認呼叫方身份：

| 驗證方式 | 說明 |
|---|---|
| UID / GID | 確認 process 的使用者 |
| PID | 查 `/proc/<pid>/` 取得 cgroup、namespace 資訊 |
| cgroup | 比對 k8s pod cgroup 路徑，確認是哪個 pod |

驗證通過後，Agent 向 SPIRE Server 查詢是否有符合的 Entry，有則簽發 SVID 回傳。

### 為什麼用 CSI Driver 而非 hostPath 直接掛

| 方式 | 問題 |
|---|---|
| hostPath 直接掛 socket | 所有 pod 都能存取，無法限制特定 workload |
| SPIFFE CSI Driver | 每次 pod 啟動時動態 provision，只掛給有需要的 pod；配合 `spiffe-managed=true` label 控制範圍 |

---

## 三者關係總結

```
ClusterSPIFFEID
  └── 定義規則（哪些 pod → 什麼 SPIFFE ID）
        │
        ▼  Controller Manager 監聽 pod 事件，依規則自動操作
SPIRE Entry（存在 SPIRE Server）
  └── 記錄「此 workload 有資格取得此 SPIFFE ID」
        │
        ▼  Envoy 透過 CSI socket 請求，Server 比對 Entry 後簽發
SPIFFE ID（嵌入 X.509 SVID）
  └── workload 的身份，在 mTLS 握手時出示給對方驗證
```

---

## Istio 自管 CA vs SPIRE 作為 CA

CA（Certificate Authority）= 憑證授權機構，負責簽發 X.509 workload cert 的服務。架構一由 istiod 擔任 CA，架構二由外部 SPIRE Server 擔任 CA。

| 比較項目 | 架構一：Istio 自管 CA（cacerts） | 架構二：SPIRE 作為 CA（本 PoC） |
|---|---|---|
| **Workload cert 簽發者** | istiod（載入 cacerts Secret） | SPIRE Server |
| **xDS TLS 簽發者** | istiod（同一個 CA） | istiod self-signed（獨立，不受影響） |
| **cacerts Secret** | 🔴 需要手動建立與管理 | 🟢 不需要 |
| **SVID 輪替**（cert 到期前自動換新，連線不中斷） | 🟡 自動，預設 TTL 24 小時 | 🟢 自動，預設 TTL 1 小時（暴露窗口更小） |
| **信任範圍** | 🔴 限於單一 Istio mesh | 🟢 跨 k8s、VM、裸機皆可 |
| **跨叢集身份驗證** | 🔴 需手動共享 root CA | 🟢 SPIRE Federation（不共享私鑰） |
| **非 k8s workload** | 🔴 不支援 | 🟢 支援（SPIRE 原生能力） |
| **整體元件數** | 🟢 少（僅 Istio） | 🔴 多（+ SPIRE Server / Agent / Controller Manager / CSI Driver） |
| **SPIRE Server HA** | 🟢 不適用 | 🔴 Production 需要（PostgreSQL backend） |
| **Helm gateway 部署** | 🟢 標準，無額外步驟 | 🔴 需要 post-renderer（chart 不原生支援 CSI volume） |
| **debug 複雜度** | 🟢 低 | 🔴 較高（多一條 SPIRE → CSI → Envoy SDS 路徑） |
| **外部系統驗證 workload 身份** | 🔴 困難（信任根不對外） | 🟢 可行（透過 SPIRE trust bundle） |
| **Signing CA 私鑰暴露窗口** | 🔴 Intermediate CA TTL（通常設 100 年，幾乎永久） | 🟢 ca_ttl（建議 24h，自動輪替） |
| **SPIRE Server 掛掉的容錯時間** | 🟢 不適用（istiod 掛掉容錯 24h） | 🔴 等於 SVID TTL（預設 1h） |
| **適用情境** | 純 k8s cluster | 混合環境、需要跨系統可驗證身份 |

---

## CA 憑證 TTL 設定整理

### 憑證鏈三層結構

```
Root CA（最長，離線保管）
  └── Signing CA / Intermediate CA（中等，自動或手動輪替）
        └── SVID / Workload Cert（最短，自動輪替）
```

**規則**：每層 TTL 必須明顯大於下一層，確保輪替期間不發生憑證空窗。

---

### 架構一：Istio 自管 CA（cacerts）

| 層級 | 預設值 | Production 建議 | 備註 |
|---|---|---|---|
| Root CA | 由你建立時決定 | 100 年 | 離線保管，輪替成本極高，長 TTL 降低操作風險 |
| Intermediate CA（`ca-cert.pem`） | 由你建立時決定 | 100 年 | 儲存於 k8s Secret，需人工輪替，與 Root CA 對齊 |
| Workload cert（SVID） | 24 小時 | 24 小時（維持預設） | istiod 自動輪替 |

> Intermediate CA 設 100 年雖操作簡便，但 `ca-key.pem` 長期存在於 k8s Secret 中，若私鑰被竊，攻擊者可偽造任意 workload cert 長達 100 年，無法透過輪替撤銷。

---

### 架構二：SPIRE 作為 CA（本 PoC）

| 層級 | 設定項目 | 本 PoC 值 | Production 建議（HA 到位） | Production 建議（HA 未到位） | 備註 |
|---|---|---|---|---|---|
| Root CA | SPIRE 預設 | `8760h`（1 年） | `87600h`（10 年） | `87600h`（10 年） | 輪替成本高，TTL 長降低操作風險 |
| Signing CA | `ca_ttl` | `168h`（7 天） | `24h` | `24h` | SPIRE 全自動輪替，短 TTL 無操作成本 |
| SVID（Workload cert） | `default_x509_svid_ttl` | `1h` | `1h`（安全優先） | `24h`（與 Istio 對齊） | HA 未到位時拉長以換取容錯時間 |

> **Signing CA `ca_ttl`** 不影響容錯時間（與可用性無關），建議維持 24h 安全設定。
> **SVID TTL** 是容錯窗口的直接決定因素：HA 未到位前建議設 24h 與架構一對齊，待 HA 穩定後再收回 1h。

---

### SPIRE Server 可用性對 SVID 的影響

```
SPIRE Server 掛掉
  → SPIRE Agent 無法更新 SVID
    → 現有 SVID 繼續有效，直到 TTL 到期
      → TTL 到期後 Envoy 無有效 cert → mTLS 失敗
```

| | SVID TTL = 1h | SVID TTL = 24h |
|---|---|---|
| 容錯時間 | ~1 小時 | ~24 小時（與 Istio 架構一對齊） |
| Signing CA 暴露窗口 | 1 小時 | 24 小時 |
| 新建 pod 能取得 SVID | 否 | 否 |
| istiod / xDS | 不受影響 | 不受影響 |

**Production 防護路線：**

```
Phase 1（HA 未到位）：SVID TTL = 24h，監控 SPIRE Server，掛掉立即告警並重啟
Phase 2（HA 到位）  ：SVID TTL 收回 1h，SPIRE Server 多副本 + PostgreSQL backend
```

---

### 架構二：SPIRE 災難還原備份項目

SPIRE Server 持有整條憑證鏈的核心資料，需備份以下項目：

| 備份項目 | 內容 | 重要性 | 備份方式 |
|---|---|---|---|
| **Datastore**（sqlite3 / PostgreSQL） | Signing CA 私鑰、trust bundle、所有 entries、node attestation records | 🔴 最關鍵 | 定期快照；PostgreSQL 用標準 DB backup |
| **Trust bundle** | Root CA 公鑰，Agent bootstrap 與 federation 需要 | 🔴 關鍵 | `spire-server bundle show` 匯出，離線保存 |
| **keys.json** | SPIRE Server 用於簽發 Signing CA 的私鑰 | 🔴 關鍵 | 與 Datastore 同目錄，一併備份 |
| **server.conf** | SPIRE Server 設定檔 | 🟡 中 | 已在 git（`spire-server/server.conf`） |
| **ClusterSPIFFEID CRD** | Entry 自動建立規則 | 🟡 中 | 已在 git（`spire/cluster-spiffeid.yaml`） |

**本 PoC 實際資料位置：**

啟動腳本（`01-start-spire-server.sh`）會將 `spire-server/server.conf` 中的 `/opt/spire` 路徑替換為 `$SPIRE_HOME`（預設 `~/.local/share/spire/`）再啟動：

```
~/.local/share/spire/data/server/
├── datastore.sqlite3          # 主資料庫（entries、CA 資料、trust bundle）
├── datastore.sqlite3-shm      # SQLite WAL shared memory
├── datastore.sqlite3-wal      # SQLite Write-Ahead Log
├── journal.pem                # CA 憑證歷史紀錄
└── keys.json                  # Server 私鑰（權限 600）
```

Trust bundle 匯出：

```bash
spire-server bundle show \
  -socketPath /tmp/spire-server/private/api.sock \
  > trust-bundle.pem
```

**⚠️ `make clean` 注意：**

`make clean` 只清除 `/tmp/spire-server/`（socket），**不清除** `~/.local/share/spire/data/`。
若需要從 0 完整重置（清除 CA 資料重新 bootstrap），需額外執行：

```bash
rm -rf ~/.local/share/spire/data/
```

**還原優先順序：**

```
1. 還原 Datastore（含 keys.json）→ SPIRE Server 可完整重啟，所有 entries 保留
2. 若 Datastore 遺失 → 還原 trust bundle，重新 bootstrap SPIRE Server
   → Controller Manager 會自動重建所有 entries（依 ClusterSPIFFEID）
   → 需重新分發新 trust bundle 給所有 federated 方
3. 若全部遺失 → 完整重新 bootstrap，影響範圍最大
```

> **Production**：sqlite3 不支援多副本，需改用 PostgreSQL 並啟用定期備份。`keys.json` 建議額外存放於 KMS 或 HSM，不應僅依賴檔案系統備份。

---

## 維護成本比較：Istio 單獨 vs Istio + SPIRE

以 **Production 架構**為基準的維護成本、考量點與風險點比較。

### Production 架構前提

| | 架構一：Istio 自管 CA | 架構二：Istio + SPIRE |
|---|---|---|
| istiod | 2～3 replica | 2～3 replica |
| SPIRE Server | 不需要 | 3 replica（HA）|
| SPIRE Datastore | 不需要 | PostgreSQL HA（非 SQLite3）|
| SPIRE Agent | 不需要 | DaemonSet（每個 node）|
| SPIRE Controller Manager | 不需要 | 1～2 replica |
| SPIFFE CSI Driver | 不需要 | DaemonSet（每個 node）|
| cacerts Secret | 需要（人工管理）| 不需要 |

---

### 元件數量與升級複雜度

架構一需要維護的元件只有 istiod，升級跟隨 Istio release cycle。

架構二需要額外維護：

```
SPIRE Server + Agent + Controller Manager（三者版本需一致，不可各自獨立升級）
SPIFFE CSI Driver（獨立 release cycle，需與 kernel CSI 介面相容）
PostgreSQL（DB 版本升級、schema migration 相容性）
```

- SPIRE 與 Istio 無官方版本相容矩陣，升級前需自行在 staging 驗證
- PostgreSQL 升級需確認 SPIRE schema migration 相容性
- SPIFFE CSI Driver 與 Linux kernel CSI 介面相依，節點 kernel 升級可能影響

---

### CA 憑證管理成本

| 操作 | 架構一 | 架構二 |
|---|---|---|
| Intermediate / Signing CA 輪替 | 🔴 人工，每 1～3 年 | 🟢 全自動（ca_ttl，建議 24h）|
| Workload cert 輪替 | 🟢 自動（24h TTL）| 🟢 自動（1h TTL）|
| CA 私鑰保護 | 🔴 k8s Secret 明文 base64 | 🟡 keys.json（建議搭配 KMS/HSM）|
| DB 備份 | 🟢 不需要 | 🔴 PostgreSQL 定期備份 + trust bundle 離線備份 |

架構一的 Intermediate CA 通常設 100 年，`ca-key.pem` 以 base64 長期存於 k8s Secret，有 cluster admin 權限即可讀取，私鑰長期暴露無法透過輪替撤銷。架構二的 Signing CA 每 24h 自動輪替，私鑰暴露窗口大幅縮小。

---

### 可用性與 HA 需求

**架構一**：istiod 掛掉後，現有 workload SVID 撐 24h（SVID TTL）。

**架構二** SPIRE Server 失效影響鏈：

```
SPIRE Server 全掛 → Agent 無法更新 SVID
  → SVID TTL 到期（1h）→ Envoy cert 失效 → 所有 mTLS 連線中斷
```

| | 架構一 | 架構二 |
|---|---|---|
| 額外 DB HA 需求 | 🟢 不需要 | 🔴 PostgreSQL HA（primary + standby）|
| DaemonSet 監控 | 🟢 不需要 | 🔴 Agent + CSI Driver（每 node 狀態）|
| CA 服務掛掉容錯時間 | 🟢 24h | 🔴 1h（HA 未到位前）|

架構二的可用性門檻比架構一更高：PostgreSQL HA 成為整個 mTLS 架構的關鍵依賴，HA 未到位前容錯僅 1h。

---

### Observability 與 Debug 複雜度

**架構一** cert 問題排查路徑：

```
mTLS 失敗 → istioctl proxy-config secret → 確認 istiod 狀態（2～3 層）
```

**架構二** cert 問題排查路徑：

```
mTLS 失敗
  → SVID 是否存在（istioctl proxy-config secret）
    → CSI volume 是否掛載（kubectl describe pod）
      → SPIFFE CSI Driver 是否正常（DaemonSet pod 狀態）
        → SPIRE Agent 是否連接 Server（Agent log）
          → SPIRE entry 是否存在（spire-server entry show）
            → ClusterSPIFFEID selector 是否匹配
              → SPIRE Server 與 PostgreSQL 連線（6～8 層）
```

| | 架構一 | 架構二 |
|---|---|---|
| 排查層數 | 2～3 層 | 6～8 層 |
| On-call 需要的知識 | Istio | Istio + SPIFFE/SPIRE + PostgreSQL |
| 跨團隊協作 | 🟢 低（Istio 團隊自理）| 🔴 高（Istio + SPIRE + DBA 三方）|

---

### 跨團隊依賴與組織風險

架構二的 Istio 可用性依賴於：

```
SPIRE 維護團隊（Server SLA、ClusterSPIFFEID 維護、trust domain 管理）
DBA / Platform 團隊（PostgreSQL 可用性與備份）
Security 團隊（KMS / HSM，keys.json 保護）
```

**組織風險**：
- SPIRE 團隊與 Istio 團隊 SLA 未對齊時，發生 incident 責任歸屬模糊
- SPIRE 升級計畫若未提前通知 Istio 團隊，可能造成相容性問題
- **trust domain 一旦設定不可更改**，若初始設定錯誤，重建成本極高

---

### 維護成本總覽

| 面向 | 架構一 | 架構二 | 差異 |
|---|---|---|---|
| 日常維運元件數 | 1 | 5～6 | 🔴 顯著增加 |
| 升級複雜度 | 低 | 高（版本矩陣自行維護）| 🔴 顯著增加 |
| CA 輪替人工成本 | 中 | 低（全自動）| 🟢 架構二較佳 |
| HA 建置成本 | 低 | 高（需 PostgreSQL HA）| 🔴 顯著增加 |
| CA 服務容錯時間 | 24h | 1h（HA 未到位前）| 🔴 架構二劣勢 |
| Debug 複雜度 | 低（2～3 層）| 高（6～8 層）| 🔴 顯著增加 |
| On-call 知識需求 | Istio | Istio + SPIRE + DB | 🔴 增加 |
| 跨團隊依賴 | 無 | SPIRE + DBA + Security | 🔴 增加 |
| App 部署規範 | 簡單 | 需額外兩個標記 | 🟡 輕度增加 |
| Signing CA 暴露窗口 | 100 年 | 24h | 🟢 架構二顯著優勢 |
| 跨系統身份驗證 | 不支援 | 支援（SPIRE Federation）| 🟢 架構二優勢 |

---

### 決策建議

**選擇架構一的條件：**
- 純 k8s 環境，無跨系統身份驗證需求
- 沒有獨立 Platform / Security 團隊，人力有限
- 希望 on-call 責任範圍單純，避免跨團隊依賴

**選擇架構二的條件：**
- 有 VM、裸機、多叢集等混合環境，需要統一身份
- 有獨立的 Platform 團隊可負責 SPIRE + PostgreSQL 維運
- 安全要求高，Signing CA 私鑰暴露窗口需控制在 24h 以內

**若選擇架構二，最低建議：**

```
① SPIRE Server HA（3 replica + PostgreSQL HA）就緒後才全面切換
② SVID TTL 在 HA 未到位前設 24h，到位後收回 1h
③ 建立跨團隊 Runbook：SPIRE outage 時誰負責、SLA 多少、Istio 側如何緊急應對
④ PostgreSQL 定期備份 + trust bundle 離線備份納入 DR 演練
⑤ SPIRE / Istio 升級前在 staging 完整驗證版本相容性
```
