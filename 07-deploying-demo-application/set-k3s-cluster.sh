#!/usr/bin/env bash

# Build a single-host multi-node K3s lab using k3d.
# Why k3d: plain K3s needs separate machines or VMs for extra nodes.
# On one OCI instance, k3d is the practical way to run 1 server + N agents,
# because each node runs as a Docker container but still uses real K3s.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CILIUM_VALUES_FILE="${REPO_ROOT}/07-deploying-demo-application/cilium-values.yaml"

CLUSTER_NAME="kubelab"
SERVER_COUNT=1
AGENT_COUNT="auto"
API_PORT=6550
HTTP_PORT=80
HTTPS_PORT=443
INGRESS_HTTP_NODEPORT=32080
INGRESS_HTTPS_NODEPORT=32443
DELETE_EXISTING=0
FORCE=0
CILIUM_VERSION="1.19.1"

usage() {
    cat <<'EOF'
Usage: ./scripts/setup-k3s-cluster.sh [options]

Options:
  --name <name>           Cluster name. Default: kubelab
  --agents <count>        Worker node count. Default: auto
  --api-port <port>       Host port for Kubernetes API. Default: 6550
  --http-port <port>      Host port for ingress HTTP. Default: 80
  --https-port <port>     Host port for ingress HTTPS. Default: 443
  --delete-existing       Delete an existing k3d cluster with the same name first
  --force                 Allow a worker count above the host recommendation
  -h, --help              Show this help

Examples:
  ./scripts/setup-k3s-cluster.sh
  ./scripts/setup-k3s-cluster.sh --agents 2 --delete-existing
  ./scripts/setup-k3s-cluster.sh --name lab --http-port 8080 --https-port 8443
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --agents)
            AGENT_COUNT="$2"
            shift 2
            ;;
        --api-port)
            API_PORT="$2"
            shift 2
            ;;
        --http-port)
            HTTP_PORT="$2"
            shift 2
            ;;
        --https-port)
            HTTPS_PORT="$2"
            shift 2
            ;;
        --delete-existing)
            DELETE_EXISTING=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        return 1
    fi
}

port_in_use() {
    local port="$1"
    ss -ltn "( sport = :$port )" 2>/dev/null | awk 'NR>1 {print $4}' | grep -q .
}

get_mem_gib() {
    awk '/MemTotal/ {printf "%.0f\n", $2/1024/1024}' /proc/meminfo
}

get_disk_gib() {
    df -BG / | awk 'NR==2 {gsub(/G/, "", $4); print $4}'
}

recommend_agents() {
    local cpus mem_gib disk_gib
    cpus="$(nproc)"
    mem_gib="$(get_mem_gib)"
    disk_gib="$(get_disk_gib)"

    if (( cpus >= 4 && mem_gib >= 16 && disk_gib >= 50 )); then
        echo 3
    elif (( cpus >= 2 && mem_gib >= 10 && disk_gib >= 30 )); then
        echo 2
    elif (( cpus >= 2 && mem_gib >= 8 && disk_gib >= 20 )); then
        echo 1
    else
        echo 0
    fi
}

echo "🚀 K3s Multi-Node Lab Setup"
echo "==========================="
echo ""

require_command docker
require_command kubectl
require_command k3d
require_command helm
require_command ss

if ! docker info >/dev/null 2>&1; then
    echo "Docker is installed but not reachable. Start Docker first." >&2
    exit 1
fi

CPU_COUNT="$(nproc)"
MEM_GIB="$(get_mem_gib)"
DISK_GIB="$(get_disk_gib)"
RECOMMENDED_AGENTS="$(recommend_agents)"

echo "Host capacity:"
echo "  CPU: ${CPU_COUNT} vCPU"
echo "  RAM: ${MEM_GIB} GiB"
echo "  Free disk: ${DISK_GIB} GiB"
echo ""

if [[ "$AGENT_COUNT" == "auto" ]]; then
    AGENT_COUNT="$RECOMMENDED_AGENTS"
fi

if ! [[ "$AGENT_COUNT" =~ ^[0-9]+$ ]]; then
    echo "--agents must be an integer or 'auto'." >&2
    exit 1
fi

if (( RECOMMENDED_AGENTS == 0 )); then
    echo "This host is too small for a useful multi-node K3s lab." >&2
    echo "Minimum practical target: 2 vCPU, 8 GiB RAM, 20 GiB free disk." >&2
    exit 1
fi

if (( AGENT_COUNT > RECOMMENDED_AGENTS )) && (( FORCE == 0 )); then
    echo "Requested ${AGENT_COUNT} workers, but this host only recommends ${RECOMMENDED_AGENTS}." >&2
    echo "Use --force if you want to overcommit intentionally." >&2
    exit 1
fi

if (( AGENT_COUNT > 2 )) && (( CPU_COUNT <= 2 )) && (( FORCE == 0 )); then
    echo "More than 2 workers on a 2 vCPU host is not a sensible default." >&2
    exit 1
fi

