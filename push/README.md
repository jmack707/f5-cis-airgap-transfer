# f5-airgap-push — Closed-Network Registry Import

The closed-network half of the F5 air-gap deployment pipeline. Reads the
bundle produced by `f5-airgap-pull` (the internet-side project), verifies
file integrity against the bundle manifest, and pushes every container
image and OCI Helm chart into the local Docker Registry v2.

## Where This Fits

```
┌──────────────────────────────────┐   physical    ┌──────────────────────────────────┐
│      INTERNET SIDE               │   transfer    │   CLOSED NETWORK (this project)  │
│                                  │  ──────────►  │                                  │
│   f5-airgap-pull                 │  airgap       │   f5-airgap-push                 │
│   (separate project)             │  bundle       │   Verify → load → push           │
└──────────────────────────────────┘  .tar.gz      └──────────────────────────────────┘
```

This project takes `airgap-bundle.tar.gz` + `.sha256` as input. The
closed-network Kubernetes cluster pulls from the local registry after
push completes.

## Repository Layout

```
f5-airgap-push/
├── README.md                        ← you are here
├── .gitignore
├── ansible.cfg
├── setup.sh                         ← verifies tooling (no internet install)
├── vault.yaml.example
├── collections/requirements.yml
├── inventory/hosts.yaml
├── group_vars/
│   └── all/main.yaml                ← paths + push_repo mappings (visible)
└── ccn-push/
    ├── README.md                    ← detailed stage docs
    ├── playbooks/
    │   ├── push_artifacts.yaml
    │   └── push_artifacts_remove.yaml
    └── tasks/
        ├── preflight.yaml
        ├── configure_insecure_registry.yaml
        ├── trust_ca.yaml
        ├── extract_bundle.yaml
        ├── verify_manifest.yaml
        ├── build_push_plan.yaml
        ├── login.yaml
        ├── load_and_push_images.yaml
        ├── push_charts.yaml
        └── logout.yaml
```

## Quick Start

### 1. Verify the host

```bash
bash setup.sh
```

This checks for ansible-core, Docker, Helm 3.8+, and the required Ansible
collections. It does not install anything — closed-network hosts can't
reach the internet, so installations must be done manually from local
sources. The script detects the OS family from `/etc/os-release` and, when
a check fails, prints an install hint phrased for that platform (`apt`/.deb
on Ubuntu/Debian, `dnf`/.rpm on Rocky/RHEL).

### 2. Configure paths and registry

The configuration is split across two files by sensitivity:

**Operational paths** (visible, no vault password needed to read or change)
live in `group_vars/all/main.yaml`. Edit directly:

```yaml
ccn_bundle_incoming_path: "/srv/airgap-incoming/airgap-bundle.tar.gz"
ccn_staging_dir:          "/srv/airgap-staging"
ccn_registry_ca_path:     "/etc/ssl/certs/internal-ca.crt"
ccn_min_free_disk_gb:     30
```

**Registry endpoint and credentials** (encrypted) live in `vault.yaml`:

```bash
cp vault.yaml.example vault.yaml
# Edit vault.yaml — set the registry host, port, TLS toggle, auth toggle
ansible-vault encrypt vault.yaml
```

The defaults in `vault.yaml.example` target a lab Docker Registry v2 at
`registry.example.com:5000` running HTTP without authentication.

### 3. Place the bundle

Drop the bundle and its checksum at the path defined by
`ccn_bundle_incoming_path` in `group_vars/all/main.yaml`. With the
default value:

```
/srv/airgap-incoming/airgap-bundle.tar.gz
/srv/airgap-incoming/airgap-bundle.tar.gz.sha256
```

### 4. Run

```bash
ansible-playbook ccn-push/playbooks/push_artifacts.yaml --ask-vault-pass
```

The playbook handles the full sequence:

1. Preflight — bundle, tools, Helm version, disk, network reachability
2. Configure Docker for the registry profile (HTTPS+CA trust, or HTTP+insecure entry)
3. Extract the bundle
4. Verify SHA-256 of every image and chart against the manifest
5. Authenticate to the registry (if required)
6. Load, re-tag, and push every image
7. Push every Helm chart as an OCI artifact
8. Log out cleanly

### 5. Verify

```bash
# HTTP / anonymous:
curl http://registry.example.com:5000/v2/_catalog | python3 -m json.tool
curl http://registry.example.com:5000/v2/f5/k8s-bigip-ctlr/tags/list

# OCI charts:
helm show chart oci://registry.example.com:5000/f5/charts/f5-bigip-ctlr --version 0.0.35
```

### 6. Clean up (optional)

```bash
# Removes the staging area:
ansible-playbook ccn-push/playbooks/push_artifacts_remove.yaml --ask-vault-pass

# Also remove insecure-registries entry (HTTP profile, restarts Docker):
ansible-playbook ccn-push/playbooks/push_artifacts_remove.yaml \
  --extra-vars "confirm_removal=true remove_insecure_entry=true" \
  --ask-vault-pass
```

## Where Each Value Lives

The configuration is split into three locations by sensitivity and
purpose. Below is the complete map of every value the playbook reads.

### group_vars/all/main.yaml — operational, visible in the repo

These are paths and tuning knobs. Edit them directly with any editor.
No vault password required.

