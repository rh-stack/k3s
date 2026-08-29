# Phase 1 - From empty k3s to Jellyfin + qBittorrent on the 250 GB disk

This is the complete to-do for phase 1. Follow it in order to replicate the stack.
It verifies the base cluster, enables secrets encryption, bootstraps the repo, deploys Jellyfin and qBittorrent+gluetun with a Proton WireGuard tunnel, and moves bulk data to the 250 GB disk on the host.
All host names end in `k3s.lan` and resolve to `192.168.1.6`. Bulk data is on the 250 GB disk `/dev/sdb` at `/srv/data`.

## Versions at this point

* k3s `v1.36.3+k3s1` single node, `secrets-encryption: true`
* jellyfin `10.11.11` `sha256:aefb67e6a7ff1debdd154a78a7bbb780fd0c873d8639210a7f6a2016ad2b35db`
* gluetun `latest` `sha256:8e92dcb57ed64b0e4469c933f00ef1e09ee00867fee150e783a95fa6b53effa4`
* qbittorrent `5.2.3` `sha256:304b19cf94bf4fda534e0b086cab9c5f1a9e139a8180c05c0ad7d2ba1526fa99`
* Storage `local-path` default, disks `sda 32G` system `/` + `sdb 250G ext4 UUID 199a30e2-2775-429b-b0c5-f56d7146de9c` at `/srv/data`
* Repo `https://github.com/rh-stack/k3s.git` on `main`

## 1.1 Verify the base cluster

To do:

* The node is already installed via `curl -sfL https://get.k3s.io | sh -`.

```bash
sudo k3s kubectl get nodes
sudo k3s kubectl -n kube-system get pods
```

Expect `Ready` and `Running` for `traefik-`, `coredns`, `local-path-provisioner`, `svclb-traefik-`, `metrics-server`.

## 1.2 Make kubectl usable without sudo

To do:

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
chmod 600 ~/.kube/config
kubectl get nodes
```

## 1.3 Enable secrets encryption at rest

To do:

* Create `/etc/rancher/k3s/config.yaml`:

```yaml
secrets-encryption: true
```

* Commit the same content as `base/k3s/config.yaml` so a re-bootstrap keeps it.

```bash
sudo systemctl restart k3s
sudo k3s secrets-encrypt enable
sudo k3s secrets-encrypt status   # Status: Enabled
kubectl get nodes
```

## 1.4 Commit the repo and pick a remote

To do:

```bash
git add GOAL.md IMPLEMENTATION.md base/ .pi/
git commit -m "chore: bootstrap repo with goal, implementation plan, and k3s config"
# amend once to include .pi/ and the global identity
git config user.name "Russ Heller"
git config user.email "heller.ruslan+github@gmail.com"
git commit --amend --reset-author --no-edit
git remote add origin git@github.com:rh-stack/k3s.git
git push -u origin main
```

`.pi/` holds the k3s skill and references. Keep it tracked.

## 1.5 Deploy Jellyfin

To do:

* Commit this as `apps/jellyfin/`:

```yaml
# namespace.yaml
apiVersion: v1
kind: Namespace
metadata: { name: media }
---
# pvc.yaml - only config stays on local-path, media is hostPath
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: jellyfin-config, namespace: media }
spec:
  storageClassName: local-path
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 5Gi } }
---
# deployment.yaml - excerpt
spec:
  strategy: { type: Recreate }
  template:
    spec:
      containers:
        - name: jellyfin
          image: jellyfin/jellyfin:10.11.11@sha256:aefb67e6a7ff1debdd154a78a7bbb780fd0c873d8639210a7f6a2016ad2b35db
          ports: [{ containerPort: 8096, name: http }]
          volumeMounts:
            - { name: config, mountPath: /config }
            - { name: cache, mountPath: /cache }
            - { name: media, mountPath: /media, readOnly: true }
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits: { cpu: "2", memory: 4Gi }
          readinessProbe: { httpGet: { path: /health, port: 8096 }, initialDelaySeconds: 10, periodSeconds: 10 }
          livenessProbe: { httpGet: { path: /health, port: 8096 }, initialDelaySeconds: 30, periodSeconds: 30 }
      volumes:
        - { name: config, persistentVolumeClaim: { claimName: jellyfin-config } }
        - { name: cache, emptyDir: {} }
        - { name: media, hostPath: { path: /srv/data/media, type: Directory } }
