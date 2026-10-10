# Backup notes - manual copies, no schedule

There is no automatic backup today. No backup exists for the system disk or `/srv/data`.
Every copy below is made by hand. Do it after big edits.

## Weft - live data and second copy

- Live data is the `weft-data` PVC. Size 1 Gi, class `local-path`, node-local on the system disk.
- It holds everything: `graph.yaml`, `nodes/*.md`, `assets/`.
- Second copies live in `/srv/data/weft-backup/`. That is the 250 GB data disk, a different disk from the live PVC.

## Weft - backup

Run from the repo root or anywhere with kubectl:

```bash
POD=$(kubectl -n weft get pod -l app=weft -o jsonpath='{.items[0].metadata.name}')
mkdir -p /srv/data/weft-backup
kubectl -n weft cp $POD:/data /srv/data/weft-backup/manual-$(date +%F)
ls /srv/data/weft-backup/manual-$(date +%F)
```

Check the copy holds `graph.yaml` and the `nodes/` files. If `kubectl cp` fails with `tar: not found`, copy files one by one instead:

```bash
kubectl -n weft exec $POD -- cat /data/graph.yaml > /srv/data/weft-backup/manual-$(date +%F)-graph.yaml
```

## Weft - restore

Stop the app first so nothing writes during the copy:

```bash
kubectl -n weft scale deploy/weft --replicas=0
kubectl -n weft run weft-restore --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"weft-restore","image":"busybox:1.36","command":["sleep","3600"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"weft-data"}}]}}'
kubectl -n weft wait --for=condition=Ready pod/weft-restore --timeout=60s
kubectl -n weft cp /srv/data/weft-backup/manual-<DATE>/data weft-restore:/data
kubectl -n weft delete pod weft-restore
kubectl -n weft scale deploy/weft --replicas=1
```

Replace `<DATE>` with the backup folder date. Open `http://weft.lan` and check the map.

## Other apps

Jellyfin and qBittorrent use the same pattern: config on a `local-path` PVC, bulk data on `/srv/data`.
The same `kubectl cp` method works for their config PVCs. Bulk media is not copied by these commands.
