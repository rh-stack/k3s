---
name: k3s
description: Lightweight Kubernetes (k3s) operations for this homelab - install and configure k3s, Traefik ingress, storage, Helm controller, GitOps with Argo CD + KSOPS/SOPS, and app recipes. Use when setting up the cluster, writing manifests, or migrating Docker apps to k3s.
---

# k3s Homelab Skill

This skill is the primary reference for the Proxmox -> k3s -> GitOps migration described in `GOAL.md`.
It is grounded in https://docs.k3s.io and tailored to this repo's stack and constraints.

## When to Use

Use this skill when you need to install or configure k3s, write cluster manifests, debug networking or storage, manage Helm charts via the embedded Helm controller, or operate the Argo CD GitOps loop.
Do not use it for ad-hoc `kubectl apply` or SSH changes - this repo requires git-committed proposals that Argo CD syncs.

## Stack At A Glance

This Debian VM is the dedicated k3s host.
The old Docker host stays untouched until each app has a verified replacement.
Cluster is bootstrapped with `k3sup install --ip <VM_IP> --user debian` (see [Installation & Config](references/installation-and-config.md)).
Bundled components in use: Traefik (ingress), local-path-provisioner (storage), ServiceLB (LoadBalancer), Flannel (CNI), CoreDNS, Kube-router (NetworkPolicy).
The embedded Spegel registry mirror is present but disabled by default - enable it with `--embedded-registry` if peer-to-peer image sharing across nodes is wanted; on a single node it adds nothing.
Ingress-nginx (community project) is EOL as of March 2026 and must not be installed - Traefik covers ingress.
GitOps layer: Argo CD with KSOPS plugin for SOPS + age decryption.
Manifests are Helm charts or plain YAML, one directory per app under `apps/<app>/`, with one Argo CD Application per app under `clusters/home/argocd-apps/`.
Argo CD renders every workload directly from `apps/<app>/` (kustomize `helmCharts` for upstream charts, plain resources for custom pods).
`HelmChart` CRs are reserved for bootstrapping Argo CD itself.
Secrets live in `secrets/` encrypted with SOPS and are safe to commit.
Future add-ons: OpenTofu for VM lifecycle and Ansible once node count reaches 10+.

## Canonical Reference

Upstream docs are at https://docs.k3s.io.
Key sections this skill summarizes: Quick-Start, Installation/Configuration, CLI (server/agent), Architecture, Networking, Storage, Helm, Security/Secrets Encryption, Advanced.
Always prefer the installed k3s version's flags (`k3s server --help`, `k3s agent --help`) as the authoritative flag list.

## Repo Conventions (from GOAL.md)

- Agent proposes changes as git commits or PRs against this repo only.
- Argo CD is the only actor that touches the cluster.
- OS or VM level changes (SSH, packages, sysctl) go through a tracked bash script in the repo and are reviewed before running.
- No unattended merge or apply until the propose -> review -> merge -> sync loop has been observed several times.
- Expected layout (adapt as needed, keep Argo CD Applications separate from app charts):

```text
homelab/
├── clusters/home/argocd-apps/   # one Argo CD Application per app
├── apps/
│   ├── jellyfin/
│   ├── qbittorrent/
│   ├── immich/
│   ├── adguard-home/
│   └── homepage/
├── base/
└── secrets/                      # SOPS-encrypted
```

## Quick Start (Single Node)

```bash
# On control node - install server with install script (systemd service)
curl -sfL https://get.k3s.io | sh -s - server \
  --write-kubeconfig-mode 644 \
  --secrets-encryption \
  --disable traefik # only if you plan to reinstall Traefik with custom values, otherwise omit

# Check status
sudo systemctl status k3s
sudo k3s kubectl get nodes
sudo cat /etc/rancher/k3s/k3s.yaml  # kubeconfig

# Join an agent (if scaling out later)
curl -sfL https://get.k3s.io | K3S_URL=https://<server-ip>:6443 K3S_TOKEN=<token> sh -s - agent
# Token lives at /var/lib/rancher/k3s/server/node-token on the server
```

For k3sup path used in this project:

