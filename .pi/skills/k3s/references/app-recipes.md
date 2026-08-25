# App Recipes

Per GOAL.md these are the target workloads.
Delivery pattern for every app: Argo CD renders and syncs it directly from `apps/<app>/` via a `kustomization.yaml` - upstream charts through a `helmCharts` entry, hand-written workloads as plain resources.
One Application manifest points at `apps/<app>` from `clusters/home/argocd-apps/<app>.yaml` (see GitOps reference).
Do not use `HelmChart` CRs for apps - those are reserved for bootstrapping Argo CD itself, and Argo CD cannot see the health of resources a HelmChart Job installs.
All recipes verify via Argo CD sync before removing the old Docker container.

## Global Helm values pattern

```yaml
# apps/<app>/values.yaml (common fields)
replicaCount: 1
image:
  repository: jellyfin/jellyfin
  tag: "10.9.13"
ingress:
  enabled: true
  className: traefik
  hosts:
    - host: jellyfin.homelab.local
      paths:
        - path: /
          pathType: Prefix
persistence:
  config:
    enabled: true
    storageClass: local-path
    size: 5Gi
resources:
  requests: { cpu: 100m, memory: 256Mi }
  limits: { cpu: 2, memory: 4Gi }
```

Pin images by digest when possible.

## 1. Jellyfin (CPU transcode to start)

Start without GPU passthrough.
Plan to add device plugin later for `/dev/dri`.

```yaml
# apps/jellyfin/templates/deployment.yaml snippet
spec:
  containers:
    - name: jellyfin
      image: jellyfin/jellyfin:10.9.13  # pin to current release or digest
      ports:
        - containerPort: 8096
      volumeMounts:
        - name: config
          mountPath: /config
        - name: cache
          mountPath: /cache
        - name: media
          mountPath: /media
          readOnly: true
      # CPU transcode - no devices section yet
      # For GPU later add:
      # resources:
      #   limits:
      #     gpu.intel.com/i915: 1  # or nvidia.com/gpu: 1 with NVIDIA plugin
```

Official chart: `https://jellyfin.github.io/jellyfin-helm`, chart name `jellyfin` (latest 3.2.0 at review time).
Wire it up with kustomize + values:

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
```

```yaml
# apps/jellyfin/values.yaml - adjust keys against the chart's values.yaml
ingress:
  enabled: true
  className: traefik
  hosts:
    - host: jellyfin.homelab.local
      paths: [{ path: /, pathType: Prefix }]
persistence:
  config:
    enabled: true
    storageClass: local-path
    size: 5Gi
```

Mount the media library read-only into the pod (`/media`).
GPU passthrough later: install Intel `intel-gpu-plugin` or NVIDIA `nvidia-device-plugin` DaemonSet, label nodes `gpu=intel`, mount `/dev/dri`.

## 2. qBittorrent + gluetun VPN sidecar (same pod from day one)

Use a single pod with two containers in one network namespace - qBittorrent sends all traffic through gluetun's tunnel and firewall.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: qbittorrent
  namespace: media
spec:
  selector:
    matchLabels: { app: qbittorrent }
  template:
    metadata:
      labels: { app: qbittorrent }
    spec:
      containers:
        - name: gluetun
          image: qmcgaw/gluetun:<pin-to-current-release>
          env:
            - name: VPN_SERVICE_PROVIDER
              value: mullvad  # or protonvpn, etc
            - name: VPN_TYPE
              value: wireguard
            - name: WIREGUARD_PRIVATE_KEY
              valueFrom:
                secretKeyRef: { name: gluetun-secrets, key: WIREGUARD_PRIVATE_KEY }
            - name: FIREWALL_OUTBOUND_SUBNETS
              value: "10.42.0.0/16,10.43.0.0/16"  # allow k8s nets
          securityContext:
            capabilities:
              add: [NET_ADMIN]
          ports:
            # declare all service ports here only - gluetun owns the pod's network namespace
            - containerPort: 8080  # qBittorrent web UI
            - containerPort: 6881
            - containerPort: 6881
              protocol: UDP
          livenessProbe:
            httpGet:
              path: /v1/openvpn/status  # endpoint keeps this name even in wireguard mode
              port: 8000
        - name: qbittorrent
          image: linuxserver/qbittorrent:<pin-to-current-release>
          env:
            - name: PUID
              value: "1000"
            - name: PGID
              value: "1000"
          # no ports block needed - traffic goes through gluetun
          volumeMounts:
            - name: config
              mountPath: /config
            - name: downloads
              mountPath: /downloads
      volumes:
        - name: config
          persistentVolumeClaim: { claimName: qbittorrent-config }
        - name: downloads
          persistentVolumeClaim: { claimName: qbittorrent-downloads }
```

If gluetun dies, the probe restarts the pod.
SOPS secret `gluetun-secrets` holds WireGuard keys.
This is a hand-written workload, so `apps/qbittorrent/kustomization.yaml` lists plain resources (`deployment.yaml`, `pvc.yaml`) instead of a `helmCharts` entry.

PVCs on `local-path` is fine initially; move downloads to NFS when NAS exists.

## 3. Immich (official Helm chart - server + Postgres + Redis + ML)

Use the official chart which bundles Postgres, Redis, and machine-learning in one release.
Repo: `https://immich-app.github.io/immich-charts` (verified live; chart `immich`, latest 5.0.1 at review time).

```yaml
# apps/immich/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
helmCharts:
  - name: immich
    repo: https://immich-app.github.io/immich-charts
    version: 5.0.1
    releaseName: immich
    namespace: immich
    valuesFile: values.yaml
```

