# Secrets & SOPS

Source: https://docs.k3s.io/security/secrets-encryption, https://github.com/getsops/sops, https://github.com/viaduct-ai/kustomize-sops

This homelab uses two layers: k3s at-rest encryption for etcd/SQLite, and SOPS+age for git-committed secrets decrypted by KSOPS in Argo CD.

## Layer 1: k3s Secrets Encryption at Rest

Enable at server init - it generates an AES-CBC key and writes `/var/lib/rancher/k3s/server/cred/encryption-config.json`.

```bash
# Install script
curl -sfL https://get.k3s.io | sh -s - server --secrets-encryption
# Or config.yaml
secrets-encryption: true
secrets-encryption-provider: aescbc  # aescbc (default) or secretbox (XSalsa20+Poly1305)
```

Providers (since April 2025 releases v1.30.12+k3s1+): `aescbc` (AES-CBC PKCS7) and `secretbox` (XSalsa20/Poly1305).
`secretbox` is newer - migrate by setting `secrets-encryption-provider: secretbox` and rotating keys.

The generated config looks like:

```json
{
  "kind": "EncryptionConfiguration",
  "apiVersion": "apiserver.config.k8s.io/v1",
  "resources": [{
    "resources": ["secrets"],
    "providers": [
      {"aescbc": {"keys": [{"name": "aescbckey", "secret": "base64key..."}]}},
      {"identity": {}}
    ]
  }]
}
```

Management tool:

```bash
k3s secrets-encrypt status
k3s secrets-encrypt enable
k3s secrets-encrypt disable
k3s secrets-encrypt rotate-keys
k3s secrets-encrypt reencrypt
sudo cat /var/lib/rancher/k3s/server/cred/encryption-config.json
```

Note: enabling on an existing cluster requires a restart.
Back up encryption-config.json offline - losing it loses secrets.

## Layer 2: SOPS + age (for GitOps)

### Install tooling (workstation)

```bash
# age and sops
sudo apt-get install age  # or brew install age
# sops binary from https://github.com/getsops/sops/releases
curl -Lo sops https://github.com/getsops/sops/releases/download/v3.9.0/sops-v3.9.0.linux.amd64
chmod +x sops && sudo mv sops /usr/local/bin/

# Generate age keypair
age-keygen -o ~/.config/sops/age/keys.txt
# Output shows:
# # public key: age1ql3z7hj432v2... 
# Keep keys.txt private - public key goes to .sops.yaml
```

### .sops.yaml (repo root)

```yaml
# .sops.yaml - defines who can encrypt and which files are encrypted
creation_rules:
  - path_regex: secrets/.*\.enc\.yaml$
    age: age1ql3z7hj432v2...  # your public key
    encrypted_regex: '^(data|stringData)$'
  - path_regex: apps/.*/secrets\.enc\.yaml$
    age: age1ql3z7hj432v2...
    encrypted_regex: '^(data|stringData)$'
```

### Create an encrypted Secret

```yaml
# apps/jellyfin/secrets.yaml (plaintext - do not commit)
apiVersion: v1
kind: Secret
metadata:
  name: jellyfin-secrets
  namespace: media
stringData:
  JELLYFIN_JWT_SECRET: "change-me"
```

```bash
sops --encrypt --age age1ql3z7... --encrypted-regex '^(data|stringData)$' \
  apps/jellyfin/secrets.yaml > apps/jellyfin/secrets.enc.yaml
# Or with .sops.yaml: sops --encrypt apps/jellyfin/secrets.yaml > apps/jellyfin/secrets.enc.yaml
cat apps/jellyfin/secrets.enc.yaml  # should show ENC[AES256_GCM,data:...] values
# Delete plaintext
rm apps/jellyfin/secrets.yaml
# Decrypt locally when needed
sops --decrypt apps/jellyfin/secrets.enc.yaml
```

Edit in place: `sops apps/jellyfin/secrets.enc.yaml`.

### Argo CD side (KSOPS)

Argo CD needs the age private key mounted into `argocd-repo-server`.
Create Secret:

```bash
kubectl -n argocd create secret generic sops-age \
  --from-file=keys.txt=$HOME/.config/sops/age/keys.txt
```

And configure repo-server to mount it (see GitOps reference for Helm values).
KSOPS generator in `kustomization.yaml`:

```yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: ksops-secret-generator
files:
  - ./secrets.enc.yaml
```

Argo CD will run `ksops` which calls `sops --decrypt` at sync time.

### Key rotation

```bash
# Add new recipient
age-keygen -o age-new.key
# Update .sops.yaml to include old + new public keys
sops updatekeys apps/jellyfin/secrets.enc.yaml  # re-encrypts to both
# Once all files updated, remove old key from .sops.yaml and updatekeys again
# Update cluster Secret
kubectl -n argocd create secret generic sops-age --from-file=keys.txt=age-new.key --dry-run=client -o yaml | kubectl apply -f -
```

### What to encrypt

Encrypt `data`/`stringData` in Secrets, and any Helm values containing credentials.
Do not encrypt entire manifests - keep metadata and non-sensitive values readable for review.

```yaml
# Example Helm values with secret via valuesSecrets
spec:
  valuesSecrets:
    - name: immich-secrets
      keys: [postgresPassword]
```

## Verification

```bash
sops --decrypt apps/jellyfin/secrets.enc.yaml | kubectl apply --dry-run=client -f -
kubectl -n media get secrets jellyfin-secrets -o yaml  # check keys exist after Argo sync
k3s secrets-encrypt status  # verify at-rest encryption on server
```

## Common pitfalls

- Forgetting `--enable-alpha-plugins` on repo-server - KSOPS silently ignored.
- Mounting age key to wrong path (`/root/.config/sops/age/keys.txt` vs `/home/argocd/...` depends on image user).
- Committing plaintext `secrets.yaml` instead of `.enc.yaml` - add `secrets.yaml` to .gitignore except `.enc.yaml`.
- Losing encryption-config.json or age private key - back both up to offline vault.
