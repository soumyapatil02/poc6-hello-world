#!/usr/bin/env bash
# POC-6 | Step 4: Deploy hello-world to EKS via Helm (manual/fallback)
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
IMAGE_TAG="${IMAGE_TAG:-latest}"
NAMESPACE="hello-world"

echo "=== POC-6: Helm Deploy ==="

# Ensure kubeconfig is set
CLUSTER_NAME=$(cd "$(dirname "$0")/../terraform" && terraform output -raw eks_cluster_name 2>/dev/null || echo "poc6-cluster")
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install hello-world "$(dirname "$0")/../helm/hello-world" \
  --namespace $NAMESPACE \
  --set image.repository="$ECR_REGISTRY/poc6-hello-world" \
  --set image.tag="$IMAGE_TAG" \
  --wait --timeout=3m

echo ""
APP_LB=$(kubectl -n $NAMESPACE get svc hello-world -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending...")
echo "App URL: http://$APP_LB"
echo "kubectl get pods -n $NAMESPACE"
kubectl get pods -n $NAMESPACE
