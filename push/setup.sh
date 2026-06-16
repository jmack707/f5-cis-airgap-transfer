#!/usr/bin/env bash
# =============================================================================
# setup.sh — ccn-push (closed-network host)
#
# Verifies the closed-network host has the required tooling. Unlike the
# internet-side setup, this script does NOT install anything — the host has no
# internet access, so there is nothing to install *from*. If a check fails, the
# script reports what is missing AND prints an OS-appropriate hint for how an
# operator would install it from local sources.
#
# Supported OS families (auto-detected from /etc/os-release):
#   - debian  → Ubuntu 22.04 / 24.04       (apt-phrased remediation hints)
#   - rhel    → Rocky Linux 9.x / RHEL 9.x  (dnf-phrased remediation hints)
#
# The OS family changes ONLY the wording of the "how to fix it" hints. The
# checks themselves, and the "install nothing" policy, are identical on every
# platform.
#
# Run once after extracting the zip:
#   bash setup.sh
# =============================================================================
set -euo pipefail

FAIL=0

# -----------------------------------------------------------------------------
# detect_os — normalise the OS into OS_FAMILY (debian | rhel | unknown) and set
# PKG_HINT, the package-manager phrasing used in MISSING remediation messages.
# Identical detection logic to the pull side, kept inline so this script stays
# self-contained on an air-gapped host with nothing else from the repo present.
# -----------------------------------------------------------------------------
detect_os() {
  if [ ! -r /etc/os-release ]; then
    OS_FAMILY="unknown"; OS_PRETTY="unknown (no /etc/os-release)"
    PKG_HINT="your platform's package manager"
    return
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  OS_PRETTY="${PRETTY_NAME:-${NAME:-unknown}}"

  local id="${ID:-}"
  local id_like="${ID_LIKE:-}"

  case " ${id} ${id_like} " in
    *" debian "*|*" ubuntu "*)
      OS_FAMILY="debian"
      PKG_HINT="a local apt mirror (apt-get install) or an offline .deb" ;;
    *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*)
      OS_FAMILY="rhel"
      PKG_HINT="a local dnf repo (dnf install) or an offline .rpm" ;;
    *)
      OS_FAMILY="unknown"
      PKG_HINT="your platform's package manager" ;;
  esac
}

# check NAME COMMAND [HINT]
#   Runs COMMAND; prints OK or MISSING. On MISSING, prints the optional HINT
#   (or the generic OS package-manager hint) so the operator knows the local
#   remediation path. Increments FAIL on failure.
check() {
  local name="$1"; local cmd="$2"; local hint="${3:-}"
  if eval "$cmd" >/dev/null 2>&1; then
    echo "    OK:      $name"
  else
    echo "    MISSING: $name"
    if [ -n "$hint" ]; then
      echo "             → $hint"
    else
      echo "             → provide via ${PKG_HINT}"
    fi
    FAIL=$((FAIL + 1))
  fi
}

detect_os
echo "==> Detected OS family: ${OS_FAMILY}  (${OS_PRETTY})"
echo

echo "==> Verifying ansible-core..."
check "ansible-playbook" "command -v ansible-playbook" \
      "install ansible-core (>=2.17) from ${PKG_HINT}, or an offline pip wheel"
check "ansible-galaxy"   "command -v ansible-galaxy"   \
      "ships with ansible-core — same source as above"

echo
echo "==> Verifying Docker..."
check "docker binary"        "command -v docker" \
      "install docker-ce from a local mirror (NOT the distro podman/docker shim)"
check "docker daemon access" "docker info" \
      "start dockerd and add your user to the 'docker' group, then re-login"

echo
echo "==> Verifying Helm 3.8.0+..."
if command -v helm >/dev/null 2>&1; then
  HELM_VER=$(helm version --short --template='{{.Version}}' | sed 's/^v//')
  # Minimum 3.8.0 required for OCI registry push.
  if [ "$(printf '%s\n3.8.0\n' "$HELM_VER" | sort -V | head -1)" = "3.8.0" ]; then
    echo "    OK:      helm $HELM_VER (>= 3.8.0)"
  else
    echo "    TOO OLD: helm $HELM_VER (need >= 3.8.0 for OCI push)"
    echo "             → copy a newer static helm binary via the physical transfer"
    FAIL=$((FAIL + 1))
  fi
else
  echo "    MISSING: helm"
  echo "             → copy a static helm 3.8.0+ binary via the physical transfer"
  FAIL=$((FAIL + 1))
fi

echo
echo "==> Verifying required CLI tools..."
# tar/sha256sum/openssl are in the base install on both Ubuntu and Rocky/RHEL;
# they are only ever missing on a deliberately minimised image.
check "tar"       "command -v tar"       "base OS package (coreutils/tar)"
check "sha256sum" "command -v sha256sum" "base OS package (coreutils)"
check "openssl"   "command -v openssl"   "base OS package (openssl)"

echo
echo "==> Verifying Ansible collections..."
if [ -f collections/requirements.yml ]; then
  echo "    Installing from collections/requirements.yml (offline if a local mirror is configured)..."
  ansible-galaxy collection install -r collections/requirements.yml --force || {
    echo "    NOTE: collection install failed. If collections are already present, this is fine."
    echo "          If not, install them from a local Galaxy mirror or an offline tarball"
    echo "          built with: ansible-galaxy collection download -r collections/requirements.yml"
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
  echo "==> $FAIL check(s) failed. Install the missing items from local sources"
  echo "    before running ccn-push. See the hints above for the ${OS_FAMILY} path."
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
