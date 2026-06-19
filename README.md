# f5-cis-airgap-transfer

Ansible automation that pulls F5 BIG-IP CIS, NGINX Plus Ingress
Controller, and cert-manager from the public internet, bundles them
with a verifiable manifest, and pushes them into a closed-network
Docker Registry — so an air-gapped Kubernetes cluster can later install
them from a registry it can actually reach.

This project does the **transfer**. Cluster install is a separate
exercise on the operator's side, after this project finishes.

## Why this exists

F5 CIS and NGINX Plus Ingress Controller deploy cleanly when the
target cluster has internet access — `helm install`, the cluster pulls
images from Docker Hub or quay.io, done. The official documentation
assumes this.

In a real enterprise environment, the cluster usually does not have
internet access. It sits behind a security boundary that allows
traffic in but not out. The workstation running `helm` faces the same
constraint: it can talk to the cluster, but it can't reach Docker Hub.
Everything the cluster needs has to be physically transported across
the air gap, then loaded into an internal registry that the cluster's
nodes can reach.

The mechanics of doing this correctly are surprisingly fiddly:

- **Image format mismatches** between `docker save` and `docker load`
  on different Docker versions and image stores (the containerd
  snapshotter on Docker 24+ introduces a whole new failure mode)
- **Authentication mechanics** that differ per source registry — Docker
  Hub uses username and password, F5's NGINX registry uses a
  JWT-as-username pattern, quay.io is anonymous
- **Helm OCI charts** that need a different push mechanism than
  container images (`helm push`, not `docker push`)
- **Integrity verification** — without per-file checksums, a corrupted
  transfer or a tampered bundle goes undetected until something fails
  in production
- **Credential hygiene** — robot tokens that can leak into shell
  history, process listings, or playbook logs unless handled with care

This project codifies the right answers to all of these in a
production-quality Ansible pipeline. It runs against a verified lab
environment and follows the conventions that hold up in real
enterprise deployments: vault-encrypted secrets, idempotent reruns,
explicit teardown playbooks, and engineering-level documentation in
every task file.

## What it does

A two-stage pipeline. Each stage is a self-contained Ansible project.

**Stage 1 — pull** (runs on an internet-connected workstation)
- Authenticates to Docker Hub, quay.io, and F5's private NGINX
  registry using credentials from an encrypted vault
- Pulls every container image and Helm chart that the cluster will need
- Saves images as `.tar` files, charts as `.tgz` files
- Generates a `manifest.json` with SHA-256 of every artifact
- Bundles everything into a single `airgap-bundle.tar.gz` for transfer
- Produces a companion `.sha256` for outer integrity verification

**Stage 2 — push** (runs on a closed-network host)
- Verifies the outer bundle SHA-256
- Extracts the bundle into a staging area
- Verifies every file's SHA-256 against the manifest (catches
  corruption, partial overwrites, or tampering)
- Configures Docker for the registry's TLS profile (HTTP with an
  insecure-registries entry, or HTTPS with a trusted private CA)
- Loads each image, retags it for the local registry, and pushes
- Pushes Helm charts as OCI artifacts
- Logs out cleanly even when an earlier task fails (block/always)

The contract between the two stages is the bundle manifest. Each
project's `ARCHITECTURE.md` documents that contract in detail.

## Architecture

```
INTERNET SIDE                                          CLOSED NETWORK
─────────────                                          ──────────────

  ┌─────────────────────────────┐                      ┌─────────────────────────────┐
  │ Operator workstation        │                      │ Closed-network host         │
  │                             │                      │                             │
  │  pull/  ─►  airgap-bundle ──┼─── physical ─────────┼──►  push/  ─►  registry     │
  │             tar.gz          │    transfer          │                             │
  │             + manifest      │                      │                             │
  │             + .sha256       │                      │  ← this project ends here   │
  └─────────────────────────────┘                      └─────────────────────────────┘
```

## What's included

Container images pulled and pushed:

| Component | Source | Purpose |
|-----------|--------|---------|
| F5 BIG-IP CIS | `docker.io/f5networks/k8s-bigip-ctlr` | The F5 ingress controller |
| NGINX Plus IC | `private-registry.nginx.com/nginx-ic/nginx-plus-ingress` | The NGINX ingress controller |
| cert-manager (4 images) | `quay.io/jetstack/cert-manager-*` | TLS certificate automation |
| nginx-hello | `docker.io/nginxdemos/nginx-hello` | Demo backend for testing |
| syslog-ng | `docker.io/linuxserver/syslog-ng` | Optional logging sidecar |

