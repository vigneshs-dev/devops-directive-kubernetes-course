#!/usr/bin/env bash
# =============================================================================
# setup-k3s-cluster.sh
# Creates a k3d + Cilium cluster for devops-directive-kubernetes-course on OCI.
#
# Key design:
#   - k3d cluster created first, then Gateway API CRDs, then Cilium (order matters)
#   - gatewayAPI.enabled=true set at Cilium install time (not as a later upgrade)
#   - k3d maps host:80 → NodePort 32080, host:443 → NodePort 32443
#   - CoreDNS deployed manually (k3s coredns addon disabled to avoid CNI conflict)
#   - No MetalLB needed: Cilium Gateway svc patched to NodePort in deploy script
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CILIUM_VALUES_FILE="${REPO_ROOT}/setup/cilium-values.yaml"

CLUSTER_NAME="kubelab"
SERVER_COUNT=1
AGENT_COUNT="auto"
API_PORT=6550
HTTP_PORT=80
HTTPS_PORT=443
GW_HTTP_NODEPORT=32080
GW_HTTPS_NODEPORT=32443
DELETE_EXISTING=0
FORCE=0
CILIUM_VERSION="1.19.1"
GATEWAY_API_VERSION="v1.2.0"

usage() { cat <<'EOF'
Usage: ./scripts/setup-k3s-cluster.sh [options]

Options:
  --name <n>           Cluster name (default: kubelab)
  --agents <count>     Worker nodes (default: auto)
  --api-port <port>    Kubernetes API host port (default: 6550)
  --http-port <port>   HTTP ingress host port (default: 80)
  --https-port <port>  HTTPS ingress host port (default: 443)
  --delete-existing    Delete existing same-name cluster first
  --force              Allow worker count above recommendation
  -h, --help           Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)            CLUSTER_NAME="$2"; shift 2 ;;
        --agents)          AGENT_COUNT="$2";  shift 2 ;;
        --api-port)        API_PORT="$2";     shift 2 ;;
        --http-port)       HTTP_PORT="$2";    shift 2 ;;
        --https-port)      HTTPS_PORT="$2";   shift 2 ;;
        --delete-existing) DELETE_EXISTING=1; shift   ;;
        --force)           FORCE=1;           shift   ;;
        -h|--help)         usage; exit 0              ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
port_in_use() { ss -ltn "( sport = :$1 )" 2>/dev/null | awk 'NR>1{print $4}' | grep -q .; }
get_mem_gib()  { awk '/MemTotal/{printf "%.0f\n",$2/1024/1024}' /proc/meminfo; }
get_disk_gib() { df -BG / | awk 'NR==2{gsub(/G/,"",$4);print $4}'; }
recommend_agents() {
    local c m d; c=$(nproc); m=$(get_mem_gib); d=$(get_disk_gib)
    if   (( c>=4 && m>=16 && d>=50 )); then echo 3
    elif (( c>=2 && m>=10 && d>=30 )); then echo 2
    elif (( c>=2 && m>=8  && d>=20 )); then echo 1
    else echo 0; fi
}
step() { echo ""; echo "▶  $*"; }
ok()   { echo "   ✅ $*"; }
warn() { echo "   ⚠️  $*" >&2; }

# ---------------------------------------------------------------------------
echo ""
echo "╔══════════════════════════════════════╗"
echo "║  K3s + Cilium + Gateway API Setup    ║"
echo "╚══════════════════════════════════════╝"

for cmd in docker kubectl k3d helm ss curl; do require_cmd "$cmd"; done
docker info >/dev/null 2>&1 || { echo "Docker not reachable." >&2; exit 1; }

RECOMMENDED=$(recommend_agents)
[[ "$AGENT_COUNT" == "auto" ]] && AGENT_COUNT="$RECOMMENDED"
[[ "$AGENT_COUNT" =~ ^[0-9]+$ ]] || { echo "--agents must be integer or 'auto'" >&2; exit 1; }
(( RECOMMENDED==0 )) && { echo "Host too small. Need ≥2 vCPU, 8 GiB RAM, 20 GiB disk." >&2; exit 1; }
(( AGENT_COUNT>RECOMMENDED && FORCE==0 )) && {
    echo "Requested ${AGENT_COUNT} workers, host recommends ${RECOMMENDED}. Use --force." >&2; exit 1; }

echo "Host: $(nproc) vCPU | $(get_mem_gib) GiB RAM | $(get_disk_gib) GiB disk"
echo "Cluster: 1 server + ${AGENT_COUNT} agent(s) | Cilium ${CILIUM_VERSION} | GW API ${GATEWAY_API_VERSION}"

if command -v k3s >/dev/null 2>&1 || [[ -f /etc/systemd/system/k3s.service ]]; then
    echo "Native k3s detected — uninstall it first:" >&2
    echo "  sudo /usr/local/bin/k3s-uninstall.sh" >&2; exit 1
fi

