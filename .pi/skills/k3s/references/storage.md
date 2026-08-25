# Storage

Source: https://docs.k3s.io/add-ons/storage (volumes), https://docs.k3s.io/installation/requirements, https://docs.k3s.io/advanced (containerd).

## Default: local-path-provisioner

K3s ships `rancher/local-path-provisioner` in `kube-system`.
StorageClass `local-path` is default and creates `hostPath` volumes dynamically.

```bash
kubectl get storageclass
# NAME         PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
# local-path   rancher.io/local-path   Delete          WaitForFirstConsumer
kubectl -n kube-system get pods | grep local-path
```

Location on node: `/var/lib/rancher/k3s/storage/<pvc-namespace>_<pvc-name>_<pv-name>`.

### Basic PVC usage

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jellyfin-config
  namespace: media
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jellyfin
  namespace: media
spec:
  selector:
    matchLabels: { app: jellyfin }
  template:
    metadata:
      labels: { app: jellyfin }
    spec:
      containers:
        - name: jellyfin
          image: jellyfin/jellyfin:10.9.13  # pin to current release or digest
          volumeMounts:
            - name: config
              mountPath: /config
            - name: cache
              mountPath: /cache
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: jellyfin-config
        - name: cache
          persistentVolumeClaim:
            claimName: jellyfin-cache
```

Check binding:

```bash
kubectl -n media get pvc,pv,po
ls -R /var/lib/rancher/k3s/storage
```

### Limitations

Local-path is node-local and not replicated.
Pod rescheduling to another node loses the path unless storage is shared.
It is suitable for single-node homelab start (per GOAL.md) but plan migration when adding nodes or needing HA.
Back up `/var/lib/rancher/k3s/storage` and etcd/SQLite regularly (see Operations).

## Config tweak: custom storage path

local-path reads its configuration from the `local-path-config` ConfigMap in `kube-system` (the `config.json` key holds the data directory and helper settings).
To move volumes elsewhere, edit that ConfigMap, restart the local-path-provisioner pod, and commit the change to this repo so it survives a re-bootstrap.
Inspect the live objects first - names can change between k3s releases:

```bash
kubectl -n kube-system get configmap local-path-config -o yaml
kubectl -n kube-system get deploy local-path-provisioner
```

For most uses keep the defaults and add a second StorageClass for shared storage later.

## NFS (for Immich/media and future NAS)

For a Proxmox NAS or external NFS server, install the NFS CSI driver.

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: csi-driver-nfs
  namespace: kube-system
spec:
  chart: csi-driver-nfs
  repo: https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
  targetNamespace: kube-system
  valuesContent: |-
    externalSnapshotter:
      enabled: false
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-csi
provisioner: nfs.csi.k8s.io
parameters:
  server: 10.0.0.20
  share: /export/k3s
reclaimPolicy: Delete
volumeBindingMode: Immediate
mountOptions:
  - nfsvers=4.1
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: immich-pgdata
  namespace: immich
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: nfs-csi
  resources:
    requests:
      storage: 20Gi
```

Verify NFS connectivity from nodes before using: `showmount -e 10.0.0.20` from Debian host.

## Longhorn (replicated block storage)

Longhorn provides replicated, HA storage across nodes - good when you have 3+ nodes.
It requires open-iscsi and NFS tools on each node.

```bash
# On each Debian node
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid
```

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: longhorn
  namespace: kube-system
spec:
  chart: longhorn
  repo: https://charts.longhorn.io
  targetNamespace: longhorn-system
  createNamespace: true
  valuesContent: |-
    persistence:
      defaultClass: true
      defaultClassReplicaCount: 2
      reclaimPolicy: Retain
```

After install, if you want Longhorn as default StorageClass, flip both annotations:

```bash
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
kubectl patch storageclass longhorn -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

## Immich specific

Per GOAL.md Immich is deployed via its official Helm chart (server + Postgres + Redis + ML in one release).
Short-term local-path PVC is acceptable.
Long-term move Postgres PV to NFS or Longhorn and media library to a shared volume.
See App Recipes for the Helm values snippet.

## Backup notes

- local-path data: `rsync`/`restic` of `/var/lib/rancher/k3s/storage` plus `k3s etcd-snapshot save` if using embedded etcd.
- NFS/Longhorn: use Velero or Longhorn's built-in backup to S3/NFS.

## Troubleshooting

```bash
kubectl describe pvc -n media jellyfin-config   # Events show provisioner errors
kubectl -n kube-system logs deploy/local-path-provisioner
kubectl get events --sort-by=.lastTimestamp | tail
# Common: pod stuck Pending due to insufficient storage or node affinity
```
