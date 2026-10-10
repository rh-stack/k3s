#!/bin/bash
# Import the locally built weft image into k3s containerd.
# The image is built on this VM (no external registry while single node):
#   docker build -t weft:0.1.0 /path/to/weft
# Then run this script and enter your sudo password when asked:
#   bash scripts/import-weft-image.sh
set -euo pipefail
docker save weft:0.1.0 | sudo k3s ctr images import -
sudo k3s ctr images ls | grep 'weft:0.1.0'
