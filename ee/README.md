# f5-airgap Execution Environment (EE)

This directory defines the **Ansible Execution Environment** that both stages
of the pipeline run inside. The EE is a container image, built once with
[`ansible-builder`](https://ansible.readthedocs.io/projects/builder/), that
carries the entire toolchain:

| Inside the EE | Why |
|---------------|-----|
| ansible-core ≥ 2.17 on Python 3.12 | runs the playbooks |
| `community.docker`, `ansible.utils` | the collections the transfer playbooks call |
| `f5networks.f5_modules` (+ `ansible.netcommon`) | F5 BIG-IP automation (CIS onboarding, AS3/DO) run through the same EE |

Helm repo management uses the `helm` CLI directly (not `kubernetes.core`), so the
EE stays minimal — `kubernetes.core` would drag in the `openshift-clients` RPM,
which isn't packaged for the UBI 9 base.
| Docker SDK for Python | required by every `community.docker` module |
| `docker` CLI (client only) | `docker save` / `load` / `tag` / `push` against the **host** daemon |
| `helm` CLI (≥ 3.13) | `helm pull` and OCI `helm push` (`--plain-http` / `--ca-file`) |
| `tar`, `gzip`, `openssl`, `sha256sum` | bundling + integrity checks |

It is built **from a minimal base** — `registry.access.redhat.com/ubi9/ubi-minimal`
(microdnf, glibc) — chosen for size, since the image is physically carried
across the air gap. The `docker` and `helm` clients are installed from their
official static tarballs (no package repos), and the lean package set avoids a
compiler because ansible-core's Python deps install from manylinux wheels.

The EE **replaces** the old per-host `setup.sh` + venv + `ansible-galaxy`
flow. Hosts no longer need ansible, collections, or Python set up directly —
they only need a container runtime (Docker or Podman) and the host Docker
daemon the pipeline drives.

> **No docker-in-docker.** The EE ships only the Docker *client*. At run time
> the host's `/var/run/docker.sock` is bind-mounted in, so every `docker`
> command and every `community.docker` module talks to the **host** daemon.
> The EE never starts its own `dockerd`.

## Files

| File | Purpose |
|------|---------|
| `execution-environment.yml` | ansible-builder v3 definition (base image, deps, CLI install steps) |
| `requirements.yml` | Galaxy collections baked in (single source of truth) |
| `requirements.txt` | Python packages baked in (Docker SDK, requests) |
| `bindep.txt` | system/OS packages baked in (git, tar, gzip, openssl, build deps) |
| `build-ee.sh` | wrapper around `ansible-builder build` |

## Build the EE (internet-connected build host)

You need a build host with outbound internet (it pulls the base image, RPMs,
pip packages, the docker/helm CLIs, and the collections).

```bash
# 1. Install the builder (once). On Ubuntu 24.04 / Debian 12, system-wide
#    `pip install` is blocked (PEP 668) — use pipx (apt install -y pipx):
pipx install ansible-builder       # >= 3.0  (pip works inside a venv too)

# 2. Build the image (default tag: f5-airgap-ee:latest, runtime: docker)
cd ee
bash build-ee.sh

# Customize:
EE_IMAGE=f5-airgap-ee:1.0.0 bash build-ee.sh
CONTAINER_RUNTIME=podman      bash build-ee.sh
```

Verify the result:

```bash
docker run --rm f5-airgap-ee:latest ansible --version
docker run --rm f5-airgap-ee:latest helm version --short
docker run --rm f5-airgap-ee:latest docker --version
```

## Use the EE

Each stage has an `ansible-navigator.yml` that points at `f5-airgap-ee:latest`
and wires up the right mounts. From the stage directory:

```bash
cd pull   # or push
ansible-navigator run open-pull/playbooks/pull_artifacts.yaml \
  --vault-password-file .vault-pass
```

See `pull/README.md` and `push/README.md` for the full per-stage flow.

## Air-gapped (closed-network) hosts

The push host has no internet, so it can't build the EE. Build it on the
internet side, then carry the image across the gap alongside the artifact
bundle:

```bash
# On the internet-side build host, after build-ee.sh:
docker save f5-airgap-ee:latest | gzip > f5-airgap-ee.tar.gz
sha256sum f5-airgap-ee.tar.gz > f5-airgap-ee.tar.gz.sha256

# Transfer both files across the air gap, then on the closed-network host:
sha256sum -c f5-airgap-ee.tar.gz.sha256
gunzip -c f5-airgap-ee.tar.gz | docker load
docker image ls f5-airgap-ee
```

`pull-policy: missing` in the navigator configs means navigator uses the
locally loaded image and never tries to reach a registry — exactly what an
air-gapped host needs.

## Bumping versions

| To change | Edit | Then |
|-----------|------|------|
| A collection version | `requirements.yml` | rebuild |
| A Python dep | `requirements.txt` | rebuild |
| ansible-core floor | `dependencies.ansible_core` in `execution-environment.yml` (and the matching assert in both `preflight.yaml`) | rebuild |
| helm version | `HELM_VERSION` in `execution-environment.yml` | rebuild |
| docker client version | `DOCKER_VERSION` in `execution-environment.yml` | rebuild |
| base OS | `images.base_image` (+ `options.package_manager_path` if the package manager changes) in `execution-environment.yml` | rebuild |

After rebuilding, re-load the image on every host that uses it (air-gapped
hosts via the `docker save` / `docker load` procedure above).