| Variable | Default | What it controls |
|----------|---------|------------------|
| `ccn_bundle_incoming_path` | `/srv/airgap-incoming/airgap-bundle.tar.gz` | Path the playbook looks for the bundle at |
| `ccn_staging_dir` | `/srv/airgap-staging` | Working directory for extraction and verification |
| `ccn_registry_ca_path` | `/etc/ssl/certs/internal-ca.crt` | Private CA for HTTPS registries (ignored when insecure) |
| `ccn_min_free_disk_gb` | `30` | Preflight rejects the run if less is free |
| `image_push_map` | (table) | tarname → target repository path in the local registry |
| `chart_push_map` | (table) | filename → target OCI path in the local registry |

To change any of these, just edit the file:

```bash
nano group_vars/all/main.yaml
```

### vault.yaml — encrypted, requires the vault password

These reveal internal network topology or grant push access.

| Variable | Default | What it controls |
|----------|---------|------------------|
| `vault_ccn_registry_host` | `registry.example.com` | Registry FQDN or IP |
| `vault_ccn_registry_port` | `5000` | Registry TCP port |
| `vault_ccn_registry_insecure` | `true` | `true` = HTTP profile, `false` = HTTPS profile |
| `vault_ccn_registry_auth_required` | `false` | `true` = login required, `false` = anonymous push |
| `vault_ccn_registry_robot_username` | `airgap-bot` | Username for `docker login` (when auth required) |
| `vault_ccn_registry_token` | `REPLACE_ME` | Token/password for `docker login` (when auth required) |

To change any of these:

```bash
ansible-vault edit vault.yaml
```

### Command-line overrides — one-off runs

Any variable can be overridden at run time with `--extra-vars`:

```bash
# Override the bundle path for a single run without editing files:
ansible-playbook ccn-push/playbooks/push_artifacts.yaml \
  --ask-vault-pass \
  --extra-vars "ccn_bundle_incoming_path=/home/labuser/airgap-bundle.tar.gz"
```

Useful for testing a different bundle location without re-encrypting vault
or editing group_vars.

## Configuration Profiles

The stage supports four combinations of TLS and auth via two booleans in
`vault.yaml`:

| Profile | `vault_ccn_registry_insecure` | `vault_ccn_registry_auth_required` | Use case |
|---------|--------------------------------|-------------------------------------|----------|
| **HTTP, no auth** | `true`  | `false` | Lab registry — *current default* |
| **HTTP, with auth** | `true`  | `true`  | Lab registry with htpasswd |
| **HTTPS, no auth** | `false` | `false` | Internal registry behind another auth proxy |
| **HTTPS, with auth** | `false` | `true`  | Production default |

See `ccn-push/README.md` for the detailed behavior of each profile.

## Push Mapping

Each image and chart from the bundle gets re-tagged to a specific path in
the local registry. The mapping lives in `group_vars/all/main.yaml`:

| Source (from manifest) | Target in local registry |
|------------------------|--------------------------|
| `docker.io/f5networks/k8s-bigip-ctlr:2.20.3` | `<registry>/f5/k8s-bigip-ctlr:2.20.3` |
| `quay.io/jetstack/cert-manager-controller:v1.19.1` | `<registry>/cert-manager/controller:v1.19.1` |
| `private-registry.nginx.com/nginx-ic/nginx-plus-ingress:5.3.2` | `<registry>/nginx/nginx-plus-ingress:5.3.2` |
| `f5-bigip-ctlr-0.0.35.tgz` (OCI) | `oci://<registry>/f5/charts/f5-bigip-ctlr:0.0.35` |

If the bundle gains a new image (because the internet-side
`f5-airgap-pull` project added one), this project needs an `image_push_map`
entry for it, or the playbook fails at the manifest-checking step before
any push runs.

## Prerequisites

| Requirement | Minimum | How to provide on a closed-network host |
|-------------|---------|------------------------------------------|
| ansible-core | 2.17 | Local apt/dnf mirror, offline pip wheel, or pre-built tarball |
| community.docker | 3.10.0 | Offline collection tarball (`ansible-galaxy collection download`) |
| kubernetes.core | 2.4.0 | Same as above |
| Docker Engine | 18.09+ | Local package repository |
| Helm | **3.8.0+** | Static binary, copied via the same physical transfer as the bundle |

---

## Targeted Runs (using `--tags`)

The playbook is tagged so you can run subsets without running everything:

```bash
# Just preflight — fast environment validation
ansible-playbook ccn-push/playbooks/push_artifacts.yaml --ask-vault-pass --tags preflight

# Bundle integrity check only (no push)
ansible-playbook ccn-push/playbooks/push_artifacts.yaml --ask-vault-pass --tags extract,verify

# Skip preflight/extract/verify; assume staging is already populated
ansible-playbook ccn-push/playbooks/push_artifacts.yaml --ask-vault-pass --tags push

# Images only (skip charts)
ansible-playbook ccn-push/playbooks/push_artifacts.yaml --ask-vault-pass --tags push_images

# Charts only (skip images)
ansible-playbook ccn-push/playbooks/push_artifacts.yaml --ask-vault-pass --tags push_charts
```

---

## Dry-Run (Check Mode)

```bash
ansible-playbook ccn-push/playbooks/push_artifacts.yaml --ask-vault-pass --check --diff
```

`--check` skips command modules but exercises the bulk of the playbook
structure. `--diff` shows exactly what would change in
`/etc/docker/daemon.json` before any actual write.

---

## For Developers

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for:

- Bundle contract specification
- Configuration profile matrix
- Design decisions and rationale
- Full variable reference tables
- Per-task idempotency contract
- Failure mode matrix
- Contributor guide (adding images, switching profiles, etc.)
