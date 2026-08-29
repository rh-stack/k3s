# Phase 2 - GitOps with Argo CD + KSOPS/SOPS

This file logs what was done in phase 2 for education and future replication.
It covers the bootstrap of Argo CD, the SOPS age setup, the KSOPS plugin, the cutover of Jellyfin and qBittorrent to GitOps, and the install of Homepage and Headlamp.
Every pitfall that blocked a sync is here so you can replicate the stack without hitting it again.

## Cluster at phase 2 start

* k3s `v1.36.3+k3s1` single node `k3s` on Debian VM, `secrets-encryption: true` in `/etc/rancher/k3s/config.yaml` and `base/k3s/config.yaml`.
* Node IP `192.168.1.6`. Traefik, CoreDNS, local-path-provisioner, ServiceLB running.
* Two workloads already running from phase 1 via `kubectl apply`: `media/jellyfin` and `media/qbittorrent+gluetun` with `hostPath` on the 250 GB data disk `/dev/sdb` at `/srv/data` (`/srv/data/media` read-only at `/media`, `/srv/data/downloads` at `/downloads`). PVCs `jellyfin-config` and `qbittorrent-config` on `local-path` (system disk). WireGuard NL-FREE#156 `185.107.56.22:51820` with `pUY22Gd3zhSoZZO6p0rxg2F96gwNgkpFjYSun4TWf2s=` and `WIREGUARD_ALLOWED_IPS=0.0.0.0/0`, `userspace` implementation.
* No Argo CD, no SOPS, repo `git@github.com:rh-stack/k3s.git` on `main`, Helm not installed.

## 2.1 SOPS + age tooling

Agent committed `.sops.yaml` and `.gitignore`. You generated the age keypair.

### Files

* `.sops.yaml` at repo root

```yaml
creation_rules:
  - path_regex: secrets/.*\.yaml$
    age: age1xt6wrssyc8t3ykj4dxg9pgk0yd95lpumqvgw5jaz3hgecutcsvss8rwcd3
    encrypted_regex: '^(data|stringData)$'
  - path_regex: apps/.*/secrets(\.enc)?\.yaml$
    age: age1xt6...rwcd3
    encrypted_regex: '^(data|stringData)$'
  - path_regex: apps/.*/secret(\.enc)?\.yaml$
    age: age1xt6...rwcd3
    encrypted_regex: '^(data|stringData)$'
```

 * `.gitignore` ignores `secrets.yaml`, `secret.yaml`, `*.key`, `keys.txt` so only `*.enc.yaml` can be committed.

### Pitfalls fixed

* Initial `.sops.yaml` only matched `*.enc.yaml`. Then `sops --encrypt apps/jellyfin/secrets.yaml > apps/jellyfin/secrets.enc.yaml` failed with `no matching creation rules found` because SOPS matches the input path, not the output. Fixed by widening `path_regex` to `*.yaml` and `(\.enc)?\.yaml` so both `secrets.yaml` and `secrets.enc.yaml` match.
* `sops --encrypt /tmp/test.yaml` from inside the repo also failed when the repo had a `.sops.yaml` that only matched `secrets/` and `apps/*/`. From inside the repo SOPS searches up the tree, finds the repo config and requires a match. Workaround: use a path under `secrets/` or `apps/*/`, or `cd /tmp` so the repo config is not found and pass `--age` explicitly.
* `cat > /tmp/test.yaml <<'YAML'` is a heredoc. After the first line the shell waits for lines until a line exactly `YAML`. It looks hung. Use `printf '...' > file` to avoid it.

### Your steps

```bash
sudo apt-get install age
curl -Lo sops https://github.com/getsops/sops/releases/download/v3.13.3/sops-v3.13.3.linux.amd64
chmod +x sops && sudo mv sops /usr/local/bin/sops
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
# public key: age1xt6wrssyc8t3ykj4dxg9pgk0yd95lpumqvgw5jaz3hgecutcsvss8rwcd3
# back up keys.txt to password manager or paper, never commit it
```

