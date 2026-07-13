# kind-spire-istio-poc

PoC: External SPIRE as Istio mTLS CA on Kind, with OPA Gatekeeper enforcement

---

## 文件

| 文件 | 內容 |
|------|------|
| [docs/poc-spire-istio-summary.md](docs/poc-spire-istio-summary.md) | PoC 實作參考、設計決策、驗證指令 |
| [docs/workload-identity-architecture.md](docs/workload-identity-architecture.md) | SPIFFE/SPIRE 概念架構、CA 比較、TTL 設定、DR 備份 |
| [docs/istio-spire-migration-spec.md](docs/istio-spire-migration-spec.md) | Istio 維護者遷移操作指南（切換流程、維護成本考量）|

---

## 快速開始

```bash
make        # 等同 make all，完整建立 PoC 環境
```

執行順序：Kind cluster → SPIRE Server / Agent / Controller Manager → OPA Gatekeeper → Istio → 測試 workload

---

## Make Targets

| Target | 說明 |
|--------|------|
| `make` / `make all` | 完整 PoC 環境建立（依序執行所有步驟）|
| `make cluster` | 建立 Kind cluster |
| `make spire` | 啟動 SPIRE Server、Agent、Controller Manager |
| `make gatekeeper` | 安裝 OPA Gatekeeper 與 Constraints |
| `make istio` | 安裝 Istio（SPIFFE CSI Driver + SDS 整合）|
| `make deploy` | 部署測試 workload 並驗證 |
| `make check` | Sanity check：驗證整體 PoC 架構是否正確建立 |
| `make status` | 查看各元件運行狀態 |
| `make clean` | 刪除 Kind cluster、停止背景 process、清除 SPIRE Server 資料 |
| `make help` | 顯示說明 |

---

## 版本管理

所有元件版本集中定義在 [`versions.env`](versions.env)：

```env
SPIRE_VERSION             = 1.9.6
SPIRE_CRDS_CHART_VERSION  = 0.5.0
SPIRE_AGENT_CHART_VERSION = 0.21.0
SPIRE_CM_VERSION          = 0.6.6
GATEKEEPER_VERSION        = 3.18.2
ISTIO_VERSION             = 1.29.4
```

**修改預設版本**：編輯 `versions.env` 後重新執行 `make`。

**CLI 臨時覆蓋**（不修改檔案）：

```bash
make SPIRE_VERSION=1.10.0
make GATEKEEPER_VERSION=3.19.0 gatekeeper
```

---

## 目錄結構

```
.
├── Makefile                    # 單一進入點
├── versions.env                # 元件版本設定
├── kind/                       # Kind cluster 設定
├── scripts/                    # 各步驟部署腳本（00～08）
├── spire-server/               # SPIRE Server 設定（server.conf）
├── spire/                      # SPIRE Agent Helm values、ClusterSPIFFEID
├── istio/                      # IstioOperator 設定、validation-gateway post-renderer
├── gatekeeper/
│   ├── constraint-templates/   # OPA ConstraintTemplate CRD
│   └── constraints/            # OPA Constraint 規則
├── test/                       # 測試用 workload（good / bad SA、PeerAuthentication、AuthorizationPolicy）
└── docs/                       # 架構文件（見上方文件表）
```
