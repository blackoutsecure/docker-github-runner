#!/bin/bash
set -euo pipefail

BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

echo "Linuxserver.io version:- ${APP_VERSION} Build-date:- ${BUILD_DATE}" > /build_version

find /etc/s6-overlay/s6-rc.d -type f \( -name run -o -name finish -o -name check \) \
    -exec chmod 0755 {} +

# ASCII-fy the LSIO baseimage startup banner.
# The upstream init-adduser script prints box-drawing characters
# (U+2500 ─, U+2501 ━, etc.) which render as garbled multi-byte sequences
# (`â`-prefixed) in any log consumer that does not strictly decode UTF-8
# (notably the balenaCloud dashboard log pane and some basic terminals).
# Replacing them with plain ASCII dashes keeps the banner readable
# everywhere without losing any information.
# The dashes appear in two places: the `run` script (the GID/UID block)
# and the `branding` data file (the box around the LSIO ASCII art logo).
# We patch both so log consumers without strict UTF-8 decoding (notably
# the balenaCloud dashboard log pane) don't show `âââââ` mojibake.
for LSIO_FILE in \
    /etc/s6-overlay/s6-rc.d/init-adduser/run \
    /etc/s6-overlay/s6-rc.d/init-adduser/branding; do
    if [ -f "${LSIO_FILE}" ]; then
        # U+2500 ─ , U+2501 ━ , U+2550 ═  ->  '-'
        sed -i 's/\xe2\x94\x80/-/g; s/\xe2\x94\x81/-/g; s/\xe2\x95\x90/-/g' "${LSIO_FILE}"
        echo "Patched ${LSIO_FILE} to ASCII-only line separators"
    fi
done

# Make custom helper scripts executable
[ -f /usr/local/bin/gh-runner-healthcheck ] && chmod 0755 /usr/local/bin/gh-runner-healthcheck
[ -f /usr/local/bin/log-functions.sh ] && chmod 0644 /usr/local/bin/log-functions.sh

rm -f /etc/s6-overlay/s6-rc.d/user/contents.d/svc-cron \
      /etc/s6-overlay/s6-rc.d/user/contents.d/init-crontab-config

rm -rf /tmp/* /var/tmp/*
[ -d /var/lib/apt/lists ] && rm -rf /var/lib/apt/lists/*

echo "Finalization complete (build_version: ${APP_VERSION}, ${BUILD_DATE})"
