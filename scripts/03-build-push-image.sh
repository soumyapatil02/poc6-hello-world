#!/usr/bin/env bash
# POC-6 | Step 3: Manually build & push Docker image to ECR (dev/test use)
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
ECR_REPO="poc6-hello-world"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo 'latest')}"

echo "=== POC-6: Docker Build & Push ==="
echo "Registry : $ECR_REGISTRY/$ECR_REPO:$IMAGE_TAG"

# Login to ECR
echo "[1/4] Logging in to ECR..."
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

# Build
echo "[2/4] Building Docker image..."
cd "$(dirname "$0")/../app"
docker build -t "$ECR_REGISTRY/$ECR_REPO:$IMAGE_TAG" -t "$ECR_REGISTRY/$ECR_REPO:latest" .

# Trivy scan
echo "[3/4] Running Trivy security scan..."
trivy image --severity HIGH,CRITICAL --exit-code 0 "$ECR_REGISTRY/$ECR_REPO:$IMAGE_TAG"

# Push
echo "[4/4] Pushing to ECR..."
docker push "$ECR_REGISTRY/$ECR_REPO:$IMAGE_TAG"
docker push "$ECR_REGISTRY/$ECR_REPO:latest"

echo ""
echo "Image pushed: $ECR_REGISTRY/$ECR_REPO:$IMAGE_TAG"
echo "Run 04-deploy-helm.sh to deploy to EKS."
