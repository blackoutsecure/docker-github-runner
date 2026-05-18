# syntax=docker/dockerfile:1.7

ARG BASE_IMAGE=ghcr.io/linuxserver/baseimage-ubuntu:noble
ARG APP_VERSION=2.333.1

FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG APP_VERSION
ARG TARGETARCH

LABEL maintainer="Blackout Secure - https://blackoutsecure.app/" \
    org.opencontainers.image.title="docker-github-runner" \
    org.opencontainers.image.description="Containerized GitHub Actions self-hosted runner with s6 process supervision" \
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
        python3 \
        unzip \
        zip && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME}") stable" \
        > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-buildx-plugin \
        docker-compose-plugin && \
    apt-get purge -y --auto-remove gnupg lsb-release && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --link build/ /tmp/build/
RUN /tmp/build/install-runner.sh && \
    rm -rf /tmp/build && \
    mkdir -p /tmp /scaler && \
    chmod 1777 /tmp && \
    chmod 0700 /scaler && \
    cd /opt/runner-bin && \
    ./bin/installdependencies.sh && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --link root/ /

# Optional autoscaler sidecar entrypoint. Baked in so Balena (no host bind mounts)
# can use the sidecar pattern. Inert unless invoked via an explicit entrypoint
# override on a sidecar service; the normal s6 boot path never touches it.
COPY --link scripts/autoscale.sh /usr/local/bin/gh-runner-autoscale

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
    DOCKER_IN_DOCKER="false" \
    CLEANUP_OFFLINE_RUNNERS="false" \
    CLEANUP_OFFLINE_AFTER="86400" \
    CLEANUP_OFFLINE_NAME_REGEX="" \
    CLEANUP_OFFLINE_DRY_RUN="false" \
    CLEANUP_OFFLINE_MAX="25" \
    CLEANUP_OFFLINE_IMMEDIATE="" \
    HEARTBEAT_INTERVAL="120" \
    JOB_HEARTBEAT_INTERVAL="120" \
    FORCE_RUNNER_PERMISSIONS_FIX="false" \
    S6_SERVICES_GRACETIME="30000" \
    S6_KILL_GRACETIME="30000"

COPY --link build/finalize.sh /tmp/finalize.sh
RUN /tmp/finalize.sh && rm -f /tmp/finalize.sh

VOLUME ["/config"]

# 300s start-period covers slow ARM cold-start (large runner tree extraction +
# API-based registration); retries=5 tolerates brief api.github.com flakes.
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=5 \
    CMD /usr/local/bin/gh-runner-healthcheck