---
# service.yaml
apiVersion: v1
kind: Service
metadata: { name: jellyfin, namespace: media }
spec:
  type: ClusterIP
  selector: { app: jellyfin }
  ports: [{ name: http, port: 8096, targetPort: http }]
---
# ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jellyfin
  namespace: media
  annotations: { traefik.ingress.kubernetes.io/router.entrypoints: web }
spec:
  ingressClassName: traefik
  rules:
    - host: jf.k3s.lan
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: jellyfin, port: { number: 8096 } } }
```

* Bulk data is **not** a PVC. The 250 GB disk `/dev/sdb` `ext4` `UUID 199a30e2-2775-429b-b0c5-f56d7146de9c` is mounted at `/srv/data` via `/etc/fstab`. The data was already on the disk after `vm-101` -> `vm-102` re-attach. No `rsync` is needed any more.

* Verify the disk before the first apply:

```bash
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINT
# sdb 250G ext4 199a30e2-2775-429b-b0c5-f56d7146de9c /srv/data
cat /etc/fstab
# UUID=199a30e2-2775-429b-b0c5-f56d7146de9c /srv/data ext4 defaults 0 2
ls -lh /srv/data/media  # _movies _shows
```

* Apply and verify:

```bash
kubectl apply -f apps/jellyfin/
kubectl -n media get pods,pvc,ingress
curl -I --resolve jf.k3s.lan:80:192.168.1.6 http://jf.k3s.lan/health  # 200
kubectl -n media exec deploy/jellyfin -- ls /media  # _movies _shows
```

* Inside Jellyfin Web UI the library folders are `/media/_movies` and `/media/_shows`, not `/srv/data/media/...`. `.Trash-1000`, `lost+found` and `.hist` on `/srv/data` are ignored.

* Fix that must be in the committed files:

  * `ingress` host `jf.k3s.lan`, not `jellyfin.homelab.local`. `.local` is `mDNS` on Arch and bypasses the Mikrotik.
  * `strategy: Recreate` for the local data.
  * `hostPath` `Directory`, not `PersistentVolumeClaim` for media. The old `jellyfin-media` `500Gi` PVC is deleted after the cutover (`kubectl -n media delete pvc jellyfin-media`).

Add to Mikrotik or hosts file:

```bash
/ip dns static add name=jf.k3s.lan address=192.168.1.6
# or on Arch: 192.168.1.6 jf.k3s.lan in /etc/hosts
```

## 1.6 Deploy qBittorrent + gluetun

To do:

* Create the WireGuard private key from Proton. At `account.protonvpn.com -> Downloads -> WireGuard -> Generate` pick a `FREE` node. For this stack use `NL-FREE#156`:

```
PublicKey = pUY22Gd3zhSoZZO6p0rxg2F96gwNgkpFjYSun4TWf2s=
Endpoint  = 185.107.56.22:51820
Address   = 10.2.0.2/32
```

* Create the secret directly, never commit it:

```bash
kubectl -n media create secret generic gluetun-secrets \
  --from-literal=WIREGUARD_PRIVATE_KEY=<private key for NL-FREE#156>
# verify length: 44 after one base64 decode
kubectl -n media get secret gluetun-secrets -o jsonpath='{.data.WIREGUARD_PRIVATE_KEY}' | base64 -d | wc -c  # 44
```

* Commit this as `apps/qbittorrent/`:

