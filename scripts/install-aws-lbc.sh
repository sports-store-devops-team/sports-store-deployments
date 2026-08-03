#!/bin/bash
set -e

CLUSTER_NAME="<YOUR_CLUSTER_NAME>"
REGION="<YOUR_AWS_REGION>"

echo "Installing AWS Load Balancer Controller for cluster $CLUSTER_NAME in $REGION..."

helm repo add eks https://aws.github.io/eks-charts
helm repo update eks

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=$REGION

echo "AWS Load Balancer Controller installation initiated."
