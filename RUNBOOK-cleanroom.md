# Clean-room test runbook — pull side via Execution Environment (RHEL 9 / Rocky 9)

## WHAT this is

A start-to-finish procedure for proving that a **fresh** RHEL 9 / Rocky 9 host
can run the `pull` stage successfully — **through the Ansible Execution
Environment (EE)** — by following the documentation **alone**, with no manual
fixes along the way. It is written to be copy-pasted one step at a time. Each
step has a single command block and, where it matters, a **Checkpoint**
telling you what "good" looks like before you continue.

Acronyms, first use: **EL9** = Enterprise Linux 9 (RHEL 9, Rocky 9, Alma 9).
**EE** = Ansible Execution Environment (a container image carrying ansible-core,
the collections, the Docker SDK, and the `docker`/`helm` CLIs). **CIS** = F5
BIG-IP Container Ingress Services. **JWT** = JSON Web Token (the F5 NGINX
subscription credential).

## WHY it exists

Running the pull once on a host you fixed up by hand only proves it can work
when babied. The real bar is: a clean machine reaches a finished bundle by
following these steps verbatim. This runbook is that test. The governing rule:

> **If you have to deviate from a step to make it work, that deviation is a
> bug.** Note where it happened and fix the doc or the code — do not just work
> around it and move on. A clean-room test that needed a manual rescue did not
> pass.

## BEFORE YOU START

1. The host is a freshly rolled-back **Rocky 9.x** (or RHEL 9) on which
   `cni-net-lab` has already run — so Docker is installed and your user is in
   the `docker` group. This mirrors the real environment the pull runs in.
2. You have your Docker Hub credentials and your F5 NGINX JWT token to hand
   (needed at Step 7).

---

## The test

### 1. Start a capture log

Records the whole session so the run can be compared against this runbook
afterward.

```bash
script -q ~/cleanroom-$(date +%H%M).log
```

### 2. Confirm the clean starting state and Docker access

Docker is present (from `cni-net-lab`); a fresh login session has picked up the
`docker` group.

```bash
docker --version                            # expect: a version
docker info >/dev/null 2>&1 && echo "docker OK" || echo "run: newgrp docker"
which ansible-navigator 2>&1                 # expect: not found (yet)
```

**Checkpoint:** must print `docker OK`. If it prints the `newgrp` hint, run
`newgrp docker` and repeat until it says `docker OK`.

### 3. Clone the repository

Clone — do **not** reuse an unzipped copy. Cloning tests exactly what an
operator would pull from GitHub.

```bash
sudo dnf install -y git
cd ~
git clone https://github.com/jmack707/f5-cis-airgap-transfer.git
cd f5-cis-airgap-transfer
```

### 4. Install the build tooling

The EE is built with `ansible-builder`; it's run with `ansible-navigator`.
EL9 ships Python 3.9 as the system `python3`; install a newer one, then use
`pipx` so each tool gets its own isolated venv (this also matches the Ubuntu
path, where system-wide `pip install` is blocked by PEP 668).

```bash
sudo dnf install -y python3.12 python3.12-pip
python3.12 -m pip install --user pipx
export PATH="$HOME/.local/bin:$PATH"
pipx install ansible-builder
pipx install ansible-navigator
ansible-builder --version && ansible-navigator --version
```

**Checkpoint:** both commands print a version. (Add the `export PATH` line to
`~/.bashrc` if you want it to persist across shells.)

### 5. Build the Execution Environment

This builds `f5-airgap-ee:latest` with ansible-core, the collections, the
Docker SDK, and the `docker`/`helm` CLIs baked in.

```bash
cd ~/f5-cis-airgap-transfer
CONTAINER_RUNTIME=docker bash ee/build-ee.sh
```

**Checkpoint:** the build ends with `==> Built f5-airgap-ee:latest.` Verify:

```bash
docker run --rm f5-airgap-ee:latest ansible --version | head -1
docker run --rm f5-airgap-ee:latest helm version --short
docker run --rm f5-airgap-ee:latest docker --version
```

You should see ansible-core ≥ 2.17, helm ≥ 3.13, and a docker client version.

### 6. (No host venv, no host collections)

There is nothing to install on the host beyond the build tooling — ansible,
the collections, the Docker SDK, and `helm` all live inside the EE. This is the
whole point of the migration: the host stays clean.

### 7. Provide credentials and run the pull

`vault.yaml` holds your registry credentials and is encrypted at rest; only
`vault.yaml.example` is ever committed. `ansible-navigator` reads the vault
password from a file.

```bash
cd ~/f5-cis-airgap-transfer/pull
cp vault.yaml.example vault.yaml
nano vault.yaml                 # fill in Docker Hub + F5 NGINX JWT, then save
ansible-vault encrypt vault.yaml
printf '%s' 'your-vault-password' > .vault-pass && chmod 600 .vault-pass

ansible-navigator run open-pull/playbooks/pull_artifacts.yaml \
  --vault-password-file .vault-pass
```

The playbook runs inside the EE; the host Docker socket is mounted in
(`pull/ansible-navigator.yml`), so the pulls and saves hit the host daemon and
`artifacts/` is written back to this directory.

### 8. Confirm success

```bash
ls -lh artifacts/airgap-bundle.tar.gz artifacts/airgap-bundle.tar.gz.sha256 artifacts/manifest.json
```

**Checkpoint (the whole point of the test):** the `PLAY RECAP` shows
`failed=0`, and all three files above exist. The bundle is the artifact you
carry across the air gap to the push side — alongside the EE image (see
`ee/README.md` for `docker save`/`docker load`).

### 9. Close the capture log

```bash
exit
```

The session transcript is saved at `~/cleanroom-<HHMM>.log` for review.

---

## Pass / fail

- **Pass:** every step ran as written, every Checkpoint matched, `failed=0`, and
  the bundle exists — with zero manual interventions.
- **Fail (for doc purposes):** you had to deviate, retry, or fix something by
  hand at any step. Record exactly where, correct the runbook or the code, roll
  the VM back, and run again. The goal is a procedure a new operator can follow
  without a mentor present.

## Reminders that prevent the common stumbles

1. **The EE is the toolchain.** The host has no ansible and no collections —
   they're inside `f5-airgap-ee:latest`. If a run can't find a module, the fix
   is to rebuild the EE (`bash ee/build-ee.sh`), not to pip-install on the host.
2. **Docker socket access.** The EE runs as root and bind-mounts the host
   `/var/run/docker.sock`. If pulls fail with a permission error, confirm
   `docker info` works as your user first (Step 2).
3. **Clone, do not unzip.** Testing a cloned repo while shipping from a
   different copy is how "what I tested" and "what I shipped" drift apart.