```yaml
# apps/immich/values.yaml - adjust keys against the current chart README
immich:
  persistence:
    library:
      existingClaim: immich-library
machine-learning:
  enabled: true
redis:
  enabled: true
postgresql:
  enabled: true
  primary:
    persistence:
      enabled: true
      storageClass: local-path
      size: 20Gi
ingress:
  main:
    enabled: true
    className: traefik
    hosts:
      - host: immich.homelab.local
        paths: [{ path: /, pathType: Prefix }]
```

Create library PVC on `local-path` for now:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: immich-library
  namespace: immich
spec:
  storageClassName: local-path
  accessModes: [ReadWriteOnce]
  resources:
    requests: { storage: 100Gi }
```

Move to NFS/Longhorn when storage grows.

## 4. AdGuard Home (DoH/DoT/DoQ, per-client rules)

Chosen over Pi-hole for native encrypted DNS and per-client rules.
Needs raw DNS port 53 via LoadBalancer - Traefik does not carry DNS.

```yaml
# apps/adguard-home/kustomization.yaml - no maintained official chart; use plain resources
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - pvc.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

```yaml
# apps/adguard-home/deployment.yaml (core fields)
spec:
  template:
    spec:
      containers:
        - name: adguard-home
          image: adguard/adguardhome:<pin-to-current-release>
          ports:
            - containerPort: 3000   # initial setup web UI
            - containerPort: 80     # web UI after setup
            - containerPort: 53
            - containerPort: 53
              protocol: UDP
```

The DNS Service must be `LoadBalancer` so it gets a routable IP outside Traefik:

```yaml
# apps/adguard-home/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: adguard-home-dns
  namespace: adguard
spec:
  type: LoadBalancer
  selector: { app: adguard-home }
  ports:
    - name: dns-tcp
      port: 53
      targetPort: 53
      protocol: TCP
    - name: dns-udp
      port: 53
      targetPort: 53
      protocol: UDP
---
apiVersion: v1
kind: Service
metadata:
  name: adguard-home-web
  namespace: adguard
spec:
  selector: { app: adguard-home }
  ports:
    - name: http
      port: 80
      targetPort: 80
```

Add a normal Traefik Ingress for the web UI against the `adguard-home-web` Service.
ServiceLB will allocate the node's IP as external IP; point your router's DHCP DNS to that IP.
For HA across nodes add MetalLB later (see Networking).

## 5. Homepage (gethomepage.dev) - service launcher

Homepage YAML config lives in git and auto-discovers ingresses via its Kubernetes provider.

Homepage has no official Helm chart (upstream documents plain Kubernetes manifests and calls community charts unofficial).
Deploy it as hand-written resources in `apps/homepage/` following https://github.com/gethomepage/homepage/blob/main/docs/installation/k8s.md - the manifest set includes a ServiceAccount, Service, Deployment, ConfigMap for `settings.yaml`/`services.yaml`, and Ingress.
Commit the Homepage YAML config in that ConfigMap so it lives in git.

For the Kubernetes provider to auto-discover ingresses, give its ServiceAccount a ClusterRole that can list Ingresses cluster-wide, and set `mode: cluster` in `kubernetes.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: homepage-ingress-reader
rules:
  - apiGroups: [networking.k8s.io]
    resources: [ingresses]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: homepage-ingress-reader
subjects:
  - kind: ServiceAccount
    name: homepage
    namespace: homepage
roleRef:
  kind: ClusterRole
  name: homepage-ingress-reader
  apiGroup: rbac.authorization.k8s.io
```

Defer per GOAL.md - install after Jellyfin/qBittorrent are verified.

## 6. Headlamp (cluster web UI)

```yaml
# apps/headlamp/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
helmCharts:
  - name: headlamp
    repo: https://kubernetes-sigs.github.io/headlamp  # verified live; latest 0.45.0 at review time
    version: 0.45.0
    releaseName: headlamp
    namespace: headlamp
    valuesFile: values.yaml
```

```yaml
# apps/headlamp/values.yaml
ingress:
  enabled: true
  ingressClassName: traefik
  hosts:
    - host: headlamp.homelab.local
config:
  baseURL: ""
```

Headlamp shows logs, resource health, and exec in browser.
Defer per GOAL.md.

## 7. DDNS CronJob

Simple CronJob that hits a DDNS provider - no special cluster handling.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ddns
  namespace: infra
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: ddns
              image: curlimages/curl:<pin-to-current-release>
              env:
                - name: DDNS_TOKEN
                  valueFrom:
                    secretKeyRef: { name: ddns-secrets, key: token }
              command: [sh, -c, "curl https://ddns.example.com/update?token=$DDNS_TOKEN"]
          restartPolicy: OnFailure
```

## 8. Future: Caddy and NAS

Caddy runs as its own pod outside Traefik routing for non-HTTP or externally exposed services.
There is no official Caddy Helm chart - deploy a plain Deployment + LoadBalancer Service in `apps/caddy/` when needed.
NAS enables NFS-backed PVCs for Immich/media - wire StorageClass `nfs-csi` when ready (see Storage reference).

## Migration Checklist (per app)

1. Create chart in `apps/<app>/` and Application in `clusters/home/argocd-apps/<app>.yaml`.
2. Encrypt secrets with SOPS and commit.
3. Push commit, watch `argocd app get <app>` and `kubectl -n <ns> get pods,pvc,ingress`.
4. Verify endpoint `https://<app>.homelab.local` and data persistence across pod restart.
5. Only then remove the old container on the old Docker host.