Agent replaced the placeholder `age1REPLACE_WITH_YOUR_AGE_PUBLIC_KEY` in `.sops.yaml` with your public key and committed it.

Verification that `.sops.yaml` is wired:

```bash
cd /home/rythm/_git/k3s
mkdir -p secrets
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: test\n  namespace: media\nstringData:\n  foo: bar\n' > secrets/test.yaml
sops --encrypt secrets/test.yaml > secrets/test.enc.yaml
cat secrets/test.enc.yaml # shows ENC[AES256_GCM,data:...]
sops --decrypt secrets/test.enc.yaml # shows foo: bar
rm secrets/test.yaml secrets/test.enc.yaml
```

The `encrypted_regex` keeps `apiVersion`, `kind`, `metadata` readable and only encrypts `data` and `stringData`.

## 2.2 Install Argo CD

### File

* `base/argocd/helmchart.yaml` - HelmChart CR in `kube-system` that the k3s Helm controller reconciles.

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: argocd
  namespace: kube-system
spec:
  chart: argo-cd
  repo: https://argoproj.github.io/argo-helm
  version: 10.4.0 # appVersion v3.5.1
  targetNamespace: argocd
  createNamespace: true
  valuesContent: |-
    configs:
      params:
        server.insecure: true
    global:
      domain: argocd.k3s.lan
    server:
      ingress:
        enabled: true
        ingressClassName: traefik
        hostname: argocd.k3s.lan
```

### Pitfall

First `helmchart.yaml` used `server.ingress.hosts: [argocd.k3s.lan]`. Chart `10.4.0` expects `server.ingress.hostname: argocd.k3s.lan` and `global.domain`. With `hosts` it fell back to `global.domain` default `argocd.example.com`, so `kubectl -n argocd get ingress` showed `argocd.example.com` instead of `argocd.k3s.lan`. Fixed by setting both `global.domain` and `server.ingress.hostname`.

### Your steps

This is the one-time bootstrap exception where `kubectl apply` is allowed.

```bash
kubectl apply -f base/argocd/helmchart.yaml
kubectl -n kube-system get helmchart argocd
kubectl -n argocd get pods -w # 7 pods Running
kubectl -n argocd get ingress # host argocd.k3s.lan -> 192.168.1.6
```

Add `192.168.1.6 argocd.k3s.lan` to LAN DNS or hosts file, then `http://argocd.k3s.lan`.

Initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
# log in as admin, change password immediately
```

## 2.3 KSOPS plugin

### File change

Added to `base/argocd/helmchart.yaml` values:

```yaml
configs:
  cm:
    kustomize.buildOptions: --enable-alpha-plugins --enable-exec
repoServer:
  volumes:
    - name: sops-age
      secret:
        secretName: sops-age
    - name: custom-tools
      emptyDir: {}
  initContainers:
    - name: install-ksops
      image: alpine:3.20
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
      mountPath: /home/argocd/.config/kustomize/plugin/viaduct.ai/v1/ksops/ksops
      subPath: ksops
    - name: custom-tools
      mountPath: /usr/local/bin/sops
      subPath: sops
```

### Pitfall

First mount was `mountPath: /usr/local/bin/ksops`. Kustomize `v5` as used by Argo CD `v3.5.1` loads exec plugins from `$XDG_CONFIG_HOME/kustomize/plugin/viaduct.ai/v1/ksops/ksops` or `$KUSTOMIZE_PLUGIN_HOME`. With the binary at `/usr/local/bin/ksops` the error was `failed to load generator: unable to find plugin root - tried: /home/argocd/.config/kustomize/plugin, /home/argocd/kustomize/plugin`. Fixed by mounting `ksops` at `/home/argocd/.config/kustomize/plugin/viaduct.ai/v1/ksops/ksops`.

### Your steps

```bash
kubectl -n argocd create secret generic sops-age \
  --from-file=keys.txt=/home/rythm/.config/sops/age/keys.txt \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f base/argocd/helmchart.yaml
