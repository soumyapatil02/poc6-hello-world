#!/usr/bin/env bash
# POC-6 | Step 1: Provision AWS infrastructure via Terraform
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT="poc6"

echo "=== POC-6: Terraform Infrastructure Setup ==="
echo "Region: $AWS_REGION | Account: $(aws sts get-caller-identity --query Account --output text)"

# --- Terraform init & apply ---
cd "$(dirname "$0")/../terraform"

echo "[1/3] Initializing Terraform..."
terraform init

echo "[2/3] Planning..."
terraform plan -var="aws_region=$AWS_REGION" -out=tfplan

echo "[3/3] Applying..."
terraform apply tfplan

echo ""
echo "=== Outputs ==="
terraform output

# Configure kubectl
CLUSTER_NAME=$(terraform output -raw eks_cluster_name)
echo ""
echo "Configuring kubectl for cluster: $CLUSTER_NAME"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

echo ""
echo "Infrastructure ready. Run 02-setup-tools.sh next."
