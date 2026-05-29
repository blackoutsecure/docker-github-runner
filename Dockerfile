# syntax=docker/dockerfile:1.7

ARG BASE_IMAGE=ghcr.io/linuxserver/baseimage-ubuntu:noble
ARG APP_VERSION=2.333.1

FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG APP_VERSION
ARG TARGETARCH

LABEL maintainer="Blackout Secure - https://blackoutsecure.app/" \
    org.opencontainers.image.title="docker-github-runner" \
    org.opencontainers.image.description="Containerized GitHub Actions self-hosted runner with s6 process supervision; doubles as the autoscaler sidecar via RUNNER_ROLE=autoscaler (or the 'autoscaler' command argument)." \
    org.opencontainers.image.url="https://github.com/blackoutsecure/docker-github-runner" \
    org.opencontainers.image.source="https://github.com/blackoutsecure/docker-github-runner" \
    org.opencontainers.image.version="${APP_VERSION}" \
    org.opencontainers.image.licenses="MIT"

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        libicu74 \
        libssl3t64 \
        lsb-release \
        nodejs \
        npm \
        python3 \
        python3-pip \
        python3-yaml \
        shellcheck \
        sudo \
        unzip \
        xz-utils \
        zip && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME}") stable" \
        > /etc/apt/sources.list.d/docker.list && \
    # GitHub CLI (`gh`). Mirrors the docker-ce-cli apt-repo pattern above.
    # Required by org workflows that call `gh api`, `gh release create`,
    # `gh workflow run`, etc. on the self-hosted runner (e.g.
    # bos-marketplace-kit `release.yml` preflight + publish steps).
    # cli.github.com serves a binary GPG keyring (`.gpg`), not an ASCII-
    # armored key, so the keyring file extension differs from docker's.
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-buildx-plugin \
        docker-compose-plugin \
        gh && \
    apt-get purge -y --auto-remove gnupg lsb-release && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /root/.npm /root/.cache

COPY --link build/ /tmp/build/
RUN /tmp/build/install-runner.sh && \
    rm -rf /tmp/build && \
    mkdir -p /tmp /scaler && \
    chmod 1777 /tmp && \
    chmod 0700 /scaler && \
    cd /opt/runner-bin && \
    ./bin/installdependencies.sh && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \
    # System-wide git config (applies to every user the runner ever drops
    # to: root, abc, or anything a workflow's `run:` block uses). Keeps
    # checkout-step logs quiet by suppressing the standard `git init`
    # hint banner ("Using 'master' as the name for the initial branch
    # ...") that fires every time `actions/checkout` initializes the
    # work tree. `actions/checkout` always renames to the real ref
    # immediately afterwards, so init.defaultBranch has no behavioral
    # effect -- it just silences the hint.
    install -d -m 0755 /etc && \
    printf '[init]\n\tdefaultBranch = main\n' > /etc/gitconfig && \
    chmod 0644 /etc/gitconfig

COPY --link root/ /

# -----------------------------------------------------------------------------
# Dual-role entrypoint wrapper.
#
# The same image serves both roles via /usr/local/bin/gh-runner-entrypoint:
#   1. Default (RUNNER_ROLE unset / "runner" / no arg) → execs /init from
#      the LSIO baseimage (full s6-overlay supervised runner).
#   2. RUNNER_ROLE=autoscaler  OR first arg == "autoscaler" → execs
#      /usr/local/bin/gh-runner-autoscale (single-process sidecar loop).
#
# Either env-var or arg form makes the scaler portable to every orchestrator
# without having to override Docker's ENTRYPOINT (which is awkward on Balena
# fleet vars, Kubernetes Deployment templates, etc.). Explicit `entrypoint:`
# overrides still bypass this wrapper and continue to work unchanged.
#
# The baked-in HEALTHCHECK below auto-detects sidecar mode via
# /proc/1/cmdline, so a single image-level healthcheck definition is correct
# for both roles -- no `healthcheck: disable: true` workaround required.
# -----------------------------------------------------------------------------
COPY --link scripts/autoscale.sh /usr/local/bin/gh-runner-autoscale
RUN chmod 0755 /usr/local/bin/gh-runner-autoscale \
               /usr/local/bin/gh-runner-entrypoint && \
    chmod 0644 /usr/local/bin/log-functions.sh \
               /usr/local/bin/banner-functions.sh \
               /usr/local/bin/gh-api.sh \
               /usr/local/bin/gh-config.sh \
               /usr/local/bin/gh-runtime.sh \
               /usr/local/bin/gh-dind.sh \
               /usr/local/bin/gh-preflight.sh \
               /usr/local/bin/gh-cleanup.sh \
               /usr/local/bin/gh-banner.sh \
               /usr/local/bin/gh-heartbeat.sh \
               /usr/local/bin/gh-diag.sh && \
    # Defensive: COPY preserves file mode from the host, so a run/finish
    # script that lost its +x bit (e.g. created on macOS via tooling that
    # defaults to 0644) would crash s6 with "exec ... Permission denied"
    # (exit 126). Force-mark every s6 run/finish script executable here.
    # 0755 because s6-overlay sometimes invokes these as user `abc` not root.
    find /etc/s6-overlay/s6-rc.d -type f \( -name run -o -name finish \) -exec chmod 0755 {} + && \
    # Lock down the sudoers drop-in to the mode sudo requires (0440,
    # root:root). COPY would otherwise preserve the host file mode (often
    # 0644 on macOS), which causes sudo to refuse the file with
    # "/etc/sudoers.d/10-abc-nopasswd is mode 0644, should be 0440" and
    # then fail every subsequent `sudo` call from `abc`. Run `visudo -c`
    # as a build-time syntax check so a malformed drop-in fails the build
    # instead of the first workflow that tries to use sudo.
    chown root:root /etc/sudoers.d/10-abc-nopasswd && \
    chmod 0440 /etc/sudoers.d/10-abc-nopasswd && \
    visudo -c -f /etc/sudoers.d/10-abc-nopasswd