echo "Cluster shape:"
echo "  Control planes: ${SERVER_COUNT}"
echo "  Workers: ${AGENT_COUNT}"
echo "  CNI: Cilium ${CILIUM_VERSION} (kube-proxy replacement enabled)"
echo ""

if command -v k3s >/dev/null 2>&1 || [[ -x /usr/local/bin/k3s ]] || [[ -f /etc/systemd/system/k3s.service ]]; then
    echo "Native k3s appears to be installed on this machine." >&2
    echo "Stop or uninstall it before creating a k3d-based multi-node cluster." >&2
    echo "Typical cleanup commands:" >&2
    echo "  sudo /usr/local/bin/k3s-uninstall.sh" >&2
    echo "  sudo /usr/local/bin/k3s-agent-uninstall.sh" >&2
    exit 1
fi

if k3d cluster list | awk '{print $1}' | grep -qx "$CLUSTER_NAME"; then
    if (( DELETE_EXISTING == 1 )); then
        echo "Deleting existing cluster: ${CLUSTER_NAME}"
        k3d cluster delete "$CLUSTER_NAME"
    else
        echo "Cluster '${CLUSTER_NAME}' already exists. Use --delete-existing to replace it." >&2
        exit 1
    fi
fi

if [[ ! -f "$CILIUM_VALUES_FILE" ]]; then
    echo "Missing Cilium values file: ${CILIUM_VALUES_FILE}" >&2
    exit 1
fi

for port in "$API_PORT" "$HTTP_PORT" "$HTTPS_PORT"; do
    if port_in_use "$port"; then
        echo "Port ${port} is already in use. Pick a different port or stop the conflicting service." >&2
        exit 1
    fi
done

echo "Creating cluster..."
k3d cluster create "$CLUSTER_NAME" \
    --servers "$SERVER_COUNT" \
    --agents "$AGENT_COUNT" \
    --api-port "$API_PORT" \
    --port "${HTTP_PORT}:${INGRESS_HTTP_NODEPORT}@loadbalancer" \
    --port "${HTTPS_PORT}:${INGRESS_HTTPS_NODEPORT}@loadbalancer" \
    --k3s-arg "--flannel-backend=none@server:*" \
    --k3s-arg "--disable-network-policy@server:*" \
    --k3s-arg "--disable-kube-proxy@server:*" \
    --k3s-arg "--disable=traefik@server:*" \
    --k3s-arg "--disable=servicelb@server:*" \
    --k3s-arg "--disable=coredns@server:*"
    # ^^^ Disable k3s's built-in CoreDNS so Cilium can manage DNS entirely.
    # Without this, k3s deploys its own CoreDNS that conflicts with Cilium's
    # kube-proxy replacement, causing DNS resolution failures inside pods.

kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null

echo "Waiting for Kubernetes API..."
timeout 120 bash -c 'until kubectl cluster-info >/dev/null 2>&1; do sleep 2; done'

API_HOST="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "k3d-${CLUSTER_NAME}-server-0")"
if [[ -z "$API_HOST" ]]; then
    echo "Could not determine the k3d server node IP." >&2
    exit 1
fi

echo "Installing Cilium..."
helm repo add cilium https://helm.cilium.io --force-update >/dev/null
helm repo update >/dev/null
helm upgrade --install cilium cilium/cilium \
    --namespace kube-system \
    --version "$CILIUM_VERSION" \
    --values "$CILIUM_VALUES_FILE" \
    --set k8sServiceHost="$API_HOST" \
    --set k8sServicePort=6443 \
    --set dns.enabled=true
    # ^^^ Explicitly enable Cilium's DNS proxy so cluster DNS works correctly
    # when k3s CoreDNS is disabled above.

kubectl rollout status daemonset/cilium -n kube-system --timeout=300s >/dev/null
kubectl rollout status deployment/cilium-operator -n kube-system --timeout=300s >/dev/null

# Hubble relay needs all cilium agents peered before its gRPC health check passes.
# It is observability-only and does not affect app traffic or ingress.
echo "Waiting for hubble-relay (this can take 2-3 mins)..."
kubectl wait --for=condition=Available deployment/hubble-relay \
    -n kube-system --timeout=300s >/dev/null || \
    echo "⚠️  hubble-relay not yet ready — continuing anyway, it self-recovers."

kubectl wait --for=condition=Ready node --all --timeout=300s >/dev/null

# ---------------------------------------------------------------------------
# Deploy CoreDNS manually.
# k3s normally installs CoreDNS via an AddOn manifest, but we passed
# --disable=coredns so that k3s's embedded flannel-dependent coredns config
# does not conflict with Cilium's kube-proxy replacement.
# We apply a clean, self-contained CoreDNS manifest here instead.
#
# ClusterIP 10.43.0.10 is the k3s default for kube-dns. Cilium's DNS proxy
# forwards pod DNS queries to this address.
# ---------------------------------------------------------------------------
echo "Deploying CoreDNS..."
# Detect the kube-dns ClusterIP that k3s pre-allocated. k3s creates the
# kube-dns Service even when --disable=coredns is set, so we can read it.
KUBE_DNS_IP="$(kubectl get svc kube-dns -n kube-system \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "10.43.0.10")"
echo "  kube-dns ClusterIP: ${KUBE_DNS_IP}"

