# Networking

Source: https://docs.k3s.io/networking (basic), https://docs.k3s.io/add-ons/traefik, https://docs.k3s.io/networking/servicelb, https://docs.k3s.io/advanced (CoreDNS, etc).

## Overview

K3s networking stack: Flannel CNI (VXLAN default) for pod networking, kube-router for NetworkPolicy, ServiceLB for bare-metal LoadBalancer, Traefik for ingress, CoreDNS for service discovery.

## Flannel (CNI)

Default backend is `vxlan`.
Other options: `host-gw`, `wireguard-native`, `none` (if you bring your own CNI like Cilium).

```yaml
# config.yaml - change CNI
flannel-backend: none        # disable Flannel
# or
flannel-backend: wireguard-native
cluster-cidr: "10.42.0.0/16"
service-cidr: "10.43.0.0/16"
cluster-dns: "10.43.0.10"
```

Important: changing CIDRs or backend after init requires cluster re-init on all servers.
Agent/server flags for networking must match across HA servers.

To disable Flannel and install Cilium/Calico instead:

```bash
curl -sfL https://get.k3s.io | sh -s - server --flannel-backend=none --disable-network-policy
# then install your CNI via HelmChart or kubectl
```

## Traefik Ingress (bundled)

Traefik is deployed as a HelmChart in `kube-system` automatically.
It watches `Ingress` and `IngressRoute` (CRD) resources and publishes ports 80/443 via ServiceLB.

### Basic Ingress example

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jellyfin
  namespace: media
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
    - host: jellyfin.homelab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: jellyfin
                port:
                  number: 8096
```

### Customizing packaged Traefik with HelmChartConfig

Do not edit the auto-deployed HelmChart directly.
Create a HelmChartConfig with the same name/namespace (`traefik` in `kube-system`):

```yaml
# /var/lib/rancher/k3s/server/manifests/traefik-config.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    ports:
      web:
        forwardedHeaders:
          trustedIPs: ["10.0.0.0/8"]
      websecure:
        forwardedHeaders:
          trustedIPs: ["10.0.0.0/8"]
    # example: enable dashboard, set log level, add middlewares
    logs:
      general:
        level: INFO
    # Persist via hostPath or PVC if needed
```

Values precedence: HelmChart valuesContent < HelmChartConfig valuesContent (but `spec.set` on HelmChart wins over both - see Helm reference).

To disable Traefik if you need a different ingress:

```yaml
# config.yaml
disable:
  - traefik
```

Do not install `ingress-nginx` - it is EOL since March 2026 per GOAL.md.
Traefik covers HTTP ingress for this homelab.

### Homepage auto-discovery

Homepage (gethomepage.dev) has a Kubernetes provider that lists ingress hosts automatically.
Give its ServiceAccount a ClusterRole that can `list` Ingresses cluster-wide and set `providers.kubernetes.ingress.enabled: true` in Homepage config.

## ServiceLB (LoadBalancer on bare metal)

K3s includes Klipper ServiceLB (small LB that reuses host ports).
Any Service of type `LoadBalancer` gets an external IP equal to the node's IP and forwards via hostPort.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: adguard-dns-tcp
  namespace: adguard
spec:
  type: LoadBalancer
  ports:
    - name: dns-tcp
      port: 53
      targetPort: 53
      protocol: TCP
    - name: dns-udp
      port: 53
      targetPort: 53
      protocol: UDP
  selector:
    app: adguard-home
```

ServiceLB is sufficient for AdGuard DNS on a single node.
If you need true L2/BGP LB later (multiple nodes sharing one VIP), add MetalLB.

### MetalLB (future for AdGuard HA)

When you outgrow ServiceLB, disable it and install MetalLB:

```yaml
# config.yaml on all servers
disable:
  - servicelb
```

Then install MetalLB (chart `metallb` from https://metallb.github.io/metallb, v0.13+) rendered by Argo CD, and declare address pools with the CRDs - the old `configInline` syntax was removed in v0.13:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: homelab-pool
  namespace: metallb-system
spec:
  addresses: ["10.0.0.100-10.0.0.120"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2
  namespace: metallb-system
spec:
  ipAddressPools: [homelab-pool]
```

Use `spec.loadBalancerIP` on the Service for DNS port 53 afterwards.

## CoreDNS

CoreDNS runs in `kube-system`.
Check viability of `/etc/resolv.conf` - K3s ignores loopback/multicast/link-local nameservers and warns if none are viable, falling back to stub `8.8.8.8`/`2001:4860:4860::8888`.
Override with `--resolv-conf /etc/resolv-alt.conf` if needed.

### Custom CoreDNS config

Create a `coredns-custom` ConfigMap in `kube-system`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  example-com.override: |
    forward example.com 10.0.0.1
  example-net.server: |
    example.net:53 {
      log
      errors
      file /etc/coredns/custom/db.example.net
    }
  db.example.net: |
    $ORIGIN example.net.
    @ 3600 IN SOA sns.dns.icann.org. noc.dns.icann.org. 2017042745 7200 3600 1209600 3600
    @ 3600 IN NS a.iana-servers.net.
    www IN A 127.0.0.1
```

Keys `*.override` are injected into the `:53` block, `*.server` creates new server blocks, other keys are mounted under `/etc/coredns/custom`.

## NetworkPolicy

Kube-router enforces `NetworkPolicy` resources.
Disable with `--disable-network-policy` if replacing with Cilium network policy.
Example allow-only:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-only
  namespace: media
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
        - podSelector: {}
```

## Proxmox / Host tweaks

Ensure VM has IP forwarding enabled and no firewall blocking 6443/8472/10250/80/443/53.
On Proxmox bridge, disable MAC filtering that blocks Flannel VXLAN.
For Debian host: `sysctl -w net.ipv4.ip_forward=1` is handled by k3s launcher but verify after reboots.

## Debugging

```bash
kubectl -n kube-system get pods -o wide   # traefik, coredns, svclb-*
kubectl -n kube-system logs deploy/traefik
kubectl get ingress -A
kubectl get svc -A | grep LoadBalancer
ss -tulnp | grep -E '80|443|53|6443|8472'
k3s check-config  # validates kernel/cgroups
```
