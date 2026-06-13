# ccn-push — Closed-Network Registry Import Stage

## What This Stage Does

Runs on a closed-network host that has been physically handed the
`airgap-bundle.tar.gz` produced by the `open-pull` stage. It:

1. Verifies the bundle and the host's tooling
2. Configures Docker for the target registry — either trusts a private CA
   (HTTPS) or adds the registry to the daemon's insecure-registries list (HTTP)
3. Extracts the bundle into a staging area
4. Recomputes SHA-256 for every image and chart and asserts the values match
   the manifest the open-pull stage signed off on
5. Authenticates (if required) and pushes every image and OCI chart into
   the local registry
6. Logs out cleanly (even if a step fails partway through)

After ccn-push completes, the closed-network Kubernetes cluster can pull
everything from the local registry without any internet access.

---

## How to Run

### Prerequisites on the closed-network host

| Tool | Minimum | Notes |
|------|---------|-------|
| Docker Engine | 18.09+ | Must be running and accessible to the current user |
| Helm | **3.8.0+** | Required for OCI registry push (`helm push oci://…`) |
| ansible-core | 2.17+ | Same as open-pull |
| Private CA certificate | PEM-encoded | HTTPS only — must be readable at `ccn_registry_ca_path` |

### 1. Place the bundle

Drop the bundle from the open-pull stage at the path defined by
`ccn_bundle_incoming_path` (default `/srv/airgap-incoming/airgap-bundle.tar.gz`).
Drop the companion `.sha256` next to it for an automatic outer-checksum verify.

### 2. Pick your registry configuration profile

The stage supports four combinations of TLS and auth via two booleans in
`group_vars/all/main.yaml`:

| Profile | `ccn_registry_insecure` | `ccn_registry_auth_required` | Use case |
|---------|------------------------|-----------------------------|----------|
| **HTTP, no auth** | `true`  | `false` | Lab registry, e.g. `registry.example.com:5000` |
| **HTTP, with auth** | `true`  | `true`  | Lab registry with htpasswd |
| **HTTPS, no auth** | `false` | `false` | Internal registry behind another auth proxy |
| **HTTPS, with auth** | `false` | `true`  | Production default |

### 3. Set the configuration

**Profile: lab registry on `registry.example.com:5000` (HTTP, no auth)**

```yaml
# group_vars/all/main.yaml
ccn_registry_host:           "registry.example.com"
ccn_registry_port:           5000
ccn_registry_insecure:       true
ccn_registry_auth_required:  false
ccn_bundle_incoming_path:    "/srv/airgap-incoming/airgap-bundle.tar.gz"
ccn_staging_dir:             "/srv/airgap-staging"
ccn_min_free_disk_gb:        30
```

No vault changes needed. `ccn_registry_ca_path` and `ccn_registry_robot_username`
are ignored in this profile but can be left at their defaults.

**Profile: production (HTTPS, with auth)**

```yaml
# group_vars/all/main.yaml
ccn_registry_host:           "registry.internal.example.com"
ccn_registry_port:           443
ccn_registry_insecure:       false
ccn_registry_auth_required:  true
ccn_registry_robot_username: "airgap-bot"
ccn_registry_ca_path:        "/etc/ssl/certs/internal-ca.crt"
ccn_bundle_incoming_path:    "/srv/airgap-incoming/airgap-bundle.tar.gz"
ccn_staging_dir:             "/srv/airgap-staging"
ccn_min_free_disk_gb:        30
```

```yaml
# vault.yaml (then ansible-vault encrypt)
vault_ccn_registry_token: "<robot-account-token>"
```

### 4. Confirm push_repo mappings are sensible

Each image and chart in `group_vars/all/main.yaml` carries a `push_repo` or
`push_chart_repo` field that controls where it lands in the local registry.

| Source | Target in local registry |
|--------|--------------------------|
| `docker.io/f5networks/k8s-bigip-ctlr:2.20.3` | `<registry>/f5/k8s-bigip-ctlr:2.20.3` |
| `quay.io/jetstack/cert-manager-controller:v1.19.1` | `<registry>/cert-manager/controller:v1.19.1` |
| `private-registry.nginx.com/nginx-ic/nginx-plus-ingress:5.3.2` | `<registry>/nginx/nginx-plus-ingress:5.3.2` |
| `f5-bigip-ctlr-0.0.35.tgz` (OCI) | `<registry>/f5/charts/f5-bigip-ctlr:0.0.35` |

### 5. Run

