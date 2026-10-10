# Weft image updates - from new source to running pod

Each Weft release is a local image. No registry is used while the cluster is one node.
The running image lives only in k3s containerd. The tag in `apps/weft/deployment.yaml` picks which one runs.

## One-time setup (already done for 0.1.0)

- Weft source plus `Dockerfile` lives in the weft repo. Keep a checkout on this VM to build from.
- The local commit `cc89dc0` in `/tmp/weft` holds the `Dockerfile`. Push it to the weft repo so any machine can rebuild.

## Update flow for a new release

Use a new tag per release (for example `0.2.0`). Never rebuild over an old tag. A new tag keeps rollback to one line.

1. Develop in the weft repo and commit. Pull the result onto this VM:

```bash
cd /path/to/weft && git pull
```

2. Build the image on this VM:

```bash
docker build -t weft:<TAG> .
```

3. Import it into k3s containerd (asks for your sudo password):

```bash
cd /home/rythm/_git/personal/k3s
bash scripts/import-weft-image.sh <TAG>
```

Import before changing the manifests. A pod that references a missing image waits in `ImagePullBackOff` and starts on its own after the import, but the order above avoids the red state entirely.

4. Point the Deployment at the new tag in `apps/weft/deployment.yaml`:

```yaml
image: weft:<TAG>
```

Commit and push. Argo CD syncs and recreates the pod (strategy `Recreate`, policy `IfNotPresent`).

5. Verify at each boundary:

```bash
kubectl -n weft get pods
kubectl -n weft logs deploy/weft --tail=5
curl -s http://weft.lan/api/state | head -c 120; echo
```

Open `http://weft.lan` and check the map. The PVC is untouched by image updates, so data stays.

## Rollback

Set `image:` back to the old tag in `apps/weft/deployment.yaml`, commit, push. The old image stays in containerd until someone deletes it. Check with:

```bash
sudo k3s ctr images ls | grep weft
```

## Disk cleanup after every build

Build cache uses about 1 GB and the Docker daemon keeps its own copy of the image. k3s does not need either after the import. Remove both:

```bash
docker rmi weft:<TAG>
docker builder prune -af
```

The 84 MB copy inside containerd stays. That is the one k3s runs.

## Later - second node or external registry

A local image runs only on the node that imported it. When a second node joins, push to a registry instead:

```bash
docker tag weft:<TAG> ghcr.io/rh-stack/weft:<TAG>
docker push ghcr.io/rh-stack/weft:<TAG>
```

Then set `image: ghcr.io/rh-stack/weft:<TAG>` in `apps/weft/deployment.yaml` with `imagePullPolicy: IfNotPresent`.
Delete the local path at that point. The update flow above stays the same otherwise.

## Data safety

Image updates never touch the `weft-data` PVC. The container seeds `/data` from the sample map only when `graph.yaml` is missing, so an update over existing data changes nothing. Back up before major releases anyway - see `.md/BACKUP.md`.
