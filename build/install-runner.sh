#!/bin/bash
set -euo pipefail

# Install the GitHub Actions runner to /opt/runner-bin and run it from
# there directly at container start. The directory is owned by the abc
# runner user, with read-only files but writable directories so the
# runner can drop its registration files (.runner, .credentials, .env,
# .path, _diag/, _work/, ...) into the tree.
#
# Earlier revisions copied or hard-linked /opt/runner-bin into a
# separate /opt/actions-runner runtime tree at boot, but on overlayfs
# `cp -al` of ~9000 files took ~140 s on every container restart -- the
# dominant cold-start cost for ephemeral runners. Running directly from
# the install dir is safe: writes go to the container's upper overlay
# layer (or a tmpfs if the operator chose to mount one over
# /opt/runner-bin) and are wiped on container recreation, which matches
# the lifecycle of an ephemeral runner.
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

# Owned by abc so that the runner can write .runner / .credentials / .env
# / .path / _diag/ / _work/ into this dir at runtime. Bundled files are
# read-only (the runner never modifies them in place); directories keep
# owner +wx so the runner can create the new state files inside them.
chown -R abc:abc "${INSTALL_DIR}"
find "${INSTALL_DIR}" -type d -exec chmod 0755 {} +
find "${INSTALL_DIR}" -type f -exec chmod a-w,a+r {} +
# Preserve executable bits on scripts and the .NET launcher
chmod 0755 "${INSTALL_DIR}/config.sh" "${INSTALL_DIR}/run.sh" \
           "${INSTALL_DIR}/run-helper.sh" 2>/dev/null || true
[ -d "${INSTALL_DIR}/bin" ] && find "${INSTALL_DIR}/bin" -maxdepth 1 -type f \
    \( -name 'Runner.*' -o -name 'installdependencies.sh' \) -exec chmod 0755 {} +

# Build-time ownership marker. The runtime init script trusts this marker
# and skips the defensive `chown -R abc:abc` walk -- on slow storage
# (balena/overlayfs on ARM SBCs) that walk over ~9000 files takes 60-130 s
# of completely silent cold-start time even though ownership is already
# correct (the runtime stat probe sometimes reports stale uid/gid for
# files on the immutable image layer). The marker is owned by abc:abc
# 0644 so its very presence is also a positive permission proof.
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

