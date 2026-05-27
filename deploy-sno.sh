#!/bin/bash
# Deploy Single-Node OpenShift on libvirt/KVM (IPv6-only, agent-based installer)
set -euo pipefail

###############################################################################
# Configuration — adjust these to your environment
###############################################################################
CLUSTER_NAME="ocp"
BASE_DOMAIN="mydomain.io"

# IPv6 networking
NODE_IP="2002:db8:cafe:d891::1"
GATEWAY_IP="2002:db8:cafe:d891::fffe"   # host bridge IP / default gateway
DNS_SERVER="${GATEWAY_IP}"               # DNS64 resolver reachable from VM
NETWORK_CIDR="2002:db8:cafe:d891::/64"
NETWORK_PREFIX=64

# Libvirt
NETWORK_NAME="ocp-net"
BRIDGE_NAME="virbr-ocp"
VM_NAME="ocp-sno"
VM_VCPUS=12
VM_RAM=32768      # MiB  (minimum 16384, 32768+ recommended)
VM_DISK=120       # GiB
MAC_ADDRESS="52:54:00:00:00:01"
LIBVIRT_IMAGES="/var/lib/libvirt/images"

# Cluster-internal networks (ULA, don't change unless you have a reason)
CLUSTER_NETWORK_CIDR="fd01::/48"
CLUSTER_HOST_PREFIX=64
SERVICE_NETWORK_CIDR="fd02::/112"

# Files
PULL_SECRET_FILE="/etc/cluster/pull-secrets.txt"
SSH_KEY_FILE="${HOME}/.ssh/id_rsa.pub"
CERT_FILE="/etc/cluster/certs/fullchain.pem"
KEY_FILE="/etc/cluster/certs/privkey.pem"
INSTALL_DIR="${HOME}/ocp-sno-install"

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
  [[ -f "${PULL_SECRET_FILE}" ]] || missing+=("pull-secret (${PULL_SECRET_FILE})")
  [[ -f "${SSH_KEY_FILE}" ]]     || missing+=("ssh public key (${SSH_KEY_FILE})")
  if (( ${#missing[@]} )); then
    echo "ERROR: missing prerequisites: ${missing[*]}" >&2; exit 1
  fi
  echo "    all OK"
}

###############################################################################
# Step 1 — Libvirt network
###############################################################################
create_network() {
  echo "==> Creating libvirt network '${NETWORK_NAME}'"
  if virsh net-info "${NETWORK_NAME}" &>/dev/null; then
    echo "    network already exists, skipping"
    return
  fi

  local net_xml
  net_xml=$(mktemp /tmp/ocp-net-XXXXXX.xml)
  cat > "${net_xml}" <<XMLEOF
<network>
  <name>${NETWORK_NAME}</name>
  <forward mode='route'/>
  <bridge name='${BRIDGE_NAME}' stp='on' delay='0'/>
  <ip family='ipv6' address='${GATEWAY_IP}' prefix='${NETWORK_PREFIX}'/>
</network>
XMLEOF

  sudo virsh net-define "${net_xml}"
  sudo virsh net-start "${NETWORK_NAME}"
  sudo virsh net-autostart "${NETWORK_NAME}"
  rm -f "${net_xml}"
  echo "    done"
}

###############################################################################
# Step 2 — Generate install-config.yaml + agent-config.yaml
###############################################################################
generate_configs() {
  echo "==> Generating install configs in ${INSTALL_DIR}"
  rm -rf "${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}"

  local pull_secret ssh_key
  pull_secret=$(<"${PULL_SECRET_FILE}")
  ssh_key=$(<"${SSH_KEY_FILE}")

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
  - cidr: ${CLUSTER_NETWORK_CIDR}
    hostPrefix: ${CLUSTER_HOST_PREFIX}
  serviceNetwork:
  - ${SERVICE_NETWORK_CIDR}
  machineNetwork:
  - cidr: ${NETWORK_CIDR}
platform:
  none: {}
pullSecret: '${pull_secret}'
sshKey: '${ssh_key}'
CFGEOF

  # --- agent-config.yaml ---
  cat > "${INSTALL_DIR}/agent-config.yaml" <<AGENTEOF
apiVersion: v1beta1
kind: AgentConfig
metadata:
  name: ${CLUSTER_NAME}
rendezvousIP: "${NODE_IP}"
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
        enabled: false
      ipv6:
        enabled: true
        autoconf: false
        dhcp: false
        address:
        - ip: "${NODE_IP}"
          prefix-length: ${NETWORK_PREFIX}
    dns-resolver:
      config:
        server:
        - "${DNS_SERVER}"
    routes:
      config:
      - destination: "::/0"
        next-hop-address: "${GATEWAY_IP}"
        next-hop-interface: ${NODE_IFACE}
        table-id: 254
AGENTEOF

  # Keep a backup (openshift-install consumes the originals)
  cp "${INSTALL_DIR}/install-config.yaml" "${INSTALL_DIR}/install-config.yaml.bak"
  cp "${INSTALL_DIR}/agent-config.yaml"   "${INSTALL_DIR}/agent-config.yaml.bak"
  echo "    done"
}

###############################################################################
# Step 3 — Generate agent ISO
###############################################################################
generate_iso() {
  echo "==> Generating agent ISO (this may take a few minutes)"
  openshift-install --dir "${INSTALL_DIR}" agent create image
  echo "    ISO: ${INSTALL_DIR}/agent.x86_64.iso"
}

###############################################################################
# Step 4 — Create and boot the VM
###############################################################################
create_vm() {
  echo "==> Creating VM '${VM_NAME}'"

  # Destroy any previous VM with the same name
  if virsh dominfo "${VM_NAME}" &>/dev/null; then
    echo "    destroying existing VM '${VM_NAME}'"
    virsh destroy  "${VM_NAME}" 2>/dev/null || true
    virsh undefine "${VM_NAME}" --nvram 2>/dev/null || true
  fi
  rm -f "${LIBVIRT_IMAGES}/${VM_NAME}.qcow2"

  sudo virt-install \
    --name "${VM_NAME}" \
    --memory "${VM_RAM}" \
    --vcpus "${VM_VCPUS}" \
    --cpu host-passthrough \
    --os-variant fedora-coreos-stable \
    --disk "path=${LIBVIRT_IMAGES}/${VM_NAME}.qcow2,size=${VM_DISK},bus=virtio,format=qcow2" \
    --network "network=${NETWORK_NAME},mac=${MAC_ADDRESS},model=virtio" \
    --cdrom "${INSTALL_DIR}/agent.x86_64.iso" \
    --boot uefi \
    --graphics vnc,listen=:: \
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
  openshift-install --dir "${INSTALL_DIR}" agent wait-for bootstrap-complete \
    --log-level=info
  echo "==> Bootstrap complete, waiting for cluster install ..."
  openshift-install --dir "${INSTALL_DIR}" agent wait-for install-complete \
    --log-level=info
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

  echo "    certificates applied — API servers will roll out (~5 min for SNO)"
}

###############################################################################
# Main
###############################################################################
main() {
  echo "========================================"
  echo " SNO Deployment: ${CLUSTER_NAME}.${BASE_DOMAIN}"
  echo " Node IP:        ${NODE_IP}"
  echo " API:            ${API_DOMAIN}"
  echo " Apps wildcard:  *.${APPS_DOMAIN}"
  echo "========================================"
  echo ""
  echo "Required DNS AAAA records (all → ${NODE_IP}):"
  echo "  ${API_DOMAIN}"
  echo "  api-int.${CLUSTER_NAME}.${BASE_DOMAIN}"
  echo "  *.${APPS_DOMAIN}"
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
