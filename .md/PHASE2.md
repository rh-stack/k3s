# Phase 2 - From manual kubectl to GitOps

This is the complete to-do for phase 2. Follow it in order to replicate the stack.
It creates SOPS age encryption, Argo CD, KSOPS, the cutover of Jellyfin and qBittorrent, and Homepage plus Headlamp.
All host names end in `k3s.lan` and resolve to `192.168.1.6`. Bulk data is on the 250 GB disk `/dev/sdb` at `/srv/data`.

## Versions at this point

* k3s `v1.36.3+k3s1` single node, `secrets-encryption: true`
* sops `v3.13.3`, age `1.2.1`, ksops `v4.5.1`, alpine `3.20` for the initContainer
* argo-cd chart `10.4.0` with app `v3.5.1`, homepage `v2.1.2`, headlamp chart `0.45.0`
* Repo `https://github.com/rh-stack/k3s.git` on `main`, made public so Argo CD can fetch via https without a token

## 2.1 SOPS with age

To do:

* Install `age` and `sops` from `https://github.com/getsops/sops/releases`.
* Create the keypair and keep the private part offline. Never commit it.

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
# public key example: age1nbmwrs3333t3ykh4dxd9pgk0yd95lphmqvbw5jaz3hgecutcsvss8rwcd3
```

* Put this in the repo root as `.sops.yaml`. Replace the age value with the real public key.

```yaml
creation_rules:
  - path_regex: secrets/.*\.yaml$
    age: age1xt6wrssyc8t3ykj4dxg9pgk0yd95lpumqvgw5jaz3hgecutcsvss8rwcd3
    encrypted_regex: '^(data|stringData)$'
  - path_regex: apps/.*/secrets(\.enc)?\.yaml$
    age: age1xt6wrssyc8t3ykj4dxg9pgk0yd95lpumqvgw5jaz3hgecutcsvss8rwcd3
    encrypted_regex: '^(data|stringData)$'
  - path_regex: apps/.*/secret(\.enc)?\.yaml$
    age: age1xt6wrssyc8t3ykj4dxg9pgk0yd95lpumqvgw5jaz3hgecutcsvss8rwcd3
    encrypted_regex: '^(data|stringData)$'
