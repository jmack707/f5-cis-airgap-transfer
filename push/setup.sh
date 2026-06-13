#!/usr/bin/env bash
# =============================================================================
# setup.sh — ccn-push (closed-network host)
#
# Verifies the closed-network host has the required tooling. Unlike the
# internet-side setup, this script does NOT attempt to install anything —
# the host has no internet access. If any check fails, the script reports
# what's missing so an operator can install it from local sources.
#
# Run once after extracting the zip:
#   bash setup.sh
# =============================================================================
set -euo pipefail

FAIL=0

check() {
  local name="$1"; local cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    echo "    OK:      $name"
  else
    echo "    MISSING: $name"
    FAIL=$((FAIL + 1))
  fi
}

echo "==> Verifying ansible-core..."
check "ansible-playbook"     "command -v ansible-playbook"
check "ansible-galaxy"       "command -v ansible-galaxy"

echo
echo "==> Verifying Docker..."
check "docker binary"        "command -v docker"
check "docker daemon access" "docker info"

echo
echo "==> Verifying Helm 3.8.0+..."
if command -v helm >/dev/null 2>&1; then
  HELM_VER=$(helm version --short --template='{{.Version}}' | sed 's/^v//')
  # Minimum 3.8.0 required for OCI registry push.
  if [ "$(printf '%s\n3.8.0\n' "$HELM_VER" | sort -V | head -1)" = "3.8.0" ]; then
    echo "    OK:      helm $HELM_VER (>= 3.8.0)"
  else
    echo "    TOO OLD: helm $HELM_VER (need >= 3.8.0 for OCI push)"
    FAIL=$((FAIL + 1))
  fi
else
  echo "    MISSING: helm"
  FAIL=$((FAIL + 1))
fi

echo
echo "==> Verifying required CLI tools..."
check "tar"                  "command -v tar"
check "sha256sum"            "command -v sha256sum"
check "openssl"              "command -v openssl"

echo
echo "==> Verifying Ansible collections..."
if [ -f collections/requirements.yml ]; then
  echo "    Installing from collections/requirements.yml (offline if a local mirror is configured)..."
  ansible-galaxy collection install -r collections/requirements.yml --force || {
    echo "    NOTE: collection install failed. If collections are already present, this is fine."
    echo "          If not, you'll need to install them from a local Galaxy mirror or offline tarball."
  }
fi

for mod in community.docker.docker_login \
           ansible.builtin.unarchive; do
  if ansible-doc "$mod" >/dev/null 2>&1; then
    echo "    OK:      $mod"
  else
    echo "    MISSING: $mod (collection not installed)"
    FAIL=$((FAIL + 1))
  fi
done

echo
if [ "$FAIL" -gt 0 ]; then
  echo "==> $FAIL check(s) failed. Install the missing items before running ccn-push."
  exit 1
fi

echo "==> Setup complete."
echo
echo "Next steps:"
echo "  1. cp vault.yaml.example vault.yaml"
echo "  2. Edit vault.yaml with the closed-network registry endpoint details"
echo "  3. ansible-vault encrypt vault.yaml"
echo "  4. Place the bundle at the path defined by vault_ccn_bundle_incoming_path"
echo "  5. ansible-playbook ccn-push/playbooks/push_artifacts.yaml --ask-vault-pass"