```yaml
# pvc.yaml - only config
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: qbittorrent-config, namespace: media }
spec:
  storageClassName: local-path
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 5Gi } }
---
# service.yaml
apiVersion: v1
kind: Service
metadata: { name: qbittorrent, namespace: media }
spec:
  type: ClusterIP
  selector: { app: qbittorrent }
  ports: [{ name: http, port: 8080, targetPort: 8080 }]
---
# ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: qbittorrent
  namespace: media
  annotations: { traefik.ingress.kubernetes.io/router.entrypoints: web }
spec:
  ingressClassName: traefik
  rules:
    - host: qb.k3s.lan
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: qbittorrent, port: { number: 8080 } } }
---
# deployment.yaml - excerpt, single pod with sidecar
spec:
  strategy: { type: Recreate }
  template:
    spec:
      containers:
        - name: gluetun
          image: qmcgaw/gluetun:latest@sha256:8e92dcb57ed64b0e4469c933f00ef1e09ee00867fee150e783a95fa6b53effa4
          env:
            - { name: VPN_SERVICE_PROVIDER, value: custom }
            - { name: VPN_TYPE, value: wireguard }
            - { name: WIREGUARD_PRIVATE_KEY, valueFrom: { secretKeyRef: { name: gluetun-secrets, key: WIREGUARD_PRIVATE_KEY } } }
            - { name: WIREGUARD_ADDRESSES, value: "10.2.0.2/32" }
            - { name: WIREGUARD_PUBLIC_KEY, value: "pUY22Gd3zhSoZZO6p0rxg2F96gwNgkpFjYSun4TWf2s=" }
            - { name: WIREGUARD_ENDPOINT_IP, value: "185.107.56.22" }
            - { name: WIREGUARD_ENDPOINT_PORT, value: "51820" }
            - { name: WIREGUARD_ALLOWED_IPS, value: "0.0.0.0/0" }
            - { name: WIREGUARD_IMPLEMENTATION, value: "userspace" }
            - { name: FIREWALL_OUTBOUND_SUBNETS, value: "10.42.0.0/16,10.43.0.0/16,10.2.0.1/32" }
            - { name: DNS_UPSTREAM_RESOLVER_TYPE, value: "plain" }
            - { name: DNS_UPSTREAM_PLAIN_ADDRESSES, value: "1.1.1.1:53" }
            - { name: HEALTH_RESTART_VPN, value: "on" }
          lifecycle:
            postStart:
              exec: { command: ["/bin/sh", "-c", "(ip rule del table 51820; ip -6 rule del table 51820) || true"] }
          securityContext: { capabilities: { add: [NET_ADMIN] } }
          ports:
            - { containerPort: 8080, name: http }
            - { containerPort: 6881, name: torrent }
            - { containerPort: 6881, name: torrent-udp, protocol: UDP }
          livenessProbe: { tcpSocket: { port: 8000 }, initialDelaySeconds: 30, periodSeconds: 15 }
          readinessProbe: { tcpSocket: { port: 8000 }, initialDelaySeconds: 10, periodSeconds: 10 }
        - name: qbittorrent
          image: linuxserver/qbittorrent:5.2.3@sha256:304b19cf94bf4fda534e0b086cab9c5f1a9e139a8180c05c0ad7d2ba1526fa99
          env:
            - { name: PUID, value: "1000" }
            - { name: PGID, value: "1000" }
            - { name: TZ, value: "Etc/UTC" }
            - { name: WEBUI_PORT, value: "8080" }
          volumeMounts:
            - { name: config, mountPath: /config }
            - { name: downloads, mountPath: /downloads }
      volumes:
        - { name: config, persistentVolumeClaim: { claimName: qbittorrent-config } }
        - { name: downloads, hostPath: { path: /srv/data/downloads, type: Directory } }
```

* Fixes that must be in the committed files:

  * `VPN_SERVICE_PROVIDER=custom` with the exact `PublicKey`/`Endpoint` from the downloaded `.conf`. `protonvpn` provider mode picks random paid nodes and fails with a `FREE` key. `US-FREE#13 149.40.62.31` was `163ms`, `NL-FREE#156 185.107.56.22` is `39ms`.
  * `WIREGUARD_ALLOWED_IPS=0.0.0.0/0` - without it `tun0` has no route and `ping -I tun0 10.2.0.1` fails.
  * `postStart` `ip rule del table 51820` - `kernelspace` WireGuard leaves `table 51820` on abrupt exit and fails `file exists`. `userspace` with this cleanup is stable.
  * `tcpSocket` on `8000` - `httpGet /v1/openvpn/status` returns `401` on this image.
  * `WIREGUARD_IMPLEMENTATION=userspace` and `DNS plain 1.1.1.1:53` - `dot` stalls on `FREE` handshake.

* HostPath `Directory` must exist before apply:

