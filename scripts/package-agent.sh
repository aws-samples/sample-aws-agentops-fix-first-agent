#!/bin/bash
# Packages the fixFirstAgent source code + dependencies into a zip-ready directory.
# CDK's s3_assets.Asset will then zip and upload this directory.
#
# Requires: uv (https://docs.astral.sh/uv/getting-started/installation/)
#
# Usage: ./scripts/package-agent.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

AGENT_DIR="fixFirstAgent"
BUILD_DIR="${AGENT_DIR}/build"

echo "=== Packaging agent code ==="

# Clean previous build
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Install dependencies using uv (aarch64 linux for AgentCore Runtime)
echo "Installing Python dependencies for aarch64-linux..."
uv pip install \
  --python-platform aarch64-manylinux2014 \
  --python-version 3.12 \
  --target "${BUILD_DIR}" \
  -r "${AGENT_DIR}/requirements.txt"

# Copy agent source code on top
echo "Copying agent source code..."
cp -r "${AGENT_DIR}/src/"* "${BUILD_DIR}/"

# Ensure bin/ is merged (opentelemetry-instrument wrapper)
mkdir -p "${BUILD_DIR}/bin"
if [ -d "${AGENT_DIR}/src/bin" ]; then
    cp -f "${AGENT_DIR}/src/bin/opentelemetry-instrument" "${BUILD_DIR}/bin/" 2>/dev/null || true
    cp -f "${AGENT_DIR}"/src/bin/* "${BUILD_DIR}/bin/" 2>/dev/null || true
fi

# Remove Windows .exe wrappers if any
find "${BUILD_DIR}/bin" -name "*.exe" -delete 2>/dev/null || true

echo "=== Package ready at ${BUILD_DIR} ==="
du -sh "${BUILD_DIR}"
