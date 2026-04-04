# K8s GitOps Manifests

Production-grade GitOps repository for Kubernetes managed by **ArgoCD** using the **App-of-Apps** pattern with **ApplicationSets**.

ArgoCD manages itself, all infrastructure, and all application workloads across **dev**, **stage**, and **prod** environments — with zero manual intervention after bootstrap.

---

## Architecture

```
┌───────────────────────────────────────────────────────────────┐
│                   Bootstrap (one-time)                         │
│   install.sh  →  ArgoCD + Root Application                    │
└──────────────────────┬────────────────────────────────────────┘
                       │  syncs
                       ▼
┌───────────────────────────────────────────────────────────────┐
│               Root App  →  argocd/ Helm chart                 │
│   (ArgoCD manages its own installation + configuration)       │
│                                                               │
│   Sync Wave -2: AppProjects  (infra, apps)                    │
│   Sync Wave -1: ApplicationSets  (infra, apps)                │
└────────────┬──────────────────────────┬───────────────────────┘
             │                          │
             ▼                          ▼
┌────────────────────────┐  ┌────────────────────────┐
│  Infra ApplicationSet  │  │  Apps ApplicationSet   │
│   matrix generator:    │  │   matrix generator:    │
│   git dirs × env list  │  │   git dirs × env list  │
└──────┬─────┬─────┬─────┘  └──────┬─────┬─────┬────┘
       │     │     │               │     │     │
       ▼     ▼     ▼               ▼     ▼     ▼
      dev  stage  prod            dev  stage  prod
```

## Key Concepts Demonstrated

| Concept | Implementation |
|---|---|
| **ArgoCD Self-Management** | Root Application points to `argocd/` Helm chart — ArgoCD manages its own installation |
| **App-of-Apps + ApplicationSets** | Matrix generator (git directory × environment list) auto-discovers components |
| **Helm Umbrella Charts** | Each component wraps an upstream chart as a dependency with per-env value overrides |
| **Multi-Cluster Deployment** | Environments target different Kubernetes clusters via the `cluster` field |
| **Sync Waves** | Ordered deployment: Projects (wave -2) → ApplicationSets (wave -1) → Apps (wave 0) |
| **AppProject RBAC** | Scoped permissions — infra project allows cluster resources, apps project restricts to namespaced |
| **Environment Promotion** | Prod tracks `main` branch; dev/stage track `HEAD` — promote by merging |
| **Prod Safety** | Production values have pinned image tags, HPA, PDB, topology spread constraints |
| **Resource Scaling** | Progressive resource allocation: dev (minimal) → stage (moderate) → prod (production-grade) |
| **ignoreDifferences** | Webhook `caBundle` fields excluded to prevent false drift detection |
| **Retry Policies** | Exponential backoff on sync failures (5s → 10s → 20s … up to 3m) |
| **ServerSideApply** | Enabled for CRD-heavy charts (cert-manager, prometheus) to avoid field ownership conflicts |

## Directory Structure

```
├── bootstrap/                          # One-time bootstrap resources
│   └── install.sh                      # Script to install ArgoCD + root app
│
├── argocd/                             # ArgoCD self-managed Helm umbrella chart
│   ├── Chart.yaml                      # Depends on argo-cd upstream chart
│   ├── values.yaml                     # Base values (RBAC, logging, metrics)
│   ├── values-dev.yaml                 # Dev: single replica, fast reconciliation
│   ├── values-stage.yaml               # Stage: 2 replicas, moderate settings
│   ├── values-prod.yaml                # Prod: HA, Redis HA, resource limits
│   └── templates/
│       ├── projects/
│       │   ├── infra.yaml              # AppProject for infrastructure
│       │   └── apps.yaml               # AppProject for applications
│       └── applicationsets/
│           ├── infra.yaml              # Auto-discovers infra/* directories
│           └── apps.yaml               # Auto-discovers apps/* directories
│
├── infra/                              # Infrastructure components
│   ├── cert-manager/                   # TLS certificate management
│   ├── kube-prometheus-stack/          # Monitoring (Prometheus + Grafana)
│   └── external-secrets/              # Secret management from cloud providers
│
└── apps/                               # Application workloads
    ├── frontend/                       # Frontend web application
    └── backend-api/                    # Backend API service
```

Each component under `infra/` and `apps/` follows the same pattern:
```
component/
├── Chart.yaml              # Umbrella chart (depends on upstream Helm chart)
├── values.yaml             # Base values shared across all environments
├── values-dev.yaml         # Dev environment overrides
├── values-stage.yaml       # Stage environment overrides
└── values-prod.yaml        # Prod environment overrides
```

## Getting Started

### Prerequisites

- Kubernetes cluster(s) with `kubectl` access
- [Helm 3](https://helm.sh/docs/intro/install/) installed
- Git repository accessible from the cluster

### Bootstrap

```bash
# 1. Clone this repository
git clone https://github.com/OWNER/k8s-gitops-manifests.git
cd k8s-gitops-manifests

# 2. Update argocd/values.yaml with your actual repo URL
#    global.repoURL: https://github.com/YOUR-ORG/k8s-gitops-manifests.git

# 3. Run the bootstrap script (one-time only!)
chmod +x bootstrap/install.sh
./bootstrap/install.sh https://github.com/YOUR-ORG/k8s-gitops-manifests.git HEAD dev

# 4. Access ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443

# 5. Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

After bootstrap, ArgoCD takes over — all subsequent changes are made via Git commits.

## How to Add a New Application

1. Create a new directory under `apps/` (or `infra/` for infrastructure):
   ```
   apps/my-new-app/
   ├── Chart.yaml
   ├── values.yaml
   ├── values-dev.yaml
   ├── values-stage.yaml
   └── values-prod.yaml
   ```

2. Define the `Chart.yaml` with your app's Helm chart as a dependency:
   ```yaml
   apiVersion: v2
   name: my-new-app
   type: application
   version: 1.0.0
   dependencies:
     - name: my-new-app
       version: "1.0.0"
       repository: "oci://ghcr.io/YOUR-ORG/helm-charts"
   ```

3. Commit and push — the ApplicationSet **automatically** detects the new directory and creates Applications for all environments.

4. If the app needs a new namespace, add it to the relevant AppProject in `argocd/templates/projects/`.

## Environment Promotion Flow

```
feature branch  →  merge to HEAD  →  auto-syncs to dev & stage
                   merge to main  →  auto-syncs to prod
```

- **Dev & Stage**: Track `HEAD` (latest commit) — immediate deployment on push
- **Prod**: Tracks `main` branch — deploy by merging to main
- **Image tags**: Dev uses `dev-latest`, stage uses `stage-latest`, prod uses pinned semver tags

## Design Decisions

### Why ApplicationSets over App-of-Apps YAML?
ApplicationSets with the matrix generator automatically discover new components via the git directory generator. No need to manually create an Application YAML for each new service — just add a directory.

### Why Helm umbrella charts?
Each component wraps an upstream chart as a dependency. This provides:
- Pinned upstream chart versions for reproducibility
- Base + per-environment value files for DRY configuration
- Standard Helm tooling for local rendering and testing (`helm template`)

### Why a single centralized ArgoCD?
One ArgoCD instance manages all clusters, providing a single pane of glass for all environments. Cluster credentials are registered as ArgoCD cluster secrets.

### Why sync waves?
Ordering ensures AppProjects exist before ApplicationSets try to reference them, and infrastructure components (ingress, certs) are ready before applications that depend on them.