Helm charts pulled and pushed as OCI artifacts:

| Chart | Source | Installs |
|-------|--------|----------|
| f5-bigip-ctlr | `f5-stable` | CIS deployment |
| nginx-ingress | `nginx-stable` | NGINX Plus IC deployment |
| cert-manager | `jetstack` | cert-manager + CRDs |

All versions are managed by variables at the top of
`pull/group_vars/all/main.yaml`. Bumping a version is a one-line
change.

## How it runs: Ansible Execution Environment

Both stages run inside a single **Ansible Execution Environment (EE)** — a
container image, built once with `ansible-builder`, that carries ansible-core,
the required collections, the Docker SDK, and the `docker`/`helm` CLIs. You
run the playbooks through it with `ansible-navigator`. Hosts no longer install
ansible, collections, or Python directly; they only need a container runtime
and the Docker daemon the pipeline drives.

The EE ships only the Docker **client** — the host's Docker socket is mounted
in at run time, so every image operation hits the host daemon (no
docker-in-docker). See [`ee/README.md`](ee/README.md) for the full build and
offline-transfer procedure.

## Quick start

The fastest path from cloning to a populated registry. Build the EE once,
then run each stage (on a different host) through it.

### Build the EE (once, on an internet-connected build host)

```bash
git clone https://github.com/jmack707/f5-cis-airgap-transfer.git
cd f5-cis-airgap-transfer
pip install ansible-builder ansible-navigator
bash ee/build-ee.sh                       # builds f5-airgap-ee:latest
```

### Internet side

```bash
cd f5-cis-airgap-transfer/pull

# Set up credentials (one-time)
cp vault.yaml.example vault.yaml
nano vault.yaml                 # fill in Docker Hub and F5 NGINX JWT credentials
ansible-vault encrypt vault.yaml
printf '%s' 'your-vault-password' > .vault-pass && chmod 600 .vault-pass

# Run the pull through the EE
ansible-navigator run open-pull/playbooks/pull_artifacts.yaml \
  --vault-password-file .vault-pass
```

This produces `artifacts/airgap-bundle.tar.gz` (~300 MB) and
`artifacts/airgap-bundle.tar.gz.sha256`. Transfer both to the
closed-network host by whatever means your security policy allows.

### Closed-network side

The air-gapped host can't build the EE, so carry the image across the gap too
(see [`ee/README.md`](ee/README.md)):

```bash
# On the build host:
docker save f5-airgap-ee:latest | gzip > f5-airgap-ee.tar.gz
# …transfer f5-airgap-ee.tar.gz across the gap, then on the closed host:
gunzip -c f5-airgap-ee.tar.gz | docker load
```

Then:

```bash
cd f5-cis-airgap-transfer/push

cp vault.yaml.example vault.yaml
nano vault.yaml                 # fill in your registry endpoint and credentials
ansible-vault encrypt vault.yaml
printf '%s' 'your-vault-password' > .vault-pass && chmod 600 .vault-pass

# Place the bundle where the playbook expects it
sudo mkdir -p /srv/airgap-incoming /srv/airgap-staging
sudo chown -R $(whoami): /srv/airgap-incoming /srv/airgap-staging
cp /path/to/airgap-bundle.tar.gz* /srv/airgap-incoming/

# One-time HOST Docker-daemon prep (can't run inside the EE):
sudo ./host-prep.sh --host registry.example.com --port 5000 --insecure

# Run the push through the EE
ansible-navigator run ccn-push/playbooks/push_artifacts.yaml \
  --vault-password-file .vault-pass
```

After this completes, your closed-network registry contains every
image and chart needed for a CIS + NGINX Plus IC deployment.

## What happens after this project finishes

This project's job ends when the registry is populated. From there,
the operator deploys CIS, NGINX Plus IC, and cert-manager into the
cluster using `helm install` (or any other deployment mechanism)
against the local registry. Conceptually:

```bash
# Example only — real installs need values files with cluster-specific config
helm install cert-manager \
  oci://<your-registry>/cert-manager/charts/cert-manager \
  --version v1.19.1 --namespace cert-manager --create-namespace

helm install f5-bigip-ctlr \
  oci://<your-registry>/f5/charts/f5-bigip-ctlr \
  --version 0.0.35 --namespace kube-system \
  -f bigip-values.yaml

helm install nginx-ingress \
  oci://<your-registry>/nginx/charts/nginx-ingress \
  --version 2.1.0 --namespace nginx-ingress --create-namespace \
  -f nginx-values.yaml
```

