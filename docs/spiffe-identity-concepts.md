# SPIFFE Identity 概念說明

SPIFFE ID、SPIRE Entry、ClusterSPIFFEID 三個概念的關係與在本 PoC 中的實作方式。

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