kubectl -n argocd get pods -w # repo-server restarts with initContainer install-ksops
kubectl -n argocd describe pod -l app.kubernetes.io/name=argocd-repo-server | grep -A2 ksops
kubectl -n argocd get configmap argocd-cm -o yaml | grep kustomize
# kustomize.buildOptions: --enable-alpha-plugins --enable-exec
```

### Dummy test that proved the decrypt path

Created `apps/dummy-ksops/secret.enc.yaml` encrypted with `age1xt6...`, `kustomization.yaml` and `generator.yaml`:

```yaml
# generator.yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: dummy-generator
files:
  - ./secret.enc.yaml
```

Application `clusters/home/argocd-apps/dummy-ksops.yaml` pointed at `apps/dummy-ksops`. First sync failed with `authentication required: Repository not found` because the GitHub repo was private and the Application used `https://github.com/rh-stack/k3s.git` without credentials. Making the repo public fixed it (`private: false`, `git ls-remote https://github.com/rh-stack/k3s.git` succeeded). Second sync failed with `unable to find plugin root` until the mount fix above. After the fix `kubectl -n default get secret ksops-test -o jsonpath="{.data.foo}" | base64 -d` showed `bar`. The dummy was then deleted from cluster `kubectl -n argocd delete application dummy-ksops` and from git.

## 2.4 Convert Jellyfin and qBittorrent to Argo CD

### Files added

* `apps/jellyfin/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - pvc.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

* `apps/qbittorrent/kustomization.yaml` plus `generator.yaml` and `secret.enc.yaml`

```yaml
# kustomization.yaml
resources:
  - pvc.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
generators:
  - generator.yaml
# generator.yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: qbittorrent-generator
files:
  - ./secret.enc.yaml
# secret.enc.yaml
apiVersion: v1
kind: Secret
metadata:
  name: gluetun-secrets
  namespace: media
stringData:
  WIREGUARD_PRIVATE_KEY: ENC[AES256_GCM,data:...]
```

The `WIREGUARD_PRIVATE_KEY` came from the existing `media/gluetun-secrets` created in phase 1 `cCX1Lwf8KM2nZE4WFKciI1aoRc3sQZGCeJ47s49jBnA=` and was re-encrypted via `sops --encrypt apps/qbittorrent/secret.yaml > apps/qbittorrent/secret.enc.yaml` where `secret.yaml` matched `apps/.*/secret(\.enc)?\.yaml$`.

* `clusters/home/argocd-apps/jellyfin.yaml` and `qbittorrent.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: jellyfin # or qbittorrent
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: https://github.com/rh-stack/k3s.git
    targetRevision: HEAD
    path: apps/jellyfin # or apps/qbittorrent
  destination:
    server: https://kubernetes.default.svc
    namespace: media
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

`apps/qbittorrent/kustomization.yaml` does not list `namespace.yaml` because both apps share `media` and only `jellyfin` should own it. Duplicate namespace management would cause a conflict.

Bulk data stays `hostPath` `Directory` on `/srv/data/media` and `/srv/data/downloads` verified with `ls -lh /srv/data`. Argo CD adopted the already running Deployments, Services and PVCs without recreating the Pods. `kubectl diff -k apps/jellyfin/` and `apps/qbittorrent/` showed no diff before the cutover.

Warning `metadata.finalizers: "resources-finalizer.argocd.argoproj.io": prefer a domain-qualified finalizer name` from `kubectl apply -f clusters/home/argocd-apps/jellyfin.yaml` is harmless. The finalizer is correct.

### VPN endpoint change inside this step

