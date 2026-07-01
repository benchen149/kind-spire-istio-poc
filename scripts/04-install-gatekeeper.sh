#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install gatekeeper gatekeeper/gatekeeper \
  --namespace gatekeeper-system \
  --create-namespace \
  --version 3.18.2 \
  --set replicas=1 \
  --set auditInterval=60

kubectl wait pod --for=condition=ready -n gatekeeper-system -l gatekeeper.sh/operation=webhook --timeout=120s

kubectl apply -f "$REPO_ROOT/gatekeeper/constraint-templates/"
sleep 3
kubectl apply -f "$REPO_ROOT/gatekeeper/constraints/"

kubectl get constrainttemplates
kubectl get constraints -A