# First apply a CiliumClusterwideNetworkPolicy that explicitly allows CoreDNS
# pods to bind their health/readiness ports. Without this, Cilium's default-deny
# posture blocks the loopback probe before CoreDNS finishes initializing, which
# causes the readiness probe (port 8181) to fail → BackOff crash loop.
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
    - fromEntities:
        - world
        - cluster
  egress:
    - toEntities:
        - world
        - cluster
NETPOL

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
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30
        loop
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
            limits:
              memory: 170Mi
            requests:
              cpu: 100m
              memory: 70Mi
          args: ["-conf", "/etc/coredns/Corefile"]
          volumeMounts:
            - name: config-volume
              mountPath: /etc/coredns
              readOnly: true
          ports:
            - containerPort: 53
              name: dns
              protocol: UDP
            - containerPort: 53
              name: dns-tcp
              protocol: TCP
            - containerPort: 9153
              name: metrics
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              add: [NET_BIND_SERVICE]
              drop: [ALL]
            readOnlyRootFilesystem: true
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
              scheme: HTTP
            # Give CoreDNS 90s to fully initialize before liveness kicks in.
            # Cilium's BPF datapath takes a moment to program rules for new pods.
            initialDelaySeconds: 90
            timeoutSeconds: 5
            successThreshold: 1
            failureThreshold: 5
          readinessProbe:
            httpGet:
              path: /ready
              port: 8181
              scheme: HTTP
            # Same grace period for the readiness probe — this was the port
            # that Cilium was blocking, causing the BackOff crash loop.
            initialDelaySeconds: 30
            timeoutSeconds: 5
            successThreshold: 1
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
    - name: dns
      port: 53
      protocol: UDP
    - name: dns-tcp
      port: 53
      protocol: TCP
    - name: metrics
      port: 9153
      protocol: TCP
EOF

echo "Waiting for CoreDNS to be ready..."
kubectl rollout status deployment/coredns -n kube-system --timeout=120s >/dev/null
echo "✅ CoreDNS is ready."

# ---------------------------------------------------------------------------
# Verify DNS works inside the cluster before proceeding.
# ---------------------------------------------------------------------------
echo "Verifying in-cluster DNS..."
DNS_OK=0
for i in $(seq 1 10); do
    if kubectl run "dns-test-$$" \
        --image=busybox:1.36 \
        --restart=Never \
        --rm -i \
        --command -- \
        nslookup kubernetes.default.svc.cluster.local \
        >/dev/null 2>&1; then
        DNS_OK=1
        break
    fi
    echo "  DNS not ready yet, retrying (${i}/10)..."
    sleep 8
done

if (( DNS_OK == 0 )); then
    echo "⚠️  Warning: in-cluster DNS check did not pass. Investigate with:" >&2
    echo "   kubectl get pods -n kube-system -l k8s-app=kube-dns" >&2
    echo "   kubectl logs -n kube-system -l k8s-app=kube-dns" >&2
else
    echo "✅ In-cluster DNS is working."
fi

timeout 120 bash -c 'until kubectl get svc -n kube-system cilium-ingress >/dev/null 2>&1; do sleep 2; done'

echo "Pinning Cilium ingress node ports for k3d public listeners..."
kubectl patch svc -n kube-system cilium-ingress --type merge -p \
    "{\"spec\":{\"ports\":[{\"name\":\"http\",\"port\":80,\"protocol\":\"TCP\",\"targetPort\":80,\"nodePort\":${INGRESS_HTTP_NODEPORT}},{\"name\":\"https\",\"port\":443,\"protocol\":\"TCP\",\"targetPort\":443,\"nodePort\":${INGRESS_HTTPS_NODEPORT}}]}}" >/dev/null

echo ""
echo "✅ Cluster ready"
echo ""
kubectl get nodes -o wide
echo ""

PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

echo "Next steps:"
echo "  1. Verify context: kubectl config current-context"
echo "  2. Create your secrets file if needed: cp k8s/secrets.yaml.example k8s/secrets.yaml"
echo "  3. Confirm Cilium is healthy: kubectl get pods -n kube-system"
echo "  4. Deploy KubeLab: ./scripts/deploy-all.sh"
echo "  5. Frontend:  http://${PUBLIC_IP:-<public-ip>}/"
echo "  6. Grafana:   http://${PUBLIC_IP:-<public-ip>}/grafana/"
echo "  7. Another project: deploy it into a separate namespace"
echo ""
echo "Notes:"
echo "  - On this host, 2 workers is the recommended maximum."
echo "  - Ingress is served by Cilium through the cilium-ingress service on fixed node ports ${INGRESS_HTTP_NODEPORT}/${INGRESS_HTTPS_NODEPORT} behind the k3d public listener."
echo "  - Prometheus is configured to scrape Cilium and Hubble metrics in kube-system."
echo "  - If you add another project, prefer a new namespace and modest resource requests."
echo "  - Prometheus/Grafana plus another app can still fit, but avoid high replica counts on 2 vCPU."