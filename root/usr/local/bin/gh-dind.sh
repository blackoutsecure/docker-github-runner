#!/usr/bin/with-contenv bash
# shellcheck shell=bash
#
# Docker-in-Docker (DinD) socket plumbing.
#
# When DOCKER_IN_DOCKER=true the operator has bind-mounted a host engine
# socket into the container and expects container-based GitHub Actions
# (docker/setup-buildx-action, docker/build-push-action, etc.) to be able
# to talk to it. This module:
#   - finds the socket (DOCKER_HOST_SOCK override, then a list of common
#     paths -- supports Balena's balena-engine.sock)
#   - exposes it at /var/run/docker.sock via symlink when it isn't there
#     already (so the docker CLI works without DOCKER_HOST)
#   - adds the runner user (abc) to a group with the same gid as the
#     socket so DinD jobs don't hit EACCES
#
# All operations are best-effort: misconfiguration logs a warning but
# never aborts startup -- the preflight stage in gh-preflight.sh is the
# authoritative gate.
#

DOCKER_SOCK_PATH=""

# gh_dind_resolve_sock
# Probe DOCKER_HOST_SOCK + canonical paths. Sets DOCKER_SOCK_PATH on
# success, returns 1 when nothing is mounted.
gh_dind_resolve_sock() {
    local candidates=()
    [[ -n "${DOCKER_HOST_SOCK:-}" ]] && candidates+=("${DOCKER_HOST_SOCK}")
    candidates+=(
        "/var/run/docker.sock"
        "/var/run/balena-engine.sock"
        "/var/run/balena.sock"
        "/run/docker.sock"
    )
    local p
    for p in "${candidates[@]}"; do
        if [[ -S "${p}" ]]; then
            DOCKER_SOCK_PATH="${p}"
            return 0
        fi
    done
    return 1
}

# Backwards-compat shim for callers that referenced the old name.
resolve_docker_sock() { gh_dind_resolve_sock "$@"; }

# gh_dind_setup
# Top-level entry: no-op when DOCKER_IN_DOCKER!=true. Otherwise resolves
# the socket, symlinks it to /var/run/docker.sock when needed, and adds
# abc to a group matching the socket's gid (only in root mode -- non-root
# operators must pick a uid that's already a member of an appropriate
# group on the host).
gh_dind_setup() {
    [[ "${DOCKER_IN_DOCKER:-false}" == "true" ]] || return 0

    if ! gh_dind_resolve_sock; then
        log "warn" "DOCKER_IN_DOCKER=true but no engine socket is mounted"
        log "warn" "  Checked: \${DOCKER_HOST_SOCK}, /var/run/docker.sock, /var/run/balena-engine.sock, /var/run/balena.sock, /run/docker.sock"
        log "warn" "  Plain Docker:  volumes:\n    - /var/run/docker.sock:/var/run/docker.sock"
        log "warn" "  Balena:        labels: { io.balena.features.balena-socket: '1' }"
        return 0
    fi
    log "info" "DOCKER_IN_DOCKER: using engine socket ${DOCKER_SOCK_PATH}"

    # Symlink non-canonical paths to /var/run/docker.sock so the docker CLI
    # works without DOCKER_HOST being set inside job containers.
    if [[ "${DOCKER_SOCK_PATH}" != "/var/run/docker.sock" && ! -e /var/run/docker.sock ]]; then
        if ln -s "${DOCKER_SOCK_PATH}" /var/run/docker.sock 2>/dev/null; then
            log "info" "DOCKER_IN_DOCKER: symlinked ${DOCKER_SOCK_PATH} -> /var/run/docker.sock"
        else
            log "warn" "DOCKER_IN_DOCKER: could not symlink ${DOCKER_SOCK_PATH} -> /var/run/docker.sock; jobs may need DOCKER_HOST=unix://${DOCKER_SOCK_PATH}"
        fi
    fi

    if [[ "${RUN_AS_NONROOT:-0}" == "1" ]]; then
        log "info" "DOCKER_IN_DOCKER=true: running as non-root (--user) -- group fixup skipped"
        log "info" "  Ensure the chosen uid is already a member of a group with gid matching the host's docker socket"
        return 0
    fi

    local sock_gid sock_group
    sock_gid="$(stat -c '%g' "${DOCKER_SOCK_PATH}" 2>/dev/null || echo 0)"
    if [[ "${sock_gid}" == "0" ]]; then
        log "info" "DOCKER_IN_DOCKER: ${DOCKER_SOCK_PATH} is owned by root -- abc already has access via DAC_OVERRIDE/root drop"
        return 0
    fi

    sock_group="$(getent group "${sock_gid}" | cut -d: -f1 || true)"

    # /etc must be writable for groupadd/usermod. read_only: true makes
    # the rootfs immutable and we can't modify /etc/group or /etc/passwd.
    if ! ( : > /etc/.dind.rwtest ) 2>/dev/null; then
        log "warn" "DOCKER_IN_DOCKER=true: /etc is read-only -- cannot add abc (uid 911) to group with gid=${sock_gid}"
        log "warn" "  Options: (1) set read_only: false, (2) on the host run: sudo setfacl -m u:911:rw ${DOCKER_SOCK_PATH}, or (3) use a docker socket proxy"
        return 0
    fi
    rm -f /etc/.dind.rwtest

    if [[ -z "${sock_group}" ]]; then
        sock_group="docker_host"
        if groupadd -g "${sock_gid}" "${sock_group}" 2>/dev/null; then
            log "info" "DOCKER_IN_DOCKER: created group ${sock_group} (gid=${sock_gid}) to match ${DOCKER_SOCK_PATH}"
        else
            log "warn" "DOCKER_IN_DOCKER: failed to create group with gid=${sock_gid} -- DinD jobs may fail"
            return 0
        fi
    else
        log "info" "DOCKER_IN_DOCKER: ${DOCKER_SOCK_PATH} gid=${sock_gid} maps to existing group '${sock_group}'"
    fi

    if id -nG abc 2>/dev/null | tr ' ' '\n' | grep -qx "${sock_group}"; then
        log "debug" "DOCKER_IN_DOCKER: abc already a member of ${sock_group}"
    elif usermod -aG "${sock_group}" abc 2>/dev/null; then
        log "info" "DOCKER_IN_DOCKER: added abc to ${sock_group} group"
    else
        log "warn" "DOCKER_IN_DOCKER: failed to add abc to ${sock_group} -- DinD jobs may fail"
    fi
}

# Backwards-compat shim
setup_docker_in_docker() { gh_dind_setup "$@"; }
