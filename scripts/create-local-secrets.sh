#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/local-secrets.env"
NAMESPACE="${1:-sports-store}"

for command_name in kubectl base64; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'Error: required command not found: %s\n' "${command_name}" >&2
    exit 1
  fi
done

if [[ ! -f "${ENV_FILE}" ]]; then
  if ! command -v openssl >/dev/null 2>&1; then
    printf 'Error: required command not found: openssl (needed to create local-secrets.env).\n' >&2
    exit 1
  fi

  umask 077
  generated_mongo_password="$(openssl rand -hex 24)"
  generated_jwt_secret="$(openssl rand -hex 32)"

  printf 'MONGO_ROOT_USERNAME=root\nMONGO_ROOT_PASSWORD=%s\nJWT_SECRET=%s\n' \
    "${generated_mongo_password}" "${generated_jwt_secret}" > "${ENV_FILE}"

  unset generated_mongo_password generated_jwt_secret
  printf 'Created protected local secret configuration at scripts/local-secrets.env.\n'
fi

if [[ ! "${NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || (( ${#NAMESPACE} > 63 )); then
  printf 'Error: namespace must be a valid Kubernetes DNS label.\n' >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

required_variables=(
  MONGO_ROOT_USERNAME
  MONGO_ROOT_PASSWORD
  JWT_SECRET
)

for variable_name in "${required_variables[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    printf 'Error: required variable %s is missing or empty in local-secrets.env.\n' "${variable_name}" >&2
    exit 1
  fi
done

if [[ "${MONGO_ROOT_USERNAME}" != "root" ]]; then
  printf 'Error: MONGO_ROOT_USERNAME must be exactly "root" to match mongodb.auth.rootUser in the Helm chart.\n' >&2
  exit 1
fi

if [[ ! "${MONGO_ROOT_PASSWORD}" =~ ^[A-Za-z0-9]+$ ]]; then
  printf 'Error: MONGO_ROOT_PASSWORD must contain only URL-safe alphanumeric characters.\n' >&2
  exit 1
fi

mongo_uri() {
  local database_name="$1"
  printf 'mongodb://%s:%s@sports-store-mongodb:27017/%s?authSource=admin' \
    "${MONGO_ROOT_USERNAME}" "${MONGO_ROOT_PASSWORD}" "${database_name}"
}

if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  printf 'Creating namespace %s\n' "${NAMESPACE}"
  kubectl create namespace "${NAMESPACE}"
fi

if kubectl get secret app-secrets --namespace "${NAMESPACE}" >/dev/null 2>&1; then
  existing_password_base64="$(
    kubectl get secret app-secrets \
      --namespace "${NAMESPACE}" \
      -o 'jsonpath={.data.mongodb-root-password}'
  )"
  configured_password_base64="$(printf '%s' "${MONGO_ROOT_PASSWORD}" | base64 | tr -d '\r\n')"

  if [[ "${existing_password_base64}" != "${configured_password_base64}" ]]; then
    printf 'Error: refusing to update Secret app-secrets because its existing mongodb-root-password differs from local-secrets.env.\n' >&2
    printf 'Changing the Secret alone does not change the password stored in an initialized MongoDB PVC. Restore the matching local value or use a planned database password-rotation procedure.\n' >&2
    exit 1
  fi
fi

printf 'Creating or updating Secret app-secrets in namespace %s\n' "${NAMESPACE}"
kubectl create secret generic app-secrets \
  --namespace "${NAMESPACE}" \
  --from-literal=mongodb-root-password="${MONGO_ROOT_PASSWORD}" \
  --from-literal=MONGO_ROOT_USERNAME="${MONGO_ROOT_USERNAME}" \
  --from-literal=MONGO_ROOT_PASSWORD="${MONGO_ROOT_PASSWORD}" \
  --from-literal=JWT_SECRET="${JWT_SECRET}" \
  --from-literal=AUTH_MONGO_URI="$(mongo_uri auth_db)" \
  --from-literal=CATALOG_MONGO_URI="$(mongo_uri catalog_db)" \
  --from-literal=CART_MONGO_URI="$(mongo_uri cart_db)" \
  --from-literal=ORDER_MONGO_URI="$(mongo_uri order_db)" \
  --from-literal=PAYMENT_MONGO_URI="$(mongo_uri payment_db)" \
  --dry-run=client \
  -o yaml | kubectl apply -f -

printf 'Secret app-secrets is ready. Secret values were not displayed or written to disk.\n'
