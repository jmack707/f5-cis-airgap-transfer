# f5-airgap-pull — Internet-Side Artifact Collection

The internet-side half of the F5 air-gap deployment pipeline. Pulls every
container image and Helm chart needed by the closed-network Kubernetes
cluster, writes a provenance manifest with per-file SHA-256 checksums,
and produces a single compressed bundle for physical transfer.

## Where This Fits

```
┌──────────────────────────────────┐   physical    ┌──────────────────────────────────┐
│   INTERNET SIDE (this project)   │   transfer    │      CLOSED NETWORK              │
│                                  │  ──────────►  │                                  │
│   f5-airgap-pull                 │  airgap       │   f5-airgap-push                 │
│   Pull → manifest → bundle       │  bundle       │   (separate project)             │
└──────────────────────────────────┘  .tar.gz      └──────────────────────────────────┘
```

This project produces `airgap-bundle.tar.gz` plus a `.sha256` companion
file. Transfer both to the closed network for the push stage.

## Repository Layout

```
f5-airgap-pull/
├── README.md                        ← you are here
├── .gitignore
├── ansible.cfg
├── ansible-navigator.yml            ← runs this stage inside the EE
├── vault.yaml.example
├── inventory/hosts.yaml
├── group_vars/
│   └── all/main.yaml                ← image list + paths + tuning knobs
└── open-pull/
    ├── README.md                    ← detailed stage docs
    ├── playbooks/
    │   ├── pull_artifacts.yaml
    │   └── pull_artifacts_remove.yaml
    └── tasks/
        ├── preflight.yaml
        ├── pull_dockerhub.yaml
        ├── pull_quay.yaml
        ├── pull_nginx_registry.yaml
        ├── pull_charts.yaml
        └── bundle.yaml
```

The Ansible toolchain (ansible-core, collections, Docker SDK, `helm`) lives in
the **Execution Environment** defined at the repo root in
[`../ee/`](../ee/README.md), not in this directory.

## Quick Start

### 1. Build the EE and install the runner (one-time)

The toolchain ships as an Execution Environment image. Build it once on an
internet-connected host, then install the runner:

```bash
# Ubuntu 24.04 / Debian 12 block system-wide `pip install` (PEP 668); use pipx
# (apt install -y pipx) so each tool gets its own venv:
pipx install ansible-builder
pipx install ansible-navigator
pipx ensurepath               # then open a new shell

bash ../ee/build-ee.sh        # builds f5-airgap-ee:latest
```

The host itself only needs a container runtime (Docker or Podman) and a
running Docker daemon — the EE drives that daemon over the mounted socket to
pull and save images. There is nothing else to install: ansible-core, the
collections, the Docker SDK, and `helm` all live inside the EE. See
[`../ee/README.md`](../ee/README.md) for build details and version bumps.

> **Docker socket access.** The EE runs as root and the host socket is
> bind-mounted in (`/var/run/docker.sock`), so the pulls reach the host
> daemon. With **rootless Podman**, root-in-container maps to your host UID,
> which must be able to read the socket — add yourself to the `docker` group
> on the host (or run the EE with Docker, the default). The navigator config
> already requests `--user=root`.

### 2. Fill in secrets

```bash
cp vault.yaml.example vault.yaml
# edit vault.yaml — replace REPLACE_ME with your credentials
ansible-vault encrypt vault.yaml

# Vault password file, read by ansible-navigator (gitignored):
printf '%s' 'your-vault-password' > .vault-pass && chmod 600 .vault-pass
```

You'll need:
- Docker Hub username and password (PAT recommended)
- F5 NGINX JWT subscription token (download from MyF5)

### 3. (Optional) Adjust the output path

The bundle defaults to `<project>/artifacts/airgap-bundle.tar.gz`. To
write somewhere else, edit `group_vars/all/main.yaml`:

```yaml
artifact_staging_dir: "/mnt/transfer/airgap-bundles"
```

The directory gets created automatically if it doesn't exist.

### 4. Run

```bash
ansible-navigator run open-pull/playbooks/pull_artifacts.yaml \
  --vault-password-file .vault-pass
```

`ansible-navigator.yml` in this directory tells navigator to run the playbook
inside `f5-airgap-ee:latest` with the host Docker socket mounted. Output
streams to your terminal (`mode: stdout`). If you prefer an interactive vault
prompt, drop the flag and add `--playbook-artifact-enable false` — but a
password file is the smoother path.

### 5. Transfer

After the playbook completes, copy these two files to the closed network:

```
<artifact_staging_dir>/airgap-bundle.tar.gz
<artifact_staging_dir>/airgap-bundle.tar.gz.sha256
```

Use the matching `f5-airgap-push` project on the closed-network side to
load everything into the local registry.

### 6. Verify the bundle