```

 * Put this in `.gitignore`:

```
secrets.yaml
secrets.yml
secret.yaml
secret.yml
*.key
keys.txt
```

 * Verify from the repo root:

```bash
mkdir -p secrets
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: test\n  namespace: media\nstringData:\n  foo: bar\n' > secrets/test.yaml
sops --encrypt secrets/test.yaml > secrets/test.enc.yaml
sops --decrypt secrets/test.enc.yaml
rm secrets/test.yaml secrets/test.enc.yaml
```

The file must be under `secrets/` or `apps/*/` to match `path_regex`, or run the command from `/tmp` with `--age <public key>` if it is in `/tmp`.

## 2.2 Argo CD bootstrap

To do:

* Commit this as `base/argocd/helmchart.yaml`:

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: argocd
  namespace: kube-system
spec:
  chart: argo-cd
  repo: https://argoproj.github.io/argo-helm
  version: 10.4.0
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

Use `hostname` and `global.domain`, not `hosts`. `hosts` is ignored and falls back to `argocd.example.com`.

* Apply and verify:

```bash
kubectl apply -f base/argocd/helmchart.yaml
kubectl -n kube-system get helmchart argocd
kubectl -n argocd get pods -w
kubectl -n argocd get ingress # host argocd.k3s.lan -> 192.168.1.6
```

Add `192.168.1.6 argocd.k3s.lan` to LAN DNS or hosts file and open `http://argocd.k3s.lan`.

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
# log in as admin and change the password
```

## 2.3 KSOPS plugin

To do:

* Create the age secret in `argocd`:

```bash
kubectl -n argocd create secret generic sops-age \
  --from-file=keys.txt=/home/rythm/.config/sops/age/keys.txt \
  --dry-run=client -o yaml | kubectl apply -f -
```

* Patch `base/argocd/helmchart.yaml` to add the plugin. Keep the values from 2.2 and add:

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

The `ksops` binary must be at `/home/argocd/.config/kustomize/plugin/viaduct.ai/v1/ksops/ksops`.

* Apply and verify:

```bash
kubectl apply -f base/argocd/helmchart.yaml
kubectl -n argocd get pods -w
kubectl -n argocd get configmap argocd-cm -o yaml | grep kustomize
```

* Test the decrypt path once. Create `apps/dummy-ksops/secret.enc.yaml` with a `kustomization.yaml` and `generator.yaml`, an Application at `clusters/home/argocd-apps/dummy-ksops.yaml` pointing at `apps/dummy-ksops`, let Argo CD sync, check `kubectl -n default get secret ksops-test`, then delete the dummy.

## 2.4 Move Jellyfin and qBittorrent to Argo CD

To do:

* Add `revisionHistoryLimit: 3` to `apps/jellyfin/deployment.yaml` and `apps/qbittorrent/deployment.yaml` under `spec`.

* Wrap `apps/jellyfin` with `kustomization.yaml`:

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

* For `apps/qbittorrent` encrypt the WireGuard private key:

```bash
cat > apps/qbittorrent/secret.yaml <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: gluetun-secrets
  namespace: media
stringData:
  WIREGUARD_PRIVATE_KEY: <private key for k3s_qt2>
YAML
sops --encrypt apps/qbittorrent/secret.yaml > apps/qbittorrent/secret.enc.yaml
rm apps/qbittorrent/secret.yaml
```

Use `WIREGUARD_PUBLIC_KEY OFlzJwrpDCqqTYTUQxu9y9Dch5SDQzaEkzuKaE0eJ1E=`, `WIREGUARD_ENDPOINT_IP 212.8.249.202`, `WIREGUARD_ENDPOINT_PORT 51820`, `WIREGUARD_ALLOWED_IPS 0.0.0.0/0,::/0`, `WIREGUARD_ADDRESSES 10.2.0.2/32`, `userspace`. For the switch to NL-FREE#239 update the same `secret.enc.yaml` via `sops apps/qbittorrent/secret.enc.yaml` and update the three public fields in `deployment.yaml`.

* Add `kustomization.yaml` and `generator.yaml` to `apps/qbittorrent`:

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
```

Do not put `namespace.yaml` in the qbittorrent kustomization - `media` is owned by jellyfin. `CreateNamespace=true` in the Applications covers it.

* Commit the Applications:

```yaml
# clusters/home/argocd-apps/jellyfin.yaml and qbittorrent.yaml
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

* Push and let Argo CD adopt the already running objects:

```bash
git push origin main
kubectl apply -f clusters/home/argocd-apps/jellyfin.yaml
kubectl apply -f clusters/home/argocd-apps/qbittorrent.yaml
kubectl -n argocd get applications -w # Synced Healthy
kubectl -n media get pods,pvc,ingress
kubectl -n media exec deploy/qbittorrent -c qbittorrent -- curl -s https://ifconfig.me
```

HostPaths `/srv/data/media` and `/srv/data/downloads` must exist and be `type: Directory`.

## 2.5 Homepage and Headlamp

To do:

* Homepage `ghcr.io/gethomepage/homepage:v2.1.2` on `home.k3s.lan` - plain manifests in `apps/homepage/` (`namespace.yaml`, `serviceaccount.yaml`, `rbac.yaml` with ClusterRole to list `ingresses` and `nodes`, `configmap.yaml`, `service.yaml` `ClusterIP:3000`, `deployment.yaml`, `ingress.yaml` with `gethomepage.dev/enabled: "true"`, `kustomization.yaml`).

Fixes that must be in the committed files:

  * `HOMEPAGE_ALLOWED_HOSTS: "$(MY_POD_IP):3000,home.k3s.lan,localhost:3000"` where `MY_POD_IP` is `valueFrom: status.podIP`.
  * `proxmox.yaml: ""` in the ConfigMap and mounted in the Deployment, otherwise the image fails `copyfile proxmox.yaml`.
  * `checksum/config: <sha256 of configmap.yaml>` annotation on `spec.template.metadata` so a ConfigMap change made via `subPath` mounts restarts the Pod. Recompute with `sha256sum apps/homepage/configmap.yaml` after every config change.

* Headlamp `0.45.0` on `headlamp.k3s.lan` - chart `https://kubernetes-sigs.github.io/headlamp`:

```yaml
# apps/headlamp/kustomization.yaml
helmCharts:
  - name: headlamp
    repo: https://kubernetes-sigs.github.io/headlamp
    version: 0.45.0
    releaseName: headlamp
    namespace: headlamp
    valuesFile: values.yaml
# apps/headlamp/values.yaml
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

`type: Prefix` is required, `pathType` fails the chart schema.

* Applications `clusters/home/argocd-apps/homepage.yaml` and `headlamp.yaml` pointing at `apps/homepage` and `apps/headlamp` with `CreateNamespace=true`.

* Verify:

```bash
kubectl apply -f clusters/home/argocd-apps/homepage.yaml
kubectl apply -f clusters/home/argocd-apps/headlamp.yaml
kubectl -n argocd get applications -w
kubectl -n homepage get pods,ingress
kubectl -n headlamp get pods,ingress
# add to hosts or LAN DNS: 192.168.1.6 home.k3s.lan headlamp.k3s.lan
curl -I http://home.k3s.lan
curl -I http://headlamp.k3s.lan
```

* Headlamp login: create an admin ServiceAccount and token

```bash
kubectl create serviceaccount headlamp-admin -n headlamp
kubectl create clusterrolebinding headlamp-admin-user --clusterrole=cluster-admin --serviceaccount=headlamp:headlamp-admin
kubectl -n headlamp create token headlamp-admin --duration 8760h
# paste in headlamp.k3s.lan
```

* Homepage theming and Argo CD widget: `apps/homepage/configmap.yaml` holds `kubernetes.yaml: mode: cluster`, `settings.yaml`, `services.yaml`, `widgets.yaml`, `custom.css`. After every change recompute `sha256sum apps/homepage/configmap.yaml` and put it in `deployment.yaml` `checksum/config`. To make `home.k3s.lan` phthalo green `#123524` with semitransparent cards, to fix `API Error` from `disk: /srv/data` inside the pod, and to get `argocd` icon and `github-light` icon, use the final state already committed in this repo as the template.

* Argo CD widget for Homepage: in `base/argocd/helmchart.yaml` add

```yaml
configs:
  cm:
    accounts.readonly: apiKey
  rbac:
    policy.csv: "g, readonly, role:readonly"
```

Then generate a token `argocd account generate-token --account readonly` or UI Settings -> Accounts -> readonly -> Generate Token, and put it in `apps/homepage/configmap.yaml` `services.yaml` `Argo CD` `widget.key` with `url: http://argocd-server.argocd.svc.cluster.local`.

## After 2.5

* `kubectl -n argocd get applications` shows `jellyfin`, `qbittorrent`, `homepage`, `headlamp` all `Synced Healthy`.
* `argocd-application-controller` polls `https://github.com/rh-stack/k3s.git` every 3 minutes. A `git push origin main` makes Argo CD fetch and auto-sync. No GitHub pipeline is needed. A webhook to `argocd.k3s.lan/api/webhook` is optional.
* Keep `revisionHistoryLimit: 3` on all Deployments. Each new change creates a new ReplicaSet.
* For any `apps/homepage/configmap.yaml` change also update the `checksum/config` annotation or run `kubectl -n homepage rollout restart deploy/homepage`.
* Memory: `k3s server` 1.0 GB at idle is expected. With `3.8 Gi` total and `argocd + jellyfin + qbittorrent` used `3.3 Gi` with `available 560 Mi` and `Swap 418 Mi`, grow the Proxmox VM `Hardware -> Memory` to `8 GiB` and `sudo reboot` before phase 3.

## Commands to verify a fresh replication

```bash
kubectl get nodes
kubectl -n kube-system get pods
kubectl -n argocd get pods
kubectl -n media get pods,pvc,ingress
kubectl -n homepage get pods,ingress
kubectl -n headlamp get pods,ingress
curl -I --resolve jf.k3s.lan:80:192.168.1.6 http://jf.k3s.lan
curl -I --resolve qb.k3s.lan:80:192.168.1.6 http://qb.k3s.lan
curl -I --resolve home.k3s.lan:80:192.168.1.6 http://home.k3s.lan
curl -I --resolve headlamp.k3s.lan:80:192.168.1.6 http://headlamp.k3s.lan
curl -I --resolve argocd.k3s.lan:80:192.168.1.6 http://argocd.k3s.lan
```

From now on only push to git. Argo CD is the only writer to the cluster.

