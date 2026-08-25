# GitOps with Argo CD + KSOPS

Source: https://docs.k3s.io/add-ons/helm, https://argo-cd.readthedocs.io, https://github.com/viaduct-ai/kustomize-sops (KSOPS)

This repo's rule: the agent only proposes git commits or PRs.
Argo CD is the only actor that mutates the cluster.

## Architecture

```text
Developer / Agent --git push--> GitHub (this repo)
                                    |
                                    v
                              Argo CD (in-cluster)
                                    |
                              KSOPS plugin (kustomize + SOPS)
                                    |
                                    v
                              Kubernetes API -> rendered manifests -> pods
```

- App manifests (Helm charts via kustomize `helmCharts`, or plain resources) live in `apps/<app>/`.
Argo CD renders every workload directly from those directories.
`HelmChart` CRs are reserved for bootstrapping Argo CD itself - Argo CD cannot see the health of resources a HelmChart Job installs, so do not use them for apps.
- One Argo CD `Application` per app lives in `clusters/home/argocd-apps/<app>.yaml` and points at its `apps/<app>` directory.
- Encrypted secrets live in `secrets/` and are decrypted at sync time by KSOPS using an age key stored as a Secret in the cluster.

## Install Argo CD on k3s

This is the one-time bootstrap exception: Argo CD must exist before it can manage anything, so installing it with a HelmChart CR or helm CLI is acceptable - everything after it goes through Argo CD.

Via HelmChart CR:

```yaml
# /var/lib/rancher/k3s/server/manifests/argocd.yaml (or via k3sup/Argo bootstrap)
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: argocd
  namespace: kube-system
spec:
  chart: argo-cd
  repo: https://argoproj.github.io/argo-helm
  targetNamespace: argocd
  createNamespace: true
  valuesContent: |-
    configs:
      params:
        server.insecure: true  # Traefik terminates TLS
    server:
      ingress:
        enabled: true
        ingressClassName: traefik
        hosts: [argocd.homelab.local]
```

Or with helm CLI:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl create namespace argocd
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd \
  --set configs.params.server\.insecure=true
kubectl -n argocd get pods
```

Expose via Traefik Ingress - do not expose Argo CD with LoadBalancer unless intentional.

Initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
# Change immediately after login: argocd account update-password
```

## Install KSOPS plugin

KSOPS is a kustomize exec plugin that decrypts SOPS files.
The Argo CD repo-server needs the plugin binary, the `sops` binary, and the age key.
No official KSOPS container image is published, so install both binaries into repo-server with an initContainer:

```yaml
# Helm values for argocd
repoServer:
  volumes:
    - name: sops-age
      secret:
        secretName: sops-age
    - name: custom-tools
      emptyDir: {}
  initContainers:
    - name: install-ksops
      image: alpine:3.20  # pin digest when committing
      command: [sh, -c]
      args:
        - |
          wget -qO- https://github.com/viaduct-ai/kustomize-sops/releases/download/v4.5.1/ksops_4.5.1_Linux_x86_64.tar.gz | tar -xz -C /custom-tools &&
          wget -qO /custom-tools/sops https://github.com/getsops/sops/releases/download/v3.13.3/sops-v3.13.3.linux.amd64 &&
          chmod +x /custom-tools/*
      volumeMounts:
        - name: custom-tools
          mountPath: /custom-tools
  volumeMounts:
    - name: sops-age
      mountPath: /home/argocd/.config/sops/age
      readOnly: true
    - name: custom-tools
      mountPath: /usr/local/bin/ksops
      subPath: ksops
    - name: custom-tools
      mountPath: /usr/local/bin/sops
      subPath: sops
configs:
  cm:
    kustomize.buildOptions: --enable-alpha-plugins --enable-exec
```

Check https://github.com/viaduct-ai/kustomize-sops/releases for the current ksops version and asset name before committing.
If the age key mount path fails, check the user the repo-server image runs as (`/home/argocd/.config/sops/age` vs `/root/.config/sops/age`).

Create the age secret that KSOPS reads (also a one-time bootstrap action - Argo CD cannot decrypt its own key yet):