```bash
k3sup install --ip <VM_IP> --user debian --k3s-extra-args '--secrets-encryption --write-kubeconfig-mode 644'
# Merge kubeconfig: export KUBECONFIG=~/kubeconfig then k3sup handles it
```

See [Installation & Config](references/installation-and-config.md) for config file, env vars, and flag precedence.

## Networking Summary

K3s ships Flannel (VXLAN by default) and kube-router for NetworkPolicy.
Traefik is the bundled ingress controller and ServiceLB provides LoadBalancer IPs on bare metal without an external LB.
CoreDNS handles cluster DNS and can be extended via a `coredns-custom` ConfigMap.
For this homelab AdGuard Home needs raw DNS port 53 via a `LoadBalancer` Service backed by ServiceLB or future MetalLB - Traefik cannot carry raw DNS/UDP.
See [Networking](references/networking.md) for Traefik, ServiceLB/MetalLB, Flannel options, and DNS customization.

## Storage Summary

Default is `local-path-provisioner` with StorageClass `local-path`.
It creates hostPath PVs dynamically under `/var/lib/rancher/k3s/storage`.
This is fine for initial migration and is not highly available.
Plan NFS or Longhorn when data grows (Immich, Jellyfin media).
See [Storage](references/storage.md).

## Helm

No extra install is needed.
K3s includes a Helm controller that reconciles `HelmChart` and `HelmChartConfig` CRDs in `kube-system`.
Chart values precedence: chart defaults < HelmChart valuesContent < valuesSecrets < HelmChartConfig valuesContent/valuesSecrets < HelmChart set.
See [Helm Controller](references/helm-controller.md) for CRD fields and packaged-component customization (Traefik).

## GitOps (Argo CD + KSOPS)

Argo CD watches this git repo and syncs Applications.
KSOPS (kustomize + SOPS via viaduct) lets Argo CD decrypt SOPS/age secrets at sync time.
Install order: get core k3s + Traefik + local-path healthy, then Argo CD + KSOPS, then SOPS keys, then apps.
See [GitOps](references/gitops.md).

## Secrets

Enable `--secrets-encryption` at server init for etcd/SQLite at-rest encryption (aescbc default, secretbox optional).
For git-committed secrets use SOPS with an age key and the KSOPS plugin - never commit plaintext.
See [Secrets & SOPS](references/secrets.md).

## Operations

Certificates (CA 10y, client/server 365d auto-renew within 90d), token rotation, upgrades (`k3s server --help`), etcdctl access, and kubelet/containerd tweaks are covered in [Operations](references/operations.md) and [App Recipes](references/app-recipes.md).

## Reference Index

| Guide | Path | Covers |
|---|---|---|
| Installation & Config | [references/installation-and-config.md](references/installation-and-config.md) | install script, binary, config.yaml, env vars, merge behavior |
| Networking | [references/networking.md](references/networking.md) | Flannel, Traefik, ServiceLB/MetalLB, CoreDNS, NetworkPolicy |
| Storage | [references/storage.md](references/storage.md) | local-path, Longhorn, NFS, PVC examples |
| Helm Controller | [references/helm-controller.md](references/helm-controller.md) | HelmChart/HelmChartConfig CRDs, values precedence, auth |
| GitOps | [references/gitops.md](references/gitops.md) | Argo CD install, Application manifests, KSOPS integration |
| Secrets | [references/secrets.md](references/secrets.md) | secrets-encryption, SOPS/age, KSOPS plugin, key rotation |
| App Recipes | [references/app-recipes.md](references/app-recipes.md) | Jellyfin, qBittorrent+gluetun, Immich, AdGuard, Homepage, Headlamp |
| Operations | [references/operations.md](references/operations.md) | upgrades, certs, tokens, etcdctl, containerd, troubleshooting |

## Verification

After any change verify at the appropriate boundary.
For cluster config check `kubectl get nodes`, `kubectl -n kube-system get pods`, `kubectl get helmcharts -A`, and `argocd app get <app>` / `argocd app sync`.
State what remains unverified and why.

## Sources

Primary: https://docs.k3s.io (Introduction, Quick-Start, Installation/Configuration, Networking, Storage, Helm, Security, Advanced, CLI).
This skill was generated 2026-08-24 and should be refreshed when the cluster's k3s minor version changes.
