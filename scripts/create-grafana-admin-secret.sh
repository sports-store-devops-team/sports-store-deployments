#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [[ $# -ne 1 ]]; then
  echo "Usage: EXPECTED_KUBE_CONTEXT=<context> $0 <namespace>" >&2
  exit 64
fi

namespace=$1
if [[ ! $namespace =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "Refusing invalid Kubernetes namespace: $namespace" >&2
  exit 64
fi

: "${EXPECTED_KUBE_CONTEXT:?Set EXPECTED_KUBE_CONTEXT to the exact intended kubectl context}"
current_context=$(kubectl config current-context)
if [[ $current_context != "$EXPECTED_KUBE_CONTEXT" ]]; then
  echo "Refusing context mismatch: expected '$EXPECTED_KUBE_CONTEXT', current '$current_context'" >&2
  exit 65
fi

kubectl --context "$EXPECTED_KUBE_CONTEXT" get namespace "$namespace" >/dev/null
command -v openssl >/dev/null

password=$(openssl rand -hex 32)
trap 'unset password' EXIT

kubectl --context "$EXPECTED_KUBE_CONTEXT" --namespace "$namespace" \
  create secret generic monitoring-grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal="admin-password=$password" \
  --dry-run=client -o yaml |
  kubectl --context "$EXPECTED_KUBE_CONTEXT" --namespace "$namespace" apply -f -
