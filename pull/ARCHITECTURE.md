# f5-airgap-pull — Engineering Reference

This document is for engineers maintaining or extending the pull stage.
For operator-facing instructions (how to run it), see `README.md`.

## Table of Contents

1. [Architecture](#architecture)
2. [The Bundle Contract](#the-bundle-contract)
3. [Version Variables and Derivation Conventions](#version-variables-and-derivation-conventions)
4. [Design Decisions](#design-decisions)
5. [Variable Reference](#variable-reference)
6. [Task File Reference](#task-file-reference)
7. [Idempotency Contract](#idempotency-contract)
8. [Failure Mode Matrix](#failure-mode-matrix)
9. [Testing](#testing)
10. [Contributor Guide](#contributor-guide)

---

## Architecture

```
                ┌─────────────────────────────────────┐
                │ Operator host (internet-connected)  │
                │                                     │
                │  ┌────────────┐                     │
                │  │ ansible-   │                     │
                │  │ playbook   │                     │
                │  └─────┬──────┘                     │
                │        │                            │
                │        ├─► docker login + pull ───► docker.io
                │        ├─► docker pull ──────────► quay.io
                │        ├─► docker login + pull ───► private-registry.nginx.com
                │        ├─► helm repo add + pull ─► (Helm repos)
                │        │                            │
                │        ▼                            │
                │   artifacts/                        │
                │   ├── images/  (8 .tar files)       │
                │   ├── charts/  (3 .tgz files)       │
                │   ├── manifest.json                 │
                │   ├── airgap-bundle.tar.gz          │
                │   └── airgap-bundle.tar.gz.sha256   │
                └─────────────────────────────────────┘
```

The six-stage pipeline (one task file per stage):

```
preflight ─► pull_dockerhub ─► pull_quay ─► pull_nginx_registry ─► pull_charts ─► bundle
```

---

## The Bundle Contract

`manifest.json` is the load-bearing contract between the pull and push
stages. Field shape is stable; any change here requires a coordinated
change on the push side.

```json
{
  "generated_at": "2026-06-12T18:00:00Z",
  "bundle_filename": "airgap-bundle.tar.gz",
  "images": [
    {
      "registry": "docker.io",
      "repo": "f5networks/k8s-bigip-ctlr",
      "tag": "2.20.3",
      "tarname": "k8s-bigip-ctlr_2.20.3.tar",
      "sha256": "0b72f3edbdabc66f..."
    }
  ],
  "charts": [
    {
      "chart": "f5-stable/f5-bigip-ctlr",
      "version": "0.0.35",
      "filename": "f5-bigip-ctlr-0.0.35.tgz",
      "sha256": "d0f60e675eec0baf..."
    }
  ]
}
```

| Field | Type | Meaning |
|-------|------|---------|
| `generated_at` | str (ISO-8601) | Wall-clock time when bundle was created |
| `bundle_filename` | str | Filename of the bundle itself |
| `images[].registry` | str | Source registry FQDN (no scheme) |
| `images[].repo` | str | Repository path within the registry |
| `images[].tag` | str | Image tag (NEVER `latest` in production) |
| `images[].tarname` | str | **Computed** filename of the saved .tar (`{basename(repo)}_{tag}.tar`) |
| `images[].sha256` | str | Hex-encoded SHA-256 of the .tar file |
| `charts[].chart` | str | Helm chart reference (`repo/chart` format) |
| `charts[].version` | str | Helm chart version |
| `charts[].filename` | str | **Computed** filename of the .tgz (`{basename(chart)}-{version}.tgz`) |
| `charts[].sha256` | str | Hex-encoded SHA-256 of the .tgz file |

### Critical invariant

The manifest MUST be regenerated any time an image .tar or chart .tgz
is rewritten. The bundle task does both in the same play, so the
invariant holds automatically.

---

## Version Variables and Derivation Conventions

The most important simplification in this project: **versions live in
exactly one place**. The top of `group_vars/all/main.yaml` defines a
version variable per component:

```yaml
cis_version:          "2.20.3"
cis_chart_version:    "0.0.35"
nginx_plus_version:   "5.3.2"
nginx_chart_version:  "2.1.0"
cert_manager_version: "v1.19.1"
nginx_hello_tag:      "plain-text"
syslog_ng_version:    "4.8.1"
```

Image and chart definitions reference these via Jinja:

```yaml
quay_images:
  - { repo: "jetstack/cert-manager-controller",      tag: "{{ cert_manager_version }}" }
  - { repo: "jetstack/cert-manager-cainjector",      tag: "{{ cert_manager_version }}" }
  - { repo: "jetstack/cert-manager-webhook",         tag: "{{ cert_manager_version }}" }
  - { repo: "jetstack/cert-manager-startupapicheck", tag: "{{ cert_manager_version }}" }

helm_charts:
  - { chart: "jetstack/cert-manager", version: "{{ cert_manager_version }}" }
```

### Derivation conventions

Tarnames and chart filenames are **derived inline** in every task file
using two rules:

| Artifact | Rule | Example |
|----------|------|---------|
| Image .tar | `{basename(repo)}_{tag}.tar` | `jetstack/cert-manager-controller:v1.19.1` → `cert-manager-controller_v1.19.1.tar` |
| Chart .tgz | `{basename(chart)}-{version}.tgz` | `jetstack/cert-manager@v1.19.1` → `cert-manager-v1.19.1.tgz` |

The same expression is repeated in every task file that needs it. This
is intentional — Ansible doesn't reliably evaluate nested Jinja
expressions defined in `group_vars`, so we keep the convention textual
and applied at the task level. The convention is documented in
`group_vars/all/main.yaml` and in this file.

### How a version bump works now

Before this refactor, bumping cert-manager from v1.19.1 to v1.19.2
required editing roughly 15 lines across both projects (4 tags + 4
tarnames + 1 chart version + 1 chart filename on the pull side, plus
4 image_push_map keys + 1 chart_push_map key on the push side).

Now it's **one line on the pull side, zero on the push side**:

```yaml
cert_manager_version: "v1.19.2"   # was v1.19.1
```

The push side never changes because `image_push_map` is keyed by
basename (e.g. `cert-manager-controller`), not by full tarname.

---

## Design Decisions

### Why version variables at the top instead of YAML anchors?

YAML anchors deduplicate within a single document, but they don't help
across documents (e.g. between pull and push). Named variables do, and
they read more clearly. The cost of "yet another variable" is paid back
the first time you bump a version family.

### Why derive tarname/filename instead of storing it explicitly?

Three things were tangled together before:
1. The version itself (used as image tag and chart version)
2. The tarname (used as filename and as push-side join key)
3. The chart filename (used similarly)

Items 2 and 3 are purely a function of item 1 plus the image/chart
name. Storing them explicitly meant any version bump had to keep three
strings in sync — and forgetting one created the kind of subtle bug
where the bundle's manifest claimed one tarname but the file on disk
had another. Deriving them means the version variable is the single
source of truth.

### Why per-file SHA-256 in the manifest?

Three failure modes need distinct detection:

1. **Transit corruption** — caught by `airgap-bundle.tar.gz.sha256`
2. **Partial bundle overwrite** — caught by per-file checksums in manifest
3. **Targeted tampering** — caught by per-file checksums

The outer SHA covers (1). Per-file SHAs are needed for (2) and (3).

### Why operational paths in group_vars, credentials in vault?

Operational paths are not secret. Filesystem paths are operational
choices an engineer makes based on disk layout. Putting them in vault
would mean every operator needs the vault password just to read the
layout — hostile to inspection. Credentials genuinely reveal access
to systems and belong in vault.

---

## Variable Reference

### Component versions (`group_vars/all/main.yaml`)

| Variable | Default | Controls |
|----------|---------|----------|
| `cis_version` | `2.20.3` | F5 BIG-IP CIS image tag |
| `cis_chart_version` | `0.0.35` | Helm chart for CIS |
| `nginx_plus_version` | `5.3.2` | NGINX Plus IC image tag |
| `nginx_chart_version` | `2.1.0` | Helm chart for NGINX Plus IC |
| `cert_manager_version` | `v1.19.1` | All 4 cert-manager image tags AND the chart version |
| `nginx_hello_tag` | `plain-text` | nginx demo image tag |
| `syslog_ng_version` | `4.8.1` | syslog-ng image tag |

### Operational paths

| Variable | Type | Default | Purpose |
|----------|------|---------|---------|
| `artifact_staging_dir` | str | `<repo>/artifacts` | Root output directory |
| `bundle_filename` | str | `airgap-bundle.tar.gz` | Output bundle filename |
| `image_tar_dir` | str | `<staging>/images` | Image .tar storage |
| `helm_chart_dir` | str | `<staging>/charts` | Chart .tgz storage |
| `min_free_disk_gb` | int | 20 | Disk threshold |
| `max_bundle_gb` | int | 8 | Bundle size ceiling |

### Image/chart entry shapes

```yaml
# Image entry (every *_images list):
- repo: "f5networks/k8s-bigip-ctlr"     # required
  tag:  "{{ cis_version }}"              # required, usually a version var

# Chart entry:
- chart:   "f5-stable/f5-bigip-ctlr"     # required
  version: "{{ cis_chart_version }}"      # required, usually a version var
```

Notice what's NOT in these entries: `tarname` and `filename`. Both are
computed inline by the task files. This is the simplification.

### Vault variables (vault.yaml)

| Variable | Required | Used by |
|----------|----------|---------|
| `vault_dockerhub_username` | yes | pull_dockerhub |
| `vault_dockerhub_password` | yes | pull_dockerhub |
| `vault_nginx_jwt_token` | yes | pull_nginx_registry |

---

## Task File Reference

| File | Inputs | Outputs | Idempotent | Side effects |
|------|--------|---------|------------|--------------|
| `preflight.yaml` | path vars, `min_free_disk_gb` | None | Yes | Creates staging dirs |
| `pull_dockerhub.yaml` | `dockerhub_*`, vault creds | `image_tar_dir/*.tar` | Layer-level | docker.io login/pulls/logout |
| `pull_quay.yaml` | `quay_*` | `image_tar_dir/*.tar` | Layer-level | docker pulls |
| `pull_nginx_registry.yaml` | `nginx_*`, JWT | `image_tar_dir/*.tar` | Layer-level | F5 registry login/pulls/logout |
| `pull_charts.yaml` | `helm_*` | `helm_chart_dir/*.tgz` | Mostly | helm repo add, pulls |
| `bundle.yaml` | Everything above | manifest.json, bundle.tar.gz, .sha256 | Rewrites every run | Compute checksums, write bundle |

---

## Idempotency Contract

| Task | Re-run behavior |
|------|-----------------|
| Preflight | Pure no-op on second run |
| `docker login` | Overwrites stored credential |
| `docker pull` | Layer-level idempotent; cache hits report "ok" |
| `docker_image archive_path:` | Always rewrites the .tar (reports "changed") |
| `docker logout` | Removes credential or no-ops |
| `helm repo add force_update:` | Updates URL if changed, otherwise no-op |
| `helm pull` | Always rewrites the .tgz |
| Per-file SHA-256 | Recomputes every run; pure function of input |
| Manifest write | Rewrites every run |
| `tar -czf` | Always rewrites bundle (gzip embeds a timestamp) |

The pipeline is **safe to re-run** at any time.

---

## Failure Mode Matrix

| Failure | Surfaces in | Recovery |
|---------|-------------|----------|
| CLI tool missing (docker/helm/tar/sha256sum) | preflight | Rebuild the EE — these ship inside it (`ee/`) |
| Insufficient disk space | preflight | Free space or lower `min_free_disk_gb` |
| Docker Hub 401 | pull_dockerhub login | Fix `vault_dockerhub_*` |
| Docker Hub 429 | pull_dockerhub pull | Wait and retry |
| Quay.io rate limit | pull_quay | Wait and retry |
| F5 NGINX 401 | pull_nginx_registry login | Re-download .jwt from MyF5 |
| F5 NGINX 403 | pull_nginx_registry pull | Check subscription entitlement |
| Image not found | Any pull task | Verify repo/tag in group_vars; upstream may have moved |
| Helm repo unreachable | pull_charts | Check internet |
| Chart version not found | pull_charts | Verify version still published |
| Disk full during save | pull_* save tasks | Free space and re-run |
| Bundle exceeds max size | bundle | Raise `max_bundle_gb` or shrink manifest |

---

## Testing

### Dry-run

```bash
ansible-navigator run open-pull/playbooks/pull_artifacts.yaml \
  --vault-password-file .vault-pass --check
```

### Targeted runs

```bash
# Just preflight
ansible-navigator run open-pull/playbooks/pull_artifacts.yaml \
  --vault-password-file .vault-pass --tags preflight

# Re-bundle existing staged files (skip pulls)
ansible-navigator run open-pull/playbooks/pull_artifacts.yaml \
  --vault-password-file .vault-pass --tags bundle
```

### Verifying a bundle

```bash
cd artifacts/
sha256sum -c airgap-bundle.tar.gz.sha256
tar -xOf airgap-bundle.tar.gz manifest.json | python3 -m json.tool
```

---

## Contributor Guide

### Bumping an existing version

Edit one line in `group_vars/all/main.yaml`:

```yaml
cert_manager_version: "v1.19.2"   # was v1.19.1
```

That's it. Re-run the pull, transfer the new bundle, push it. No
changes needed on the push side.

### Adding a new image

1. If the image needs a new source registry, add a new task file
   modeled on `pull_quay.yaml` (no auth) or `pull_dockerhub.yaml`
   (with auth).
2. If the new image is a new component, add a version variable at the
   top of `group_vars/all/main.yaml`.
3. Add the image entry to the appropriate `*_images` list:
   ```yaml
   dockerhub_images:
     - repo: "example/new-image"
       tag:  "{{ new_image_version }}"
   ```
4. Add a basename → push-target mapping on the push side:
   ```yaml
   # push/group_vars/all/main.yaml
   image_push_map:
     new-image: "category/new-image"
   ```

### Adding a new Helm chart

1. Verify the chart's source repo is in `helm_repos`, or add one.
2. Add the chart entry to `helm_charts`:
   ```yaml
   - chart: "repo-name/chart-name"
     version: "{{ chart_name_version }}"
   ```
3. Add a basename → push-target mapping:
   ```yaml
   # push/group_vars/all/main.yaml
   chart_push_map:
     chart-name: "category/charts"
   ```

### Changing the bundle output location

Edit `artifact_staging_dir` in `group_vars/all/main.yaml`. No other
changes needed.
