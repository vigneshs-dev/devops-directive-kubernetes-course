#!/usr/bin/env bash
# =============================================================================
# deploy-demo-app.sh
#
# Deploys the devops-directive-kubernetes-course demo app.
# Uses Nginx Ingress Controller (NOT Cilium Gateway API) because on a bare
# OCI VM + k3d, Cilium keeps reassigning NodePorts away from 32080 and
# the Gateway stays stuck in "AddressNotAssigned".
#
# Traffic flow:
#   internet → OCI VM :80 → k3d LB container → NodePort 32080
#   → nginx-ingress controller pod → backend service
#
# Nginx ingress is pinned to NodePort 32080 so k3d's existing port mapping
# picks it up with zero extra config.
#
# Run from: 07-deploying-demo-application/
#   ./scripts/deploy-demo-app.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

NAMESPACE="demo-app"
DOMAIN="k8s.vigneshsdev.uk"
HTTP_NODEPORT=32080
HTTPS_NODEPORT=32443

step() { echo ""; echo "▶  $*"; }
ok()   { echo "   ✅ $*"; }
warn() { echo "   ⚠️  $*" >&2; }

wait_pods() {
    local label=$1 ns=${2:-$NAMESPACE} timeout=${3:-120}
    kubectl wait --for=condition=Ready pod -l "$label" -n "$ns" \
        --timeout="${timeout}s" >/dev/null \
        && ok "Pods ready: ${label}" \
        || { warn "Pods not ready: ${label}"; kubectl get pods -n "$ns" -l "$label"; }
}

echo ""
echo "╔══════════════════════════════════════╗"
echo "║     Demo App Deployment              ║"
echo "╚══════════════════════════════════════╝"

CURRENT_CTX="$(kubectl config current-context)"
echo "Context : ${CURRENT_CTX}"
[[ "$CURRENT_CTX" == k3d-* ]] || warn "Not a k3d context — verify you're on the right cluster"

# ---------------------------------------------------------------------------
# STEP 1 — Nginx Ingress Controller pinned to NodePort 32080
# We install it via Helm and hard-pin the NodePorts so k3d's LB container
# (which forwards host:80 → 32080) always routes to it correctly.
# Cilium acts only as the CNI/network layer — it does NOT handle ingress here.
# ---------------------------------------------------------------------------
step "Installing Nginx Ingress Controller (NodePort ${HTTP_NODEPORT})..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update ingress-nginx >/dev/null

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.service.type=NodePort \
    --set controller.service.nodePorts.http=${HTTP_NODEPORT} \
    --set controller.service.nodePorts.https=${HTTPS_NODEPORT} \
    --set controller.ingressClassResource.name=nginx \
    --set controller.ingressClassResource.enabled=true \
    --set controller.ingressClassResource.default=true \
    --wait --timeout=120s

ok "Nginx Ingress Controller ready on NodePort ${HTTP_NODEPORT}"

# ---------------------------------------------------------------------------
# STEP 2 — Namespace
# ---------------------------------------------------------------------------
step "Creating namespace '${NAMESPACE}'..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
EOF
kubectl config set-context --current --namespace="$NAMESPACE" >/dev/null
ok "Namespace active"

# ---------------------------------------------------------------------------
# STEP 3 — PostgreSQL via Helm (into postgres namespace, accessed cross-ns)
# ---------------------------------------------------------------------------
step "Deploying PostgreSQL..."
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo update bitnami >/dev/null

helm upgrade --install postgres bitnami/postgresql \
    --namespace postgres \
    --create-namespace \
    --version 18.5.8 \
    --values "${APP_DIR}/postgresql/values.yaml" \
    --set auth.postgresPassword=foobarbaz \
    --wait --timeout=180s
ok "PostgreSQL ready"

# ---------------------------------------------------------------------------
# STEP 4 — DB Migrator Job
# ---------------------------------------------------------------------------
step "Running DB migrator..."
kubectl apply -f "${APP_DIR}/postgresql/Secret.db-password.yaml" -n "$NAMESPACE"
kubectl apply -f "${APP_DIR}/postgresql/Job.db-migrator.yaml"    -n "$NAMESPACE"

