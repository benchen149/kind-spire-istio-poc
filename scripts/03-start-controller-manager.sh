#!/usr/bin/env bash
# 啟動 SPIRE Controller Manager（與 SPIRE Server 同機 host 執行）
# 官方 spire-controller-manager 僅支援與 SPIRE Server 同機透過本地 UDS 通訊，
# 因此本 PoC 讓它跑在 host 上，透過 kubeconfig 遠端管理 Kind cluster 內的資源。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM_HOME="/opt/spire-controller-manager"
IMAGE="ghcr.io/spiffe/spire-controller-manager:0.6.6"

mkdir -p "$CM_HOME/conf"
cp "$REPO_ROOT/spire/controller-manager-config.yaml" "$CM_HOME/conf/config.yaml"

docker rm -f spire-controller-manager >/dev/null 2>&1 || true

docker run -d --name spire-controller-manager \
  --network host \
  -e ENABLE_WEBHOOKS=false \
  -e KUBECONFIG=/kubeconfig \
  -v "$CM_HOME/conf/config.yaml:/config.yaml:ro" \
  -v /opt/spire/conf/server/kubeconfig:/kubeconfig:ro \
  -v /tmp/spire-server/private:/tmp/spire-server/private \
  "$IMAGE" \
  --config /config.yaml

sleep 3
docker logs spire-controller-manager --tail 40