ENV HOME="/config" \
    RUNNER_WORKDIR="/config/work" \
    RUNNER_NAME="" \
    RUNNER_TOKEN="" \
    RUNNER_TOKEN_FILE="" \
    GITHUB_PAT="" \
    GITHUB_PAT_FILE="" \
    GITHUB_TOKEN="" \
    GITHUB_TOKEN_FILE="" \
    RUNNER_URL="" \
    RUNNER_URL_FILE="" \
    RUNNER_GROUP="" \
    RUNNER_LABELS="" \
    RUNNER_EPHEMERAL="false" \
    RUNNER_REPLACE_EXISTING="true" \
    DISABLE_RUNNER_UPDATE="false" \
    RUNNER_ENV_FILE="" \
    RUNNER_SECRETS_DIR="" \
    LOG_LEVEL="info" \
    EXTRA_PACKAGES="" \
    EXTRA_APT_REPOS="" \
    EXTRA_INIT_SCRIPT="" \
    RUNNER_SUDO="true" \
    DOCKER_IN_DOCKER="false" \
    CLEANUP_OFFLINE_RUNNERS="false" \
    CLEANUP_OFFLINE_AFTER="86400" \
    CLEANUP_OFFLINE_NAME_REGEX="" \
    CLEANUP_OFFLINE_DRY_RUN="false" \
    CLEANUP_OFFLINE_MAX="25" \
    CLEANUP_OFFLINE_IMMEDIATE="" \
    HEARTBEAT_INTERVAL="120" \
    JOB_HEARTBEAT_INTERVAL="120" \
    LOG_WATCH_INTERVAL="2" \
    LISTENER_WAIT_TIMEOUT="600" \
    DIAG_WAIT_TIMEOUT="120" \
    CONFIG_TIMEOUT="90" \
    SKIP_DEREGISTER="false" \
    FORCE_RUNNER_PERMISSIONS_FIX="false" \
    RUNNER_ROLE="" \
    S6_SERVICES_GRACETIME="30000" \
    S6_KILL_GRACETIME="30000"

COPY --link build/finalize.sh /tmp/finalize.sh
RUN /tmp/finalize.sh && rm -f /tmp/finalize.sh

VOLUME ["/config"]

# 300s start-period covers slow ARM cold-start (large runner tree extraction +
# API-based registration); retries=5 tolerates brief api.github.com flakes.
# The script also detects sidecar mode (PID 1 == gh-runner-autoscale) and
# short-circuits to a process-liveness check, so the same HEALTHCHECK works
# for both the runner and the scaler sidecar.
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=5 \
    CMD /usr/local/bin/gh-runner-healthcheck

# Dual-role dispatcher (see /usr/local/bin/gh-runner-entrypoint for the full
# decision matrix). Overrides the LSIO baseimage's default ENTRYPOINT of
# `/init` so a single env var (RUNNER_ROLE=autoscaler) or CMD arg
# (`docker run IMAGE autoscaler`) flips the container into sidecar mode
# without having to override Docker ENTRYPOINT on every orchestrator. The
# default (no env var, no arg) path is `exec /init "$@"`, so the standard
# runner role is bit-for-bit identical to the previous behavior.
ENTRYPOINT ["/usr/local/bin/gh-runner-entrypoint"]
