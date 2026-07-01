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
