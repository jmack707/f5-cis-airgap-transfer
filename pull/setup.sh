#!/usr/bin/env bash
# =============================================================================
# setup.sh — open-pull stage (internet-side workstation)
#
# One-shot setup for the open-pull stage on a fresh workstation. Installs
# ansible-core, verifies Docker and Helm are present, installs the required
# Ansible collections, and confirms every module the playbook uses is
# reachable.
#
# Supported OS families (auto-detected from /etc/os-release):
#   - debian  → Ubuntu 22.04 / 24.04           (ansible from the Ansible PPA)
#   - rhel    → Rocky Linux 9.x / RHEL 9.x      (ansible-core from dnf/AppStream,
#                                                with an EPEL `ansible` fallback)
#
# Docker is treated as an operator-provided prerequisite on every platform:
# this script checks for it and points you at the correct install docs if it
# is missing, but it does NOT install Docker itself (installing docker-ce
# pulls in daemon-restart and docker-group-membership steps that an operator
# should do deliberately, not as a side effect of running setup).
#
# Run once after cloning the repo:
#   bash setup.sh
# =============================================================================
set -euo pipefail

# Minimum ansible-core the playbooks are validated against. dnf on RHEL 9 /
# Rocky 9 can ship an ansible-core BELOW this floor, so we check the installed
# version after install and fail loudly with remediation if it is too old.
ANSIBLE_MIN="2.17"

# -----------------------------------------------------------------------------
# detect_os — read /etc/os-release and set OS_FAMILY + package-manager hints.
#
# OS_FAMILY is normalised to one of: debian | rhel | unknown
#   - debian : Ubuntu, Debian (ID or ID_LIKE contains "debian")
#   - rhel   : RHEL, Rocky, AlmaLinux, CentOS (ID or ID_LIKE contains "rhel"
#              or "fedora")
# We branch every OS-specific step on OS_FAMILY rather than on the exact ID so
# that Rocky and RHEL (and Alma) share one code path.
# -----------------------------------------------------------------------------
detect_os() {
  if [ ! -r /etc/os-release ]; then
    OS_FAMILY="unknown"
    OS_PRETTY="unknown (no /etc/os-release)"
    return
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  OS_PRETTY="${PRETTY_NAME:-${NAME:-unknown}}"

  local id="${ID:-}"
  local id_like="${ID_LIKE:-}"

  case " ${id} ${id_like} " in
    *" debian "*|*" ubuntu "*)
      OS_FAMILY="debian" ;;
    *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*)
      OS_FAMILY="rhel" ;;
    *)
      # Fall back to probing for a package manager if the IDs are unfamiliar.
      if command -v apt-get >/dev/null 2>&1; then
        OS_FAMILY="debian"
      elif command -v dnf >/dev/null 2>&1; then
        OS_FAMILY="rhel"
      else
        OS_FAMILY="unknown"
      fi ;;
  esac
}

# -----------------------------------------------------------------------------
# version_ge A B  →  exit 0 if A >= B (semantic-version compare), else 1.
# Reused for the ansible-core floor check; same trick used for Helm elsewhere.
# -----------------------------------------------------------------------------
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

# -----------------------------------------------------------------------------
# install_ansible_debian — Ubuntu/Debian path: Ansible PPA + apt-get.
# This is the original, verified-working path; unchanged in behaviour.
# -----------------------------------------------------------------------------
install_ansible_debian() {
  echo "==> Installing ansible-core from the Ansible PPA (apt)..."
  sudo add-apt-repository --yes --update ppa:ansible/ansible
  sudo apt-get install -y ansible
}

