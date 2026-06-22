#!/usr/bin/env bash
# =============================================================================
# push/host-prep.sh — one-time HOST Docker-daemon prep for the push stage
#
# WHY THIS EXISTS
#   The push stage runs inside the f5-airgap Execution Environment (a
#   container). Two pieces of setup, however, touch the HOST's Docker daemon
#   and cannot run cleanly from inside a container:
#
#     - HTTP registry  : add the endpoint to /etc/docker/daemon.json
#                        "insecure-registries" and RESTART dockerd.
#     - HTTPS registry : install the private CA at
#                        /etc/docker/certs.d/<host>[:<port>]/ca.crt so the
#                        daemon validates the registry's TLS cert.
#
#   This script does exactly that, on the host, with sudo, ONCE — before you
#   run the EE push. It replaces the old configure_insecure_registry.yaml and
#   trust_ca.yaml task files.
#
# WHAT IT DOES NOT DO
#   It does not push anything and it needs no vault password. The actual
#   verify/load/tag/push runs in the EE via:
#       ansible-navigator run ccn-push/playbooks/push_artifacts.yaml ...
#
# USAGE
#   HTTP (insecure) registry:
#     sudo ./host-prep.sh --host registry.example.com --port 5000 --insecure
#
#   HTTPS registry with a private CA:
#     sudo ./host-prep.sh --host registry.example.com --port 443 \
#       --ca-path /etc/ssl/certs/internal-ca.crt
#
#   Undo an insecure-registries entry (and restart dockerd):
#     sudo ./host-prep.sh --host registry.example.com --port 5000 --insecure --remove
#
# IDEMPOTENCY
#   Re-running with the same arguments is a no-op: the insecure-registries
#   entry is de-duplicated and dockerd is only restarted when daemon.json
#   actually changes; the CA is only copied when it differs.
# =============================================================================
set -euo pipefail

REG_HOST=""
REG_PORT=""
INSECURE=false
CA_PATH=""
REMOVE=false

usage() {
  sed -n '2,40p' "$0"
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host)     REG_HOST="$2"; shift 2 ;;
    --port)     REG_PORT="$2"; shift 2 ;;
    --insecure) INSECURE=true; shift ;;
    --ca-path)  CA_PATH="$2"; shift 2 ;;
    --remove)   REMOVE=true; shift ;;
    -h|--help)  usage 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage 1 ;;
  esac
done

[ -n "${REG_HOST}" ] || { echo "ERROR: --host is required" >&2; usage 1; }
[ -n "${REG_PORT}" ] || { echo "ERROR: --port is required" >&2; usage 1; }

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: this script edits /etc/docker — re-run with sudo." >&2
  exit 1
fi

ENDPOINT="${REG_HOST}:${REG_PORT}"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed on this host." >&2
  exit 1
fi

# Need a JSON-capable tool to merge daemon.json safely. python3 is in the EL9
# and Ubuntu base installs; prefer it over hand-rolled sed surgery on JSON.
PY=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { echo "ERROR: python3 is required to edit daemon.json safely." >&2; exit 1; }

restart_docker() {
  echo "==> Restarting Docker to apply the change..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart docker
  else
    service docker restart
  fi
  echo "    Waiting for the daemon to come back..."
  for _ in $(seq 1 10); do
    if docker info >/dev/null 2>&1; then echo "    Docker is back up."; return 0; fi
    sleep 2
  done
  echo "ERROR: Docker did not come back up — check 'journalctl -u docker'." >&2
  exit 1
}

