# f5-airgap-push — Engineering Reference

This document is for engineers maintaining or extending the push stage.
For operator-facing instructions, see `README.md`.

## Table of Contents

1. [Architecture](#architecture)
2. [The Bundle Contract](#the-bundle-contract)
3. [Version-Agnostic Push Maps](#version-agnostic-push-maps)
4. [Configuration Profiles](#configuration-profiles)
5. [Design Decisions](#design-decisions)
6. [Variable Reference](#variable-reference)
7. [Task File Reference](#task-file-reference)
8. [Idempotency Contract](#idempotency-contract)
9. [Failure Mode Matrix](#failure-mode-matrix)
10. [Testing](#testing)
11. [Contributor Guide](#contributor-guide)

---

## Architecture

The push stage runs on a closed-network host that has physically received
the bundle from the pull stage. It verifies integrity, then publishes
every artifact to the local registry.

```
preflight ─► configure_insecure_registry ─► extract_bundle ─► verify_manifest
                       ↓                                              ↓
                  trust_ca                                  build_push_plan
                       ↓                                              ↓
                       └──────────────────────────────────────► block: login → push images → push charts
                                                                       always: logout
```

The login/push/logout block uses `block/always` so logout fires even
when an earlier task fails. This prevents stale credentials from
lingering in `~/.docker/config.json` after a partial run.

---

## The Bundle Contract

`manifest.json` extracted from the bundle is the load-bearing contract
between the pull stage and this one. The push side reads:

```json
{
  "images": [
    {
      "registry": "docker.io",
      "repo": "f5networks/k8s-bigip-ctlr",
      "tag": "2.20.3",
      "tarname": "k8s-bigip-ctlr_2.20.3.tar",
      "sha256": "..."
    }
  ],
  "charts": [
    {
      "chart": "f5-stable/f5-bigip-ctlr",
      "version": "0.0.35",
      "filename": "f5-bigip-ctlr-0.0.35.tgz",
      "sha256": "..."
    }
  ]
}
```

The push side uses:

- `repo | basename` as the join key into `image_push_map`
- `chart | basename` as the join key into `chart_push_map`
- `sha256` for the per-file integrity check
- `registry`, `repo`, `tag` to construct `source_ref` for `docker tag`
- `tarname` and `filename` only as labels in log output

---

## Version-Agnostic Push Maps

The most important simplification in this project: **the push side
doesn't know about versions**. Push maps are keyed by image/chart
**basename**, not by full tarname/filename:

```yaml
image_push_map:
  k8s-bigip-ctlr:               "f5/k8s-bigip-ctlr"
  cert-manager-controller:      "cert-manager/controller"
  cert-manager-cainjector:      "cert-manager/cainjector"
  cert-manager-webhook:         "cert-manager/webhook"
  cert-manager-startupapicheck: "cert-manager/startupapicheck"
  nginx-plus-ingress:           "nginx/nginx-plus-ingress"
  # ...

chart_push_map:
  f5-bigip-ctlr: "f5/charts"
  nginx-ingress: "nginx/charts"
  cert-manager:  "cert-manager/charts"
```

When the pull side bumps `cert_manager_version` from `v1.19.1` to
`v1.19.2`, this file doesn't change. The push plan task computes the
target reference as:

```
<ccn_registry_endpoint>/<image_push_map[repo | basename]>:<manifest.tag>
```

So `cert-manager-controller` always maps to `cert-manager/controller`,
regardless of which version tag is in the manifest. The tag flows
through unchanged.

### Why this works

The pull side writes the computed tarname into the manifest. The push
side reads the manifest and joins by repo basename. As long as both
sides use the same derivation convention (`{basename(repo)}_{tag}.tar`),
the join works. The convention is documented in both projects'
`ARCHITECTURE.md`.

---

## Configuration Profiles

Two booleans control four behaviors:

| `ccn_registry_insecure` | `ccn_registry_auth_required` | Profile | Behavior |
|------------------------|------------------------------|---------|----------|
| `true`  | `false` | HTTP, no auth | Lab default. Configures Docker's insecure-registries, skips CA trust, skips login |
| `true`  | `true`  | HTTP, with auth | Adds insecure-registries entry, runs `docker login` over HTTP (rare) |
| `false` | `false` | HTTPS, no auth | Installs the private CA, skips login |
| `false` | `true`  | HTTPS, with auth | Production default. Installs CA, runs login |

---

## Design Decisions

### Why basename-keyed push maps?

Before this refactor, push maps were keyed by full tarname:

```yaml
# OLD — version-coupled
image_push_map:
  cert-manager-controller_v1.19.1.tar: "cert-manager/controller"
```

Bumping cert-manager required editing four lines here. Now the map
keys are basenames — version-independent.

### Why the push side never edits versions

The clean separation: the pull side decides *what version to pull*,
the push side decides *where to put it*. These are orthogonal
concerns and shouldn't couple. Version-keyed push maps coupled them.
Basename-keyed maps decouple them.

### Why a manifest-driven push, not a hardcoded image list?

The push side reads the manifest to learn what's in the bundle, then
joins with `image_push_map` to learn where each image goes. This means:

- Adding a new image requires only an `image_push_map` entry on the
  push side, not a full image redefinition
- The contract between sides is data, not code
- The integrity check exists naturally

### Why `--password-stdin` on `docker login`?

`docker login -u $USER -p $TOKEN` leaks the token to
`/proc/<pid>/cmdline`. `--password-stdin` keeps the credential out of
the process table. Combined with `no_log: true`, the token never
appears in any operator-visible log.

### Why `block/always` for login/push/logout?

Without `always:`, a failure during push would skip logout and leave
the robot token in `~/.docker/config.json`. That's a credential
hygiene problem on a shared host.

---

## Variable Reference

### Operational variables (`group_vars/all/main.yaml`)

| Variable | Type | Default | Used by | Purpose |
|----------|------|---------|---------|---------|
| `ccn_bundle_incoming_path` | str | `/srv/airgap-incoming/airgap-bundle.tar.gz` | preflight, extract | Where to find the bundle |
| `ccn_staging_dir` | str | `/srv/airgap-staging` | preflight, extract, verify, build_push_plan | Working directory |
| `ccn_registry_ca_path` | str | `/etc/ssl/certs/internal-ca.crt` | preflight, trust_ca | Private CA (HTTPS) |
| `ccn_min_free_disk_gb` | int | 30 | preflight | Disk threshold |
| `image_push_map` | dict | (8-entry default) | build_push_plan | `image_basename → target_repo` |
| `chart_push_map` | dict | (3-entry default) | build_push_plan | `chart_basename → target_oci_path` |
| `ccn_registry_endpoint` | computed | derived | Multiple | `host:port` form |
| `ccn_registry_host` | from vault | — | login, configure_insecure | Endpoint host |
| `ccn_registry_port` | from vault | — | login, configure_insecure, preflight | Endpoint port |
| `ccn_registry_insecure` | from vault | — | All TLS-conditional tasks | HTTP toggle |
| `ccn_registry_auth_required` | from vault | — | login, logout | Auth toggle |
| `ccn_registry_robot_username` | from vault | — | login | Robot username |

### Vault variables (`vault.yaml`)

| Variable | Required when | Used by |
|----------|---------------|---------|
| `vault_ccn_registry_host` | always | All TLS/network tasks |
| `vault_ccn_registry_port` | always | All TLS/network tasks |
| `vault_ccn_registry_insecure` | always | All TLS-conditional tasks |
| `vault_ccn_registry_auth_required` | always | login, logout |
| `vault_ccn_registry_robot_username` | always | login |
| `vault_ccn_registry_token` | `auth_required: true` | login |

### `image_push_map` shape

```yaml
image_push_map:
  <image-basename>: "<target-repo-path-in-local-registry>"
  k8s-bigip-ctlr: "f5/k8s-bigip-ctlr"
```

Push target: `<registry_endpoint>/<value>:<tag-from-manifest>`
Example: `registry.example.com:5000/f5/k8s-bigip-ctlr:2.20.3`

### `chart_push_map` shape

```yaml
chart_push_map:
  <chart-basename>: "<target-oci-parent-path>"
  f5-bigip-ctlr: "f5/charts"
```

Push target: `oci://<registry_endpoint>/<value>/<chart-name>:<chart-version>`
Example: `oci://registry.example.com:5000/f5/charts/f5-bigip-ctlr:0.0.35`

---

## Task File Reference

| File | Inputs | Outputs | Idempotent | Side effects |
|------|--------|---------|------------|--------------|
| `preflight.yaml` | All path vars, profile booleans | bundle stats | Yes | Creates staging dir |
| `configure_insecure_registry.yaml` | `insecure: true` | None | Yes (gated restart) | Edits `/etc/docker/daemon.json`, may restart dockerd |
| `trust_ca.yaml` | `insecure: false`, CA path | None | Yes | Copies CA to `/etc/docker/certs.d/<host>/ca.crt` |
| `extract_bundle.yaml` | Bundle path, staging dir | `bundle_manifest` fact | `creates:` marker | Extracts bundle into staging |
| `verify_manifest.yaml` | `bundle_manifest`, staging dir | None | Read-only | None |
| `build_push_plan.yaml` | `bundle_manifest`, push maps | `push_plan`, `chart_push_plan` | Pure function | None |
| `login.yaml` | Vault token, auth toggle | None | Yes | Writes auth to docker/helm configs |
| `load_and_push_images.yaml` | `push_plan`, staging dir | None | Layer + blob level | docker load, tag, push |
| `push_charts.yaml` | `chart_push_plan` | None | Artifact level | helm push (OCI) |
| `logout.yaml` | Auth toggle | None | Yes | Removes auth from docker/helm configs |

---

## Idempotency Contract

| Task | Re-run behavior |
|------|-----------------|
| Preflight | Pure no-op on second run |
| Configure insecure-registry | First run writes file + restarts; subsequent runs don't restart |
| Trust CA | Copy module compares checksums; rewrites only on diff |
| Extract bundle | `creates:` marker skips re-extraction |
| Verify manifest | Always recomputes (read-only) |
| Build push plan | Pure function of inputs |
| `docker login` | Overwrites stored credential |
| `docker load` | Layer-level idempotent |
| `docker tag` | No idempotency signal; always "changed" |
| `docker push` | Blob-level idempotent |
| `helm push` | Artifact-level idempotent at the registry |
| `docker logout` | Removes credential or no-ops |

---

## Failure Mode Matrix

| Failure | Surfaces in | Recovery |
|---------|-------------|----------|
| Bundle missing | preflight | Place bundle at `ccn_bundle_incoming_path` |
| Outer SHA-256 mismatch | preflight | Re-transfer the bundle |
| Helm < 3.8.0 | preflight | Upgrade Helm |
| CA file missing | preflight (HTTPS) | Fix `ccn_registry_ca_path` |
| CA not PEM | preflight (HTTPS) | Convert with `openssl x509 -inform DER` |
| Registry TCP unreachable | preflight | Firewall, DNS, or registry process down |
| Inner SHA-256 mismatch | verify_manifest | Bundle corrupted or manifest stale; rebuild on pull side |
| Missing push_repo mapping | build_push_plan | Add basename entry to `image_push_map` or `chart_push_map` |
| Token wrong/expired (401) | login | Re-issue robot token, update vault |
| Token lacks permission (403) | push | Fix RBAC on registry |
| HTTP-as-HTTPS error | push | `ccn_registry_insecure` should be `true` |
| x509 unknown authority | push | CA trust not in place; verify trust_ca ran |

---

## Testing

### Dry-run

```bash
ansible-playbook ccn-push/playbooks/push_artifacts.yaml --ask-vault-pass --check --diff
```

### Targeted runs

```bash
# Bundle integrity check only (no push)
ansible-playbook ccn-push/playbooks/push_artifacts.yaml --ask-vault-pass --tags extract,verify

# Skip preflight/extract/verify; assume staging is already populated
ansible-playbook ccn-push/playbooks/push_artifacts.yaml --ask-vault-pass --tags push
```

### Verifying registry state after push

```bash
curl -s http://<registry>/v2/_catalog | python3 -m json.tool
helm show chart oci://<registry>/f5/charts/f5-bigip-ctlr --version 0.0.35
```

---

## Contributor Guide

### Adding a new image to the push side

```yaml
# group_vars/all/main.yaml
image_push_map:
  new-image: "category/new-image"
```

That's it. The push side picks up the image from the bundle's manifest
automatically and joins it to this map by basename. The version flows
through from whatever the pull side bumped to.

### Adding a new Helm chart

```yaml
# group_vars/all/main.yaml
chart_push_map:
  new-chart: "category/charts"
```

### Switching from HTTP to HTTPS

1. Set `vault_ccn_registry_insecure: false` in `vault.yaml`
2. Set `vault_ccn_registry_port: 443` (or the HTTPS port)
3. Place the CA at `ccn_registry_ca_path`
4. Re-run

### Adding authentication to an anonymous registry

1. Set `vault_ccn_registry_auth_required: true`
2. Set `vault_ccn_registry_robot_username` and `vault_ccn_registry_token`
3. Re-run

`login.yaml` and `logout.yaml` activate automatically.