```bash
# If auth is required:
ansible-playbook ccn-push/playbooks/push_artifacts.yaml --ask-vault-pass

# If anonymous:
ansible-playbook ccn-push/playbooks/push_artifacts.yaml
```

On first run with an insecure (HTTP) registry, the playbook restarts the
Docker daemon to pick up the `insecure-registries` change. Brief downtime
for any running containers — minimal in practice.

### 6. Verify (manual spot-check)

```bash
# HTTP, anonymous:
curl http://registry.example.com:5000/v2/_catalog | python3 -m json.tool
curl http://registry.example.com:5000/v2/f5/k8s-bigip-ctlr/tags/list

# Helm OCI:
helm show chart oci://registry.example.com:5000/f5/charts/f5-bigip-ctlr --version 0.0.35
```

### 7. Clean up (optional)

```bash
# Interactive — removes only the staging area:
ansible-playbook ccn-push/playbooks/push_artifacts_remove.yaml

# CI / non-interactive:
ansible-playbook ccn-push/playbooks/push_artifacts_remove.yaml \
  --extra-vars "confirm_removal=true"
```

---

## Task Files

| File | Responsibility |
|------|---------------|
| `tasks/preflight.yaml` | Bundle, tools, Helm 3.8+, CA file (HTTPS), disk, network reachability |
| `tasks/configure_insecure_registry.yaml` | Add registry to `/etc/docker/daemon.json` insecure-registries (HTTP only) |
| `tasks/trust_ca.yaml` | Install private CA into `/etc/docker/certs.d/<host>/ca.crt` (HTTPS only) |
| `tasks/extract_bundle.yaml` | `tar -xzf` into staging, load `manifest.json` |
| `tasks/verify_manifest.yaml` | Per-file SHA-256 check against the manifest |
| `tasks/build_push_plan.yaml` | Join manifest with `push_repo` mappings → unified push plan |
| `tasks/login.yaml` | `docker login` + `helm registry login` — skipped if auth not required |
| `tasks/load_and_push_images.yaml` | `docker load` → `docker tag` → `docker push` per image |
| `tasks/push_charts.yaml` | `helm push <chart>.tgz oci://<registry>/<path>` per chart |
| `tasks/logout.yaml` | `docker logout` + `helm registry logout` — skipped if auth not required |

---

## How the HTTP Path Works

Docker refuses HTTP registries by default — every push first tries HTTPS
and fails with `http: server gave HTTP response to HTTPS client`.

To allow HTTP push to a specific registry, the endpoint has to be listed
under `insecure-registries` in `/etc/docker/daemon.json`. The
`configure_insecure_registry.yaml` task:

1. Reads existing `/etc/docker/daemon.json` (or starts with `{}`)
2. Merges `insecure-registries: ["<host>:<port>"]` into the JSON
3. Writes the merged result back with a backup of the original
4. Restarts `dockerd` only if the file changed
5. Waits for the daemon to come back up
6. Confirms the registry is in the daemon's reported `IndexConfigs`

This is idempotent — re-running the playbook with the same configuration
doesn't restart Docker again. Changing the registry host or port does
trigger a restart.

---

## Failure Modes and Recovery

| Failure | Where it surfaces | Recovery |
|---------|-------------------|----------|
| Bundle missing | Preflight | Re-transfer to `ccn_bundle_incoming_path` |
| Outer SHA-256 mismatch | Preflight | Re-transfer — corrupted in transit |
| Helm < 3.8.0 | Preflight | Upgrade Helm before re-running |
| Registry unreachable on TCP | Preflight | Check firewall, registry container status |
| Registry HTTP API returns 5xx | Preflight (insecure only) | Check `docker logs <registry>` on the registry host |
| `http: server gave HTTP response to HTTPS client` | Image push | `ccn_registry_insecure` should be `true` |
| `x509: certificate signed by unknown authority` | Image push | `ccn_registry_ca_path` is wrong or CA file isn't PEM |
| Inner file SHA-256 mismatch | Verify manifest | Re-run open-pull and re-transfer the bundle |
| `docker login` fails | Login | Token expired/wrong or registry RBAC blocks the account |
| `docker push` 401/403 mid-push | Image push | Robot account lacks push permission on that path |

---

## Robot Account Permissions Required (HTTPS + Auth profile)

Skip this section if you're using the HTTP/anonymous profile.

The robot account whose token you put in `vault_ccn_registry_token` needs
push permission on every `push_repo` and `push_chart_repo` path defined
in `group_vars/all/main.yaml`. If your local Docker Registry v2 uses
htpasswd-based auth, the "robot account" is simply an htpasswd entry.
