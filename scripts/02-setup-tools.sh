#!/usr/bin/env bash
# POC-6 | Step 2: Install ArgoCD, monitoring stack on EKS
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
NAMESPACE_ARGOCD="argocd"
NAMESPACE_MONITORING="monitoring"

echo "=== POC-6: Tools & Monitoring Setup ==="

# --- Add Helm repos ---
echo "[1/5] Adding Helm repos..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# --- Install ArgoCD ---
echo "[2/5] Installing ArgoCD..."
kubectl create namespace $NAMESPACE_ARGOCD --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd argo/argo-cd \
  --namespace $NAMESPACE_ARGOCD \
  --set server.service.type=LoadBalancer \
  --wait --timeout=5m

echo "Waiting for ArgoCD server..."
kubectl wait --for=condition=available deployment/argocd-server \
  -n $NAMESPACE_ARGOCD --timeout=120s

ARGOCD_PASSWORD=$(kubectl -n $NAMESPACE_ARGOCD get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
ARGOCD_LB=$(kubectl -n $NAMESPACE_ARGOCD get svc argocd-server \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "ArgoCD URL  : https://$ARGOCD_LB"
echo "ArgoCD user : admin"
echo "ArgoCD pass : $ARGOCD_PASSWORD"

# --- Install Prometheus + Grafana ---
echo "[3/5] Installing kube-prometheus-stack..."
kubectl create namespace $NAMESPACE_MONITORING --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace $NAMESPACE_MONITORING \
  -f "$(dirname "$0")/../monitoring/prometheus-values.yaml" \
  --wait --timeout=10m

GRAFANA_LB=$(kubectl -n $NAMESPACE_MONITORING get svc prometheus-grafana \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Grafana URL  : http://$GRAFANA_LB"
echo "Grafana user : admin"
echo "Grafana pass : poc6-grafana-admin"

# --- Deploy ArgoCD Application ---
echo "[4/5] Applying ArgoCD Application manifest..."
kubectl apply -f "$(dirname "$0")/../argocd/namespace.yaml"
kubectl apply -f "$(dirname "$0")/../argocd/application.yaml"

echo "[5/5] Done!"
echo ""
echo "Next step: Configure Jenkins with the Jenkinsfile at jenkins/Jenkinsfile"
echo "Jenkins credentials needed:"
echo "  - aws-credentials      (AWS Access Key/Secret)"
echo "  - argocd-server-url    (Secret text: $ARGOCD_LB)"
echo "  - argocd-auth-token    (ArgoCD API token)"
echo "  - SonarQube server     (SonarQube in Jenkins System Config)"
