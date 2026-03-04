# POC-6: Full CI/CD Pipeline on AWS EKS

## Architecture

```
GitHub → Jenkins → SonarQube → npm test → Trivy → Docker → ECR
                                                              ↓
Terraform → EKS ← ArgoCD ←────────────────── Helm values (image tag)
                ↑
         Prometheus + Grafana (monitoring)
```

## Components

| Component      | Role                                  |
|----------------|---------------------------------------|
| GitHub         | Source code & Helm values repository  |
| Jenkins        | CI/CD orchestration                   |
| SonarQube      | Static code analysis / quality gate   |
| npm / Jest     | Build & unit tests                    |
| Aqua Trivy     | Container image vulnerability scan    |
| Docker         | Image build                           |
| AWS ECR        | Container registry                    |
| AWS EKS        | Kubernetes cluster                    |
| Helm           | Kubernetes package manager            |
| Argo CD        | GitOps continuous delivery            |
| Prometheus     | Metrics collection                    |
| Grafana        | Metrics visualization                 |
| Terraform      | Infrastructure as Code                |

## Quick Start

### Prerequisites
- AWS CLI authenticated (`aws sts get-caller-identity`)
- Terraform ≥ 1.5
- kubectl, helm, docker installed
- Trivy installed (`brew install aquasecurity/trivy/trivy`)

### 1. Provision Infrastructure
```bash
bash scripts/01-setup-infrastructure.sh
```
Creates: VPC, EKS cluster (`poc6-cluster`), ECR repository (`poc6-hello-world`)

### 2. Install Tools on EKS
```bash
bash scripts/02-setup-tools.sh
```
Installs: ArgoCD, Prometheus, Grafana

### 3. Build & Push Docker Image (first time)
```bash
bash scripts/03-build-push-image.sh
```

### 4. Deploy via Helm (manual/fallback)
```bash
bash scripts/04-deploy-helm.sh
```

### 5. Configure Jenkins
1. Add the `jenkins/Jenkinsfile` as pipeline source in Jenkins
2. Set credentials:
   - `aws-credentials` — AWS Access Key + Secret
   - `argocd-server-url` — ArgoCD LoadBalancer hostname
   - `argocd-auth-token` — ArgoCD API token
   - `SonarQube` — SonarQube server (Manage Jenkins → Configure System)

## Directory Structure

```
poc-6/
├── app/                    # Node.js Hello World app
│   ├── src/index.js
│   ├── __tests__/
│   ├── package.json
│   └── Dockerfile
├── terraform/              # AWS infrastructure (VPC + ECR + EKS)
├── helm/hello-world/       # Helm chart for EKS deployment
├── jenkins/Jenkinsfile     # Full CI/CD pipeline
├── argocd/                 # ArgoCD Application manifests
├── monitoring/             # Prometheus + Grafana Helm values
├── sonarqube/              # SonarQube project config
└── scripts/                # Step-by-step setup scripts
```

## AWS Details
- Account: `672897707899`
- Region: `us-east-1`
- ECR: `672897707899.dkr.ecr.us-east-1.amazonaws.com/poc6-hello-world`
- EKS Cluster: `poc6-cluster`

## App Endpoints
| Path       | Description              |
|------------|--------------------------|
| `/`        | Hello World JSON response |
| `/health`  | Liveness/readiness probe  |
| `/metrics` | Prometheus metrics        |
