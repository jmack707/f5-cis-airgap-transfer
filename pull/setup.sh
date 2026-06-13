#!/usr/bin/env bash
# =============================================================================
# setup.sh
#
# One-shot setup for the open-pull stage on a fresh Ubuntu 22.04+ workstation.
# Installs ansible-core from the official PPA and the required collections.
#
# Run once after cloning the repo:
#   bash setup.sh
# =============================================================================
set -euo pipefail

echo "==> Checking for ansible-core..."
if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "==> Installing ansible-core from Ansible PPA..."
  sudo add-apt-repository --yes --update ppa:ansible/ansible
  sudo apt-get install -y ansible
else
  echo "    Found: $(ansible --version | head -1)"
fi

echo
echo "==> Checking for Docker daemon..."
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker is not installed."
  echo "       Install Docker Engine first: https://docs.docker.com/engine/install/ubuntu/"
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker daemon is not running or current user cannot access it."
  echo "       Try: sudo usermod -aG docker \$USER  (then log out and back in)"
  exit 1
fi
echo "    Docker daemon reachable."

echo
echo "==> Checking for Helm..."
if ! command -v helm >/dev/null 2>&1; then
  echo "    Installing Helm..."
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
