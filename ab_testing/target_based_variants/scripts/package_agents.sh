#!/bin/bash
# Package both agent variants for AgentCore Runtime (aarch64 Linux).
# Usage: ./package_agents.sh <agents_dir>
#
# This script:
# 1. Installs Python dependencies targeting arm64 linux
# 2. Copies agent source code (including bin/opentelemetry-instrument)
# 3. Removes any Windows .exe wrappers from bin/

set -euo pipefail

AGENTS_DIR="$(cd "${1:-.}" && pwd)"

package_agent() {
    local agent_dir="$1"
    local build_dir="${agent_dir}/build"

    echo "Packaging ${agent_dir}..."

    # Clean and create build directory
    rm -rf "${build_dir}"
    mkdir -p "${build_dir}"

    # Install dependencies for aarch64 linux
    uv pip install \
        --python-platform aarch64-manylinux2014 \
        --python-version 3.12 \
        --target "${build_dir}" \
        -r "${agent_dir}/requirements.txt"

    # Copy agent source code
    cp -r "${agent_dir}/src/"* "${build_dir}/"
    # Explicitly merge bin/ contents (cp glob doesn't merge dirs on some platforms)
    mkdir -p "${build_dir}/bin"
    cp -f "${agent_dir}"/src/bin/* "${build_dir}/bin/"

    # Remove Windows .exe wrappers if any
    find "${build_dir}/bin" -name "*.exe" -delete 2>/dev/null || true

    echo "Done: ${build_dir}"
}

package_agent "${AGENTS_DIR}/control"
package_agent "${AGENTS_DIR}/treatment"

echo "Both agents packaged successfully."
