#!/usr/bin/env bash

# Create the archive and checksum uploaded by the release workflow.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "${PROJECT_ROOT}/VERSION")"
OUTPUT_DIR="${1:-${PROJECT_ROOT}/dist}"
PACKAGE_NAME="workstation-${VERSION}"

if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: VERSION must use semantic versioning" >&2
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"
rm -f "${OUTPUT_DIR}/${PACKAGE_NAME}.tar.gz" "${OUTPUT_DIR}/${PACKAGE_NAME}.tar.gz.sha256" \
    "${OUTPUT_DIR}/workstation-installer.sh"

tar --create --gzip --file "${OUTPUT_DIR}/${PACKAGE_NAME}.tar.gz" \
    --transform "s,^,${PACKAGE_NAME}/," \
    --exclude-vcs --exclude='./dist' --exclude='./.terraform' --exclude='*.pem' \
    -C "${PROJECT_ROOT}" AGENTS.md CHANGELOG.md README.md VERSION bin docs scripts src tests

(cd "${OUTPUT_DIR}" && sha256sum "${PACKAGE_NAME}.tar.gz" > "${PACKAGE_NAME}.tar.gz.sha256")
sed "s/@VERSION@/${VERSION}/g" "${PROJECT_ROOT}/scripts/install.sh.in" > "${OUTPUT_DIR}/workstation-installer.sh"
chmod +x "${OUTPUT_DIR}/workstation-installer.sh"

echo "Created ${OUTPUT_DIR}/${PACKAGE_NAME}.tar.gz"
