# Remote access - Tailscale subnet router

Goal: reach the whole home LAN (the Debian k3s host, the Proxmox UI, the router, every service) from the laptop on any outside network, without exposing anything to the internet.

## Why the obvious options are out

- **WireGuard on the router (the reddit plan).** Blocked. The ISP puts the router behind carrier NAT: the WAN address is private and `/ip cloud` reports "Router is behind a NAT". Inbound UDP from the internet cannot reach the router, so there is no reachable WireGuard endpoint without a public IP from the ISP.
- **IPv6.** Dead for this use case. The router has no IPv6 configured, and the outside network tested has no IPv6 either. An IPv6-only endpoint would not be reachable from the laptop's usual outside networks.
- **MikroTik Back To Home.** Unsupported. Official requirement is ARM/ARM64/TILE hardware; the router is MIPSBE.
- **Port forwarding / Cloudflare Tunnel.** Port forwarding is impossible under CGNAT. Cloudflare Tunnel exposes single services, not the whole LAN and SSH.
- **VPS relay.** Works, but adds a rented machine and all remote traffic passes through it. Kept as the fallback if Tailscale is rejected later.

## Chosen design

Tailscale as a **subnet router** for `192.168.1.0/24`, running in a small LXC container on the Proxmox node.

- One subnet route covers the whole LAN: SSH to `192.168.1.6`, the Proxmox UI at `https://192.168.1.3:8006`, the router at `192.168.1.1`, and every k3s service.
- Split access: only LAN traffic goes through Tailscale. The laptop keeps its normal internet.
- Traffic is end-to-end encrypted. The control plane sees device names and metadata, not traffic. Direct peer-to-peer is usual; an encrypted relay is the fallback.

Why the LXC on the Proxmox node and not the k3s host:

- The k3s VM is the machine that gets tinkered with. The Proxmox node is the machine that stays untouched. The remote-access path belongs on the least-tinkered host.
- If the k3s VM hangs or its networking breaks, the subnet router is still up, so the Proxmox UI stays reachable from outside and the VM can be restarted. A subnet router on the k3s host would lose remote access at the same moment and block its own repair.
- No second subnet router for high availability: the k3s VM lives on the same Proxmox node, so a node-level failure takes both down together. The extra router would only cover a broken container on a healthy node, which can wait until it ever happens.

Facts at this point:

- Proxmox node at `192.168.1.3`, web UI `https://192.168.1.3:8006`. The Debian k3s server is one of its VMs.
- Router: MikroTik, MIPSBE, RouterOS 7, WAN behind CGNAT.
- k3s host: Debian, hostname `k3s`, `192.168.1.6`, DNS via router `192.168.1.1`, no host firewall active.
- The router already answers `*.k3s.lan` with `192.168.1.6`.
- Laptop: Arch, iwd, `wg-quick`, `resolvconf` present.

Tailscale is not a k3s component:

- Runs as the systemd unit `tailscaled` inside the LXC and creates the `tailscale0` interface there.
- No pods, no manifests, no Argo CD. k3s is unaware of it.
- The container source-NATs LAN traffic to its own LAN address (Tailscale default), so LAN devices answer without any static routes on the MikroTik.

## Subnet router: one LXC on Proxmox **[You]**

