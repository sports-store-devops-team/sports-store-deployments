#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SIBLING_ROOT="$(cd -- "${REPOSITORY_DIR}/.." && pwd)"

for command_name in docker minikube kubectl helm; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'Error: required command not found: %s\n' "${command_name}" >&2
    exit 1
  fi
done

if ! minikube status >/dev/null 2>&1; then
  printf 'Error: Minikube is not running. Start it before building images.\n' >&2
  exit 1
fi

images=(
  "sports-store/frontend:0.1.0"
  "sports-store/gateway:0.2.0"
  "sports-store/auth-service:0.1.0"
  "sports-store/catalog-service:0.1.0"
  "sports-store/cart-service:0.1.0"
  "sports-store/order-service:0.1.0"
  "sports-store/payment-service:0.1.0"
)

repositories=(
  "sports-store-frontend"
  "sports-store-gateway"
  "sports-store-auth-service"
  "sports-store-catalog-service"
  "sports-store-cart-service"
  "sports-store-order-service"
  "sports-store-payment-service"
)

for repository_name in "${repositories[@]}"; do
  repository_path="${SIBLING_ROOT}/${repository_name}"
  if [[ ! -d "${repository_path}" ]]; then
    printf 'Error: sibling repository not found: %s\n' "${repository_path}" >&2
    exit 1
  fi
  if [[ ! -f "${repository_path}/Dockerfile" ]]; then
    printf 'Error: Dockerfile not found: %s/Dockerfile\n' "${repository_path}" >&2
    exit 1
  fi
done

for index in "${!images[@]}"; do
  image="${images[$index]}"
  repository_path="${SIBLING_ROOT}/${repositories[$index]}"

  printf 'Building %s from %s\n' "${image}" "${repository_path}"
  docker build --tag "${image}" "${repository_path}"

  printf 'Loading %s into Minikube\n' "${image}"
  minikube image load "${image}"
done

minikube_images="$(minikube image ls)"
missing_images=()

for image in "${images[@]}"; do
  if ! grep -Fqx -- "${image}" <<<"${minikube_images}" && \
     ! grep -Fqx -- "docker.io/${image}" <<<"${minikube_images}"; then
    missing_images+=("${image}")
  fi
done

if (( ${#missing_images[@]} > 0 )); then
  printf 'Error: these exact image tags are missing from Minikube:\n' >&2
  printf '  %s\n' "${missing_images[@]}" >&2
  exit 1
fi

printf 'Verified all seven application image tags in Minikube.\n'