```bash
cd <artifact_staging_dir>/
sha256sum -c airgap-bundle.tar.gz.sha256
tar -tzf airgap-bundle.tar.gz
tar -xOf airgap-bundle.tar.gz manifest.json | python3 -m json.tool
```

## Where Each Value Lives

The configuration is split into two locations by sensitivity. Below is
the complete map of every value the playbook reads.

### group_vars/all/main.yaml — operational, visible in the repo

Paths, tuning knobs, image and chart lists. Edit directly. No vault
password required.

| Variable | Default | What it controls |
|----------|---------|------------------|
| `artifact_staging_dir` | `<project>/artifacts` | Where the bundle and intermediate files are written |
| `bundle_filename` | `airgap-bundle.tar.gz` | Output bundle file name |
| `helm_chart_dir` | `<artifact_staging_dir>/charts` | Intermediate chart `.tgz` storage |
| `image_tar_dir` | `<artifact_staging_dir>/images` | Intermediate image `.tar` storage |
| `min_free_disk_gb` | `20` | Preflight rejects the run if less is free |
| `max_bundle_gb` | `8` | Bundle task rejects the bundle if larger |
| `dockerhub_images` | (list) | Images pulled from Docker Hub |
| `quay_images` | (list) | Images pulled from Quay.io |
| `nginx_images` | (list) | Images pulled from F5 NGINX private registry |
| `helm_charts` | (list) | Helm charts pulled via `helm pull` |

To change any of these:

```bash
nano group_vars/all/main.yaml
```

### vault.yaml — encrypted, requires the vault password

Credentials only. These grant access to upstream registries.

| Variable | Required | What it controls |
|----------|----------|------------------|
| `vault_dockerhub_username` | yes | Docker Hub login username |
| `vault_dockerhub_password` | yes | Docker Hub login password or PAT |
| `vault_nginx_jwt_token` | yes | F5 NGINX subscription JWT (full .jwt file contents) |

To change any of these:

```bash
ansible-vault edit vault.yaml
```

### Command-line overrides — one-off runs

Any variable can be overridden at run time with `--extra-vars`:

```bash
# Pull to a USB stick mounted at /media/usb instead of the default location:
ansible-navigator run open-pull/playbooks/pull_artifacts.yaml \
  --vault-password-file .vault-pass \
  --extra-vars "artifact_staging_dir=/media/usb/airgap"
```

Useful for testing a different output location without editing files. Note
that a staging directory **outside the project** must also be added as a
`volume-mount` in `ansible-navigator.yml` so the EE can write to it.

## What Gets Bundled

Eight container images (3 from Docker Hub, 4 from Quay.io, 1 from the F5
NGINX private registry) and 3 Helm charts (f5-bigip-ctlr, nginx-ingress,
cert-manager). The manifest contains the source registry, repo, tag,
filename, and SHA-256 for every artifact — the push stage uses this to
verify integrity before importing.

See `open-pull/README.md` for the full image and chart version list.

## Prerequisites

| Requirement | Minimum | Provided by |
|-------------|---------|-------------|
| ansible-core | 2.17 | the EE (`ee/execution-environment.yml`) |
| community.docker | 3.10.0 | the EE (`ee/requirements.yml`) |
| kubernetes.core | 2.4.0 | the EE (`ee/requirements.yml`) |
| Helm | 3.13+ | the EE |
| Docker SDK for Python | 7.0+ | the EE (`ee/requirements.txt`) |
| `ansible-navigator` | current | `pipx install ansible-navigator` (host) |
| Container runtime | Docker 24+ / Podman | host (runs the EE) |
| Docker Engine | 24+ | host (the EE drives it via the mounted socket) |

---

## Targeted Runs (using `--tags`)

The playbook is tagged so you can run subsets without running everything:

```bash
# Just preflight — fast environment validation after editing group_vars
ansible-navigator run open-pull/playbooks/pull_artifacts.yaml --vault-password-file .vault-pass --tags preflight

# Just one registry's images
ansible-navigator run open-pull/playbooks/pull_artifacts.yaml --vault-password-file .vault-pass --tags pull_dockerhub
ansible-navigator run open-pull/playbooks/pull_artifacts.yaml --vault-password-file .vault-pass --tags pull_quay
ansible-navigator run open-pull/playbooks/pull_artifacts.yaml --vault-password-file .vault-pass --tags pull_nginx

# All registry pulls but skip the bundling step
ansible-navigator run open-pull/playbooks/pull_artifacts.yaml --vault-password-file .vault-pass --tags pull

# Re-bundle existing staged files (skip the pulls)
ansible-navigator run open-pull/playbooks/pull_artifacts.yaml --vault-password-file .vault-pass --tags bundle
```

---

## For Developers

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for:

- Bundle contract specification
- Design decisions and rationale
- Full variable reference tables
- Per-task idempotency contract
- Failure mode matrix
- Contributor guide (adding new images, switching install methods, etc.)
