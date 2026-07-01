# kind-spire-istio-poc

PoC: External SPIRE as Istio mTLS CA on Kind, with OPA Gatekeeper enforcement

架構細節請參閱 [docs/spire-istio-poc-summary.md](docs/spire-istio-poc-summary.md)。

---

## 快速開始

```bash
make        # 等同 make all，完整建立 PoC 環境
```

執行順序：Kind cluster → SPIRE Server/Agent/Controller Manager → OPA Gatekeeper → Istio → 測試 workload

---

## Make Targets

| Target | 說明 |
|--------|------|
| `make` / `make all` | 完整 PoC 環境建立（依序執行所有步驟） |
| `make cluster` | 建立 Kind cluster |
| `make spire` | 啟動 SPIRE Server、Agent、Controller Manager |
| `make gatekeeper` | 安裝 OPA Gatekeeper 與 Constraints |
| `make istio` | 安裝 Istio（SPIFFE CSI Driver + SDS 整合） |
| `make deploy` | 部署測試 workload 並驗證 |
| `make check` | Sanity check：驗證整體 PoC 架構是否正確建立 |
| `make status` | 查看各元件運行狀態 |
| `make clean` | 刪除 Kind cluster 並清理背景 process |
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

**直接執行 script**（不透過 make）：

```bash
SPIRE_VERSION=1.10.0 ./scripts/01-start-spire-server.sh
```

未帶環境變數時，script 會自動 fallback 到內建預設值。

---

## 目錄結構

```
.
├── Makefile                    # 單一進入點
├── versions.env                # 元件版本設定
├── kind/                       # Kind cluster 設定
├── scripts/                    # 各步驟部署腳本（00~06）
├── spire-server/               # SPIRE Server 設定
├── spire/                      # SPIRE Agent Helm values、ClusterSPIFFEID
├── istio/                      # Istio Operator 設定
├── gatekeeper/
│   ├── constraint-templates/   # OPA ConstraintTemplate CRD
│   └── constraints/            # OPA Constraint 規則
├── test/                       # 測試用 workload（good/bad）
└── docs/                       # 架構文件與圖表
```
