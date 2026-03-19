#!/usr/bin/env bash
# =============================================================================
# deploy-demo-app-nginx.sh
#
# Deploys demo app using Nginx Ingress Controller.
# Reliable on bare OCI VM + k3d because nginx NodePort is fully under our
# control — Cilium only acts as CNI, not the ingress layer.
#
# Traffic: internet→OCI:80→k3d LB→NodePort 32080→nginx→backend pod
#
# Routes:
#   /api/golang  → api-golang:8000   (prefix stripped)
#   /api/node    → api-node:3000     (prefix stripped)
#   /hubble/     → hubble-ui:80      (Cilium observability)
#   /            → client-react:8080
#
# Usage: ./scripts/deploy-demo-app-nginx.sh
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
echo "╔══════════════════════════════════════════════╗"
echo "║  Demo App Deploy — Nginx Ingress Controller  ║"
echo "╚══════════════════════════════════════════════╝"

CURRENT_CTX="$(kubectl config current-context)"
echo "Context: ${CURRENT_CTX}"
[[ "$CURRENT_CTX" == k3d-* ]] || warn "Not a k3d context — verify cluster"

# ---------------------------------------------------------------------------
# STEP 1 — Nginx Ingress Controller
# Hard-pinned to NodePort 32080/32443 to match k3d's port mapping.
# ---------------------------------------------------------------------------
step "Installing Nginx Ingress Controller..."
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
ok "Nginx Ingress ready on NodePort ${HTTP_NODEPORT}"

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
# STEP 3 — PostgreSQL
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
# STEP 4 — DB Migrator
# ---------------------------------------------------------------------------
step "Running DB migrator..."
kubectl apply -f "${APP_DIR}/postgresql/Secret.db-password.yaml" -n "$NAMESPACE"
kubectl apply -f "${APP_DIR}/postgresql/Job.db-migrator.yaml"    -n "$NAMESPACE"
kubectl wait --for=condition=Complete job/db-migrator \
    -n "$NAMESPACE" --timeout=180s >/dev/null \
    && ok "DB migration complete" \
    || { warn "Migration timed out"; kubectl logs -n "$NAMESPACE" -l job-name=db-migrator --tail=30; }

# ---------------------------------------------------------------------------
# STEP 5 — App services
# ---------------------------------------------------------------------------
step "Deploying api-golang..."
kubectl apply -f "${APP_DIR}/api-golang/" -n "$NAMESPACE"
wait_pods "app=api-golang" "$NAMESPACE" 120

step "Deploying api-node..."
kubectl apply -f "${APP_DIR}/api-node/" -n "$NAMESPACE"
wait_pods "app=api-node" "$NAMESPACE" 120

step "Deploying client-react-nginx..."
CLIENT_DIR="${APP_DIR}/client-react"
[[ -d "$CLIENT_DIR" ]] || CLIENT_DIR="${APP_DIR}/client"
kubectl apply -f "$CLIENT_DIR/" -n "$NAMESPACE"
wait_pods "app=client-react-nginx" "$NAMESPACE" 120

# ---------------------------------------------------------------------------
# STEP 6 — Ingress rules
# rewrite-target strips /api/golang and /api/node prefixes.
# Hubble UI is in kube-system — we add an ExternalName service in demo-app
# so nginx can proxy to it cross-namespace.
# ---------------------------------------------------------------------------
step "Applying Ingress routes..."

# Patch Hubble UI deployment to know it is served from /hubble/ subpath.
# Without this the UI's JS fetches assets from / instead of /hubble/ and
# the namespace list call goes to the wrong backend path.
echo "   Patching Hubble UI base URL..."
kubectl set env deployment/hubble-ui     -n kube-system     -c frontend     HUBBLE_UI_BASE_URL=/hubble/ 2>/dev/null || true
# Give the rollout a moment
sleep 5

# ExternalName service to proxy Hubble UI cross-namespace
kubectl apply -f - <<SVCEOF
apiVersion: v1
kind: Service
metadata:
  name: hubble-ui-proxy
  namespace: ${NAMESPACE}
spec:
  type: ExternalName
  externalName: hubble-ui.kube-system.svc.cluster.local
  ports:
    - port: 80
SVCEOF

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
# Hubble UI: accessible at http://${DOMAIN}/hubble/
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hubble-ui
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
          - path: /hubble(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: hubble-ui-proxy
                port:
                  number: 80
---
# Client catch-all — must be last (least specific path)
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
# STEP 7 — Smoke tests
# ---------------------------------------------------------------------------
step "Smoke tests (waiting 15s for nginx to sync)..."
sleep 15

PUBLIC_IP="$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"

for path in "/api/golang" "/api/node" "/hubble/" "/"; do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        -H "Host: ${DOMAIN}" "http://${PUBLIC_IP}${path}" 2>/dev/null || echo "000")
    [[ "$CODE" =~ ^[23] ]] && ok "${path} → HTTP ${CODE}" || warn "${path} → HTTP ${CODE}"
done

# ---------------------------------------------------------------------------
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║              ✅  Deployment Done             ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
kubectl get pods -n "$NAMESPACE"
echo ""
kubectl get ingress -n "$NAMESPACE"
echo ""
echo "  Frontend  : http://${DOMAIN}/"
echo "  Go API    : http://${DOMAIN}/api/golang"
echo "  Node API  : http://${DOMAIN}/api/node"
echo "  Hubble UI : http://${DOMAIN}/hubble/"