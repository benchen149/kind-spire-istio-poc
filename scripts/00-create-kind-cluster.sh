#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

kind create cluster --config "$REPO_ROOT/kind/kind-config.yaml"
kubectl cluster-info --context kind-spire-istio-poc
