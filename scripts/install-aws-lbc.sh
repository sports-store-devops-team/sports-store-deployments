#!/usr/bin/env bash

set -euo pipefail

CHART_VERSION="1.14.0"
CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-}"
IAM_ROLE_ARN="${IAM_ROLE_ARN:-}"

usage() {
  cat <<'EOF'
Usage:
  install-aws-lbc.sh --cluster-name NAME --region REGION --iam-role-arn ARN

Alternatively set CLUSTER_NAME, AWS_REGION, and IAM_ROLE_ARN.
Obtain IAM_ROLE_ARN from Terraform with:
  terraform -chdir=../sports-store-infrastructure/terraform output -raw aws_load_balancer_controller_iam_role_arn
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --cluster-name)
      [[ $# -ge 2 ]] || { printf 'Error: --cluster-name requires a value.\n' >&2; exit 1; }
      CLUSTER_NAME="$2"
      shift 2
      ;;
    --region)
      [[ $# -ge 2 ]] || { printf 'Error: --region requires a value.\n' >&2; exit 1; }
      AWS_REGION="$2"
      shift 2
      ;;
    --iam-role-arn)
      [[ $# -ge 2 ]] || { printf 'Error: --iam-role-arn requires a value.\n' >&2; exit 1; }
      IAM_ROLE_ARN="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Error: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

for command_name in aws kubectl helm; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'Error: required command not found: %s\n' "${command_name}" >&2
    exit 1
  fi
done

[[ -n "${CLUSTER_NAME}" ]] || { printf 'Error: cluster name is required.\n' >&2; exit 1; }
[[ -n "${AWS_REGION}" ]] || { printf 'Error: AWS region is required.\n' >&2; exit 1; }
[[ -n "${IAM_ROLE_ARN}" ]] || { printf 'Error: IAM role ARN is required.\n' >&2; exit 1; }

if [[ ! "${IAM_ROLE_ARN}" =~ ^arn:aws[a-zA-Z-]*:iam::[0-9]{12}:role/.+ ]]; then
  printf 'Error: IAM role ARN is not in the expected IAM role format.\n' >&2
  exit 1
fi

aws sts get-caller-identity >/dev/null
printf 'Verified the selected AWS identity.\n'

cluster_status="$(aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --query 'cluster.status' \
  --output text)"

if [[ "${cluster_status}" != "ACTIVE" ]]; then
  printf 'Error: the selected EKS cluster is not ACTIVE.\n' >&2
  exit 1
fi

aws eks update-kubeconfig \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" >/dev/null

kubectl cluster-info >/dev/null
kubectl get namespace kube-system >/dev/null
printf 'Verified cluster reachability.\n'

helm repo add eks https://aws.github.io/eks-charts --force-update
helm repo update eks

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --version "${CHART_VERSION}" \
  --set-string clusterName="${CLUSTER_NAME}" \
  --set-string region="${AWS_REGION}" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set-string "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${IAM_ROLE_ARN}" \
  --wait \
  --timeout 10m

kubectl wait \
  --namespace kube-system \
  --for=condition=Available \
  deployment/aws-load-balancer-controller \
  --timeout=10m

printf 'AWS Load Balancer Controller is Available.\n'
