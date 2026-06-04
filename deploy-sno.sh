#!/bin/bash
# Deploy Single-Node OpenShift on libvirt/KVM (dual-stack, agent-based installer)
set -euo pipefail

###############################################################################
# Configuration — adjust these to your environment
###############################################################################
CLUSTER_NAME="${CLUSTER_NAME:-ocp}"
BASE_DOMAIN="${BASE_DOMAIN:-mydomain.io}"

# IPv4 networking (routed via host to local network)
IPV4_SUBNET="${IPV4_SUBNET:-10.0.200}"
NODE_IPV4="${NODE_IPV4:-${IPV4_SUBNET}.10}"
GATEWAY_IPV4="${GATEWAY_IPV4:-${IPV4_SUBNET}.1}"      # host bridge IPv4
NETWORK_CIDR_V4="${NETWORK_CIDR_V4:-${IPV4_SUBNET}.0/24}"

# IPv6 networking (externally routed — DNS/ingress face this side)
IPV6_PREFIX="${IPV6_PREFIX:-2002:db8:cafe:d893}"
NODE_IPV6="${NODE_IPV6:-${IPV6_PREFIX}::2}"
GATEWAY_IPV6="${GATEWAY_IPV6:-${IPV6_PREFIX}::1}"         # host bridge IPv6
DNS_SERVER="${DNS_SERVER:-${GATEWAY_IPV6}}"               # DNS64+NAT64 handled upstream; host forwards
NETWORK_CIDR_V6="${NETWORK_CIDR_V6:-${IPV6_PREFIX}::/64}"
NETWORK_PREFIX_V6="${NETWORK_PREFIX_V6:-64}"
NTP_SERVER="${NTP_SERVER:-pool.ntp.org}"                  # public NTP pool (IPv4+IPv6)

# Libvirt
NETWORK_NAME="${NETWORK_NAME:-ocp-net}"
BRIDGE_NAME="${BRIDGE_NAME:-virbr-ocp}"
VM_NAME="${VM_NAME:-ocp-sno}"
VM_VCPUS="${VM_VCPUS:-12}"
VM_RAM="${VM_RAM:-32768}"        # MiB  (minimum 16384, 32768+ recommended)
VM_DISK="${VM_DISK:-120}"        # GiB  (OS)
VM_DATA_DISK="${VM_DATA_DISK:-80}"   # GiB  (storage / LVMS)
MAC_ADDRESS="${MAC_ADDRESS:-52:54:00:00:00:01}"
LIBVIRT_IMAGES="/var/lib/libvirt/images"

# Cluster-internal networks (dual-stack: IPv4 first, then IPv6)
CLUSTER_NETWORK_CIDR_V4="10.128.0.0/14"
CLUSTER_HOST_PREFIX_V4=23
CLUSTER_NETWORK_CIDR_V6="fd01::/48"
CLUSTER_HOST_PREFIX_V6=64
SERVICE_NETWORK_CIDR_V4="172.30.0.0/16"
SERVICE_NETWORK_CIDR_V6="fd02::/112"

# Files (relative to script directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULL_SECRET_FILE="${PULL_SECRET_FILE:-${SCRIPT_DIR}/pull-secrets.json}"
SSH_KEY="${SSH_KEY:-}"  # set via environment or paste here
CERT_FILE="${CERT_FILE:-${SCRIPT_DIR}/fullchain.pem}"
KEY_FILE="${KEY_FILE:-${SCRIPT_DIR}/privkey.pem}"
INSTALL_DIR="${SCRIPT_DIR}/ocp-sno-install"

###############################################################################
# Derived values
###############################################################################
API_DOMAIN="api.${CLUSTER_NAME}.${BASE_DOMAIN}"
APPS_DOMAIN="apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
NODE_IFACE="enp1s0"   # default virtio NIC name in KVM guests