Switched from `NL-FREE#156` `185.107.56.22` `pUY22Gd3zhSoZZO6p0rxg2F96gwNgkpFjYSun4TWf2s=` to `NL-FREE#239` `212.8.249.202` `OFlzJwrpDCqqTYTUQxu9y9Dch5SDQzaEkzuKaE0eJ1E=` with `AllowedIPs 0.0.0.0/0,::/0`. You edited `apps/qbittorrent/secret.enc.yaml` via `sops apps/qbittorrent/secret.enc.yaml`, agent edited `apps/qbittorrent/deployment.yaml` for the public key and endpoint, committed together as `feat(qbittorrent): switch to NL-FREE#239`.

### Other fixes in this step

* Set `revisionHistoryLimit: 3` in `apps/jellyfin/deployment.yaml` and `apps/qbittorrent/deployment.yaml` (and `apps/homepage/deployment.yaml` already had it). Before it defaulted to `10`, so `kubectl -n media get replicaset -l app=qbittorrent` showed 11 ReplicaSets with only one `DESIRED 1`. After `3` the old sets are pruned to 3 on the next rollout.
* `kubectl -n media exec deploy/qbittorrent -c qbittorrent -- curl -s https://am.i.mullvad.net/ip` or `https://ifconfig.me` and `kubectl -n media logs deploy/qbittorrent -c gluetun` verify the VPN exit IP.

## 2.5 Homepage and Headlamp

### Files added

* `apps/homepage/` - plain manifests from `https://github.com/gethomepage/homepage/blob/main/docs/installation/k8s.md` on namespace `homepage`

  * `namespace.yaml`, `serviceaccount.yaml`, `rbac.yaml` (ClusterRole to list `ingresses`, `namespaces`, `pods`, `nodes`, `traefik.io/ingressroutes`, `gateway.networking.k8s.io/httproutes` and `metrics.k8s.io` plus ClusterRoleBinding), `configmap.yaml` (`kubernetes.yaml: mode: cluster`, `settings.yaml`, `bookmarks.yaml`, `services.yaml`, `widgets.yaml`, `docker.yaml`, `proxmox.yaml`, `custom.css`, `custom.js`), `service.yaml` `ClusterIP:3000`, `deployment.yaml` `ghcr.io/gethomepage/homepage:v2.1.2`, `ingress.yaml` `home.k3s.lan` with `gethomepage.dev/enabled: "true"`, `kustomization.yaml`.

* `apps/headlamp/` - Helm chart via Kustomize

```yaml
# kustomization.yaml
helmCharts:
  - name: headlamp
    repo: https://kubernetes-sigs.github.io/headlamp
    version: 0.45.0
    releaseName: headlamp
    namespace: headlamp
    valuesFile: values.yaml
# values.yaml
ingress:
  enabled: true
  ingressClassName: traefik
  annotations: { traefik.ingress.kubernetes.io/router.entrypoints: web }
  hosts:
    - host: headlamp.k3s.lan
      paths:
        - path: /
          type: Prefix
```

Chart `0.45.0` is current at review time. Initial `values.yaml` used `pathType: Prefix` and failed with `missing property 'type'` from the chart's JSON schema. Fixed by using `type: Prefix`.

* `clusters/home/argocd-apps/homepage.yaml` and `headlamp.yaml` with `CreateNamespace=true`.

### Pitfalls and fixes

* **Homepage `CrashLoopBackOff` Host validation** - logs `Host validation failed for: 10.42.0.67:3000. Hint: Set HOMEPAGE_ALLOWED_HOSTS`. The pod's probe goes to its pod IP, not `home.k3s.lan`. Fixed by setting `HOMEPAGE_ALLOWED_HOSTS: "$(MY_POD_IP):3000,home.k3s.lan,localhost:3000"` where `MY_POD_IP` is `valueFrom: fieldRef: status.podIP`.

* **Homepage `EACCES: permission denied, copyfile proxmox.yaml`** - image `v2.1.2` skeleton contains `proxmox.yaml`. The ConfigMap had no `proxmox.yaml`, so the container tried to create it in `/app/config` and failed because the ConfigMap subPath mounts make writes fail as user `1000`. Fixed by adding empty `proxmox.yaml: ""` to the ConfigMap and mounting it.

