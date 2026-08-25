# Operations

Source: https://docs.k3s.io/upgrades, https://docs.k3s.io/advanced, https://docs.k3s.io/cli, https://docs.k3s.io/security, https://docs.k3s.io/datastore

## Upgrades

K3s upgrades are rolling per node.
For single-node homelab just rerun the install script with the new version or channel.

```bash
# Pin to specific version
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.32.4+k3s1 sh -s -
# Or follow stable channel
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable sh -
# Check
k3s --version
kubectl version
```

For HA with multiple servers, upgrade servers one at a time, then agents.
K3s supports automated upgrades via the system-upgrade-controller (install via HelmChart if desired).

Validate after upgrade:

```bash
kubectl -n kube-system get pods
kubectl get helmcharts -A
kubectl get nodes -o wide
```

## Cluster Datastore

Default is embedded SQLite (single-node, fast, simple).
For HA use embedded etcd (`--cluster-init` on first server, join others with `--server https://<first-ip>:6443 --token <token>`).
External DB (Postgres/MySQL/etcd3) is also supported but not needed here.

```bash
# etcd snapshot (backup) - when using embedded etcd
sudo k3s etcd-snapshot save --name pre-upgrade
sudo k3s etcd-snapshot ls
sudo ls /var/lib/rancher/k3s/server/db/snapshots/
# Restore
sudo k3s server --cluster-init --cluster-reset --etcd-snapshot=pre-upgrade
```

SQLite backup: stop k3s (`systemctl stop k3s`) and copy `/var/lib/rancher/k3s/server/db/state.db`, or use `sqlite3 state.db '.backup /backup/state.db'` while running - a plain `cp` of a live database can produce a corrupt copy.
Schedule backups via systemd timer or Cron.
Schedule snapshots via `etcd-snapshot` Cron or a systemd timer.

## Certificates

- CA certificates: self-signed, 10y validity, not auto-renewed. Rotate with `k3s certificate rotate-ca`.
- Client/server certs: 365d validity, auto-renewed within 90d of expiry on each start.

```bash
k3s certificate check
k3s certificate rotate
k3s certificate rotate-ca --help
sudo ls /var/lib/rancher/k3s/server/tls/
# After rotation restart k3s
sudo systemctl restart k3s
kubectl get nodes  # verify apiserver came back
```

For custom CAs place certs before init at `/var/lib/rancher/k3s/server/tls/server-ca.crt` etc - see `k3s certificate rotate-ca` docs.

## Tokens

By default one static token is used for servers and agents, stored at `/var/lib/rancher/k3s/server/node-token` and `/var/lib/rancher/k3s/server/agent-token`.

```bash
cat /var/lib/rancher/k3s/server/node-token
k3s token list
k3s token create --help  # temporary kubeadm-style tokens with TTL
k3s token rotate --help   # rotate static token
```

When rotating, update all agents' `/etc/rancher/k3s/config.yaml` or systemd env before restarting them.

## etcdctl

k3s does not bundle etcdctl.

```bash
ETCD_VERSION="v3.5.13"
curl -sL https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz \
  | sudo tar -zxv --strip-components=1 -C /usr/local/bin
sudo etcdctl version \
  --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt \
  --key=/var/lib/rancher/k3s/server/tls/etcd/client.key \
  endpoint health
sudo etcdctl --cacert ... --cert ... --key ... get / --prefix --keys-only | head
```

## Containerd & Kubelet

K3s generates `/var/lib/rancher/k3s/agent/etc/containerd/config.toml` from a template.
For custom mirrors or runtimes create template files: `config.toml.tmpl` (containerd 1.7, config v2) or `config-v3.toml.tmpl` (containerd 2.0, config v3, preferred since Feb 2025).
See https://docs.k3s.io/advanced.

CoreDNS customization via `coredns-custom` ConfigMap is covered in Networking.
HTTP proxy via `/etc/systemd/system/k3s.service.env` with `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` and `CONTAINERD_*` variants.

## Private Registry

```yaml
# /etc/rancher/k3s/registries.yaml
mirrors:
  docker.io:
    endpoint:
      - https://registry.homelab.local
configs:
  registry.homelab.local:
    auth:
      username: user
      password: pass
    tls:
      cert_file: /etc/rancher/k3s/certs/client.crt
      key_file: /etc/rancher/k3s/certs/client.key
      ca_file: /etc/rancher/k3s/certs/ca.crt
```

The embedded Spegel-style registry mirror is built in but disabled by default.
Enable it with `--embedded-registry: true` in config.yaml if you want peer-to-peer image sharing across nodes; on a single node it adds nothing.

## Debugging & Troubleshooting

```bash
# Node health
k3s check-config
kubectl get nodes -o wide
kubectl describe node <name>

# Core components
kubectl -n kube-system get pods -o wide
kubectl -n kube-system logs deploy/coredns
kubectl -n kube-system logs deploy/traefik
kubectl -n kube-system logs deploy/local-path-provisioner
kubectl -n kube-system logs deploy/metrics-server  # if enabled

# Networking
ss -tulnp | grep -E '6443|10250|8472|80|443|53'
iptables -S | head
kubectl get svc -A
kubectl get ingress -A

# Helm controller
kubectl -n kube-system get helmcharts,helmchartconfigs
kubectl -n kube-system get jobs | grep helm
kubectl -n kube-system logs job/helm-install-traefik-xxxx

# Argo CD
kubectl -n argocd get applications
argocd app get <app>
kubectl -n argocd logs deploy/argocd-repo-server
kubectl -n argocd logs deploy/argocd-application-controller

# Logs & journal
sudo journalctl -u k3s -f
sudo journalctl -u k3s-agent -f
crictl ps -a
crictl logs <container-id>
```

Common issues:

- Agent fails to join: check token, firewall 6443, time sync, and that critical flags match servers.
- Pod stuck Pending: `kubectl describe pod` - check PVC, node affinity, resources.
- HelmChart stuck: check `failurePolicy` and job logs; delete stale `helm-install-*` jobs.
- KSOPS decrypt failure: verify `sops-age` Secret and mount path, and `.sops.yaml` matches committed `.enc.yaml`.
- DNS resolution: check `/etc/resolv.conf` viability warning in `journalctl -u k3s`.

## Proxmox VM Setup (cloud-init)

Per GOAL.md use Proxmox + Debian cloud-init for the k3s VM.
Allocate 2 vCPU / 4GiB RAM minimum, 40GiB disk for start.
Enable `qemu-guest-agent`, set static IP or DHCP reservation, and ensure the VM has a unique hostname (`K3S_NODE_NAME` override if cloning).
Keep the VM separate from the Docker host - iptables/CNI conflict when co-located.

## Tracked Setup Script

All host-level commands go in a versioned script, e.g. `scripts/setup-node.sh` or `scripts/setup-k3s.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
# Reviewed before running - do not ad-hoc SSH
apt-get update && apt-get install -y curl open-iscsi nfs-common
curl -sfL https://get.k3s.io | sh -s - server --secrets-encryption --write-kubeconfig-mode 644
systemctl enable k3s
k3s check-config
```

Commit, review, then execute on the VM - never run untracked commands that the repo does not record.