echo "   Waiting for migration to complete (up to 180s)..."
kubectl wait --for=condition=Complete job/db-migrator \
    -n "$NAMESPACE" --timeout=180s >/dev/null \
    && ok "DB migration complete" \
    || { warn "Migration timed out"; kubectl logs -n "$NAMESPACE" -l job-name=db-migrator --tail=30; }

# ---------------------------------------------------------------------------
# STEP 5 — Backend services
# ---------------------------------------------------------------------------
step "Deploying api-golang..."
kubectl apply -f "${APP_DIR}/api-golang/" -n "$NAMESPACE"
wait_pods "app=api-golang" "$NAMESPACE" 120

step "Deploying api-node..."
kubectl apply -f "${APP_DIR}/api-node/" -n "$NAMESPACE"
wait_pods "app=api-node" "$NAMESPACE" 120

# ---------------------------------------------------------------------------
# STEP 6 — Frontend
# ---------------------------------------------------------------------------
step "Deploying client-react-nginx..."
CLIENT_DIR="${APP_DIR}/client-react"
[[ -d "$CLIENT_DIR" ]] || CLIENT_DIR="${APP_DIR}/client"
kubectl apply -f "$CLIENT_DIR/" -n "$NAMESPACE"
wait_pods "app=client-react-nginx" "$NAMESPACE" 120

# ---------------------------------------------------------------------------
# STEP 7 — Ingress (standard Kubernetes Ingress, nginx class)
# rewrite-target annotation IS supported by nginx ingress controller.
# This strips /api/golang and /api/node prefixes before forwarding,
# replicating what Traefik's stripPrefix middleware was doing.
# ---------------------------------------------------------------------------
step "Applying Ingress routes..."
kubectl apply -f - <<EOF
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-golang
  namespace: ${NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /\$2
    nginx.ingress.kubernetes.io/use-regex: "true"
spec:
  ingressClassName: nginx
  rules:
    - host: ${DOMAIN}
      http:
        paths:
          - path: /api/golang(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: api-golang
                port:
                  number: 8000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-node
  namespace: ${NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /\$2
    nginx.ingress.kubernetes.io/use-regex: "true"
spec:
  ingressClassName: nginx
  rules:
    - host: ${DOMAIN}
      http:
        paths:
          - path: /api/node(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: api-node
                port:
                  number: 3000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: client-react-nginx
  namespace: ${NAMESPACE}
spec:
  ingressClassName: nginx
  rules:
    - host: ${DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: client-react-nginx
                port:
                  number: 8080
EOF
ok "Ingress routes applied"

# ---------------------------------------------------------------------------
# STEP 8 — Smoke tests
# ---------------------------------------------------------------------------
step "Smoke testing (waiting 10s for nginx to sync routes)..."
sleep 10

PUBLIC_IP="$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"

for path in "/api/golang" "/api/node" "/"; do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        -H "Host: ${DOMAIN}" "http://${PUBLIC_IP}${path}" 2>/dev/null || echo "000")
    if [[ "$CODE" =~ ^[23] ]]; then
        ok "${path} → HTTP ${CODE}"
    else
        warn "${path} → HTTP ${CODE}"
    fi
done

# ---------------------------------------------------------------------------
echo ""
echo "╔══════════════════════════════════════╗"
echo "║         ✅  Deployment Done          ║"
echo "╚══════════════════════════════════════╝"
echo ""
kubectl get pods -n "$NAMESPACE"
echo ""
kubectl get ingress -n "$NAMESPACE"
echo ""
echo "Access your app:"
echo "  Frontend : http://${DOMAIN}/"
echo "  Go API   : http://${DOMAIN}/api/golang"
echo "  Node API : http://${DOMAIN}/api/node"
echo ""
echo "If smoke tests warned, wait 30s and retry:"
echo "  curl http://${DOMAIN}/api/golang"
echo "  curl http://${DOMAIN}/api/node"
echo "  curl http://${DOMAIN}/"