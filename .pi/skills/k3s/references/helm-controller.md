# Helm Controller

Source: https://docs.k3s.io/add-ons/helm

## Concept

K3s embeds a Helm controller that reconciles `HelmChart` and `HelmChartConfig` custom resources.
No `helm` CLI or Tiller-like server is needed on the cluster - the controller runs Helm operations as Kubernetes Jobs.
This pairs with auto-deploy manifests (anything in `/var/lib/rancher/k3s/server/manifests` is auto-applied).

Place a `HelmChart` YAML in `server/manifests` or apply via `kubectl`/`Argo CD` - the controller installs or upgrades the chart.

## Controller tuning

```yaml
# /etc/rancher/k3s/config.yaml
helm-controller-arg:
  - 'job-resources={"requests":{"cpu":"0.2","memory":"64M"},"limits":{"cpu":"1","memory":"256M"}}'
```

Available since July 2026 releases (v1.36.3+k3s1 etc).

## HelmChart CRD

Namespace is typically `kube-system` for the HelmChart object, while the chart's resources go to `spec.targetNamespace`.

| Field | Default | Description | Helm equiv |
|---|---|---|---|
| metadata.name | - | Chart release name (must be Helm-legal + DNS) | NAME |
| spec.chart | - | Chart name in repo or HTTPS URL to .tgz | CHART |
| spec.chartContent | - | Base64-encoded .tgz - overrides spec.chart | - |
| spec.targetNamespace | default | Where to install chart resources | --namespace |
| spec.createNamespace | false | Create targetNamespace if missing | --create-namespace |
| spec.version | - | Chart version | --version |
| spec.repo | - | Chart repo URL | --repo |
| spec.repoCA | - | PEM CA bundle string for repo TLS | --ca-file |
| spec.repoCAConfigMap | - | ConfigMap ref with CA for repo | --ca-file |
| spec.plainHTTP | false | Use HTTP not HTTPS | --plain-http |
| spec.insecureSkipTLSVerify | false | Skip TLS verify | --insecure-skip-tls-verify |
| spec.helmVersion | v3 | Only v3 supported | - |
| spec.bootstrap | false | Needed to bootstrap cluster | - |
| spec.jobImage | rancher/klipper-helm:v0.8.x | Image for helm job | - |
| spec.backOffLimit | 1000 | Job retries | - |
| spec.timeout | 300s | Helm op timeout | --timeout |
| spec.failurePolicy | reinstall | `abort` stops retries pending manual fix | - |
| spec.authSecret | - | Secret (kubernetes.io/basic-auth) for repo | - |
| spec.dockerRegistrySecret | - | Secret (kubernetes.io/dockerconfigjson) for OCI registry | - |
| spec.set | - | Override simple values (map) | --set |
| spec.valuesContent | - | Inline YAML values | --values |
| spec.valuesSecrets | - | Secrets containing YAML values | --values |
| spec.podSecurityContext | - | PodSecurityContext for helm job | - |
| spec.securityContext | - | SecurityContext for containers | - |

### Values precedence (low to high)

1. Chart default values.
2. HelmChart spec.valuesContent.
3. HelmChart spec.valuesSecrets (in listed order).
4. HelmChartConfig spec.valuesContent.
5. HelmChartConfig spec.valuesSecrets (in listed order).
6. HelmChart spec.set (highest - overrides all).

### Example: Bitnami Apache

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: web
---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: apache
  namespace: kube-system
spec:
  repo: https://charts.bitnami.com/bitnami
  chart: apache
  targetNamespace: web
  valuesContent: |-
    service:
      type: ClusterIP
    ingress:
      enabled: true
      hostname: www.example.com
    metrics:
      enabled: true
```

### Example: private repo with auth

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: example-app
  namespace: kube-system
spec:
  targetNamespace: example-namespace
  createNamespace: true
  version: v1.2.3
  chart: example-app
  repo: https://secure-repo.example.com
  authSecret:
    name: example-repo-auth
  repoCAConfigMap:
    name: example-repo-ca
  valuesContent: |-
    image:
      tag: v1.2.2
---
apiVersion: v1
kind: Secret
metadata:
  name: example-repo-auth
  namespace: kube-system
type: kubernetes.io/basic-auth
stringData:
  username: user
  password: pass
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: example-repo-ca
  namespace: kube-system
data:
  ca.crt: |
    -----BEGIN CERTIFICATE-----
    <YOUR CERTIFICATE>
    -----END CERTIFICATE-----
```

### Chart values from Secrets (for sensitive values)

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: example-app
  namespace: kube-system
spec:
  chart: example-app
  repo: https://repo.example.com
  targetNamespace: example-namespace
  valuesSecrets:
    - name: example-app-custom-values
      keys: [someValues, moreValues]
      ignoreUpdates: false  # if true, Secret changes do not trigger re-deploy
  valuesContent: |-
    image:
      tag: v1.2.2
---
apiVersion: v1
kind: Secret
metadata:
  name: example-app-custom-values
  namespace: kube-system
stringData:
  someValues: |-
    adminUser:
      create: true
      username: admin
      password: secret
  moreValues: |-
    database:
      address: db.example.com
      username: user
      password: pass
```

Notes: valuesSecrets and auth Secrets must be in the same namespace as the HelmChart.
If `ignoreUpdates: false` (default), the Secret must exist with all listed keys or the chart fails; any key change triggers a helm upgrade.

## HelmChartConfig CRD

HelmChartConfig lets you override values for charts you did not author, like the packaged Traefik.

| Field | Description |
|---|---|
| metadata.name | Must match HelmChart name |
| metadata.namespace | Must match HelmChart namespace |
| spec.valuesContent | YAML values merged as an extra values file |
| spec.valuesSecrets | Secrets with YAML values |
| spec.failurePolicy | `abort` to stop on failure |

```yaml
# Customize packaged Traefik
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    image:
      repository: docker.io/library/traefik
      tag: "3.3.5"
    ports:
      web:
        forwardedHeaders:
          trustedIPs: ["10.0.0.0/8"]
```

Store this file in `/var/lib/rancher/k3s/server/manifests/traefik-config.yaml` (or manage via Argo CD).
The controller re-renders the chart on change.

## Using Helm directly (when controller is not enough)

K3s does not block standard Helm:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm upgrade --install my-release bitnami/apache -n web --create-namespace
```

Prefer HelmChart CRs when you want GitOps reconciliation; use `helm` CLI for one-off tests.

## Static chart URL

Content in `/var/lib/rancher/k3s/server/static/` is served anonymously via the API server at `https://%{KUBERNETES_API}%/static/...`.
The packaged Traefik chart is loaded as `https://%{KUBERNETES_API}%/static/charts/traefik-*.tgz` - you can host your own .tgz there and reference with `%{KUBERNETES_API}%`.

## Troubleshooting

```bash
kubectl -n kube-system get helmcharts,helmchartconfigs
kubectl -n kube-system describe helmchart traefik
kubectl -n kube-system get jobs | grep helm
kubectl -n kube-system logs job/helm-install-traefik-xxxxx
kubectl get events --sort-by=.lastTimestamp | grep HelmChart
```
Common failures: version mismatch, repo unreachable, values YAML invalid, Secret key missing, or `failurePolicy: abort` requiring manual delete of the failed Job.
