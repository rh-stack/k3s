# Implementation Plan

Goal: reach the GOAL.md end state in three phases.
Phase 1 is deliberately small: k3s is already installed, so we stand up two pods (Jellyfin, qBittorrent+gluetun) and verify them before adding any tooling.
Phase 2 adds GitOps (Argo CD + KSOPS/SOPS) plus Homepage and Headlamp.
Phase 3 adds Immich.

Deployment rule for phase 1 only: because Argo CD does not exist yet, we apply committed manifests from this repo with `kubectl` by hand.
This is a documented bootstrap exception.
Phase 2 hands those same manifests to Argo CD, after which the normal rule applies again: Argo CD is the only actor that touches the cluster.

Steps marked **[You]** need a human: sudo on this VM, an account or registration somewhere, DNS changes, or a review/approval decision.
Everything else the agent can prepare as commits, and you apply or approve.

## Current state

- k3s `v1.36.3+k3s1` installed and running on this Debian VM via the plain install script (`curl -sfL https://get.k3s.io | sh -`).
- Consequence: no config file exists, secrets encryption at rest is off, and `/etc/rancher/k3s/k3s.yaml` is root-only (mode 600).
- No workloads deployed. Traefik, local-path-provisioner, ServiceLB, CoreDNS are present but unverified.
- This repo has no commits and no remote yet.

---

## Phase 1 - k3s healthy + Jellyfin + qBittorrent

### 1.1 Verify the base cluster

```bash
sudo k3s kubectl get nodes
sudo k3s kubectl -n kube-system get pods
```

Expect every pod Running and the node Ready.
Traefik, coredns, local-path-provisioner, svclb, and metrics-server should appear.
If anything is not Running, stop here and debug before deploying apps.

**[You]** Run the sudo commands above (or give the agent a sudo path you approve).

### 1.2 Make kubectl usable without sudo

**[You]** Run:

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
chmod 600 ~/.kube/config
kubectl get nodes   # no sudo needed after this
```

### 1.3 Enable secrets encryption at rest

Cheap to do now while the cluster is empty; painful later when secrets exist.
Do it before phase 2 creates any real Secret.

**[You]** Create `/etc/rancher/k3s/config.yaml` with:

```yaml
secrets-encryption: true
```

Then:

```bash
sudo systemctl restart k3s
sudo k3s secrets-encrypt enable
sudo k3s secrets-encrypt status   # expect Status: Enabled
kubectl get nodes                  # confirm cluster came back
```

Commit the same config content in this repo (for example `base/k3s/config.yaml`) so it survives a re-bootstrap.

### 1.4 Commit the repo and pick a remote

The agent prepares the initial commit: GOAL.md, IMPLEMENTATION.md, and the app manifests from 1.5/1.6 under `apps/jellyfin/` and `apps/qbittorrent/`.

**[You]**

- Review and approve the commit.
- Create the GitHub repo (the GitOps reference assumes `github.com/rh-stack/k3s`; rename or adjust) and push.

### 1.5 Deploy Jellyfin

Plain manifests in `apps/jellyfin/`: namespace `media`, PVC `jellyfin-config` on `local-path` + `hostPath` `/srv/data/media` (250GB data disk `/dev/sdb` at `/srv/data`, re-attached from `vm-101`), Deployment, ClusterIP Service, Traefik Ingress at `jf.k3s.lan`.
Media volume mounted read-only at `/media`. Config stays on the 32GB system disk so bulk data does not waste it.
CPU transcode only; GPU comes later.

Apply and verify:

```bash
kubectl apply -f apps/jellyfin/
kubectl -n media get pods,pvc,ingress
curl -I --resolve jf.k3s.lan:80:<node-ip> http://jf.k3s.lan
```

**[You]**

- The 250GB data disk (`/dev/sdb`, `ext4`, `UUID=199a30e2-2775-429b-b0c5-f56d7146de9c`) is mounted at `/srv/data` via `/etc/fstab`. Media already lives at `/srv/data/media` (`_movies`, `_shows`) after the Proxmox re-attach - verify with `ls -lh /srv/data/media`, no PVC copy needed. A temporary read-only check mount was `mount -o ro /dev/sdb /mnt/sdb_check`.
- Add `jf.k3s.lan` to your LAN DNS or, for testing only, your workstation hosts file.
- Confirm playback and a library scan in the browser.

### 1.6 Deploy qBittorrent + gluetun

Plain manifests in `apps/qbittorrent/`: single pod, gluetun sidecar holding the network namespace, qBittorrent container with no ports of its own, PVC `qbittorrent-config` on `local-path` + `hostPath` `/srv/data/downloads` on the 250GB data disk.
Web UI through a Service + Traefik Ingress at `qb.k3s.lan`; the gluetun liveness probe restarts the pod if the VPN dies.

**[You]** You need a WireGuard configuration from a commercial VPN provider (Mullvad, Proton, and similar).
If you do not have one, register now - this is an external signup, not something the agent can do.
Then create the secret directly (plaintext never enters git):

```bash
kubectl -n media create secret generic gluetun-secrets \
  --from-literal=WIREGUARD_PRIVATE_KEY=<your-key>
