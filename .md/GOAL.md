# Homelab Migration Plan — Proxmox → k3s → GitOps

## Goal

Move Docker containers (currently SSH-managed on another Debian host) into a k3s
cluster managed by Argo CD, without touching the currently-working services
until each replacement is verified.

## Host

This Debian server is a freshly created server dedicated to k3s — not installed on the existing Docker host (Docker and k3s fight over iptables/CNI on the same box). Old Docker host stays untouched until each app has a working replacement in the cluster, then that one container gets
removed.

## Stack

| Layer | Tool |
|---|---|
| VM | Proxmox + Debian, cloud-init |
| Cluster | k3s, bootstrapped with `k3sup install --ip <VM_IP> --user debian` |
| Ingress | Traefik (bundled with k3s) |
| Storage | local-path-provisioner (bundled with k3s) for now |
| GitOps | Argo CD |
| Manifests | Helm charts, one per app |
| Secrets | SOPS + age, decrypted via the KSOPS plugin in Argo CD |
| Cluster web UI | Headlamp |
| Service launcher | Homepage (gethomepage.dev) — has a Kubernetes provider that auto-lists ingress hosts |

`ingress-nginx` (the community project, not F5's) is EOL as of March 2026.
Don't install it. Traefik covers this.

Not using Terraform or Ansible yet.
- Add **OpenTofu** (not Terraform — MPL license, no vendor risk) once VMs get destroyed/recreated regularly.
- Add **Ansible** once node count hits 10+.

## Repo layout

```
homelab/
├── clusters/home/argocd-apps/   # one Argo CD Application manifest per app
├── apps/
│   ├── jellyfin/
│   ├── qbittorrent/
│   ├── immich/
│   ├── adguard-home/
│   └── homepage/
├── base/
└── secrets/                      # SOPS-encrypted, safe to commit
```

## Apps

- **Jellyfin** — start on CPU transcode. Add GPU passthrough later via the NVIDIA/Intel device plugin (needs setup Docker's `/dev/dri` mount doesn't require).
- **qBittorrent** — run with a `gluetun` VPN sidecar in the same pod from day one.
- **Immich** — deploy via the official Helm chart (server + Postgres + Redis + ML in one release). PVC on local-path is fine short-term; move to NFS or Longhorn once storage grows.
- **AdGuard Home** — chosen over Pi-hole for native DoH/DoT/DoQ and per-client rules. Needs port 53 exposed via MetalLB `LoadBalancer` — Traefik ingress doesn't carry raw DNS traffic.
- **Homepage** — service launcher, config as YAML in git, auto-discovers ingress hosts.
- **Headlamp** — cluster state, logs, resource health, in a browser.
- **DDNS** — CronJob, no special handling needed.
- **Caddy** (future) — its own pod, for anything outside the Traefik-routed apps.
- **NAS** (future) — NFS-backed PVCs for Immich/media once it exists.

## Migration order

1. k3s up on the new VM [this is done], confirm Traefik + local-path work.
2. Install Argo CD + KSOPS plugin, point Argo CD at the git repo.
3. Set up SOPS + age keys before deploying anything with a secret.
4. Jellyfin (CPU transcode).
5. qBittorrent + gluetun.
6. Adguard, Immich via Helm, Homepage + Headlamp will go later, don't do it now
7. Remove each old container only after its replacement is confirmed working.

## Agent rules

- Agent proposes changes as git commits/PRs against this repo only. Never applies directly to the cluster — Argo CD is the only thing that touches it.
- OS/VM-level changes (SSH, packages, sysctl) stay outside GitOps. Route them through a tracked bash script in the repo, reviewed before running — not ad-hoc SSH.
- No unattended merge/apply rights until you've watched the propose → review → merge → Argo CD sync loop work reliably a few times.
