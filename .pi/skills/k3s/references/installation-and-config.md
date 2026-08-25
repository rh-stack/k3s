# Installation & Configuration

Source: https://docs.k3s.io/installation/configuration and https://docs.k3s.io/quick-start, https://docs.k3s.io/cli/server, https://docs.k3s.io/cli/agent

## Requirements

K3s requires a modern kernel and cgroup mounts.
No other external dependencies are needed - containerd, Flannel, CoreDNS, Traefik, ServiceLB, kube-router, local-path-provisioner, and host utilities are bundled.
Check https://docs.k3s.io/installation/requirements for CPU/RAM/disk and port requirements (6443 apiserver, 8472 Flannel VXLAN, 10250 kubelet, etc).

## Install Methods

### 1. Install script (systemd/openrc) - recommended for this homelab

The script at https://get.k3s.io installs k3s as a system service with auto-restart.

```bash
# Server (single-node cluster is fully functional - datastore + control-plane + kubelet)
curl -sfL https://get.k3s.io | sh -s - server --write-kubeconfig-mode 644 --secrets-encryption

# Agent join (set K3S_URL to trigger agent mode)
curl -sfL https://get.k3s.io | K3S_URL=https://<server-ip>:6443 K3S_TOKEN=<from /var/lib/rancher/k3s/server/node-token> sh -s - agent

# Custom channel or version
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable sh -s -
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.32.4+k3s1 sh -s -
```

What the script does: creates `k3s` or `k3s-agent` systemd service, installs `kubectl`/`crictl`/`ctr`/`k3s-killall.sh`/`k3s-uninstall.sh`, writes kubeconfig to `/etc/rancher/k3s/k3s.yaml`.

### 2. k3sup (used in GOAL.md)

```bash
k3sup install --ip <VM_IP> --user debian --k3s-extra-args '--secrets-encryption --write-kubeconfig-mode 644'
# For additional args use --k3s-extra-args and for agent: k3sup join --ip <agent-ip> --server-ip <server-ip> --user debian
k3sup install --ip 10.0.0.10 --user debian --local-path ~/kubeconfig
```

### 3. Binary directly

```bash
curl -Lo /usr/local/bin/k3s https://github.com/k3s-io/k3s/releases/download/v1.32.4+k3s1/k3s
chmod a+x /usr/local/bin/k3s
K3S_KUBECONFIG_MODE=644 k3s server --secrets-encryption
# or k3s agent --server https://k3s.example.com --token mypassword
```

### 4. Container image

`docker.io/rancher/k3s` supports the same `K3S_*` env vars and flags as the binary.

## Configuration Precedence

Order from lowest to highest: config file (`/etc/rancher/k3s/config.yaml`) and drop-ins -> environment variables (`K3S_*`) -> CLI flags.
The install script persists `INSTALL_K3S_EXEC`, `K3S_*` env vars, and trailing args into the systemd env file (`/etc/systemd/system/k3s.service.env`).
Re-running the installer without re-passing values will lose them - prefer the config file for durable settings.

## Config File

Default: `/etc/rancher/k3s/config.yaml` plus drop-ins in `/etc/rancher/k3s/config.yaml.d/*.yaml` (alphabetical).
Override path with `--config` or `K3S_CONFIG_FILE`.
YAML keys map to CLI flags: `--write-kubeconfig-mode 644` becomes `write-kubeconfig-mode: "0644"`.
Repeatable flags become YAML lists.

```yaml
# /etc/rancher/k3s/config.yaml - minimal server
write-kubeconfig-mode: "0644"
tls-san:
  - "k3s.homelab.local"
  - "10.0.0.10"
node-label:
  - "role=homelab"
  - "env=prod"
cluster-init: true
secrets-encryption: true
# To disable a bundled component, repeat the flag or list it:
# disable:
#   - traefik   # only if you manage Traefik externally; normally keep it
```

Agent example:

```yaml
# /etc/rancher/k3s/config.yaml on agent
server: https://10.0.0.10:6443
token: "mynodetoken"
node-label:
  - "workload=media"
```

### Value merge behavior

Last value wins across files.
Append `+` to a key to append instead of replace: `node-taint+:` appends to prior `node-taint:` entries.
All subsequent occurrences must also use `+` to keep appending.
CLI args overwrite the entire list for repeatable flags like `--node-label`.

## Environment variables

Every flag has a `K3S_` env counterpart: `--write-kubeconfig-mode` <-> `K3S_KUBECONFIG_MODE`, `--token` <-> `K3S_TOKEN`, `--server`/`--url` <-> `K3S_URL`.
See https://docs.k3s.io/reference/env-variables for the full table.
For proxy environments `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` and `CONTAINERD_*` variants are written to the systemd env file.

## Critical Flags Must Match Across Servers

If you set `--disable servicelb`, `--cluster-cidr`, `--service-cidr`, `--flannel-backend` etc on the first server, all additional server nodes must use the same values or they fail with `critical configuration value mismatch`.

## Kubelet config

K3s writes defaults to `/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/00-k3s-defaults.conf`.
Options (v1.32+): 1) drop-in files in that dir (recommended), 2) `--kubelet-arg=config=$FILE` or `config-dir=$DIR`, 3) `--kubelet-arg=<kubelet-flag>` like `image-gc-high-threshold=100`.
See https://kubernetes.io/docs/tasks/administer-cluster/kubelet-config-file/ for merging order.

## Uninstall / Reset

```bash
/usr/local/bin/k3s-uninstall.sh        # server
/usr/local/bin/k3s-agent-uninstall.sh  # agent
k3s-killall.sh  # kills containers and cleans pods without uninstalling
```

## Homelab Recommendation

Commit a canonical `/etc/rancher/k3s/config.yaml` template in this repo (e.g. `base/k3s/config.yaml`) and a tracked setup script that copies it and restarts the service.
Keep `k3sup` or `get.k3s.io` invocation in that script so it is reviewable and re-runnable.
Do not hand-edit the live config without committing the change.
