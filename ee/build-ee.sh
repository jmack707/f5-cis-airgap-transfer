#!/usr/bin/env bash
# =============================================================================
# ee/build-ee.sh — build the f5-airgap Execution Environment image
#
# Wraps `ansible-builder build` so the EE is produced identically every time.
# Run this on an INTERNET-connected build host (the build pulls a base image,
# RPMs, pip packages, the docker/helm CLIs, and the Galaxy collections).
#
# PREREQUISITES (build host only — NOT the air-gapped host)
#   - python3 + pip
#   - pip install ansible-builder        (>= 3.0)
#   - a container runtime: docker (default) or podman
#
# USAGE
#   bash build-ee.sh                       # build f5-airgap-ee:latest with docker
#   EE_IMAGE=f5-airgap-ee:1.0.0 bash build-ee.sh
#   CONTAINER_RUNTIME=podman bash build-ee.sh
#
# AFTER BUILDING
#   Internet side : ansible-navigator references f5-airgap-ee:latest directly.
#   Air-gapped side: save and carry the image across the gap, e.g.
#       docker save f5-airgap-ee:latest | gzip > f5-airgap-ee.tar.gz
#     then on the closed-network host:
#       gunzip -c f5-airgap-ee.tar.gz | docker load
#   (see ee/README.md for the full offline procedure.)
# =============================================================================
set -euo pipefail

EE_IMAGE="${EE_IMAGE:-f5-airgap-ee:latest}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"

cd "$(dirname "$0")"

if ! command -v ansible-builder >/dev/null 2>&1; then
  echo "ERROR: ansible-builder is not installed on this build host."
  echo "       Install it first:  pip install ansible-builder"
  exit 1
fi

if ! command -v "${CONTAINER_RUNTIME}" >/dev/null 2>&1; then
  echo "ERROR: container runtime '${CONTAINER_RUNTIME}' not found."
  echo "       Install docker or podman, or set CONTAINER_RUNTIME accordingly."
  exit 1
fi

echo "==> Building ${EE_IMAGE} with ${CONTAINER_RUNTIME}..."
ansible-builder build \
  --file execution-environment.yml \
  --tag "${EE_IMAGE}" \
  --container-runtime "${CONTAINER_RUNTIME}" \
  --verbosity 2

echo
echo "==> Built ${EE_IMAGE}."
echo "    Verify its contents:"
echo "      ${CONTAINER_RUNTIME} run --rm ${EE_IMAGE} ansible --version"
echo "      ${CONTAINER_RUNTIME} run --rm ${EE_IMAGE} helm version --short"
echo "      ${CONTAINER_RUNTIME} run --rm ${EE_IMAGE} docker --version"