1. In the Proxmox UI (https://192.168.1.3:8006), create a small container (example: CT `103`, hostname `tailscale-router`, Debian template, unprivileged):
   - Resources: 1 CPU core, 256 MiB RAM, 1 GiB disk. `tailscaled` idles well under 100 MiB. Swap: keep the Proxmox default (512 MiB) - it is host swap, not container disk.
   - Network: bridge `vmbr0`, IPv4 **static**, one free address outside the DHCP range (example: `192.168.1.7/24`; reserve it on the router too), gateway `192.168.1.1`.
   - Network tab -> Firewall: **off**. It only sees the LAN side, not Tailscale, so it cannot filter tailnet access and would only add a silent drop path.
   - DNS tab: DNS domain `k3s.lan` (search domain, optional), DNS servers `192.168.1.1`.
   - Options -> Start/Shutdown -> **Start at boot: on**.

2. Give the container a TUN device and keyring access. On the Proxmox node shell (change `103` to your CT ID):

   ```
   echo -e 'lxc.cgroup2.devices.allow: c 10:200 rwm\nlxc.mount.entry: /dev/net/tun dev/net/tun none bind,optional,create=file' >> /etc/pve/lxc/103.conf
   pct set 103 --features keyctl=1
   pct reboot 103
   ```

3. Open the container console: in the Proxmox UI select CT `103` -> **Console**, login `root`. Paste these commands one after another:

   ```
   ls /dev/net/tun     # must print the path; an error here means step 2 is not active
   curl -fsSL https://tailscale.com/install.sh | sh    # official Tailscale installer
   echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-tailscale.conf
   sysctl -q --system
   tailscale up --advertise-routes=192.168.1.0/24 --accept-dns=false
   tailscale status
   ```

   The `tailscale up` command prints a login URL. Open the URL in the laptop browser and authenticate. `--accept-dns=false` keeps the container on the router's DNS. Then check:

   ```
   tailscale status
   tailscale ip -4
   ```

## Admin console **[You]**

1. https://login.tailscale.com/admin/machines -> `tailscale-router` -> three-dot menu -> **Edit route settings** -> approve `192.168.1.0/24`.
2. Same menu -> **Disable key expiry**. Otherwise the router leaves the tailnet after about 180 days and remote access stops.
3. https://login.tailscale.com/admin/dns -> Nameservers -> Add nameserver -> Custom -> `192.168.1.1` -> enable **Restrict to search domain** -> `k3s.lan`. Leave "Override local DNS" off.

## Laptop setup **[You]**

```
sudo pacman -S tailscale
sudo systemctl enable --now tailscaled
sudo tailscale up --accept-routes
```

Authenticate in the browser when prompted. `--accept-routes` makes `192.168.1.0/24` reachable through the subnet router.

## Verify from an outside network **[You]**

Disconnect from the home Wi-Fi and use the phone hotspot:

```
tailscale status                 # tailscale-router listed, not offline
tailscale ping tailscale-router  # direct or relay path
ping 192.168.1.1
ping 192.168.1.6
ssh <user>@192.168.1.6
getent hosts argocd.k3s.lan      # 192.168.1.6
curl -I http://argocd.k3s.lan
```

In the laptop browser, open `https://192.168.1.3:8006` and expect the Proxmox login page.

Failure signal: `100.x.y.z` and `192.168.1.7` reachable but `192.168.1.1` and `192.168.1.6` not -> the subnet route was not approved in the admin console.

If `ls /dev/net/tun` in step 3 errors, or `tailscale up` reports a TUN error -> the two `lxc.*` lines are missing from the CT config or the CT was not restarted after step 2.

## What you can do from outside

- SSH to `192.168.1.6` - the whole Debian host. `kubectl` works through SSH with no extra setup: `ssh <user>@192.168.1.6 sudo k3s kubectl get nodes`. For a local `kubectl` on the laptop, optionally copy `/etc/rancher/k3s/k3s.yaml` and change the server URL from `https://127.0.0.1:6443` to `https://192.168.1.6:6443`. The API server listens on all interfaces (`*:6443`). k3s normally adds the node IP to the API certificate, so TLS should pass; verify with `kubectl get nodes`. If TLS fails, the certificate SANs need fixing.
- The Proxmox UI at `https://192.168.1.3:8006` - restart or repair any VM, including the k3s VM.
- Argo CD, Headlamp, Jellyfin, and every other `*.k3s.lan` UI via the split DNS.
- Any NodePort or LoadBalancer service on `192.168.1.6`.
- The router at `192.168.1.1` and any other device in `192.168.1.0/24`.

No k3s manifest changes are needed.

## Why this is the right fit

This is the standard pattern for reaching a whole LAN behind CGNAT with minimal maintenance, and what Tailscale recommends for this case: one subnet router on a host that is already in the LAN. Hosting it in an LXC on the Proxmox node keeps the remote-access path independent of the machine it protects.

Optimizations already included:

- Subnet router instead of installing Tailscale on every device.
- Split tunnel: only `192.168.1.0/24` goes home.
- Split DNS: only `k3s.lan` queries go to the router.
- `--accept-dns=false` on the server, so its own DNS stays untouched.
- Route approval and key expiry handled in the admin console.

Tradeoff: the Tailscale control plane is a third party. It sees device names and connection metadata, not traffic, which is end-to-end encrypted. Direct peer-to-peer is the usual path; when the phone network blocks it, an encrypted relay carries traffic and is slower.

What would beat it in other senses:

- **If the ISP gives you a public IP:** WireGuard on the router. No third party, no dependency on the Proxmox node, lower latency. This stays the cleanest self-hosted answer, and it is one ISP request away.
- **If you refuse any company in the path:** Headscale (self-hosted Tailscale control plane) or plain WireGuard on a VPS. You own everything, but you also own the VPS, updates, and the relay. A few euros per month, and all remote traffic passes through the VPS.

## Limits

- Remote access depends on the Proxmox node being up. If the node dies, the k3s VM dies with it too, and no subnet router on this LAN could help then. If only the k3s VM has trouble, remote access still works and the Proxmox UI can repair it.
- Split access only. No exit node, so the laptop's internet does not route through home.
- Tested once from the phone hotspot after setup: route approval, SSH, the Proxmox UI, and DNS split all work. If speed ever drops, run `tailscale status` and look for `direct` vs `relay` in the connection line.
