#!/bin/bash
# Package the configuration-based agent for AgentCore Runtime (aarch64 Linux).
# Usage: ./package_config_agent.sh [agent_dir]

set -euo pipefail

AGENT_DIR="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/../agent}" && pwd)"
BUILD_DIR="${AGENT_DIR}/build"

echo "Packaging config-based agent: ${AGENT_DIR}..."

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

uv pip install \
    --python-platform aarch64-manylinux2014 \
    --python-version 3.12 \
    --target "${BUILD_DIR}" \
    -r "${AGENT_DIR}/requirements.txt"

# Copy agent source code
cp -r "${AGENT_DIR}/src/"* "${BUILD_DIR}/"
# Explicitly merge bin/ contents
mkdir -p "${BUILD_DIR}/bin"
cp -f "${AGENT_DIR}"/src/bin/* "${BUILD_DIR}/bin/"
# Remove Windows .exe wrappers
find "${BUILD_DIR}/bin" -name "*.exe" -delete 2>/dev/null || true

echo "Done: ${BUILD_DIR}"
