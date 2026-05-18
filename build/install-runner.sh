#!/bin/bash
set -euo pipefail

# Install the GitHub Actions runner to /opt/runner-bin. The runner runs
# directly from this directory: bundled files are read-only, but directories
# stay writable so the runner can drop its registration state (.runner,
# .credentials, .env, .path, _diag/, _work/) into the tree at runtime.
ARCH=""
case "${TARGETARCH}" in
    amd64) ARCH="x64" ;;
    arm64) ARCH="arm64" ;;
    *)     echo "Unsupported architecture: ${TARGETARCH}"; exit 1 ;;
esac

INSTALL_DIR="/opt/runner-bin"
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

echo "Downloading actions-runner v${APP_VERSION} for ${ARCH}..."
curl -fsSL -o actions-runner.tar.gz \
    "https://github.com/actions/runner/releases/download/v${APP_VERSION}/actions-runner-linux-${ARCH}-${APP_VERSION}.tar.gz"

tar xzf actions-runner.tar.gz
rm -f actions-runner.tar.gz

# Own as abc with read-only files but +wx directories so the runner can write
# .runner / .credentials / .env / .path / _diag/ / _work/ at runtime.
chown -R abc:abc "${INSTALL_DIR}"
find "${INSTALL_DIR}" -type d -exec chmod 0755 {} +
find "${INSTALL_DIR}" -type f -exec chmod a-w,a+r {} +
# Preserve executable bits on scripts and the .NET launcher
chmod 0755 "${INSTALL_DIR}/config.sh" "${INSTALL_DIR}/run.sh" \
           "${INSTALL_DIR}/run-helper.sh" 2>/dev/null || true
[ -d "${INSTALL_DIR}/bin" ] && find "${INSTALL_DIR}/bin" -maxdepth 1 -type f \
    \( -name 'Runner.*' -o -name 'installdependencies.sh' \) -exec chmod 0755 {} +

# Build-time ownership marker. init-gh-runner-config trusts this and skips
# the defensive `chown -R abc:abc` walk (60-130s on slow ARM storage).
# Override with FORCE_RUNNER_PERMISSIONS_FIX=true.
date -u +'%Y-%m-%dT%H:%M:%SZ' > "${INSTALL_DIR}/.ownership-baked"
chown abc:abc "${INSTALL_DIR}/.ownership-baked"
chmod 0444 "${INSTALL_DIR}/.ownership-baked"

# Stamp build metadata into the image so the runtime banner can show it.
mkdir -p /etc/gh-runner
cat > /etc/gh-runner/build-info << EOF
APP_VERSION=${APP_VERSION}
RUNNER_ARCH=${ARCH}
BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
EOF
chmod 0644 /etc/gh-runner/build-info

echo "GitHub Actions runner v${APP_VERSION} (${ARCH}) installed to ${INSTALL_DIR}"