# -----------------------------------------------------------------------------
# HTTPS path: install (or this is just a no-op when --insecure) the private CA.
# -----------------------------------------------------------------------------
if [ "${INSECURE}" = false ]; then
  [ -n "${CA_PATH}" ] || { echo "ERROR: HTTPS profile needs --ca-path <pem-file>" >&2; exit 1; }
  [ -r "${CA_PATH}" ] || { echo "ERROR: CA file not readable: ${CA_PATH}" >&2; exit 1; }
  if ! openssl x509 -in "${CA_PATH}" -noout -subject >/dev/null 2>&1; then
    echo "ERROR: ${CA_PATH} is not a PEM-encoded certificate." >&2
    echo "       Convert DER → PEM: openssl x509 -inform DER -in ca.der -out ca.pem" >&2
    exit 1
  fi

  # Docker's convention: port is included in the directory name unless it's 443.
  if [ "${REG_PORT}" = "443" ]; then
    CERT_DIR="/etc/docker/certs.d/${REG_HOST}"
  else
    CERT_DIR="/etc/docker/certs.d/${ENDPOINT}"
  fi

  mkdir -p "${CERT_DIR}"
  install -m 0644 "${CA_PATH}" "${CERT_DIR}/ca.crt"
  echo "==> Trusted ${CA_PATH} for ${ENDPOINT} at ${CERT_DIR}/ca.crt"
  echo "    (Docker reads CAs fresh on every interaction — no restart needed.)"
  echo
  echo "Host prep complete. Next:"
  echo "  - Ensure ${CA_PATH} is also mounted into the EE for helm (see"
  echo "    push/ansible-navigator.yml, the HTTPS volume-mount block)."
  echo "  - Run: ansible-navigator run ccn-push/playbooks/push_artifacts.yaml --vault-password-file .vault-pass"
  exit 0
fi

# -----------------------------------------------------------------------------
# HTTP path: add or remove the insecure-registries entry, restart if changed.
# -----------------------------------------------------------------------------
mkdir -p /etc/docker
DAEMON_JSON="/etc/docker/daemon.json"

# Merge with python so any pre-existing daemon.json options are preserved. The
# script prints CHANGED or UNCHANGED so we know whether to restart dockerd.
RESULT="$(
  ENDPOINT="${ENDPOINT}" REMOVE="${REMOVE}" DAEMON_JSON="${DAEMON_JSON}" "$PY" - <<'PYEOF'
import json, os, shutil, time, sys

path = os.environ["DAEMON_JSON"]
endpoint = os.environ["ENDPOINT"]
remove = os.environ["REMOVE"] == "true"

cfg = {}
if os.path.exists(path):
    with open(path) as fh:
        text = fh.read().strip()
    if text:
        cfg = json.loads(text)

entries = list(cfg.get("insecure-registries", []))
if remove:
    new = [e for e in entries if e != endpoint]
else:
    new = entries + ([endpoint] if endpoint not in entries else [])
    # de-dup, preserve order
    seen, deduped = set(), []
    for e in new:
        if e not in seen:
            seen.add(e); deduped.append(e)
    new = deduped

if new == entries:
    print("UNCHANGED")
    sys.exit(0)

cfg["insecure-registries"] = new
if os.path.exists(path):
    shutil.copy2(path, path + "." + time.strftime("%Y%m%d%H%M%S") + ".bak")
with open(path, "w") as fh:
    fh.write(json.dumps(cfg, indent=2) + "\n")
print("CHANGED")
PYEOF
)"

if [ "${REMOVE}" = true ]; then
  echo "==> Removing insecure-registries entry for ${ENDPOINT}"
else
  echo "==> Ensuring insecure-registries contains ${ENDPOINT}"
fi

if [ "${RESULT}" = "CHANGED" ]; then
  echo "    ${DAEMON_JSON} updated (a timestamped .bak was kept)."
  restart_docker
else
  echo "    ${DAEMON_JSON} already correct — no restart needed."
fi

# Confirm the daemon actually reports the endpoint (catches a silently-ignored
# daemon.json), unless we just removed it.
if [ "${REMOVE}" = false ]; then
  if docker info 2>/dev/null | grep -q "${ENDPOINT}"; then
    echo "    Confirmed: dockerd lists ${ENDPOINT} as an insecure registry."
  else
    echo "WARNING: dockerd did not report ${ENDPOINT} in its insecure registry list." >&2
    echo "         Check that /etc/docker is the daemon's config dir and re-run." >&2
  fi
fi

echo
echo "Host prep complete. Next:"
echo "  ansible-navigator run ccn-push/playbooks/push_artifacts.yaml --vault-password-file .vault-pass"
