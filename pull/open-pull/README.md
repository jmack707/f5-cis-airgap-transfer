# open-pull — Internet-Side Artifact Collection Stage

## What This Stage Does

Pulls every container image and Helm chart required by the closed-network
deployment from three registries, writes a provenance manifest with per-file
SHA-256 checksums, and produces a single compressed bundle for physical
transfer.

**Outputs:**

| File | Contents |
|------|----------|
| `artifacts/airgap-bundle.tar.gz` | Manifest + image `.tar` files + chart `.tgz` files |
| `artifacts/airgap-bundle.tar.gz.sha256` | SHA-256 of the bundle itself |

**Bundle layout:**

```
airgap-bundle.tar.gz
├── manifest.json          ← per-file SHA-256, registry, tag, timestamp
├── images/
│   ├── k8s-bigip-ctlr_2.20.3.tar
│   ├── nginx-hello_plain-text.tar
│   ├── syslog-ng_4.8.1.tar
│   ├── cert-manager-controller_v1.19.1.tar
│   ├── cert-manager-cainjector_v1.19.1.tar
│   ├── cert-manager-webhook_v1.19.1.tar
│   ├── cert-manager-startupapicheck_v1.19.1.tar
│   └── nginx-plus-ingress_5.3.2.tar
└── charts/
    ├── f5-bigip-ctlr-0.0.35.tgz
    ├── nginx-ingress-2.1.0.tgz
    └── cert-manager-v1.19.1.tgz
```

The `manifest.json` looks like this:

```json
{
  "generated_at": "2026-06-12T05:55:29Z",
  "bundle_filename": "airgap-bundle.tar.gz",
  "images": [
    {
      "registry": "docker.io",
      "repo": "f5networks/k8s-bigip-ctlr",
      "tag": "2.20.3",
      "tarname": "k8s-bigip-ctlr_2.20.3.tar",
      "sha256": "a30e43c2236f6ced979e5251b0d8dad6efec2847c4420bdb01ad40e00fdc2715"
    }
  ],
  "charts": [ ... ]
}
```

The ccn-push stage uses these checksums to verify each file before importing
into Harbor.

---

## How to Run

### Prerequisites

Build the Execution Environment once (`bash ../ee/build-ee.sh`) and install
`ansible-navigator` on this host. ansible-core, the collections, the Docker
SDK, and `helm` all live inside the EE; the host needs only a container
runtime and a running Docker daemon. See [`../ee/README.md`](../ee/README.md).

### Run the pull

```bash
cp vault.yaml.example vault.yaml
# edit vault.yaml with real values, then:
ansible-vault encrypt vault.yaml
printf '%s' 'your-vault-password' > .vault-pass && chmod 600 .vault-pass

ansible-navigator run open-pull/playbooks/pull_artifacts.yaml \
  --vault-password-file .vault-pass
```

The single play executes six task files in sequence:

1. `tasks/preflight.yaml` — CLI tool check, disk space check, directory creation
2. `tasks/pull_dockerhub.yaml` — Docker Hub login → pull → save → logout
3. `tasks/pull_quay.yaml` — pull cert-manager images from quay.io (public)
4. `tasks/pull_nginx_registry.yaml` — JWT login → pull → save → logout
5. `tasks/pull_charts.yaml` — helm repo add → helm pull
6. `tasks/bundle.yaml` — per-file SHA-256 → manifest → tar.gz → bundle SHA-256

### Verify before transfer

```bash
cd artifacts/
sha256sum -c airgap-bundle.tar.gz.sha256
tar -tzf airgap-bundle.tar.gz
tar -xOf airgap-bundle.tar.gz manifest.json | python3 -m json.tool
```

### Clean up (optional)

```bash
# Interactive:
ansible-navigator run open-pull/playbooks/pull_artifacts_remove.yaml

# CI / non-interactive:
ansible-navigator run open-pull/playbooks/pull_artifacts_remove.yaml \
  --extra-vars "confirm_removal=true"
```

---

## Configuration Knobs

All in `group_vars/all/main.yaml`:

| Variable | Default | Purpose |
|----------|---------|---------|
| `min_free_disk_gb` | 20 | Preflight rejects the run if less is available |
| `max_bundle_gb` | 8 | Bundle task rejects the bundle if larger |
| `dockerhub_images` | (list) | Images pulled from Docker Hub |
| `quay_images` | (list) | Images pulled from quay.io (public) |
| `nginx_images` | (list) | Images pulled from `private-registry.nginx.com` |
| `helm_charts` | (list) | Charts pulled via helm pull |

---

## Image Registries

| Registry | Auth | Images |
|----------|------|--------|
| `docker.io` | Docker Hub username + password | k8s-bigip-ctlr, nginx-hello, syslog-ng |
| `quay.io` | None (public) | cert-manager-controller, cainjector, webhook, startupapicheck |
| `private-registry.nginx.com` | JWT token + literal "none" password | nginx-plus-ingress |

---

## Version Reference

| Artifact | Version | Registry |
|----------|---------|----------|
| f5-bigip-ctlr (chart) | 0.0.35 | — |
| nginx-ingress (chart) | 2.1.0 | — |
| cert-manager (chart) | v1.19.1 | — |
| k8s-bigip-ctlr | 2.20.3 | Docker Hub |
| nginx-hello | plain-text | Docker Hub |
| syslog-ng | 4.8.1 | Docker Hub |
| cert-manager-controller | v1.19.1 | Quay.io |
| cert-manager-cainjector | v1.19.1 | Quay.io |
| cert-manager-webhook | v1.19.1 | Quay.io |
| cert-manager-startupapicheck | v1.19.1 | Quay.io |
| nginx-plus-ingress | 5.3.2 | F5 private |
