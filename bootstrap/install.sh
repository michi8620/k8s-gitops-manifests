#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Bootstrap Script - Run ONCE to install ArgoCD and the Root Application
# After this, ArgoCD manages itself and all other applications via GitOps.
#
# Usage: ./install.sh <git-repo-url> [target-revision] [environment]
# Example: ./install.sh https://github.com/OWNER/k8s-gitops-manifests.git HEAD dev
###############################################################################

NAMESPACE="argocd"
ARGOCD_CHART_VERSION="7.7.5"
REPO_URL="${1:?Usage: ./install.sh <git-repo-url> [target-revision] [environment]}"
TARGET_REVISION="${2:-HEAD}"
ENVIRONMENT="${3:-dev}"

echo "============================================"
echo "  ArgoCD GitOps Bootstrap"
echo "  Repo:        ${REPO_URL}"
echo "  Revision:    ${TARGET_REVISION}"
echo "  Environment: ${ENVIRONMENT}"
echo "============================================"

# --- Step 1: Create namespace ---
echo "==> Creating namespace '${NAMESPACE}'"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# --- Step 2: Install ArgoCD via Helm (initial bootstrap only) ---
echo "==> Adding Helm repo and installing ArgoCD"
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace "${NAMESPACE}" \
  --version "${ARGOCD_CHART_VERSION}" \
  --wait --timeout 5m

# --- Step 3: Wait for ArgoCD to be ready ---
echo "==> Waiting for ArgoCD server to be ready"
kubectl -n "${NAMESPACE}" rollout status deployment/argocd-server --timeout=120s

# --- Step 4: Apply the Root Application (app-of-apps) ---
echo "==> Applying root application (ArgoCD will now manage itself)"
k apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${TARGET_REVISION}
    path: argocd
    helm:
      valueFiles:
        - values.yaml
        - values-${ENVIRONMENT}.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: ${NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF

echo ""
echo "============================================"
echo "  Bootstrap complete!"
echo "============================================"
echo ""
echo "ArgoCD will now:"
echo "  1. Take over management of its own installation"
echo "  2. Create AppProjects and ApplicationSets"
echo "  3. Auto-discover and deploy infra/ and apps/ components"
echo ""
echo "Access the ArgoCD UI:"
echo "  k port-forward svc/argocd-server -n ${NAMESPACE} 8080:443"
echo ""
echo "Get the initial admin password:"
echo "  k -n ${NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
