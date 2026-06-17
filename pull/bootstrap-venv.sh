#!/usr/bin/env bash
# =============================================================================
# bootstrap-venv.sh — one-shot EL9 (RHEL 9 / Rocky 9) ansible venv builder
#
# Scripts the manual recipe that setup.sh prints when it hits the EL9 floor:
#   install python3.12 → build a venv → install ansible-core + the Docker SDK
#   into it → verify → (optionally) run setup.sh with the venv on PATH.
#
# WHY THIS EXISTS
#   RHEL 9 / Rocky 9 ship Python 3.9 as the system python3, but ansible-core
#   2.17+ requires Python 3.10+. The supported path is a venv built from a
#   newer Python (python3.12, AppStream). This automates that.
#
# WHAT IT CANNOT DO
#   It cannot leave YOUR shell activated — a script's `source` only affects its
#   own subshell. It installs into the venv by calling the venv's pip directly
#   (no activation needed), then tells you the one command you still run by hand:
#       source ~/.venv/ansible/bin/activate
#   before invoking ansible-playbook in any shell.
#
# SCOPE
#   This is an INTERNET-side helper (it dnf-installs and pip-installs). On the
#   air-gapped push host, build the same venv but point pip at offline wheels /
#   a local mirror, and dnf at a local repo.
#
# USAGE
#   bash bootstrap-venv.sh                 # build venv, then run ./setup.sh
#   VENV_DIR=/opt/ansible bash bootstrap-venv.sh    # custom venv location
#   BOOTSTRAP_NO_SETUP=1 bash bootstrap-venv.sh      # build venv only
#   FORCE=1 bash bootstrap-venv.sh         # rebuild even if venv looks valid
# =============================================================================
set -euo pipefail

ANSIBLE_MIN="2.17"
VENV_DIR="${VENV_DIR:-$HOME/.venv/ansible}"

# version_ge A B → exit 0 if A >= B (semver compare). Same trick as setup.sh.
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

# -----------------------------------------------------------------------------
# 1. Sanity: this helper is for the RHEL/Rocky family. On Ubuntu, setup.sh's
#    PPA path already gives a current ansible-core — no venv needed.
# -----------------------------------------------------------------------------
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case " ${ID:-} ${ID_LIKE:-} " in
    *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*) : ;;
    *)
      echo "NOTE: this helper targets RHEL 9 / Rocky 9. Detected: ${PRETTY_NAME:-unknown}."
      echo "      On Ubuntu/Debian just run: bash setup.sh"
      exit 1 ;;
  esac
fi

# -----------------------------------------------------------------------------
# 2. Pick the newest available python3.1x (>= 3.10). Prefer 3.12 to match the
#    Ubuntu baseline's ansible-core 2.21; accept 3.11 as a fallback.
# -----------------------------------------------------------------------------
PYBIN=""
for cand in python3.12 python3.11; do
  if command -v "$cand" >/dev/null 2>&1; then PYBIN="$cand"; break; fi
done

if [ -z "$PYBIN" ]; then
  echo "==> No suitable Python found; installing python3.12 via dnf..."
  if ! sudo dnf install -y python3.12 python3.12-pip; then
    echo "    python3.12 not available; trying python3.11..."
    sudo dnf install -y python3.11 python3.11-pip || {
      echo "ERROR: could not install python3.12 or python3.11."
      echo "       Check what's available:  dnf list available 'python3.1*'"
      exit 1
    }
  fi
  for cand in python3.12 python3.11; do
    if command -v "$cand" >/dev/null 2>&1; then PYBIN="$cand"; break; fi
  done
fi
echo "==> Using interpreter: ${PYBIN} ($("$PYBIN" --version))"

# -----------------------------------------------------------------------------
# 3. Build the venv (idempotent: keep a valid one unless FORCE=1).
# -----------------------------------------------------------------------------
if [ -x "${VENV_DIR}/bin/ansible" ] && [ -z "${FORCE:-}" ]; then
  existing="$("${VENV_DIR}/bin/ansible" --version | head -1 | sed -E 's/.*core ([0-9.]+).*/\1/')"
  if version_ge "$existing" "$ANSIBLE_MIN"; then
    echo "==> Existing venv at ${VENV_DIR} already has ansible-core ${existing} (>= ${ANSIBLE_MIN}); reusing."
    echo "    (Pass FORCE=1 to rebuild.)"
  else
    echo "==> Existing venv has ansible-core ${existing} (< ${ANSIBLE_MIN}); rebuilding..."
    rm -rf "${VENV_DIR}"
  fi
fi

if [ ! -x "${VENV_DIR}/bin/ansible" ]; then
  echo "==> Building venv at ${VENV_DIR}..."
  rm -rf "${VENV_DIR}"
  "$PYBIN" -m venv "${VENV_DIR}"
  echo "==> Installing ansible-core (>= ${ANSIBLE_MIN}) + Docker SDK into the venv..."
  # Call the venv's pip directly — no activation required.
  "${VENV_DIR}/bin/pip" install --upgrade pip
  "${VENV_DIR}/bin/pip" install "ansible-core>=${ANSIBLE_MIN}" docker
fi

# -----------------------------------------------------------------------------
# 4. Verify the result.
# -----------------------------------------------------------------------------
ANSIBLE_VER="$("${VENV_DIR}/bin/ansible" --version | head -1 | sed -E 's/.*core ([0-9.]+).*/\1/')"
PY_VER="$("${VENV_DIR}/bin/python" --version 2>&1 | awk '{print $2}')"
if ! version_ge "$ANSIBLE_VER" "$ANSIBLE_MIN"; then
  echo "ERROR: venv has ansible-core ${ANSIBLE_VER}, still below ${ANSIBLE_MIN}."
  exit 1
fi
echo "==> venv ready: ansible-core ${ANSIBLE_VER} on Python ${PY_VER}"

# -----------------------------------------------------------------------------
# 5. Optionally run setup.sh with the venv on PATH (installs collections, etc.)
#    so a fresh box goes from zero to ready in one command. This works WITHOUT
#    activating your shell because we set PATH only for this child process.
# -----------------------------------------------------------------------------
if [ -z "${BOOTSTRAP_NO_SETUP:-}" ] && [ -f setup.sh ]; then
  echo "==> Running setup.sh with the venv on PATH..."
  PATH="${VENV_DIR}/bin:${PATH}" bash setup.sh
fi

# -----------------------------------------------------------------------------
# 6. The one thing a script can't do for you: activate your interactive shell.
# -----------------------------------------------------------------------------
cat <<EOF

============================================================================
 Bootstrap complete.

 ONE manual step remains — a script can't activate a venv in your shell.
 In THIS shell (and every new terminal) before running playbooks, run:

     source ${VENV_DIR}/bin/activate

 Then, e.g.:
     ansible-playbook open-pull/playbooks/pull_artifacts.yaml --ask-vault-pass
============================================================================
EOF
