#!/usr/bin/env bash
# 啟動本機 SPIRE Server（模擬文件中「外部 Ubuntu VM」的角色）
# PoC 環境無獨立 VM，改以背景 process 執行於 sandbox 本機，
# Kind cluster 內的 SPIRE Agent 透過 kind docker network 的 gateway IP 連線。
set -euo pipefail

SPIRE_VERSION="1.9.6"
SPIRE_HOME="/opt/spire"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$SPIRE_HOME"/bin "$SPIRE_HOME"/conf/server "$SPIRE_HOME"/data/server

if [ ! -x "$SPIRE_HOME/bin/spire-server" ]; then
  TMP_DIR=$(mktemp -d)
  curl -sL -o "$TMP_DIR/spire.tar.gz" \
    "https://github.com/spiffe/spire/releases/download/v${SPIRE_VERSION}/spire-${SPIRE_VERSION}-linux-amd64-musl.tar.gz"
  tar -xzf "$TMP_DIR/spire.tar.gz" -C "$TMP_DIR"
  cp "$TMP_DIR/spire-${SPIRE_VERSION}/bin/spire-server" "$SPIRE_HOME/bin/"
  cp "$TMP_DIR/spire-${SPIRE_VERSION}/bin/spire-agent" "$SPIRE_HOME/bin/"
  chmod +x "$SPIRE_HOME"/bin/*
  rm -rf "$TMP_DIR"
fi

# SPIRE Server 透過 kubeconfig 對 Kind API Server 做 TokenReview（k8s_sat node attestor）
kubectl config view --minify --flatten --raw > "$SPIRE_HOME/conf/server/kubeconfig"
chmod 600 "$SPIRE_HOME/conf/server/kubeconfig"

cp "$REPO_ROOT/spire-server/server.conf" "$SPIRE_HOME/conf/server/server.conf"

# 找出 kind docker network 的 gateway IP，供 Controller Manager / Agent 連線使用
KIND_GATEWAY=$(docker network inspect kind --format '{{(index .IPAM.Config 1).Gateway}}')
echo "SPIRE Server 將監聽 0.0.0.0:8082，Kind 內部請使用 gateway IP 連線：${KIND_GATEWAY}:8082"

nohup "$SPIRE_HOME/bin/spire-server" run -config "$SPIRE_HOME/conf/server/server.conf" \
  > "$SPIRE_HOME/spire-server.log" 2>&1 &
disown

sleep 3
"$SPIRE_HOME/bin/spire-server" healthcheck -socketPath /tmp/spire-server/private/api.sock