BIG-IP-side configuration (Declarative Onboarding and AS3 declarations
posted to the BIG-IP's iControl REST API) is separate from any of this
and lives wherever your BIG-IP automation lives.

This project does NOT cover the install or the BIG-IP configuration.
It covers the transfer.

## Requirements

The Ansible toolchain (ansible-core, collections, Docker SDK, `helm`) now
lives **inside the EE**, so the hosts themselves need very little:

**Build host (internet-connected, builds the EE once):**

- Python 3 + `pip install ansible-builder ansible-navigator`
- A container runtime: Docker (default) or Podman

**Both run hosts (where the stages execute):**

- A container runtime to run the EE: Docker (default) or Podman
- `ansible-navigator` (`pip install ansible-navigator`)
- Docker Engine 24+ with the containerd snapshotter disabled — the EE drives
  this host daemon over the mounted socket (see
  [`push/ARCHITECTURE.md`](push/ARCHITECTURE.md) for the `daemon.json`
  configuration)

The EE's own base OS is Rocky Linux 9 (independent of the host OS). The hosts
themselves can be Ubuntu 24.04 (verified baseline) or Rocky/RHEL 9.x — the EE
makes the host OS largely irrelevant to the Ansible toolchain. Helm 3.13+ and
ansible-core 2.17+ are baked into the EE; nothing to install on the host.

Internet-side workstation additionally needs:

- Outbound HTTPS to docker.io, quay.io, and private-registry.nginx.com
- A Docker Hub account (free is fine — used to authenticate against
  per-account rate limits, not for paid features)
- An F5 NGINX subscription with a valid JWT token from MyF5

Closed-network host additionally needs:

- Network connectivity to a Docker Registry v2 (HTTP or HTTPS)
- ~10 GB of free disk for staging and Docker's image cache

## Repository layout

```
.
├── README.md                  ← you are here
├── LICENSE
├── CONTRIBUTING.md
├── SECURITY.md
├── .github/
│   └── workflows/             ← CI (lint + release on tag)
├── ee/                        ← Execution Environment definition
│   ├── README.md              ← build + offline-transfer guide
│   ├── execution-environment.yml
│   ├── requirements.yml       ← collections (single source of truth)
│   ├── requirements.txt       ← Python deps
│   ├── bindep.txt             ← system deps
│   └── build-ee.sh
├── pull/                      ← internet-side project
│   ├── README.md              ← operator quick-start (this side)
│   ├── ARCHITECTURE.md        ← engineering reference (this side)
│   ├── ansible-navigator.yml  ← runs the stage inside the EE
│   └── open-pull/             ← playbooks and tasks
└── push/                      ← closed-network project
    ├── README.md
    ├── ARCHITECTURE.md
    ├── ansible-navigator.yml  ← runs the stage inside the EE
    ├── host-prep.sh           ← one-time HOST Docker-daemon prep
    └── ccn-push/
```

Each project's own `README.md` covers operating that side; each
project's `ARCHITECTURE.md` covers design rationale, variable
reference, idempotency contract, failure mode matrix, and a
contributor guide.

## Releases

Operators don't need to clone — releases ship as downloadable zip
artifacts, one per side:

1. Go to [Releases](https://github.com/jmack707/f5-cis-airgap-transfer/releases)
2. Download `f5-airgap-pull-vX.Y.Z.zip` (internet side) or
   `f5-airgap-push-vX.Y.Z.zip` (closed-network side)
3. Verify the SHA-256 against `SHA256SUMS` (attached to the release)
4. Extract, then follow the project's `README.md`

Maintainers cut releases by tagging on `main`:

```bash
git tag -a v1.0.0 -m "Initial release"
git push origin v1.0.0
```

The release workflow builds both zips, computes `SHA256SUMS`, and
creates a GitHub Release with auto-generated notes.

## Bumping component versions

All component versions live at the top of
`pull/group_vars/all/main.yaml`:

```yaml
cis_version:          "2.20.3"
cis_chart_version:    "0.0.35"
nginx_plus_version:   "5.3.2"
nginx_chart_version:  "2.1.0"
cert_manager_version: "v1.19.1"
```

Bumping a version is a one-line change. Image filenames, manifest
entries, and push targets are all derived from these variables, so
nothing else needs editing. The push side's image map keys on image
basename (not version), so version bumps don't touch it at all.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the PR workflow,
documentation standard, and release procedure.

## Security

See [`SECURITY.md`](SECURITY.md) for the threat model and how to
report a vulnerability.

## License

[Apache 2.0](LICENSE).