* **ConfigMap subPath not updating** - `apps/homepage/configmap.yaml` was synced by Argo CD but the Pod kept old files and the UI showed old text. With `subPath` mounts kubelet does not update the file until the Pod is recreated. Fixed by adding `checksum/config: <sha256 of configmap.yaml>` to `apps/homepage/deployment.yaml` `spec.template.metadata.annotations`. Now any ConfigMap change changes the Deployment template, creates a new ReplicaSet and new Pod. Also did a manual `kubectl -n homepage rollout restart deploy/homepage` once.

* **Headlamp token and RBAC** - log in to `headlamp.k3s.lan` requires a ServiceAccount token. You created `headlamp-admin` and a token via `kubectl -n headlamp create token headlamp-admin --duration 8760h`. First `ClusterRoleBinding` `headlamp-admin` was created by Helm for ServiceAccount `headlamp`, not `headlamp-admin`, so `kubectl auth can-i list nodes --as=system:serviceaccount:headlamp:headlamp-admin` was `no` and the UI showed `nodes.metrics.k8s.io is forbidden`. Fixed by creating `clusterrolebinding/headlamp-admin-user` for `headlamp:headlamp-admin` with `cluster-admin`. The correct token then logs in and shows the Map page correctly.

* **Revision history** - Explained `Deployment` creates `ReplicaSet`, `ReplicaSet` creates `Pod`. `kubectl -n media get replicaset -l app=qbittorrent` history is not parallel replicas; `replicas: 1` and `revisionHistoryLimit: 10` default kept 10 old sets. Set to `3` above.

* **Argo CD polling** - `argocd-application-controller` polls `https://github.com/rh-stack/k3s.git` every `timeout.reconciliation: 180s`. `git ls-remote` is cheap. If the commit changed it does `git fetch` and `kustomize build apps/<app> --enable-alpha-plugins --enable-exec`. With `automated.prune: true, selfHeal: true` it auto applies the diff. No GitHub Action is needed. A GitHub webhook to `argocd.k3s.lan/api/webhook` can make it instant but 3 minutes is fine for a single node. `free -h` and `kubectl top pods -A` show the cost.

### Homepage theming fixes

Initial `home.k3s.lan` was dark `zinc` with mountain background `https://images.unsplash.com/photo-1519681393784-d120267933ba` and `cardBlur: sm`. You wanted darker, semitransparent, clean, phthalo green `#123524`, with each header block on its own background and aligned Cluster cards.

Iterations:

* Changed `color: slate` to `zinc`, kept `cardBlur: sm`, added `background` mountain image. The pod did not restart due to subPath, so the UI showed old text. Fixed with checksum and restart.
* Removed the second `Homepage` card. `services.yaml` had manual `Homepage: This dashboard` plus the Ingress auto-discovery `gethomepage.dev/enabled: "true"` created a second `Homepage`. Removed the manual entry, kept the Ingress one. Added `gethomepage.dev/description: Dashboard` to the Ingress so the auto card has the same height as `Headlamp`.
* Fixed `icon: argo` to `icon: argo-cd` (`argo-cd.svg` exists, `argocd.svg` 404).
* Removed `icon: argo` `Argo CD` from `bookmarks.yaml` `Developer`, left only `Github`.
* Fixed header duplication and `API Error`. `widgets.yaml` had both `kubernetes` with `cluster` and `nodes` true and `resources` with `cpu/memory` true, so the top bar showed duplicate CPU and memory. Set `kubernetes.nodes.show: false` and `resources.cpu/memory: false`, kept `resources.disk: /` and `network: true`. `drive not found for target: /srv/data` was the `API Error` because the Homepage pod has no `hostPath /srv/data`. Changed to `disk: /` and later to `disk: /` with `expanded: true` to show free out of total.
* Bars were thin and invisible because `custom.css` had `[class*="bg-theme"] { background-color: rgba(24,24,27,0.55) }` which also matched the progress bar fill. Limited it to only `.bg-theme-200\/50` for cards.
* Green flash at start then grey: `background: https://...` in `settings.yaml` overrode `custom.css` html background. Fixed by setting `backgroundOpacity: 0` and `html, body, #__next, main { background-color: #123524 !important }` and later `#0f2a1a` which is a darker phthalo green. The flash was the custom.css loading after the theme CSS.
* Github icon dim: `icon: github` is a dark SVG on dark background. Changed to `icon: github-light` for dark theme.
* Cluster alignment: `layout.Cluster.columns: 3` with 3 cards left one half empty. Changed to `columns: 2` so `Headlamp` and `Argo CD` sit side by side and `Homepage` auto card aligns. Added `custom.css` for semitransparent header blocks.