```bash
# On workstation with age installed
age-keygen -o age.key
# age.key contains: # public key: age1...
kubectl -n argocd create secret generic sops-age \
  --from-file=keys.txt=age.key
# Also keep age.key safe offline - it decrypts all SOPS secrets
```

## Repo layout for Argo CD

```text
.
├── apps/
│   ├── jellyfin/
│   │   ├── kustomization.yaml   # helmCharts entry -> upstream chart
│   │   └── values.yaml
│   └── qbittorrent/
│       ├── kustomization.yaml   # resources list -> plain manifests
│       └── deployment.yaml
├── clusters/
│   └── home/
│       ├── kustomization.yaml  # optional root kustomization
│       └── argocd-apps/
│           ├── jellyfin.yaml
│           ├── immich.yaml
│           └── homepage.yaml
├── base/
│   └── kustomization.yaml
└── secrets/
    ├── jellyfin-secrets.enc.yaml
    └── age-recipients.txt
```

### Argo CD Application example (per app)

Argo CD detects the kustomization in `apps/<app>` automatically; the repo-server's global `kustomize.buildOptions` (set above) enables the KSOPS plugin.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: jellyfin
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: https://github.com/rh-stack/homelab.git
    targetRevision: HEAD
    path: apps/jellyfin
    # kustomization.yaml here renders the helm chart and runs the ksops generator
  destination:
    server: https://kubernetes.default.svc
    namespace: media
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions: [CreateNamespace=true]
```

### With kustomize + KSOPS generator (for SOPS secrets)

```yaml
# apps/jellyfin/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
helmCharts:
  - name: jellyfin
    repo: https://jellyfin.github.io/jellyfin-helm
    version: 3.2.0
    releaseName: jellyfin
    namespace: media
    valuesFile: values.yaml
generators:
  - ksops-secret-generator.yaml
---
# apps/jellyfin/ksops-secret-generator.yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: ksops-secret-generator
files:
  - ./secrets.enc.yaml
```

```yaml
# apps/jellyfin/secrets.enc.yaml (SOPS encrypted - safe to commit)
apiVersion: v1
kind: Secret
metadata:
  name: jellyfin-secrets
  namespace: media
stringData:
  JELLYFIN_PublishedServerUrl: https://jellyfin.homelab.local
```

SOPS creation (see Secrets reference):

```bash
sops --encrypt --age age1... --encrypted-regex '^(data|stringData)$' apps/jellyfin/secrets.enc.yaml
# Or with .sops.yaml config
```

## Bootstrap order (per GOAL.md)

1. Verify k3s healthy: `kubectl -n kube-system get pods`, Traefik and local-path Running.
2. Install Argo CD + KSOPS (HelmChart).
3. Create `sops-age` Secret before syncing any app that needs secrets.
4. Configure `sops` + `age` on workstation and encrypt dummy secret to test decrypt path.
5. Deploy jellyfin (first app, CPU transcode), verify via Argo CD sync.
6. Then qbittorrent+gluetun, then later Immich via Helm, AdGuard, Homepage, Headlamp.
7. Remove old Docker container only after its k3s replacement is verified end-to-end (network, storage, secrets).

## Sync workflow

```bash
kubectl -n argocd get applications
argocd app list
argocd app get jellyfin
argocd app sync jellyfin
argocd app wait jellyfin --health
# Or via UI at https://argocd.homelab.local
```

## Agent rules

- Proposals are diffs to `apps/`, `clusters/home/argocd-apps/`, or `secrets/` only.
- Never `kubectl apply` directly - push a commit and let Argo CD sync.
- OS/VM changes (sysctl, apt, firewall) go in a tracked script like `scripts/setup-node.sh` and require review before running via SSH.
- No auto-merge until the propose->review->merge->sync loop has been observed working repeatedly.

## Troubleshooting

```bash
kubectl -n argocd logs deploy/argocd-repo-server | grep -i ksops
kubectl -n argocd logs deploy/argocd-application-controller
argocd app get <app> --refresh
kubectl -n argocd describe application <app>  # sync errors, missing age key, chart not found
# Common: "failed to generate manifests with kustomize" -> check .sops.yaml and age key mount
```
