#!/usr/bin/env bash
set -Eeuo pipefail

# Runs dry-run checks across representative Linux container images.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT

images=(
  "ubuntu:22.04"
  "ubuntu:24.04"
  "rockylinux:8"
  "rockylinux:9"
  "amazonlinux:2023"
)

for image in "${images[@]}"; do
  printf '\n==> Testing %s\n' "$image"
  docker run --rm \
    --platform linux/amd64 \
    -e DRY_RUN=1 \
    -e PROMPT_DEFAULTS=1 \
    -v "${REPO_ROOT}:/work:ro" \
    -w /work \
    "$image" \
    bash opsman_deploy/install_ops_manager_minimal.sh
done
