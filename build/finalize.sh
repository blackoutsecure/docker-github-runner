#!/bin/bash
set -euo pipefail

BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

echo "Linuxserver.io version:- ${APP_VERSION} Build-date:- ${BUILD_DATE}" > /build_version

# ASCII-fy the LSIO baseimage startup banner. The upstream init-adduser script
# prints box-drawing chars (U+2500/2501/2550) that render as mojibake in any
# log consumer that doesn't strictly decode UTF-8 (notably the balenaCloud
# dashboard log pane). Patch both the GID/UID block (run) and the logo box
# (branding).
for LSIO_FILE in \
    /etc/s6-overlay/s6-rc.d/init-adduser/run \
    /etc/s6-overlay/s6-rc.d/init-adduser/branding; do
    if [ -f "${LSIO_FILE}" ]; then
        sed -i 's/\xe2\x94\x80/-/g; s/\xe2\x94\x81/-/g; s/\xe2\x95\x90/-/g' "${LSIO_FILE}"
        echo "Patched ${LSIO_FILE} to ASCII-only line separators"
    fi
done

rm -f /etc/s6-overlay/s6-rc.d/user/contents.d/svc-cron \
      /etc/s6-overlay/s6-rc.d/user/contents.d/init-crontab-config

rm -rf /tmp/* /var/tmp/*
[ -d /var/lib/apt/lists ] && rm -rf /var/lib/apt/lists/*

echo "Finalization complete (build_version: ${APP_VERSION}, ${BUILD_DATE})"