# -----------------------------------------------------------------------------
# install_ansible_rhel — Rocky/RHEL path.
#
# Strategy:
#   1. Try `dnf install -y ansible-core` (AppStream on both Rocky 9 and RHEL 9).
#   2. If that fails, enable EPEL and install the `ansible` community bundle,
#      which carries a newer ansible-core than AppStream typically does.
# The version floor is enforced afterwards by the caller, so even if AppStream
# ships an old ansible-core the operator gets a clear, actionable failure.
# -----------------------------------------------------------------------------
install_ansible_rhel() {
  echo "==> Installing ansible-core via dnf (AppStream)..."
  if sudo dnf install -y ansible-core; then
    return 0
  fi

  echo "    ansible-core not available from default repos; enabling EPEL..."
  # epel-release exists directly on Rocky/Alma; on RHEL it may need the
  # Fedora-hosted rpm. Try the package first, then the canonical rpm URL.
  if ! sudo dnf install -y epel-release; then
    sudo dnf install -y \
      "https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
  fi
  echo "    Installing the EPEL 'ansible' bundle..."
  sudo dnf install -y ansible
}

# =============================================================================
# Main
# =============================================================================
detect_os
echo "==> Detected OS family: ${OS_FAMILY}  (${OS_PRETTY})"
echo

echo "==> Checking for ansible-core..."
if ! command -v ansible-playbook >/dev/null 2>&1; then
  case "${OS_FAMILY}" in
    debian) install_ansible_debian ;;
    rhel)   install_ansible_rhel ;;
    *)
      echo "ERROR: Unsupported or undetectable OS family."
      echo "       This script installs ansible-core on Debian/Ubuntu and"
      echo "       Rocky/RHEL only. Install ansible-core >= ${ANSIBLE_MIN}"
      echo "       manually, then re-run this script."
      exit 1 ;;
  esac
else
  echo "    Found: $(ansible --version | head -1)"
fi

# Enforce the version floor regardless of how ansible-core arrived (PPA, dnf,
# EPEL, or a pre-existing install). dnf/AppStream is the realistic offender.
ANSIBLE_VER="$(ansible --version | head -1 | sed -E 's/.*core ([0-9.]+).*/\1/')"
if version_ge "${ANSIBLE_VER}" "${ANSIBLE_MIN}"; then
  echo "    ansible-core ${ANSIBLE_VER} (>= ${ANSIBLE_MIN}) — OK"
else
  echo "ERROR: ansible-core ${ANSIBLE_VER} is older than the required ${ANSIBLE_MIN}."
  case "${OS_FAMILY}" in
    rhel)
      echo "       On RHEL/Rocky 9 the default python3 is 3.9, but ansible-core"
      echo "       >= ${ANSIBLE_MIN} requires Python >= 3.10. The system AppStream"
      echo "       ansible-core and the EPEL 'ansible' bundle are both pinned to the"
      echo "       3.9 / core-2.14 line and will NOT clear this floor. Install a newer"
      echo "       Python and build a venv from IT (python3.12 matches the Ubuntu"
      echo "       baseline's ansible-core 2.21; python3.11 also clears the floor):"
      echo "         sudo dnf install -y python3.12 python3.12-pip"
      echo "         rm -rf ~/.venv/ansible"
      echo "         python3.12 -m venv ~/.venv/ansible"
      echo "         . ~/.venv/ansible/bin/activate"
      echo "         pip install --upgrade pip"
      echo "         pip install 'ansible-core>=${ANSIBLE_MIN}' docker"
      echo "       (If python3.12 is unavailable: dnf list available 'python3.1*' and"
      echo "        use the highest you have, e.g. python3.11.)"
      echo "       Then, with the venv active, re-run: bash setup.sh"
      echo "       (ansible-core does NOT bundle community.docker/kubernetes.core;"
      echo "        re-running setup.sh installs them. The 'docker' pip package is the"
      echo "        Docker SDK the image modules need — the inventory pins localhost to"
      echo "        the venv interpreter, so it is found there.)" ;;
    debian)
      echo "       The Ansible PPA normally provides a current ansible-core."
      echo "       Confirm the PPA is enabled, or install via pip in a venv:"
      echo "         pip install 'ansible-core>=${ANSIBLE_MIN}'"
      echo "       Then re-run: bash setup.sh" ;;
    *)
      echo "       Install ansible-core >= ${ANSIBLE_MIN} via your platform's"
      echo "       package manager or pip in a virtualenv (the interpreter must be"
      echo "       Python >= 3.10), then re-run: bash setup.sh" ;;
  esac
  exit 1
