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
├── setup.sh                         ← installs ansible-core + collections + helm
├── vault.yaml.example
├── collections/requirements.yml
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

## Quick Start

### 1. One-shot setup

```bash
bash setup.sh
```

Detects the OS family from `/etc/os-release` and installs ansible-core
the right way for it — the Ansible PPA via `apt-get` on Ubuntu/Debian,
or `ansible-core` via `dnf` (AppStream, with an EPEL `ansible` fallback)
on Rocky 9 / RHEL 9. It then enforces the ansible-core version floor
(>= 2.17), verifies Docker and Helm are present, installs the required
Ansible collections, and confirms every module the playbook uses is
reachable.

Docker is treated as a prerequisite on every platform: `setup.sh` checks
for it and points you at the correct install docs if it is missing, but
does not install it for you.

> **Rocky / RHEL note.** On Ubuntu, the Ansible PPA installs the `ansible`
> bundle, which ships `community.docker` and `kubernetes.core` built in.
> On Rocky/RHEL, `setup.sh` installs `ansible-core`, which bundles
> **only** `ansible.builtin` — so the `ansible-galaxy collection install`
> step in `setup.sh` is what provides the collections the playbook needs.
>
> There is a second, sharper edge on **RHEL/Rocky 9**: the platform's
> default `python3` is 3.9, but `ansible-core` 2.17+ requires Python
> **3.10+**. The AppStream `ansible-core` (2.14) and the EPEL `ansible`
> bundle are both pinned to that 3.9 line and will **not** satisfy the
> version floor — so `setup.sh` exits at the floor check, the collection
> step is skipped, and the playbook fails with `couldn't resolve
> module/action 'community.docker.docker_login'`. The supported fix is a
> virtualenv built from a newer Python that EL9 packages alongside 3.9
> (use `python3.12` to match the Ubuntu baseline's ansible-core 2.21;
> `python3.11` also clears the floor):
>
> ```bash
> sudo dnf install -y python3.12 python3.12-pip
> rm -rf ~/.venv/ansible
> python3.12 -m venv ~/.venv/ansible
> . ~/.venv/ansible/bin/activate
> pip install --upgrade pip
> pip install 'ansible-core>=2.17' docker   # 'docker' = Docker SDK for Python
> bash setup.sh                              # now installs the collections
> ```
>
> (If `python3.12` is not available, run `dnf list available 'python3.1*'`
> and use the highest version present.)
>
> The `docker` pip package is the Docker SDK that `community.docker.docker_image`
> needs; because `inventory/hosts.yaml` pins `localhost` to
> `ansible_playbook_python`, modules run under the venv interpreter and find
> it there. Activate the venv (`. ~/.venv/ansible/bin/activate`) in every new
> shell before running the playbook, or you fall back to the system
> `ansible-core` 2.14 and hit the floor again.

### 2. Fill in secrets

```bash
cp vault.yaml.example vault.yaml
# edit vault.yaml — replace REPLACE_ME with your credentials
ansible-vault encrypt vault.yaml
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
ansible-playbook open-pull/playbooks/pull_artifacts.yaml --ask-vault-pass
```

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
ansible-playbook open-pull/playbooks/pull_artifacts.yaml \
  --ask-vault-pass \
  --extra-vars "artifact_staging_dir=/media/usb/airgap"
```

Useful for testing a different output location without editing files.

## What Gets Bundled

Eight container images (3 from Docker Hub, 4 from Quay.io, 1 from the F5
NGINX private registry) and 3 Helm charts (f5-bigip-ctlr, nginx-ingress,
cert-manager). The manifest contains the source registry, repo, tag,
filename, and SHA-256 for every artifact — the push stage uses this to
verify integrity before importing.

See `open-pull/README.md` for the full image and chart version list.

## Prerequisites

| Requirement | Minimum | Installed by |
|-------------|---------|--------------|
| ansible-core | 2.17 | `setup.sh` (Ansible PPA on Ubuntu; `dnf`/AppStream + EPEL fallback on Rocky/RHEL) |
| community.docker | 3.10.0 | `setup.sh` (ansible-galaxy) |
| kubernetes.core | 2.4.0 | `setup.sh` (ansible-galaxy) |
| Helm | 3.x | `setup.sh` (helm.sh installer) |
| Docker Engine | 18.09+ | must already be installed |

---

## Targeted Runs (using `--tags`)

The playbook is tagged so you can run subsets without running everything:

```bash
# Just preflight — fast environment validation after editing group_vars
ansible-playbook open-pull/playbooks/pull_artifacts.yaml --ask-vault-pass --tags preflight

# Just one registry's images
ansible-playbook open-pull/playbooks/pull_artifacts.yaml --ask-vault-pass --tags pull_dockerhub
ansible-playbook open-pull/playbooks/pull_artifacts.yaml --ask-vault-pass --tags pull_quay
ansible-playbook open-pull/playbooks/pull_artifacts.yaml --ask-vault-pass --tags pull_nginx

# All registry pulls but skip the bundling step
ansible-playbook open-pull/playbooks/pull_artifacts.yaml --ask-vault-pass --tags pull

# Re-bundle existing staged files (skip the pulls)
ansible-playbook open-pull/playbooks/pull_artifacts.yaml --ask-vault-pass --tags bundle
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