Final `apps/homepage/configmap.yaml` state at phase 2 end has `phthalo green` `#0f2a1a` background, `zinc`, `cardBlur: sm`, `layout` `Media 2` `Cluster 2`, `custom.css` with phthalo green and `bg-theme-200/50 rgba(30,41,35,0.7)`, `bookmarks.yaml` only Github, `services.yaml` `Media` 2 and `Cluster` 2 plus Argo CD widget, `widgets.yaml` with `kubernetes` cluster only, `resources` with `disk: /` `expanded: true`, and `proxmox.yaml`.

The Argo CD widget was added after creating the `readonly` API key user via Helm values:

```yaml
configs:
  cm:
    accounts.readonly: apiKey
  rbac:
    policy.csv: "g, readonly, role:readonly"
```

Then `argocd account generate-token --account readonly` or UI Settings -> Accounts -> readonly -> Generate Token produced `eyJhbGciOi...`. Pasted into `services.yaml` `Argo CD` `widget.key`. The `checksum/config` was updated to the sha256 of the new `configmap.yaml` so the new token is mounted.

### Resource usage at phase 2 end

`k3s server` `1.0 GB` with `30` threads is expected. `free -h` showed `3.8Gi total 3.3Gi used 143Mi free 762Mi buff/cache 560Mi available` and `Swap 418Mi` used, which is tight but not OOM. After raising the Proxmox VM memory `Hardware -> Memory` from `4 GiB` to `8 GiB` the guest still showed `3.8Gi` until `sudo reboot`, after which `free -h` showed `7.8Gi` total. Recommend `6-8 Gi` before phase 3 Immich.

## Verification at phase 2 exit

```bash
kubectl -n argocd get applications
# jellyfin Synced Healthy, qbittorrent Synced Healthy, homepage Synced Healthy, headlamp Synced Healthy

kubectl -n media get pods,pvc,ingress
kubectl -n homepage get pods,ingress
kubectl -n headlamp get pods,ingress

curl -I --resolve jf.k3s.lan:80:192.168.1.6 http://jf.k3s.lan
curl -I --resolve qb.k3s.lan:80:192.168.1.6 http://qb.k3s.lan
curl -I --resolve home.k3s.lan:80:192.168.1.6 http://home.k3s.lan
curl -I --resolve headlamp.k3s.lan:80:192.168.1.6 http://headlamp.k3s.lan
curl -I --resolve argocd.k3s.lan:80:192.168.1.6 http://argocd.k3s.lan

kubectl -n media exec deploy/qbittorrent -c qbittorrent -- curl -s https://ifconfig.me
# should be 212.8.249.202 range
```

From here GitOps is the only path: edit files under `apps/<app>/` or `base/`, commit, push to `origin/main`, Argo CD syncs. Direct `kubectl apply` is only for the initial Argo CD HelmChart bootstrap.

## Standing rules

* Agent proposes commits, you review and push, Argo CD syncs.
* Secrets go through SOPS with age, never plaintext in git. `.sops.yaml` enforces `encrypted_regex: '^(data|stringData)$'`.
* Every Deployment keeps `revisionHistoryLimit: 3` to keep etcd small.
* `hostPath` `/srv/data` stays node-local and unreplicated until NFS or Longhorn is decided for Immich.