[[ -f "$CILIUM_VALUES_FILE" ]] || { echo "Missing: ${CILIUM_VALUES_FILE}" >&2; exit 1; }

for port in "$API_PORT" "$HTTP_PORT" "$HTTPS_PORT"; do
    port_in_use "$port" && { echo "Port ${port} already in use." >&2; exit 1; }
done

if k3d cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$CLUSTER_NAME"; then
    (( DELETE_EXISTING )) || { echo "Cluster '${CLUSTER_NAME}' exists. Use --delete-existing." >&2; exit 1; }
    step "Deleting existing cluster '${CLUSTER_NAME}'..."
    k3d cluster delete "$CLUSTER_NAME"
fi

# ---------------------------------------------------------------------------
# STEP 1 — Create k3d cluster
# ---------------------------------------------------------------------------
step "Creating k3d cluster '${CLUSTER_NAME}'..."
k3d cluster create "$CLUSTER_NAME" \
    --servers "$SERVER_COUNT" \
    --agents  "$AGENT_COUNT"  \
    --api-port "$API_PORT" \
    --port "${HTTP_PORT}:${GW_HTTP_NODEPORT}@loadbalancer" \
    --port "${HTTPS_PORT}:${GW_HTTPS_NODEPORT}@loadbalancer" \
    --k3s-arg "--flannel-backend=none@server:*" \
    --k3s-arg "--disable-network-policy@server:*" \
    --k3s-arg "--disable-kube-proxy@server:*" \
    --k3s-arg "--disable=traefik@server:*" \
    --k3s-arg "--disable=servicelb@server:*" \
    --k3s-arg "--disable=coredns@server:*"

kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null

step "Waiting for API server..."
timeout 120 bash -c 'until kubectl cluster-info >/dev/null 2>&1; do sleep 2; done'
ok "API server reachable"

# ---------------------------------------------------------------------------
# STEP 2 — Gateway API CRDs (before Cilium install)
# The Cilium operator checks for these CRDs at startup. Installing after
# means the gateway controller goroutine never starts → GatewayClass stays
# "Waiting for controller" with a 1970-01-01 timestamp forever.
# ---------------------------------------------------------------------------
step "Installing Gateway API CRDs ${GATEWAY_API_VERSION}..."
kubectl apply -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
    --server-side 2>/dev/null || \
kubectl apply -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
ok "Gateway API CRDs ready"

# ---------------------------------------------------------------------------
# STEP 3 — Install Cilium with gatewayAPI.enabled=true from the start
# ---------------------------------------------------------------------------
step "Installing Cilium ${CILIUM_VERSION}..."
API_HOST="$(docker inspect \
    -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
    "k3d-${CLUSTER_NAME}-server-0")"
[[ -z "$API_HOST" ]] && { echo "Cannot determine k3d server IP." >&2; exit 1; }

helm repo add cilium https://helm.cilium.io --force-update >/dev/null
helm repo update cilium >/dev/null

helm upgrade --install cilium cilium/cilium \
    --namespace kube-system \
    --version "$CILIUM_VERSION" \
    --values "$CILIUM_VALUES_FILE" \
    --set k8sServiceHost="$API_HOST" \
    --set k8sServicePort=6443 \
    --set gatewayAPI.enabled=true

step "Waiting for Cilium daemonset..."
kubectl rollout status daemonset/cilium -n kube-system --timeout=300s >/dev/null
ok "Cilium daemonset ready"

step "Waiting for Cilium operator..."
kubectl rollout status deployment/cilium-operator -n kube-system --timeout=300s >/dev/null
ok "Cilium operator ready"

step "Waiting for Hubble relay (non-blocking)..."
kubectl wait --for=condition=Available deployment/hubble-relay \
    -n kube-system --timeout=180s >/dev/null \
    && ok "Hubble relay ready" \
    || warn "Hubble relay slow — it self-recovers. Continuing."

kubectl wait --for=condition=Ready node --all --timeout=300s >/dev/null
ok "All nodes Ready"

# ---------------------------------------------------------------------------
# STEP 4 — CoreDNS (manual deploy, k3s addon disabled)
# Apply network policy first so Cilium BPF doesn't block health probes.
# ---------------------------------------------------------------------------
step "Applying CoreDNS network policy..."
kubectl apply -f - <<'NETPOL'
apiVersion: "cilium.io/v2"
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: allow-coredns-health
spec:
  endpointSelector:
    matchLabels:
      k8s-app: kube-dns
  ingress:
    - fromEntities: [world, cluster]
  egress:
    - toEntities: [world, cluster]
NETPOL

step "Deploying CoreDNS..."
KUBE_DNS_IP="$(kubectl get svc kube-dns -n kube-system \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "10.43.0.10")"
echo "   kube-dns ClusterIP: ${KUBE_DNS_IP}"

kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: coredns
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:coredns
rules:
  - apiGroups: [""]
    resources: [endpoints, services, pods, namespaces]
    verbs: [list, watch]
  - apiGroups: [""]
    resources: [nodes]
    verbs: [get]
  - apiGroups: [discovery.k8s.io]
    resources: [endpointslices]
    verbs: [list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:coredns
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:coredns
subjects:
  - kind: ServiceAccount
    name: coredns
    namespace: kube-system
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . 8.8.8.8 8.8.4.4
        cache 30
        reload
        loadbalance
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coredns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/name: CoreDNS
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  selector:
    matchLabels:
      k8s-app: kube-dns
  template:
    metadata:
      labels:
        k8s-app: kube-dns
    spec:
      priorityClassName: system-cluster-critical
      serviceAccountName: coredns
      tolerations:
        - key: CriticalAddonsOnly
          operator: Exists
        - key: node-role.kubernetes.io/control-plane
          effect: NoSchedule
      nodeSelector:
        kubernetes.io/os: linux
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: k8s-app
                      operator: In
                      values: [kube-dns]
                topologyKey: kubernetes.io/hostname
      containers:
        - name: coredns
          image: coredns/coredns:1.11.3
          imagePullPolicy: IfNotPresent
          resources:
            limits:   { memory: 170Mi }
            requests: { cpu: 100m, memory: 70Mi }
          args: ["-conf", "/etc/coredns/Corefile"]
          volumeMounts:
            - name: config-volume
              mountPath: /etc/coredns
              readOnly: true
          ports:
            - { containerPort: 53,   name: dns,     protocol: UDP }
            - { containerPort: 53,   name: dns-tcp, protocol: TCP }
            - { containerPort: 9153, name: metrics, protocol: TCP }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              add: [NET_BIND_SERVICE]
              drop: [ALL]
            readOnlyRootFilesystem: true
          livenessProbe:
            httpGet: { path: /health, port: 8080, scheme: HTTP }
            initialDelaySeconds: 90
            timeoutSeconds: 5
            failureThreshold: 5
          readinessProbe:
            httpGet: { path: /ready, port: 8181, scheme: HTTP }
            initialDelaySeconds: 30
            timeoutSeconds: 5
            failureThreshold: 6
      volumes:
        - name: config-volume
          configMap:
            name: coredns
            items:
              - key: Corefile
                path: Corefile
---
apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  annotations:
    prometheus.io/port: "9153"
    prometheus.io/scrape: "true"
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    kubernetes.io/name: CoreDNS
spec:
  selector:
    k8s-app: kube-dns
  clusterIP: ${KUBE_DNS_IP}
  ports:
    - { name: dns,     port: 53,   protocol: UDP }
    - { name: dns-tcp, port: 53,   protocol: TCP }
    - { name: metrics, port: 9153, protocol: TCP }
EOF

step "Waiting for CoreDNS rollout..."
kubectl rollout status deployment/coredns -n kube-system --timeout=180s >/dev/null
ok "CoreDNS ready"

step "DNS smoke test..."
DNS_OK=0
for i in $(seq 1 12); do
    if kubectl run "dns-smoke-$$" --image=busybox:1.36 --restart=Never --rm -i \
        --command -- nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
        DNS_OK=1; break
    fi
    echo "   attempt ${i}/12, retrying in 10s..."; sleep 10
done
(( DNS_OK )) && ok "In-cluster DNS working" \
    || warn "DNS smoke test failed — check: kubectl get pods -n kube-system -l k8s-app=kube-dns"

# ---------------------------------------------------------------------------
# STEP 5 — Verify GatewayClass accepted (with auto-recovery)
# ---------------------------------------------------------------------------
step "Waiting for GatewayClass 'cilium' to be Accepted..."
GW_OK=0
for i in $(seq 1 18); do
    STATUS="$(kubectl get gatewayclass cilium \
        -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")"
    [[ "$STATUS" == "True" ]] && { GW_OK=1; break; }
    echo "   status='${STATUS}' (${i}/18)..."; sleep 10
done

if (( ! GW_OK )); then
    warn "GatewayClass not Accepted — restarting operator..."
    kubectl rollout restart deployment/cilium-operator -n kube-system
    kubectl rollout status deployment/cilium-operator -n kube-system --timeout=120s >/dev/null
    sleep 20
    STATUS="$(kubectl get gatewayclass cilium \
        -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")"
    [[ "$STATUS" == "True" ]] \
        && ok "GatewayClass Accepted after operator restart" \
        || warn "GatewayClass still not Accepted — run deploy script and check logs"
else
    ok "GatewayClass 'cilium' Accepted"
fi

# ---------------------------------------------------------------------------
echo ""
echo "╔══════════════════════════════════════╗"
echo "║         ✅  Cluster Ready            ║"
echo "╚══════════════════════════════════════╝"
kubectl get nodes -o wide
PUBLIC_IP="$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo ""
echo "Next: ./scripts/deploy-demo-app.sh"
echo "Public IP: ${PUBLIC_IP}"