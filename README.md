# deploy-sno.sh

Deploy a Single-Node OpenShift (SNO) cluster on libvirt/KVM using the
agent-based installer. The script creates a dual-stack (IPv4 + IPv6) VM
with static networking, applies custom TLS certificates, and optionally
installs LVM Storage and the internal image registry.

## Prerequisites

- `openshift-install` (download from [mirror.openshift.com](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/))
- `oc` (OpenShift CLI)
- `virsh`, `virt-install` (libvirt/QEMU)
- `nmstatectl` (nmstate)
- A Red Hat pull secret at `./pull-secrets.json` ([cloud.redhat.com](https://console.redhat.com/openshift/install/pull-secret))
- TLS certificate and key at `./fullchain.pem` and `./privkey.pem` (optional)

### Network routing

The libvirt network uses `forward mode='route'`, which means the host
machine acts as a router for the VM subnet. You need to add static
routes on your network router so that traffic to the VM subnets is
forwarded to the host machine:

| Destination | Via (host machine) |
|-------------|-------------------|
| `10.0.200.0/24` | host's LAN IPv4 address |
| IPv6 prefix (`/64`) | host's link-local IPv6 address (`fe80::...`) |

Without these routes the VM has no internet access and is unreachable
from the rest of the network.

### DNS

The following records must point to the node's IP addresses before
installation:

| Record | Example |
|--------|---------|
| `api.<cluster>.<domain>` | `api.ocp.mydomain.io` |
| `api-int.<cluster>.<domain>` | `api-int.ocp.mydomain.io` |
| `*.apps.<cluster>.<domain>` | `*.apps.ocp.mydomain.io` |

### TLS certificates

The certificate must include wildcard SANs for:
- `*.<cluster>.<domain>` (covers the API)
- `*.apps.<cluster>.<domain>` (covers application routes)

If no certificate files are present the script skips TLS configuration
and the cluster uses self-signed certificates.

## Configuration

All variables at the top of `deploy-sno.sh` can be overridden via
environment variables. Environment values take precedence over the
defaults in the script.

| Variable | Default | Description |
|----------|---------|-------------|
| `CLUSTER_NAME` | `ocp` | Cluster name |
| `BASE_DOMAIN` | `mydomain.io` | Base DNS domain |
| `IPV6_PREFIX` | `2002:db8:cafe:d893` | IPv6 /64 prefix (node/gateway derived from this) |
| `IPV4_SUBNET` | `10.0.200` | IPv4 /24 subnet (node/gateway derived from this) |
| `SSH_KEY` | *(empty)* | SSH public key for `core` user |
| `VM_VCPUS` | `12` | Virtual CPUs |
| `VM_RAM` | `32768` | Memory in MiB (minimum 16384) |
| `VM_DISK` | `120` | OS disk in GiB |
| `VM_DATA_DISK` | `80` | Data disk in GiB (for LVMS) |
| `NTP_SERVER` | `pool.ntp.org` | NTP server |
| `VM_NAME` | `ocp-sno` | Libvirt VM name |
| `NETWORK_NAME` | `ocp-net` | Libvirt network name |

Example with environment overrides:

```bash
BASE_DOMAIN=example.com IPV6_PREFIX=2001:db8:1:2 SSH_KEY="ssh-ed25519 AAAA..." ./deploy-sno.sh
```

See the script header for the full list of variables (network CIDRs,
file paths, cluster-internal subnets, etc.).

## Usage

### Full deployment

```bash
./deploy-sno.sh
```

This runs all steps in order:

1. **preflight** -- check prerequisites, verify TLS SANs, set filesystem ACLs
2. **create_network** -- create a routed libvirt network with DNS host entries
3. **generate_configs** -- generate `install-config.yaml` and `agent-config.yaml`
4. **generate_iso** -- build the agent ISO (cached by config hash)
5. **create_vm** -- create and boot the VM (two disks, UEFI)
6. **wait_for_install** -- monitor the VM and wait for cluster completion
7. **apply_certs** -- apply custom TLS certificates to ingress and API server

### Individual steps

Any function can be run independently:

```bash
./deploy-sno.sh preflight
./deploy-sno.sh create_network
./deploy-sno.sh generate_configs
# ...
```

### Post-install optional steps

```bash
# Install LVM Storage operator (provides default StorageClass)
./deploy-sno.sh install_lvms

# Enable the internal image registry
./deploy-sno.sh enable_registry
```

## After deployment

```bash
export KUBECONFIG=./ocp-sno-install/auth/kubeconfig
oc get nodes
oc get clusterversion
oc get clusteroperators
```

The web console is available at `https://console-openshift-console.apps.<cluster>.<domain>`.

### Cluster lifecycle

```bash
# Shut down
sudo virsh shutdown ocp-sno

# Start
sudo virsh start ocp-sno

# Destroy and remove
sudo virsh destroy ocp-sno
sudo virsh undefine ocp-sno --nvram
sudo virsh net-destroy ocp-net
sudo virsh net-undefine ocp-net
```

## Caveats

- **Host memory**: Do not allocate more than roughly half of the host's
  RAM to the VM. For example, allocating 48 GiB on a 64 GiB host caused
  the OOM killer to terminate QEMU. The default 32 GiB leaves enough
  headroom for the host, libvirtd, and page cache.
- **Install timeout**: The first `wait-for install-complete` may time out
  (typically around 70% progress). This is normal for SNO. Re-running
  `./deploy-sno.sh wait_for_install` usually succeeds.

## Notes

- **ISO caching**: The agent ISO is cached under `.iso-cache/` keyed by a
  hash of the install configs and the `openshift-install` version. Changing
  any config variable or upgrading the installer invalidates the cache.
- **VM auto-restart**: During installation RHCOS sometimes shuts off instead
  of rebooting. The script monitors the VM state and restarts it automatically.
- **Disk format**: Both disks use thin-provisioned qcow2 with `cache=writeback`.
  The OS disk size can exceed the host's free space thanks to `--check disk_size=off`.
- **LVMS**: The second data disk is used by LVM Storage for dynamic PV
  provisioning. The `install_lvms` function auto-detects the OCP version
  to select the correct operator channel.
- **Image registry**: Disabled by default on `platform: none`. The
  `enable_registry` function creates a 20 GiB RWO PVC (LVMS does not
  support RWX) and enables the registry with a single replica.

## File layout

```
.
├── deploy-sno.sh        # deployment script
├── pull-secrets.json    # Red Hat pull secret (not committed)
├── fullchain.pem        # TLS certificate chain (not committed)
├── privkey.pem          # TLS private key (not committed)
├── ocp-sno-install/     # generated install directory (not committed)
└── .iso-cache/          # cached agent ISOs (not committed)
```