```

Apply and verify:

```bash
kubectl apply -f apps/qbittorrent/
kubectl -n media get pods
kubectl -n media exec deploy/qbittorrent -c qbittorrent -- curl -s https://am.i.mullvad.net/ip
```

The IP check must return the VPN exit IP, not your home IP.
Also confirm the web UI loads and a test torrent downloads.

### 1.7 Phase 1 exit criteria

- Both pods Running, surviving a pod delete (`kubectl -n media delete pod <name>`) with data intact.
- Ingress URLs resolve from your LAN.
- qBittorrent traffic exits through the VPN.
- All manifests committed and pushed.

Only after both replacements work: remove the old Jellyfin and qBittorrent containers on the old Docker host.
**[You]** Decide when to remove them.

---

## Phase 2 - GitOps, Homepage, Headlamp

### 2.1 Install SOPS + age tooling

Agent commits `.sops.yaml` with creation rules.
**[You]** Generate the age keypair locally, back the private key up offline (password manager or printed paper), and never commit it.

### 2.2 Install Argo CD

One-time bootstrap exception: install via HelmChart CR or helm CLI, expose through Traefik at `argocd.k3s.lan`, change the initial admin password immediately.
**[You]** Log in, change the password, and approve the install.

### 2.3 Install the KSOPS plugin

Patch the argocd-repo-server with an initContainer that installs ksops + sops binaries, mount the age key as the `sops-age` Secret in namespace `argocd`, set `kustomize.buildOptions` globally.
Test the decrypt path with one dummy encrypted Secret before touching real apps.

### 2.4 Convert phase 1 apps to Argo CD

Wrap each `apps/<app>/` in a `kustomization.yaml`, add one Application manifest per app under `clusters/home/argocd-apps/`, re-encrypt the gluetun secret as a SOPS file (custom WireGuard: `WIREGUARD_PRIVATE_KEY` on `NL-FREE#156` at `185.107.56.22:51820`, `WIREGUARD_ALLOWED_IPS=0.0.0.0/0`, `userspace` impl).
Bulk data is now `hostPath` on the 250GB data disk (`/srv/data/media`, `/srv/data/downloads`), not PVCs. Adopt the running workloads: let Argo CD sync over the manually applied resources, verify `hostPath` `Directory` exists on the node, and watch for drift until sync is clean. Both `hostPath` and `local-path` are node-local and unreplicated - acceptable for phase 1, same caveat as 3.2.
From here the standing rule returns: agent proposes commits, you review and merge, Argo CD syncs.

**[You]** Watch several propose -> review -> merge -> sync loops before granting any automation trust (per GOAL.md agent rules).

### 2.5 Homepage and Headlamp

Deploy Homepage (plain manifests per upstream docs, ingress auto-discovery RBAC) and Headlamp (official chart, chart 0.45.0) through Argo CD.
Verify both UIs from the LAN.

---

## Phase 3 - Immich and storage growth

### 3.1 Deploy Immich via its official chart through Argo CD

Chart `immich` from `https://immich-app.github.io/immich-charts` (verified live, 5.0.1 at review time).
Postgres password and API keys go through SOPS.
Short-term: library PVC on `local-path` on the 32GB system disk works but fills quickly. Reuse the phase 1 pattern and put the library on `hostPath` `/srv/data/immich/library` on the 250GB data disk (`/dev/sdb`) until NFS/Longhorn exists. Postgres can stay as PVC short-term.
**[You]** Migrate your existing photos/library from the old host into the library PVC or `hostPath` directory.

### 3.2 Storage decision point

Reassess storage before or right after Immich accumulates data:
Both `local-path` (config PVCs on `sda` 32GB) and `hostPath` (bulk on `sdb` 250GB at `/srv/data`) are node-local and unreplicated, which is acceptable for phase 1 but not for a growing photo library.
Choose NFS-backed PVCs (needs a NAS - **[You]** hardware and setup) or Longhorn, per the Storage reference.
Move Immich Postgres and library data only after a tested backup exists. When choosing, decide together whether Jellyfin/qBittorrent bulk stays on `hostPath` or moves to the new shared storage.

### 3.3 Remaining apps

AdGuard Home, DDNS CronJob, and future Caddy/NAS follow the same pattern once phases 1-3 are stable.
Order and timing per GOAL.md.

---

## Standing rules during all phases

- Agent proposes changes as commits against this repo only.
- Direct `kubectl apply` is allowed in phase 1 only, and only for what this plan lists.
- OS-level changes (packages, sysctl, firewall) go through a tracked script reviewed before running.
- Every phase ends with verification at the boundary it changed: pods, PVC persistence across pod restart, ingress reachability, and (phase 2+) `argocd app get` health.
