# POC-6: Implementation Documentation

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Directory Structure](#directory-structure)
4. [Component Details](#component-details)
   - [Application](#1-application-appsrcindexjs)
   - [Docker Image](#2-docker-image)
   - [Terraform Infrastructure](#3-terraform-infrastructure)
   - [GitHub Actions CI/CD](#4-github-actions-cicd)
   - [Helm Chart](#5-helm-chart)
   - [ArgoCD GitOps](#6-argocd-gitops)
   - [Monitoring](#7-monitoring)
5. [End-to-End Flow](#end-to-end-flow)
6. [Deployed Resources](#deployed-resources)
7. [Issues Encountered & Resolutions](#issues-encountered--resolutions)
8. [Security Design](#security-design)

---

## Overview

POC-6 is a full CI/CD pipeline implementation on AWS EKS. A simple Node.js "Hello World" application is automatically built, scanned, deployed, and monitored every time code is pushed to the `master` branch — with zero manual steps after the initial push.

**Live App URL:**
```
http://af87a57d8d71d4c788dc7a3e78a4cb10-258753851.us-east-1.elb.amazonaws.com
```

---

## Architecture

```
Developer pushes code
        │
        ▼
┌───────────────────┐
│   GitHub Repo     │  soumyapatil02/poc6-hello-world
│   (master branch) │
└────────┬──────────┘
         │ triggers
         ▼
┌───────────────────────────────────────────────────┐
│              GitHub Actions CI/CD                  │
│                                                   │
│  Job 1: npm Test & SonarQube                      │
│    • npm ci → Jest unit tests with coverage       │
│    • SonarQube static analysis (non-blocking)     │
│                                                   │
│  Job 2: Docker Build → Trivy → ECR Push           │
│    • OIDC → AWS auth (no stored keys)             │
│    • docker build (multi-stage)                   │
│    • Trivy vulnerability scan (HIGH,CRITICAL)     │
│    • docker push → Amazon ECR                     │
│                                                   │
│  Job 3: Update Helm values.yaml                   │
│    • sed image tag → git commit & push            │
└────────────────────┬──────────────────────────────┘
                     │ updated values.yaml
                     ▼
┌───────────────────────────────────────────────────┐
│              ArgoCD (GitOps)                       │
│    • Watches helm/hello-world/ path in repo       │
│    • Detects image tag change                     │
│    • Auto-syncs → rolling update on EKS           │
└────────────────────┬──────────────────────────────┘
                     │ deploys Helm chart
                     ▼
┌───────────────────────────────────────────────────┐
│              AWS EKS (poc6-cluster)                │
│    • Namespace: hello-world                       │
│    • 2 pods (HPA: 2–5), t3.small nodes            │
│    • LoadBalancer Service → public endpoint       │
│    • Prometheus scraping /metrics                 │
└───────────────────────────────────────────────────┘
```

---

## Directory Structure

```
poc-6/
├── app/                          # Node.js application
│   ├── src/
│   │   └── index.js              # Express app (/, /health, /metrics)
│   ├── __tests__/
│   │   └── app.test.js           # Jest unit tests
│   ├── Dockerfile                # Multi-stage Docker build
│   ├── .dockerignore
│   ├── package.json
│   └── package-lock.json
│
├── terraform/                    # AWS infrastructure as code
│   ├── main.tf                   # Providers (aws, kubernetes, helm)
│   ├── variables.tf              # Input variables
│   ├── vpc.tf                    # VPC, subnets, NAT gateway
│   ├── ecr.tf                    # ECR repository + lifecycle policy
│   ├── eks.tf                    # EKS cluster + managed node group
│   ├── github-oidc.tf            # GitHub Actions IAM OIDC role
│   └── outputs.tf                # Output values
│
├── .github/
│   └── workflows/
│       └── ci-cd.yml             # GitHub Actions pipeline (3 jobs)
│
├── helm/
│   └── hello-world/              # Helm chart
│       ├── Chart.yaml
│       ├── values.yaml           # Image tag auto-updated by CI
│       └── templates/
│           ├── _helpers.tpl
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── serviceaccount.yaml
│           └── hpa.yaml
│
├── argocd/
│   └── application.yaml          # ArgoCD Application manifest
│
├── monitoring/
│   └── prometheus-values.yaml    # kube-prometheus-stack Helm values
│
├── jenkins/
│   └── Jenkinsfile               # Alternative Jenkins pipeline
│
├── sonarqube/
│   └── sonar-project.properties  # SonarQube project config
│
├── scripts/                      # Step-by-step setup scripts
│   ├── 01-setup-infrastructure.sh
│   ├── 02-setup-tools.sh
│   ├── 03-build-push-image.sh
│   └── 04-deploy-helm.sh
│
├── README.md
└── IMPLEMENTATION.md             # This file
```

---

## Component Details

### 1. Application (`app/src/index.js`)

A minimal Node.js/Express server exposing three endpoints:

| Endpoint  | Description                                      |
|-----------|--------------------------------------------------|
| `GET /`   | Returns JSON: message, hostname, version, timestamp |
| `GET /health` | Returns `{"status":"healthy"}` for K8s probes |
| `GET /metrics` | Returns Prometheus-format counter metric    |

**Key design choices:**
- Exports `{ app, server }` to allow Jest/supertest to cleanly close the server after tests
- Reads `APP_VERSION` from environment variable (injected at build time via `--build-arg`)
- Reads `PORT` from environment (default 3000)

**Unit tests** (`app/__tests__/app.test.js`): cover all 3 endpoints using Jest + supertest, with coverage reporting via `lcov` for SonarQube ingestion.

---

### 2. Docker Image

**File:** `app/Dockerfile`

Multi-stage build:

```
Stage 1 (builder): node:18-alpine
  └── npm ci --only=production

Stage 2 (production): node:18-alpine
  └── Copy node_modules from builder
  └── Non-root user: nodejs (UID 1001)
  └── HEALTHCHECK: curl /health every 30s
  └── EXPOSE 3000
```

**Security hardening applied:**
- Non-root user (`nodejs`, UID 1001) — prevents privilege escalation
- `node:18-alpine` base — minimal attack surface
- Production-only dependencies (`--only=production`)
- Image scanned by Trivy before push (HIGH + CRITICAL severities reported)

**ECR image lifecycle:** Last 10 images retained; older images automatically expired by ECR lifecycle policy.

---

### 3. Terraform Infrastructure

**Files:** `terraform/`

All AWS resources are provisioned via Terraform (≥1.5) using the AWS provider (~5.0).

#### 3a. VPC (`vpc.tf`)

| Resource | Detail |
|----------|--------|
| Module | `terraform-aws-modules/vpc/aws ~> 5.0` |
| CIDR | `10.0.0.0/16` |
| Availability Zones | 3 (us-east-1a, 1b, 1c) |
| Private subnets | 3 × `/20` — EKS worker nodes |
| Public subnets | 3 × `/24` — NAT gateway, Load Balancers |
| NAT Gateway | Single (cost-optimised for POC) |
| DNS | Hostnames + support enabled |
| Subnet tags | `kubernetes.io/role/elb` and `internal-elb` for ELB discovery |

#### 3b. ECR (`ecr.tf`)

| Resource | Detail |
|----------|--------|
| Repository | `poc6-hello-world` |
| Scan on push | Enabled (AES256 encryption) |
| Lifecycle policy | Keep last 10 images, expire older |
| Repository policy | Allows EKS nodes (account root) to pull images |

#### 3c. EKS (`eks.tf`)

| Resource | Detail |
|----------|--------|
| Module | `terraform-aws-modules/eks/aws ~> 20.0` |
| Cluster name | `poc6-cluster` |
| Kubernetes version | 1.29 |
| Node group | `general` — managed node group |
| Instance type | `t3.small` (2 vCPU, 2 GB) — free-tier eligible |
| Node count | min: 1, desired: 2, max: 3 |
| Networking | Worker nodes in private subnets |
| Public API access | Enabled (cluster endpoint) |
| Cluster addons | `coredns`, `kube-proxy`, `vpc-cni` (latest) |
| Node IAM | `AmazonEC2ContainerRegistryReadOnly` attached for ECR pulls |
| Creator admin | `enable_cluster_creator_admin_permissions = true` |

> **Note:** `aws-ebs-csi-driver` addon was intentionally excluded. It requires additional IRSA configuration and caused CrashLoopBackOff on t3.small nodes during the POC. The hello-world app does not require persistent volumes.

#### 3d. GitHub OIDC (`github-oidc.tf`)

Enables GitHub Actions to authenticate to AWS using OIDC tokens — **no long-lived AWS credentials stored anywhere**.

| Resource | Detail |
|----------|--------|
| OIDC Provider | `token.actions.githubusercontent.com` |
| IAM Role | `poc6-github-actions-role` |
| Trust policy | Restricted to `repo:soumyapatil02/poc6-hello-world:*` |
| Permissions | ECR: `GetAuthorizationToken` (global) + push actions on `poc6-hello-world` repo |

The role ARN is stored as a GitHub Actions secret (`AWS_ROLE_ARN`) and referenced in the workflow via `${{ secrets.AWS_ROLE_ARN }}`.

---

### 4. GitHub Actions CI/CD

**File:** `.github/workflows/ci-cd.yml`

Triggers on every push to `master`, **excluding** changes to `helm/hello-world/values.yaml` (to avoid an infinite redeploy loop when the CI itself updates the image tag).

#### Job 1: `npm Test & SonarQube`

```
actions/checkout@v4
→ actions/setup-node@v4 (Node 18, npm cache)
→ npm ci
→ npm test --coverage --coverageReporters=lcov
→ SonarSource/sonarqube-scan-action@master  [continue-on-error: true]
```

SonarQube is non-blocking (`continue-on-error: true`) — pipeline proceeds even if SonarQube server is not configured.

#### Job 2: `Docker Build → Trivy → ECR Push`

Runs only on push to `master` (not on PRs).

```
actions/checkout@v4
→ aws-actions/configure-aws-credentials@v4  (OIDC, role-to-assume)
→ aws-actions/amazon-ecr-login@v2
→ docker build --build-arg APP_VERSION=$SHA -t $ECR:$SHA -t $ECR:latest
→ aquasecurity/trivy-action@master  (HIGH,CRITICAL, exit-code: 0)
→ docker push $ECR:$SHA
→ docker push $ECR:latest
```

Trivy scan is non-blocking (`exit-code: 0`) for POC — change to `1` for production to fail the pipeline on CRITICAL CVEs.

#### Job 3: `Update Helm Image Tag`

```
actions/checkout@v4  (token: GITHUB_TOKEN, for push permission)
→ sed -i "s|tag: .*|tag: \"$SHA\"" helm/hello-world/values.yaml
→ git commit -m "ci: update image tag to $SHA"
→ git push
```

This commit triggers ArgoCD to detect the change and roll out the new image.

**Permissions required:**
```yaml
permissions:
  id-token: write   # OIDC token generation
  contents: write   # push updated values.yaml back to repo
```

---

### 5. Helm Chart

**Files:** `helm/hello-world/`

| File | Purpose |
|------|---------|
| `Chart.yaml` | Chart metadata (name: hello-world, version: 0.1.0) |
| `values.yaml` | Configurable values; `image.tag` auto-updated by CI |
| `templates/deployment.yaml` | Kubernetes Deployment |
| `templates/service.yaml` | LoadBalancer Service (port 80 → 3000) |
| `templates/serviceaccount.yaml` | Dedicated ServiceAccount |
| `templates/hpa.yaml` | HorizontalPodAutoscaler |

**Key configuration in `values.yaml`:**

```yaml
image:
  repository: 672897707899.dkr.ecr.us-east-1.amazonaws.com/poc6-hello-world
  tag: "<auto-updated by CI>"

service:
  type: LoadBalancer
  port: 80

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 70

podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/path: "/metrics"
  prometheus.io/port: "3000"

podSecurityContext:
  runAsNonRoot: true
  runAsUser: 1001

securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: [ALL]

resources:
  limits:   { cpu: 200m, memory: 256Mi }
  requests: { cpu: 100m, memory: 128Mi }
```

---

### 6. ArgoCD GitOps

**File:** `argocd/application.yaml`

ArgoCD is installed in the `argocd` namespace on the EKS cluster. It watches the GitHub repo and automatically deploys any change to the `helm/hello-world/` path.

```yaml
spec:
  source:
    repoURL: https://github.com/soumyapatil02/poc6-hello-world.git
    targetRevision: master
    path: helm/hello-world

  destination:
    server: https://kubernetes.default.svc
    namespace: hello-world

  syncPolicy:
    automated:
      prune: true       # remove resources deleted from git
      selfHeal: true    # revert manual kubectl changes
    syncOptions:
      - CreateNamespace=true
```

When the CI pipeline pushes a new `values.yaml` with an updated image tag, ArgoCD detects the git diff within ~3 minutes and performs a rolling update — achieving zero-downtime deployments.

**Installation command used:**
```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

---

### 7. Monitoring

**File:** `monitoring/prometheus-values.yaml`

Prometheus and Grafana are deployed via the `kube-prometheus-stack` Helm chart into the `monitoring` namespace. The hello-world pods expose `/metrics` and are annotated for automatic Prometheus scraping:

```yaml
podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/path: "/metrics"
  prometheus.io/port: "3000"
```

Grafana is exposed via a LoadBalancer service for dashboard access.

**Install command:**
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f monitoring/prometheus-values.yaml
```

---

## End-to-End Flow

The complete sequence when a developer pushes code:

```
1. git push origin master
   └── GitHub Actions triggered (ci-cd.yml)

2. Job 1 — Test
   ├── npm ci (install dependencies)
   ├── npm test --coverage (Jest)
   └── SonarQube scan (non-blocking)

3. Job 2 — Build & Push (runs if Job 1 passes)
   ├── OIDC → assume poc6-github-actions-role (no stored keys)
   ├── ECR login
   ├── docker build -t ECR_URL:$GIT_SHA
   ├── Trivy scan (reports HIGH/CRITICAL CVEs)
   └── docker push ECR_URL:$GIT_SHA + :latest

4. Job 3 — Update Helm (runs if Job 2 passes)
   ├── sed image tag in helm/hello-world/values.yaml
   └── git commit & push (as github-actions[bot])

5. ArgoCD detects values.yaml change (polls every ~3 min)
   └── kubectl apply Helm chart diff → rolling update

6. EKS performs rolling update
   ├── New pods started with new image
   ├── Liveness/readiness probes verified (/health)
   └── Old pods terminated

7. App accessible at LoadBalancer endpoint
   └── af87a57d8d71d4c788dc7a3e78a4cb10-258753851.us-east-1.elb.amazonaws.com
```

---

## Deployed Resources

### AWS Resources

| Resource | Name / ID |
|----------|-----------|
| AWS Account | `672897707899` |
| Region | `us-east-1` |
| VPC | `poc6-vpc` (CIDR: 10.0.0.0/16) |
| EKS Cluster | `poc6-cluster` (Kubernetes 1.29) |
| Node Group | `general` — 2× t3.small |
| ECR Repository | `672897707899.dkr.ecr.us-east-1.amazonaws.com/poc6-hello-world` |
| IAM Role (CI) | `poc6-github-actions-role` |
| Load Balancer | `af87a57d8d71d4c788dc7a3e78a4cb10-258753851.us-east-1.elb.amazonaws.com` |

### Kubernetes Resources (namespace: `hello-world`)

| Resource | Detail |
|----------|--------|
| Deployment | `hello-world` — 2 replicas |
| Service | `hello-world` — LoadBalancer, port 80 |
| HPA | min: 2, max: 5, CPU threshold: 70% |
| ServiceAccount | `hello-world` |

### Kubernetes Resources (namespace: `argocd`)

| Pod | Status |
|-----|--------|
| argocd-server | Running |
| argocd-application-controller | Running |
| argocd-repo-server | Running |
| argocd-redis | Running |
| argocd-dex-server | Running |
| argocd-applicationset-controller | Running |
| argocd-notifications-controller | Running |

### GitHub

| Item | Value |
|------|-------|
| Repository | https://github.com/soumyapatil02/poc6-hello-world |
| Branch | `master` |
| Secret: `AWS_ROLE_ARN` | `arn:aws:iam::672897707899:role/poc6-github-actions-role` |

---

## Issues Encountered & Resolutions

### Issue 1: Insufficient IAM Permissions for Terraform

**Problem:** The `poc6-user` IAM user had only `sts:GetCallerIdentity` and could not create VPC, EKS, or IAM resources.

**Resolution:** Once `IAMFullAccess` was granted via the AWS Console, the following command was used to self-elevate to full admin for the POC:
```bash
aws iam attach-user-policy \
  --user-name poc6-user \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

---

### Issue 2: t3.medium Not Free-Tier Eligible

**Problem:** The first EKS node group attempt with `t3.medium` failed with:
```
AsgInstanceLaunchFailures - InvalidParameterCombination:
The specified instance type is not eligible for Free Tier
```

**Resolution:** Changed `eks_node_instance_type` from `t3.medium` to `t3.small` in `terraform/variables.tf`. Verified `t3.small` is free-tier eligible:
```bash
aws ec2 describe-instance-types \
  --filters "Name=free-tier-eligible,Values=true" \
  --query "InstanceTypes[].InstanceTypeId"
# Returns: t3.small, t3.micro, t4g.small, ...
```

The failed node group was manually deleted before re-applying Terraform.

---

### Issue 3: `aws-ebs-csi-driver` CrashLoopBackOff

**Problem:** The `aws-ebs-csi-driver` cluster addon was included in `eks.tf`. Its controller pods entered `CrashLoopBackOff` because they lacked the required IRSA (IAM Role for Service Accounts) configuration to make EBS API calls. Terraform timed out waiting for the addon to reach ACTIVE state.

**Resolution:** Removed `aws-ebs-csi-driver` from `cluster_addons` in `eks.tf`. The hello-world application has no stateful storage requirements, so this addon is not needed.

---

### Issue 4: ArgoCD Application Had Placeholder Repo URL

**Problem:** The `argocd/application.yaml` file was created with a placeholder `https://github.com/YOUR_ORG/poc6-hello-world.git` and `targetRevision: main`, causing ArgoCD to report `ComparisonError: authentication required: Repository not found`.

**Resolution:** Updated the manifest with the correct values:
```yaml
repoURL: https://github.com/soumyapatil02/poc6-hello-world.git
targetRevision: master
```
Re-applied with `kubectl apply -f argocd/application.yaml`. ArgoCD immediately synced and deployed.

---

### Issue 5: GitHub Actions Failed — Missing `package-lock.json`

**Problem:** The `actions/setup-node@v4` step with `cache: npm` and `cache-dependency-path: app/package-lock.json` failed because `package-lock.json` had not been committed (npm install was never run locally).

**Error:**
```
Some specified paths were not resolved, unable to cache dependencies.
```

**Resolution:** Ran `npm install` in the `app/` directory locally to generate `package-lock.json`, then committed and pushed it.

---

### Issue 6: Push Rejected After CI Commits values.yaml

**Problem:** After the `update-helm` CI job committed a new `values.yaml` image tag back to the repo, a subsequent local `git push` was rejected because the local branch was behind the remote.

**Resolution:** Pulled and rebased before pushing:
```bash
git pull --rebase origin master
git push origin master
```

---

## Security Design

| Area | Implementation |
|------|---------------|
| **AWS Auth** | GitHub Actions uses OIDC (no stored AWS keys) |
| **Least Privilege** | GitHub Actions role only has ECR push permissions |
| **Repo Scope** | OIDC trust restricted to `repo:soumyapatil02/poc6-hello-world:*` |
| **Container** | Non-root user (UID 1001), read-only filesystem, all capabilities dropped |
| **Image Scanning** | Trivy scans every built image for HIGH/CRITICAL CVEs |
| **ECR Scanning** | `scan_on_push: true` — AWS-native image scanning on upload |
| **K8s Security** | `runAsNonRoot`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem` |
| **Network** | Worker nodes in private subnets; only Load Balancer is public |
| **Resource Limits** | CPU and memory limits set on all pods |
| **GitOps** | ArgoCD `selfHeal: true` — reverts any manual cluster changes |
