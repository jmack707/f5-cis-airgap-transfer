# Clean-room test runbook — pull side (RHEL 9 / Rocky 9)

## WHAT this is

A start-to-finish procedure for proving that a **fresh** RHEL 9 / Rocky 9 host
can run the `pull` stage successfully by following the documentation **alone**,
with no manual fixes along the way. It is written to be copy-pasted one step at
a time. Each step has a single command block and, where it matters, a
**Checkpoint** telling you what "good" looks like before you continue.

Acronyms, first use: **EL9** = Enterprise Linux 9 (RHEL 9, Rocky 9, Alma 9).
**venv** = Python virtual environment. **CIS** = F5 BIG-IP Container Ingress
Services. **JWT** = JSON Web Token (the F5 NGINX subscription credential).

## WHY it exists

Running the pull once on a host you fixed up by hand only proves it can work
when babied. The real bar is: a clean machine reaches a finished bundle by
following these steps verbatim. This runbook is that test. The governing rule:

> **If you have to deviate from a step to make it work, that deviation is a
> bug.** Note where it happened and fix the doc or the script — do not just work
> around it and move on. A clean-room test that needed a manual rescue did not
> pass.

## BEFORE YOU START

1. The host is a freshly rolled-back **Rocky 9.8** (or RHEL 9) on which
   `cni-net-lab` has already run — so Docker is installed and your user is in
   the `docker` group. This mirrors the real environment the pull runs in.
2. The duplicate-collection-check fix is already pushed to the branch you are
   about to clone. Step 4 verifies this; if the check there fails, stop and push
   the fix before continuing.
3. You have your Docker Hub credentials and your F5 NGINX JWT token to hand
   (needed at Step 8).

---

## The test

### 1. Start a capture log

Records the whole session so the run can be compared against this runbook
afterward.

```bash
script -q ~/cleanroom-$(date +%H%M).log
```

### 2. Confirm the clean starting state

This is what a real operator's box looks like before setup: Docker present (from
`cni-net-lab`), but no newer Python and no Ansible yet.

```bash
docker --version            # expect: a version (cni-net-lab installed it)
python3.12 --version 2>&1   # expect: command not found
which ansible 2>&1          # expect: not found
```

### 3. Confirm Docker is reachable as your user

`cni-net-lab` added you to the `docker` group; a fresh login session picks it up.

```bash
docker info >/dev/null 2>&1 && echo "docker OK" || echo "NOT reachable — run: newgrp docker"
```

**Checkpoint:** must print `docker OK`. If it prints `NOT reachable`, run
`newgrp docker` and repeat this step until it says `docker OK`.

### 4. Clone the repository from GitHub and verify the fix is present

Clone — do **not** reuse an unzipped copy. Cloning tests exactly what an operator
would pull from GitHub, and keeps "what you test" identical to "what you ship".

```bash
sudo dnf install -y git
cd ~
git clone https://github.com/jmack707/f5-cis-airgap-transfer.git
cd f5-cis-airgap-transfer
git checkout rhel-rocky-support
grep -c "ansible-galaxy collection list" pull/open-pull/tasks/preflight.yaml
```

**Checkpoint:** the final number must be **1**. If it is **2**, the
duplicate-collection-check fix is not on this branch — stop, push the fix, and
start over. (Use `main` instead of `rhel-rocky-support` if the support PR is
already merged.)

### 5. Build the Ansible venv

EL9 ships Python 3.9 as the system `python3`, but `ansible-core` 2.17+ needs
Python 3.10+. Install `python3.12` and build the venv from it.

```bash
cd ~/f5-cis-airgap-transfer/pull
sudo dnf install -y python3.12 python3.12-pip
python3.12 -m venv ~/.venv/ansible
source ~/.venv/ansible/bin/activate
pip install --upgrade pip
pip install 'ansible-core>=2.17' docker
```

### 6. Run setup.sh with the venv active

This installs the pinned Ansible collections **into the venv** and verifies the
required modules. It must run in the same shell where the venv is active.

```bash
bash setup.sh
```

**Checkpoint:** the output ends with `==> Setup complete.` and four `OK:` module
lines, and the Docker line reads `Docker daemon reachable as <you>`.

### 7. Verify the toolchain before the run

```bash
which ansible
ansible-galaxy collection list | grep -E 'community.docker|kubernetes.core'
```

**Checkpoint:** `which ansible` points into `~/.venv/ansible/bin/` (NOT
`/usr/bin/ansible`), and you see `community.docker` ≥ 3.10 and
`kubernetes.core` ≥ 2.4.

### 8. Provide credentials and run the pull

`vault.yaml` holds your registry credentials and is encrypted at rest; only
`vault.yaml.example` is ever committed.

```bash
cp vault.yaml.example vault.yaml
nano vault.yaml
ansible-vault encrypt vault.yaml
ansible-playbook open-pull/playbooks/pull_artifacts.yaml --ask-vault-pass
```

In `vault.yaml`, fill in your Docker Hub username/password and your F5 NGINX JWT
token, then save and exit `nano` before the `ansible-vault encrypt` line runs.

### 9. Confirm success

```bash
ls -lh artifacts/airgap-bundle.tar.gz artifacts/airgap-bundle.tar.gz.sha256 artifacts/manifest.json
```

**Checkpoint (the whole point of the test):** the `PLAY RECAP` shows
`failed=0`, and all three files above exist. The bundle is the artifact you
carry across the air gap to the push side.

### 10. Close the capture log

```bash
exit
```

The session transcript is saved at `~/cleanroom-<HHMM>.log` for review.

---

## Pass / fail

- **Pass:** every step ran as written, every Checkpoint matched, `failed=0`, and
  the bundle exists — with zero manual interventions.
- **Fail (for doc purposes):** you had to deviate, retry, or fix something by
  hand at any step. Record exactly where, correct the runbook or the script,
  roll the VM back, and run again. The goal is a procedure a new operator can
  follow without a mentor present.

## Reminders that prevent the common stumbles

1. **The venv is per shell.** Every new terminal starts back on the system
   `ansible-core` (2.14, too old). Run `source ~/.venv/ansible/bin/activate`
   before doing anything Ansible-related. The Step 7 `which ansible` check is
   what catches a forgotten activation.
2. **setup.sh must run with the venv active** (Step 6). That is the step that
   installs the collections where this Ansible looks; building the venv and
   skipping straight to the playbook leaves the collections missing.
3. **Clone, do not unzip.** Testing a cloned repo while pushing from a different
   copy is how "what I tested" and "what I shipped" drift apart.

## Appendix — one-command venv build (optional)

Steps 5 and 6 can be collapsed into the helper, which installs `python3.12`
(falling back to `python3.11`), builds the venv, installs `ansible-core` + the
Docker SDK, and runs `setup.sh` — all in one command. Run it from `pull/` after
Step 4:

```bash
cd ~/f5-cis-airgap-transfer/pull
bash bootstrap-venv.sh
source ~/.venv/ansible/bin/activate
```

You still activate the venv yourself afterward (a script cannot activate a venv
in your shell), then continue at Step 7.