```bash
mkdir -p /srv/data/downloads
```

* Apply and verify:

```bash
kubectl apply -f apps/qbittorrent/
kubectl -n media get pods,pvc,ingress
kubectl -n media exec deploy/qbittorrent -c gluetun -- sh -c "ping -I tun0 -c2 -W3 10.2.0.1"
kubectl -n media exec deploy/qbittorrent -c qbittorrent -- curl -s https://ifconfig.me  # 185.107.56.105 NL
curl -I --resolve qb.k3s.lan:80:192.168.1.6 http://qb.k3s.lan/  # 200
```

* First WebUI login:

```bash
kubectl -n media logs deploy/qbittorrent -c qbittorrent | grep "temporary password"
# username admin, set a real password in WebUI -> Options -> WebUI -> Authentication
```

* Downloads land at `/downloads` in the pod and `/srv/data/downloads` on the host. Check `kubectl -n media exec deploy/qbittorrent -c qbittorrent -- ls -lh /downloads` or `ls -lh /srv/data/downloads`.

* The old `qbittorrent-downloads` `100Gi` PVC is deleted after the cutover (`kubectl -n media delete pvc qbittorrent-downloads`).

Add to Mikrotik or hosts file:

```bash
/ip dns static add name=qb.k3s.lan address=192.168.1.6
```

## 1.7 Data disk and Phase 1 exit

To do - move the bulk disk:

```bash
# on Proxmox shutdown both VMs, detach vm-101-disk-1 from vm-101, attach to vm-102 as sdb
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINT
# sdb 250G ext4 199a30e2-2775-429b-b0c5-f56d7146de9c
sudo mkdir -p /mnt/sdb_check
sudo mount -o ro /dev/sdb /mnt/sdb_check
ls -lh /mnt/sdb_check/media  # _movies _shows
sudo umount /mnt/sdb_check
sudo rmdir /mnt/sdb_check
sudo mkdir -p /srv/data
sudo mount /dev/sdb /srv/data
# fstab
# UUID=199a30e2-2775-429b-b0c5-f56d7146de9c /srv/data ext4 defaults 0 2
sudo mount -a
mkdir -p /srv/data/downloads
```

To do - exit checks:

```bash
kubectl -n media get pods,pvc,ingress
kubectl -n media delete pod -l app=jellyfin --wait=true
kubectl -n media exec deploy/jellyfin -- ls /media  # _movies _shows survive
kubectl -n media delete pod -l app=qbittorrent --wait=true
kubectl -n media exec deploy/qbittorrent -c qbittorrent -- curl -s https://ifconfig.me  # still NL IP
curl -I --resolve jf.k3s.lan:80:192.168.1.6 http://jf.k3s.lan/health
curl -I --resolve qb.k3s.lan:80:192.168.1.6 http://qb.k3s.lan/
```

Criteria:

* Both pods `Running`, survive `kubectl -n media delete pod <name>` with data intact.
* Both ingresses resolve and answer `200` from LAN.
* qBittorrent traffic exits via `185.107.56.105` `NL`.
* Only `jellyfin-config` and `qbittorrent-config` remain as `local-path` PVCs on `sda`. Bulk is `hostPath` on `sdb`. Both `hostPath` and `local-path` are node-local and unreplicated - acceptable for phase 1.
* All manifests committed and pushed, `kubectl apply -f apps/jellyfin/` then `apps/qbittorrent/` is the only `kubectl` allowed before Argo CD takes over.

From now on only push to git. Phase 2 makes Argo CD the only writer to the cluster.

## Commands to verify a fresh replication

```bash
kubectl get nodes
kubectl -n kube-system get pods
kubectl -n media get pods,pvc,ingress
kubectl -n media exec deploy/jellyfin -- ls /media
kubectl -n media exec deploy/qbittorrent -c qbittorrent -- ls /downloads
kubectl -n media exec deploy/qbittorrent -c qbittorrent -- curl -s https://ifconfig.me
curl -I --resolve jf.k3s.lan:80:192.168.1.6 http://jf.k3s.lan/health
curl -I --resolve qb.k3s.lan:80:192.168.1.6 http://qb.k3s.lan/
df -h / /srv/data
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINT
```
