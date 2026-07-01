SHELL     := /bin/bash
REPO_ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SCRIPTS   := $(REPO_ROOT)scripts

-include versions.env

# Defaults（versions.env 存在時由該檔覆蓋；CLI 可再覆蓋：make SPIRE_VERSION=1.10.0）
SPIRE_VERSION             ?= 1.9.6
SPIRE_CRDS_CHART_VERSION  ?= 0.5.0
SPIRE_AGENT_CHART_VERSION ?= 0.21.0
SPIRE_CM_VERSION          ?= 0.6.6
GATEKEEPER_VERSION        ?= 3.18.2
ISTIO_VERSION             ?= 1.29.4

# 安裝路徑（預設使用者家目錄，無需 sudo；可覆蓋：make SPIRE_HOME=/opt/spire）
SPIRE_HOME  ?= $(HOME)/.local/share/spire
CM_HOME     ?= $(HOME)/.local/share/spire-controller-manager
ISTIO_HOME  ?= $(HOME)/.local/share/istio

export SPIRE_VERSION SPIRE_CRDS_CHART_VERSION SPIRE_AGENT_CHART_VERSION SPIRE_CM_VERSION GATEKEEPER_VERSION ISTIO_VERSION
export SPIRE_HOME CM_HOME ISTIO_HOME

.PHONY: all cluster spire gatekeeper istio deploy check clean status help

.DEFAULT_GOAL := all

all: cluster spire gatekeeper istio deploy  ## 完整 PoC 環境建立（00 → 06）

cluster:  ## 建立 Kind cluster
	$(SCRIPTS)/00-create-kind-cluster.sh

spire:  ## 啟動 SPIRE Server、Agent、Controller Manager
	$(SCRIPTS)/01-start-spire-server.sh
	$(SCRIPTS)/02-install-spire-agent.sh
	$(SCRIPTS)/03-start-controller-manager.sh

gatekeeper:  ## 安裝 OPA Gatekeeper 與 Constraints
	$(SCRIPTS)/04-install-gatekeeper.sh

istio:  ## 安裝 Istio（SPIFFE CSI Driver + SDS 整合）
	$(SCRIPTS)/05-install-istio.sh

deploy:  ## 部署測試 workload 並驗證
	$(SCRIPTS)/06-deploy-test-workloads.sh
	$(SCRIPTS)/08-deploy-validation-gateway.sh

check:  ## 執行 sanity check，驗證整體 PoC 架構是否正確
	$(SCRIPTS)/07-sanity-check.sh

clean:  ## 刪除 Kind cluster 並清理背景 process
	-kind delete cluster --name spire-istio-poc
	-docker rm -f spire-controller-manager
	-pkill -f "spire-server run" || true

status:  ## 查看環境狀態
	@echo "=== Kind cluster ==="
	@kubectl cluster-info --context kind-spire-istio-poc 2>/dev/null || echo "  not running"
	@echo "=== SPIRE Server ==="
	@$(SPIRE_HOME)/bin/spire-server healthcheck -socketPath /tmp/spire-server/private/api.sock 2>/dev/null || echo "  not running"
	@echo "=== SPIRE Controller Manager ==="
	@docker ps --filter name=spire-controller-manager --format "  {{.Status}}" 2>/dev/null || echo "  not running"
	@echo "=== Gatekeeper ==="
	@kubectl get pods -n gatekeeper-system 2>/dev/null || echo "  not installed"

help:  ## 顯示此說明
	@grep -E '^[a-zA-Z_-]+:.*##' Makefile | \
	  awk 'BEGIN {FS = ":.*##"}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