###############################################################################
# Preflight checks
###############################################################################
preflight() {
  echo "==> Preflight checks"
  local missing=()
  command -v openshift-install &>/dev/null || missing+=("openshift-install")
  command -v virsh            &>/dev/null || missing+=("virsh")
  command -v virt-install     &>/dev/null || missing+=("virt-install")
  command -v oc               &>/dev/null || missing+=("oc (openshift-client)")
  command -v nmstatectl       &>/dev/null || missing+=("nmstatectl (nmstate)")
  [[ -f "${PULL_SECRET_FILE}" ]] || missing+=("pull-secret (${PULL_SECRET_FILE})")
  [[ -n "${SSH_KEY}" ]]           || missing+=("SSH_KEY not set")
  if (( ${#missing[@]} )); then
    echo "ERROR: missing prerequisites: ${missing[*]}" >&2; exit 1
  fi
  echo "    all OK"

  # Verify TLS certificate covers the cluster domains
  if [[ -f "${CERT_FILE}" ]]; then
    echo "==> Verifying TLS certificate against cluster domains"
    local sans
    sans=$(openssl x509 -in "${CERT_FILE}" -noout -ext subjectAltName 2>/dev/null \
           | grep -oP 'DNS:[^,]+' | sed 's/DNS://g' || true)
    local warn=0
    # Check *.CLUSTER.DOMAIN (covers api.CLUSTER.DOMAIN)
    if ! echo "${sans}" | grep -qF "*.${CLUSTER_NAME}.${BASE_DOMAIN}"; then
      echo "    WARNING: cert does not cover *.${CLUSTER_NAME}.${BASE_DOMAIN} (needed for API)"
      warn=1
    fi
    # Check *.apps.CLUSTER.DOMAIN (covers app routes)
    if ! echo "${sans}" | grep -qF "*.${APPS_DOMAIN}"; then
      echo "    WARNING: cert does not cover *.${APPS_DOMAIN} (needed for routes)"
      warn=1
    fi
    if (( warn == 0 )); then
      echo "    cert OK"
    fi
  fi
  
  # Ensure qemu user can traverse path to install/cache dirs
  echo "==> Ensuring qemu user can access ${SCRIPT_DIR}"
  local dir="${SCRIPT_DIR}"
  while [[ "${dir}" != "/" ]]; do
    sudo setfacl -m u:qemu:x "${dir}"
    dir=$(dirname "${dir}")
  done
}

###############################################################################
# Step 1 — Libvirt network
###############################################################################
create_network() {
  echo "==> Creating libvirt network '${NETWORK_NAME}'"
  if sudo virsh net-info "${NETWORK_NAME}" &>/dev/null; then
    echo "    network already exists, skipping"
    return
  fi

  local net_xml
  net_xml=$(mktemp /tmp/ocp-net-XXXXXX.xml)
  cat > "${net_xml}" <<XMLEOF
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>${NETWORK_NAME}</name>
  <forward mode='route'/>
  <bridge name='${BRIDGE_NAME}' stp='on' delay='0'/>
  <dns>
    <host ip='${NODE_IPV4}'>
      <hostname>${BASE_DOMAIN}</hostname>
      <hostname>api.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
      <hostname>api-int.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
    </host>
    <host ip='${NODE_IPV6}'>
      <hostname>${BASE_DOMAIN}</hostname>
      <hostname>api.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
      <hostname>api-int.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
    </host>
  </dns>
  <ip address='${GATEWAY_IPV4}' netmask='255.255.255.0'/>
  <ip family='ipv6' address='${GATEWAY_IPV6}' prefix='${NETWORK_PREFIX_V6}'/>
  <dnsmasq:options>
    <dnsmasq:option value='listen-address=${GATEWAY_IPV4}'/>
    <dnsmasq:option value='listen-address=${GATEWAY_IPV6}'/>
    <dnsmasq:option value='address=/apps.${CLUSTER_NAME}.${BASE_DOMAIN}/${NODE_IPV4}'/>
    <dnsmasq:option value='address=/apps.${CLUSTER_NAME}.${BASE_DOMAIN}/${NODE_IPV6}'/>
  </dnsmasq:options>
</network>
XMLEOF

  sudo virsh net-define "${net_xml}"
  sudo virsh net-start "${NETWORK_NAME}"
  sudo virsh net-autostart "${NETWORK_NAME}"
  rm -f "${net_xml}"

  setup_dns
  echo "    done"
}

###############################################################################
# Configure host DNS resolution via systemd-resolved (transient, re-runnable)
###############################################################################
setup_dns() {
  echo "==> Configuring host DNS resolution for ${BASE_DOMAIN}"
  sudo resolvectl dns "${BRIDGE_NAME}" "${GATEWAY_IPV4}" "${GATEWAY_IPV6}"
  sudo resolvectl domain "${BRIDGE_NAME}" "~${BASE_DOMAIN}"
  sudo resolvectl default-route "${BRIDGE_NAME}" false
  echo "    queries for *.${BASE_DOMAIN} routed to dnsmasq on ${BRIDGE_NAME}"
}

###############################################################################
# Step 2 — Generate install-config.yaml + agent-config.yaml
###############################################################################
generate_configs() {
  echo "==> Generating install configs in ${INSTALL_DIR}"
  rm -rf "${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}"

  local pull_secret
  pull_secret=$(<"${PULL_SECRET_FILE}")

  # --- install-config.yaml ---
  cat > "${INSTALL_DIR}/install-config.yaml" <<CFGEOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  replicas: 0
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  replicas: 1
networking:
  networkType: OVNKubernetes
  clusterNetwork:
  - cidr: ${CLUSTER_NETWORK_CIDR_V4}
    hostPrefix: ${CLUSTER_HOST_PREFIX_V4}
  - cidr: ${CLUSTER_NETWORK_CIDR_V6}
    hostPrefix: ${CLUSTER_HOST_PREFIX_V6}
  serviceNetwork:
  - ${SERVICE_NETWORK_CIDR_V4}
  - ${SERVICE_NETWORK_CIDR_V6}
  machineNetwork:
  - cidr: ${NETWORK_CIDR_V4}
  - cidr: ${NETWORK_CIDR_V6}
platform:
  none: {}
pullSecret: '${pull_secret}'
sshKey: '${SSH_KEY}'
CFGEOF

  # --- agent-config.yaml ---
  cat > "${INSTALL_DIR}/agent-config.yaml" <<AGENTEOF
apiVersion: v1beta1
kind: AgentConfig
metadata:
  name: ${CLUSTER_NAME}
rendezvousIP: "${NODE_IPV4}"
additionalNTPSources:
- "${NTP_SERVER}"
hosts:
- hostname: sno.${CLUSTER_NAME}.${BASE_DOMAIN}
  role: master
  interfaces:
  - name: ${NODE_IFACE}
    macAddress: "${MAC_ADDRESS}"
  rootDeviceHints:
    deviceName: /dev/vda
  networkConfig:
    interfaces:
    - name: ${NODE_IFACE}
      type: ethernet
      state: up
      ipv4:
        enabled: true
        dhcp: false
        address:
        - ip: "${NODE_IPV4}"
          prefix-length: 24
      ipv6:
        enabled: true
        autoconf: false
        dhcp: false
        address:
        - ip: "${NODE_IPV6}"
          prefix-length: ${NETWORK_PREFIX_V6}
    dns-resolver:
      config:
        server:
        - "${DNS_SERVER}"
    routes:
      config:
      - destination: 0.0.0.0/0
        next-hop-address: "${GATEWAY_IPV4}"
        next-hop-interface: ${NODE_IFACE}
        table-id: 254
      - destination: "::/0"
        next-hop-address: "${GATEWAY_IPV6}"
        next-hop-interface: ${NODE_IFACE}
        table-id: 254
AGENTEOF

  # Keep a backup (openshift-install consumes the originals)
  cp "${INSTALL_DIR}/install-config.yaml" "${INSTALL_DIR}/install-config.yaml.bak"
  cp "${INSTALL_DIR}/agent-config.yaml"   "${INSTALL_DIR}/agent-config.yaml.bak"
  echo "    done"
}

###############################################################################
# Step 3 — Generate agent ISO (cached by config hash)
###############################################################################
generate_iso() {
  local cache_dir="${SCRIPT_DIR}/.iso-cache"
  local hash
  hash=$(cat "${INSTALL_DIR}/install-config.yaml.bak" \
             "${INSTALL_DIR}/agent-config.yaml.bak" \
         | sha256sum | cut -d' ' -f1)
  # include openshift-install version in the hash
  hash=$(echo "${hash}-$(openshift-install version | head -1)" | sha256sum | cut -d' ' -f1)

  local cached_prefix="${cache_dir}/${hash}"

  if [[ -f "${cached_prefix}.iso" && -d "${cached_prefix}.auth" ]]; then
    echo "==> Using cached agent ISO (hash: ${hash:0:12}…)"
    ln -sf "${cached_prefix}.iso" "${INSTALL_DIR}/agent.x86_64.iso"
    cp "${cached_prefix}.state.json" "${INSTALL_DIR}/.openshift_install_state.json"
    cp -r "${cached_prefix}.auth" "${INSTALL_DIR}/auth"
  else
    echo "==> Generating agent ISO (this may take a few minutes)"
    openshift-install --dir "${INSTALL_DIR}" agent create image
    mkdir -p "${cache_dir}"
    cp "${INSTALL_DIR}/agent.x86_64.iso" "${cached_prefix}.iso"
    cp "${INSTALL_DIR}/.openshift_install_state.json" "${cached_prefix}.state.json"
    cp -r "${INSTALL_DIR}/auth" "${cached_prefix}.auth"
    echo "    cached as ${cached_prefix}.iso"
  fi
  echo "    ISO: ${INSTALL_DIR}/agent.x86_64.iso"
}

###############################################################################
# Step 4 — Create and boot the VM
###############################################################################
create_vm() {
  echo "==> Creating VM '${VM_NAME}'"

  # Destroy any previous VM with the same name
  if sudo virsh dominfo "${VM_NAME}" &>/dev/null; then
    echo "    destroying existing VM '${VM_NAME}'"
    sudo virsh destroy  "${VM_NAME}" 2>/dev/null || true
    sudo virsh undefine "${VM_NAME}" --nvram 2>/dev/null || true
  fi
  sudo rm -f "${LIBVIRT_IMAGES}/${VM_NAME}.qcow2" \
              "${LIBVIRT_IMAGES}/${VM_NAME}-data.qcow2"

  sudo virt-install \
    --name "${VM_NAME}" \
    --memory "${VM_RAM}" \
    --vcpus "${VM_VCPUS}" \
    --cpu host-passthrough \
    --os-variant fedora-coreos-stable \
    --disk "path=${LIBVIRT_IMAGES}/${VM_NAME}.qcow2,size=${VM_DISK},bus=virtio,format=qcow2,cache=writeback" \
    --disk "path=${LIBVIRT_IMAGES}/${VM_NAME}-data.qcow2,size=${VM_DATA_DISK},bus=virtio,format=qcow2,cache=writeback" \
    --network "network=${NETWORK_NAME},mac=${MAC_ADDRESS},model=virtio" \
    --cdrom "${INSTALL_DIR}/agent.x86_64.iso" \
    --boot uefi \
    --graphics vnc,listen=:: \
    --check disk_size=off \
    --noautoconsole

  echo "    VM started. Console: sudo virsh console ${VM_NAME}"
  echo "    VNC:     virsh vncdisplay ${VM_NAME}"
}

###############################################################################
# Step 5 — Wait for install to complete
###############################################################################
wait_for_install() {
  echo "==> Waiting for installation to complete ..."
  echo "    (this typically takes 30-50 minutes)"

  # Monitor VM state — RHCOS reboots (and sometimes shuts off) during install
  _ensure_vm_running() {
    while true; do
      sleep 15
      local state
      state=$(sudo virsh domstate "${VM_NAME}" 2>/dev/null || echo "unknown")
      if [[ "${state}" == "shut off" ]]; then
        echo "    VM is shut off — restarting ..."
        sudo virsh start "${VM_NAME}" 2>/dev/null || true
      fi
    done
  }
  _ensure_vm_running &
  local vm_monitor_pid=$!

  openshift-install --dir "${INSTALL_DIR}" agent wait-for bootstrap-complete \
    --log-level=info || { kill "${vm_monitor_pid}" 2>/dev/null; return 1; }
  echo "==> Bootstrap complete, waiting for cluster install ..."
  openshift-install --dir "${INSTALL_DIR}" agent wait-for install-complete \
    --log-level=info || { kill "${vm_monitor_pid}" 2>/dev/null; return 1; }

  kill "${vm_monitor_pid}" 2>/dev/null || true
  echo ""
  echo "==> Installation finished!"
  echo "    kubeconfig : ${INSTALL_DIR}/auth/kubeconfig"
  echo "    kubeadmin pw: $(cat "${INSTALL_DIR}/auth/kubeadmin-password")"
  echo "    console URL : https://console-openshift-console.${APPS_DOMAIN}"
}

###############################################################################
# Step 6 — Apply custom TLS certificates (post-install)
###############################################################################
apply_certs() {
  echo "==> Applying custom TLS certificates"
  if [[ ! -f "${CERT_FILE}" ]] || [[ ! -f "${KEY_FILE}" ]]; then
    echo "    WARNING: cert/key files not found, skipping"
    return
  fi

  export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

  # Wait for cluster operators to settle
  echo "    waiting for cluster operators to stabilize ..."
  oc wait clusteroperators --all --for=condition=Available=True  --timeout=300s || true
  oc wait clusteroperators --all --for=condition=Progressing=False --timeout=300s || true

  # --- Ingress controller cert ---
  echo "    creating ingress TLS secret"
  oc create secret tls custom-ingress-cert \
    --cert="${CERT_FILE}" \
    --key="${KEY_FILE}" \
    -n openshift-ingress \
    --dry-run=client -o yaml | oc apply -f -

  echo "    patching default IngressController"
  oc patch ingresscontroller.operator/default \
    --type=merge \
    -p '{"spec":{"defaultCertificate":{"name":"custom-ingress-cert"}}}' \
    -n openshift-ingress-operator

  # --- API server cert ---
  echo "    creating API server TLS secret"
  oc create secret tls custom-api-cert \
    --cert="${CERT_FILE}" \
    --key="${KEY_FILE}" \
    -n openshift-config \
    --dry-run=client -o yaml | oc apply -f -

  echo "    patching APIServer"
  oc patch apiserver/cluster --type=merge -p \
    "{\"spec\":{\"servingCerts\":{\"namedCertificates\":[{\"names\":[\"${API_DOMAIN}\"],\"servingCertificate\":{\"name\":\"custom-api-cert\"}}]}}}"

  # Update kubeconfig to trust the new cert (Let's Encrypt is publicly trusted)
  echo "    updating kubeconfig to use system CA trust"
  sed -i '/^\s*certificate-authority-data:/d' "${INSTALL_DIR}/auth/kubeconfig"

  echo "    certificates applied — API servers will roll out (~5 min for SNO)"
}

###############################################################################
# Optional — Install LVM Storage operator (run: ./deploy-sno.sh install_lvms)
###############################################################################
install_lvms() {
  echo "==> Installing LVM Storage operator"
  export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

  local ocp_minor
  ocp_minor=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1-2)
  echo "    detected OCP ${ocp_minor}, using channel stable-${ocp_minor}"

  oc apply -f - <<MANIFEST
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage-og
  namespace: openshift-storage
spec:
  targetNamespaces:
  - openshift-storage
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lvms-operator
  namespace: openshift-storage
spec:
  channel: stable-${ocp_minor}
  installPlanApproval: Automatic
  name: lvms-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
MANIFEST

  echo "    waiting for operator deployment ..."
  local found=0
  for i in $(seq 1 36); do
    if oc get deployment lvms-operator -n openshift-storage &>/dev/null; then
      oc wait deployment lvms-operator -n openshift-storage \
        --for=condition=Available --timeout=180s
      found=1
      break
    fi
    sleep 5
  done
  if (( ! found )); then
    echo "    ERROR: lvms-operator deployment not found after 3 minutes" >&2; return 1
  fi

  echo "    waiting for LVMCluster CRD ..."
  found=0
  for i in $(seq 1 36); do
    if oc get crd lvmclusters.lvm.topolvm.io &>/dev/null; then
      found=1
      break
    fi
    sleep 5
  done
  if (( ! found )); then
    echo "    ERROR: LVMCluster CRD not registered after 3 minutes" >&2; return 1
  fi

  echo "    creating LVMCluster"
  oc apply -f - <<'MANIFEST'
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: lvmcluster
  namespace: openshift-storage
spec:
  storage:
    deviceClasses:
    - name: vg1
      default: true
      thinPoolConfig:
        name: thin-pool-1
        sizePercent: 90
        overprovisionRatio: 10
MANIFEST

  echo "    waiting for StorageClass ..."
  found=0
  for i in $(seq 1 30); do
    if oc get storageclass lvms-vg1 &>/dev/null; then
      echo "    StorageClass lvms-vg1 is available"
      oc annotate storageclass lvms-vg1 \
        storageclass.kubernetes.io/is-default-class=true --overwrite
      echo "    lvms-vg1 set as default StorageClass"
      found=1
      break
    fi
    sleep 5
  done
  if (( ! found )); then
    echo "    ERROR: StorageClass lvms-vg1 not created after 2.5 minutes" >&2; return 1
  fi
}

###############################################################################
# Optional — Enable internal image registry (run: ./deploy-sno.sh enable_registry)
###############################################################################
enable_registry() {
  echo "==> Enabling internal image registry"
  export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

  # SNO only needs one replica with Recreate strategy (RWO volume)
  oc patch configs.imageregistry.operator.openshift.io cluster --type merge \
    --patch '{"spec":{"managementState":"Managed","rolloutStrategy":"Recreate","replicas":1,"storage":{"pvc":{"claim":"image-registry-storage"}}}}'

  # Create RWO PVC (LVMS does not support RWX)
  oc apply -f - <<'MANIFEST'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: image-registry-storage
  namespace: openshift-image-registry
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 20Gi
  storageClassName: lvms-vg1
MANIFEST

  echo "    waiting for registry pod ..."
  local found=0
  for i in $(seq 1 60); do
    if oc get deployment image-registry -n openshift-image-registry &>/dev/null; then
      oc wait deployment image-registry -n openshift-image-registry \
        --for=condition=Available --timeout=180s
      echo "    image registry is running"
      found=1
      break
    fi
    sleep 5
  done
  if (( ! found )); then
    echo "    ERROR: image-registry deployment not found after 5 minutes" >&2; return 1
  fi
}

###############################################################################
# Optional — Create developer user (run: ./deploy-sno.sh create_dev_user)
###############################################################################
create_dev_user() {
  echo "==> Creating developer user"
  export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

  local dev_user="${NEW_USER:-developer}"
  local dev_password="${NEW_USER_PASSWORD:-developer}"
  local dev_htpasswd_entry="${NEW_USER_HTPASSWD:-}"

  # Build htpasswd entry
  local htpasswd_entry
  if [[ -n "${dev_htpasswd_entry}" ]]; then
    htpasswd_entry="${dev_htpasswd_entry}"
    dev_user="${htpasswd_entry%%:*}"
    echo "    using provided htpasswd entry for '${dev_user}'"
  else
    if ! command -v htpasswd &>/dev/null; then
      echo "ERROR: htpasswd not found (install httpd-tools)" >&2; return 1
    fi
    htpasswd_entry=$(htpasswd -nbB "${dev_user}" "${dev_password}")
    echo "    created bcrypt hash for '${dev_user}'"
  fi

  # Read existing htpasswd data and append/update user
  local existing
  existing=$(oc get secret htpass-dev-secret -n openshift-config \
    -o jsonpath='{.data.htpasswd}' 2>/dev/null | base64 -d || true)

  local updated
  if [[ -n "${existing}" ]]; then
    # Remove existing entry for this user, then append
    updated=$(echo "${existing}" | grep -v "^${dev_user}:" || true)
    updated="${updated}"$'\n'"${htpasswd_entry}"
  else
    updated="${htpasswd_entry}"
  fi
  # Remove blank lines
  updated=$(echo "${updated}" | sed '/^$/d')

  # Create/update the secret
  echo "    updating htpasswd secret"
  oc create secret generic htpass-dev-secret \
    --from-literal=htpasswd="${updated}" \
    -n openshift-config \
    --dry-run=client -o yaml | oc apply -f -

  # Configure OAuth (only if not already set up)
  local existing_provider
  existing_provider=$(oc get oauth/cluster \
    -o jsonpath='{.spec.identityProviders[?(@.name=="dev-htpasswd")].name}' 2>/dev/null || true)

  if [[ "${existing_provider}" != "dev-htpasswd" ]]; then
    local other_providers
    other_providers=$(oc get oauth/cluster \
      -o jsonpath='{.spec.identityProviders[*].name}' 2>/dev/null || true)
    if [[ -n "${other_providers}" ]]; then
      echo "    NOTE: replacing existing identity providers (${other_providers})"
    fi

    echo "    configuring OAuth identity provider"
    oc apply -f - <<'OAUTH_EOF'
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: dev-htpasswd
    mappingMethod: claim
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpass-dev-secret
OAUTH_EOF

    echo "    waiting for OAuth server rollout ..."
    local found=0
    for i in $(seq 1 60); do
      local ready
      ready=$(oc get deployment oauth-openshift -n openshift-authentication \
              -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      if [[ "${ready}" -ge 1 ]]; then
        found=1
        break
      fi
      sleep 5
    done
    if (( ! found )); then
      echo "    ERROR: OAuth server did not become ready after 5 minutes" >&2; return 1
    fi
    echo "    OAuth server ready"
  else
    echo "    OAuth identity provider already configured"
  fi

  echo ""
  echo "    User '${dev_user}' is ready."
  echo "    Log in:  oc login https://${API_DOMAIN}:6443 -u ${dev_user}"
  echo "    Console: https://console-openshift-console.${APPS_DOMAIN}"
}

###############################################################################
# Main
###############################################################################
main() {
  echo "========================================"
  echo " SNO Deployment: ${CLUSTER_NAME}.${BASE_DOMAIN}"
  echo " Node IPv4:      ${NODE_IPV4} (external)"
  echo " Node IPv6:      ${NODE_IPV6} (external)"
  echo " API:            ${API_DOMAIN}"
  echo " Apps wildcard:  *.${APPS_DOMAIN}"
  echo "========================================"
  echo ""
  echo "DNS records (served by dnsmasq on ${BRIDGE_NAME}):"
  echo "  ${API_DOMAIN}  → ${NODE_IPV4} / ${NODE_IPV6}"
  echo "  api-int.${CLUSTER_NAME}.${BASE_DOMAIN}  → ${NODE_IPV4} / ${NODE_IPV6}"
  echo "  *.${APPS_DOMAIN}  → ${NODE_IPV4} / ${NODE_IPV6}"
  echo ""
  read -rp "Press Enter to continue (Ctrl-C to abort) ..."

  preflight
  create_network
  generate_configs
  generate_iso
  create_vm
  wait_for_install
  apply_certs

  echo ""
  echo "========================================"
  echo " Deployment complete!"
  echo "========================================"
  echo " export KUBECONFIG=${INSTALL_DIR}/auth/kubeconfig"
  echo " oc get nodes"
  echo " oc get clusterversion"
  echo "========================================"
}

# Allow running individual steps: ./deploy-sno.sh <function_name>
if [[ $# -gt 0 ]]; then
  "$@"
else
  main
fi
