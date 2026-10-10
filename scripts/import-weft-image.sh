#!/bin/bash
# Import a locally built weft image into k3s containerd.
# Usage: bash scripts/import-weft-image.sh [TAG]   (default TAG 0.1.0)
# Build first on this VM (no external registry while single node):
#   docker build -t weft:<TAG> /path/to/weft
set -euo pipefail
TAG=${1:-0.1.0}
docker save weft:$TAG | sudo k3s ctr images import -
sudo k3s ctr images ls | grep "weft:$TAG"