fi

echo
echo "==> Checking for Docker daemon..."
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker is not installed."
  case "${OS_FAMILY}" in
    debian)
      echo "       Install Docker Engine first:"
      echo "         https://docs.docker.com/engine/install/ubuntu/" ;;
    rhel)
      echo "       Install Docker Engine from Docker's official RHEL/CentOS repo"
      echo "       (the docker-ce package — the distro's podman/docker is not"
      echo "       sufficient for this workflow):"
      echo "         https://docs.docker.com/engine/install/rhel/      (RHEL)"
      echo "         https://docs.docker.com/engine/install/centos/    (Rocky/Alma)" ;;
    *)
      echo "       Install Docker Engine for your platform:"
      echo "         https://docs.docker.com/engine/install/" ;;
  esac
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  # Docker access is checked but NEVER mutated here — Docker is owned by your
  # environment's prerequisites step (e.g. cni-net-lab), not by this script.
  # The common false alarm is a STALE docker-group session: a prereqs step ran
  # `usermod -aG docker you`, but THIS shell predates that membership, so the
  # socket is unreadable until you start a fresh login shell. That is transient
  # and self-healing — not a reason to abort. ansible-core and the collection
  # install below need no Docker socket, so we WARN and continue rather than
  # exit, and tell you exactly how to fix access before the playbook runs.
  me="$(id -un)"
  if sudo -n docker info >/dev/null 2>&1; then
    # Daemon is UP; only your user's socket access is the problem.
    if getent group docker 2>/dev/null | awk -F: '{print $4}' | tr ',' '\n' | grep -qx "$me"; then
      echo "    WARNING: the Docker daemon is up, but THIS shell predates your"
      echo "             'docker' group membership. Session issue, not a Docker"
      echo "             problem — no reinstall needed. Before the pull playbook:"
      echo "                 newgrp docker      # or start a fresh login shell"
    else
      echo "    WARNING: the Docker daemon is up, but ${me} is not in the 'docker'"
      echo "             group. Add yourself, then start a fresh shell, before the"
      echo "             pull playbook:"
      echo "                 sudo usermod -aG docker ${me} && newgrp docker"
    fi
  else
    echo "    WARNING: could not confirm the Docker daemon is reachable. Ensure it"
    echo "             is installed (by your prereqs step) and running before the"
    echo "             pull playbook:  sudo systemctl enable --now docker"
  fi
  echo "    (Continuing — ansible/collection setup does not need the Docker socket.)"
else
  echo "    Docker daemon reachable as $(id -un)."
fi

echo
echo "==> Checking for Helm..."
if ! command -v helm >/dev/null 2>&1; then
  echo "    Installing Helm..."
  # The upstream get-helm-3 installer is OS-agnostic and works on both
  # Debian/Ubuntu and Rocky/RHEL.
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  echo "    Found: $(helm version --short)"
fi

echo
echo "==> Installing required Ansible collections..."
ansible-galaxy collection install -r collections/requirements.yml --force

echo
echo "==> Verifying critical modules are reachable..."
for mod in community.docker.docker_image_pull \
           community.docker.docker_image_export \
           community.docker.docker_login \
           kubernetes.core.helm_repository; do
  if ansible-doc "$mod" >/dev/null 2>&1; then
    echo "    OK: $mod"
  else
    echo "    MISSING: $mod"
    exit 1
  fi
done

echo
echo "==> Setup complete."
echo
echo "Next steps:"
echo "  1. cp vault.yaml.example vault.yaml"
echo "  2. Fill in vault.yaml with your Docker Hub and NGINX JWT credentials"
echo "  3. ansible-vault encrypt vault.yaml"
echo "  4. ansible-playbook open-pull/playbooks/pull_artifacts.yaml --ask-vault-pass"
