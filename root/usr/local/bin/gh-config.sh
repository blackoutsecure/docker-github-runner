#!/usr/bin/with-contenv bash
# shellcheck shell=bash
#
# Centralized configuration for docker-github-runner.
#
# This is the SINGLE place to:
#   - declare default values for every tunable env var
#   - validate operator-supplied overrides (with clamping where sensible)
#   - resolve secrets from <VAR>_FILE pointers
#   - apply ephemeral-aware defaults (one policy, used by every consumer)
#
# Sourced by:
#   - init-gh-runner-config/run  (full validation + secret resolution)
#   - svc-gh-runner-logs/run     (heartbeat/idle-recycle tunables only)
#   - scripts/autoscale.sh       (autoscale tunables only)
#
# Every function below is idempotent: sourcing this file multiple times
# (e.g. once from init, once from svc) does not change the resolved
# values. The `log()` function is expected to be available (callers must
# source log-functions.sh first).
#

# ---------------------------------------------------------------------------
# 1. LOG_LEVEL validation
# ---------------------------------------------------------------------------
# Accepts: debug | info | warn | error | fatal (any case).
# Falls back to "info" with a warning when the value is unrecognized.
gh_config_validate_log_level() {
    case "${LOG_LEVEL:-info}" in
        debug|info|warn|error|fatal|DEBUG|INFO|WARN|ERROR|FATAL) : ;;
        *)
            log "warn" "Unknown LOG_LEVEL='${LOG_LEVEL}', falling back to 'info' (valid: debug|info|warn|error|fatal)"
            export LOG_LEVEL="info"
            ;;
    esac

    # Persist via s6 container_environment so downstream services
    # (svc-gh-runner, svc-gh-runner-logs) see the validated value.
    mkdir -p /run/s6/container_environment 2>/dev/null || true
    printf '%s' "${LOG_LEVEL:-info}" > /run/s6/container_environment/LOG_LEVEL 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 2. Secret resolution: <VAR> or <VAR>_FILE
# ---------------------------------------------------------------------------
# Reads the file pointed to by <VAR>_FILE (if set) and exports its
# contents (trimmed of trailing newline) as <VAR>. Fatals out if the
# file is missing or unreadable -- a non-existent secret file is always
# a deployment bug, never a soft warning.
gh_config_resolve_secret() {
    local var_name="$1"
    local file_var="${var_name}_FILE"
    local file_path="${!file_var:-}"

    if [[ -n "${file_path}" ]]; then
        if [[ -f "${file_path}" && -r "${file_path}" ]]; then
            local secret
            secret="$(< "${file_path}")"
            secret="${secret%%$'\n'}"
            export "${var_name}=${secret}"
            log "info" "${var_name} loaded from file (${file_var})"
        else
            log "fatal" "${file_var} is set to '${file_path}' but the file does not exist or is not readable"
            exit 1
        fi
    fi
}

# gh_config_resolve_runner_secrets
# One-shot helper for init-gh-runner-config/run: resolve every secret-bearing
# variable the runner accepts via the _FILE pattern.
gh_config_resolve_runner_secrets() {
    gh_config_resolve_secret RUNNER_TOKEN
    gh_config_resolve_secret RUNNER_URL
    gh_config_resolve_secret GITHUB_PAT
    gh_config_resolve_secret GITHUB_TOKEN
}

# ---------------------------------------------------------------------------
# 3. Idle-recycle defaults (ephemeral-aware)
# ---------------------------------------------------------------------------
# When IDLE_RECYCLE_AFTER is not explicitly set:
#   RUNNER_EPHEMERAL=true  -> 6 hours (21600s).
#       Ephemeral users opt into "single-job + fresh state per job".
#       A 6-hour idle ceiling caps state accumulation when no jobs
#       arrive and keeps long-quiet runners from drifting.
#   RUNNER_EPHEMERAL=false -> 2 days (172800s).
#       Long-running listener hygiene without churning processes
#       operators may be actively using. Long enough to span a quiet
#       weekend without recycling mid-job, short enough to bound
#       memory / fd / temp-file growth.
#
# Override with IDLE_RECYCLE_AFTER:
#   0       -> recycle DISABLED
#   1..299  -> CLAMPED to 300s (safety floor against tight loops)
#   N>=300  -> honored as-is
: "${IDLE_RECYCLE_DEFAULT_EPHEMERAL:=21600}"
: "${IDLE_RECYCLE_DEFAULT_PERSISTENT:=172800}"
: "${IDLE_RECYCLE_MIN:=300}"

gh_config_resolve_idle_recycle() {
    local user_value="${IDLE_RECYCLE_AFTER:-}"

    if [[ -z "${user_value}" ]]; then
        if [[ "${RUNNER_EPHEMERAL:-false}" == "true" ]]; then
            IDLE_RECYCLE_AFTER="${IDLE_RECYCLE_DEFAULT_EPHEMERAL}"
            IDLE_RECYCLE_AFTER_SOURCE="default (ephemeral mode)"
        else
            IDLE_RECYCLE_AFTER="${IDLE_RECYCLE_DEFAULT_PERSISTENT}"
            IDLE_RECYCLE_AFTER_SOURCE="default (persistent mode)"
        fi
    elif ! [[ "${user_value}" =~ ^[0-9]+$ ]]; then
        IDLE_RECYCLE_AFTER=0
        IDLE_RECYCLE_AFTER_SOURCE="user override (invalid '${user_value}' -> disabled)"
    elif (( user_value == 0 )); then
        IDLE_RECYCLE_AFTER=0
        IDLE_RECYCLE_AFTER_SOURCE="user override (disabled)"
    else
        IDLE_RECYCLE_AFTER="${user_value}"
        IDLE_RECYCLE_AFTER_SOURCE="user override"
    fi

    if (( IDLE_RECYCLE_AFTER > 0 && IDLE_RECYCLE_AFTER < IDLE_RECYCLE_MIN )); then
        IDLE_RECYCLE_AFTER="${IDLE_RECYCLE_MIN}"
        IDLE_RECYCLE_AFTER_SOURCE="${IDLE_RECYCLE_AFTER_SOURCE} (clamped to ${IDLE_RECYCLE_MIN}s floor)"
    fi

    export IDLE_RECYCLE_AFTER IDLE_RECYCLE_AFTER_SOURCE
}

# Backwards-compat shim for old callers that source runner-defaults.sh by
# name. New code should call gh_config_resolve_idle_recycle directly.
resolve_idle_recycle_defaults() { gh_config_resolve_idle_recycle "$@"; }

# ---------------------------------------------------------------------------
# 4. Heartbeat tunables (svc-gh-runner-logs)
# ---------------------------------------------------------------------------
# HEARTBEAT_INTERVAL: seconds between full HEALTH HEARTBEAT banners.
#   Default 120s, minimum 30s (anything lower is rejected -- avoids
#   hammering the GitHub API and balena's per-service log rate limit).
#
# JOB_HEARTBEAT_INTERVAL: seconds between mid-job JOB HEARTBEAT mini-banners.
#   Default 120s. Set to 0 to disable. Minimum 30s when enabled.
#
# ONLINE_PROBE_EVERY: how often (in heartbeat ticks) to actively probe
#   GitHub for runner online status.
#   Ephemeral mode default: 0 (disabled -- ephemeral runners complete
#       a job and exit before any active probe would fire; listener
#       liveness is enough).
#   Persistent mode default: 1 (every tick).
#
# ONLINE_FAIL_THRESHOLD: consecutive offline detections before escalating.
#   Default 3.
#
# ON_OFFLINE_ACTION: what to do when threshold is hit.
#   none | restart | shutdown (default: restart)
#
# IDLE_RECYCLE_ACTION: what to do when an idle runner exceeds IDLE_RECYCLE_AFTER.
#   none | restart | shutdown (default: shutdown)
#
# HEALTH_STALE_AFTER: seconds before the sentinel-file healthcheck declares
#   the runner unhealthy (consumed by gh-runner-healthcheck). Default 300.
gh_config_resolve_heartbeat() {
    HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-120}"
    if ! [[ "${HEARTBEAT_INTERVAL}" =~ ^[0-9]+$ ]] || (( HEARTBEAT_INTERVAL < 30 )); then
        HEARTBEAT_INTERVAL=120
    fi

    JOB_HEARTBEAT_INTERVAL="${JOB_HEARTBEAT_INTERVAL:-120}"
    if ! [[ "${JOB_HEARTBEAT_INTERVAL}" =~ ^[0-9]+$ ]]; then
        JOB_HEARTBEAT_INTERVAL=120
    fi
    if (( JOB_HEARTBEAT_INTERVAL > 0 && JOB_HEARTBEAT_INTERVAL < 30 )); then
        JOB_HEARTBEAT_INTERVAL=30
    fi

    if [[ "${RUNNER_EPHEMERAL:-false}" == "true" ]]; then
        ONLINE_PROBE_EVERY="${ONLINE_PROBE_EVERY:-0}"
    else
        ONLINE_PROBE_EVERY="${ONLINE_PROBE_EVERY:-1}"
    fi

    ONLINE_FAIL_THRESHOLD="${ONLINE_FAIL_THRESHOLD:-3}"
    ON_OFFLINE_ACTION="${ON_OFFLINE_ACTION:-restart}"
    IDLE_RECYCLE_ACTION="${IDLE_RECYCLE_ACTION:-shutdown}"
    HEALTH_STALE_AFTER="${HEALTH_STALE_AFTER:-300}"

    export HEARTBEAT_INTERVAL JOB_HEARTBEAT_INTERVAL ONLINE_PROBE_EVERY \
           ONLINE_FAIL_THRESHOLD ON_OFFLINE_ACTION IDLE_RECYCLE_ACTION \
           HEALTH_STALE_AFTER
}

# ---------------------------------------------------------------------------
# 4b. Runtime-loop tunables (svc-gh-runner-logs + init-gh-runner-config + finish)
# ---------------------------------------------------------------------------
# LOG_WATCH_INTERVAL: seconds between iterations of the main heartbeat /
#   worker-tracking loop. Lower = faster JOB STARTED / JOB FINISHED banner
#   emission; higher = lower idle CPU wakeups. Default 2s (was 5s before
#   May 2026 refactor). Clamped to [1, 10].
#
# LISTENER_WAIT_TIMEOUT: how long svc-gh-runner-logs waits for the
#   Runner.Listener process to appear before logging a warning and
#   continuing anyway. Prevents a silent infinite spin when the listener
#   crashes mid-init. Default 600s (10 min). Set 0 to wait forever.
#
# DIAG_WAIT_TIMEOUT: same idea for /opt/runner-bin/_diag appearing. The
#   diag dir is created by Runner.Listener on its first log write, so
#   waiting forever for it on a broken install would hang the heartbeat.
#   Default 120s. Set 0 to wait forever.
#
# CONFIG_TIMEOUT: hard cap (seconds) on a single config.sh invocation
#   during runner registration. Without this a wedged TCP connection to
#   api.github.com would block init forever. Default 90s. Set 0 to
#   disable the wrapper (legacy behaviour).
#
# SKIP_DEREGISTER: when "true", svc-gh-runner/finish skips the API DELETE
#   + config.sh remove pair on container stop. Useful for long-lived
#   persistent runners where you want the runner to stay visible in
#   GitHub across container restarts (so jobs queued during the restart
#   window are still dispatched to it). Default false.
gh_config_resolve_runtime_tunables() {
    LOG_WATCH_INTERVAL="${LOG_WATCH_INTERVAL:-2}"
    if ! [[ "${LOG_WATCH_INTERVAL}" =~ ^[0-9]+$ ]] || (( LOG_WATCH_INTERVAL < 1 )); then
        LOG_WATCH_INTERVAL=2
    fi
    if (( LOG_WATCH_INTERVAL > 10 )); then
        LOG_WATCH_INTERVAL=10
    fi

    LISTENER_WAIT_TIMEOUT="${LISTENER_WAIT_TIMEOUT:-600}"
    if ! [[ "${LISTENER_WAIT_TIMEOUT}" =~ ^[0-9]+$ ]]; then
        LISTENER_WAIT_TIMEOUT=600
    fi

    DIAG_WAIT_TIMEOUT="${DIAG_WAIT_TIMEOUT:-120}"
    if ! [[ "${DIAG_WAIT_TIMEOUT}" =~ ^[0-9]+$ ]]; then
        DIAG_WAIT_TIMEOUT=120
    fi

    CONFIG_TIMEOUT="${CONFIG_TIMEOUT:-90}"
    if ! [[ "${CONFIG_TIMEOUT}" =~ ^[0-9]+$ ]]; then
        CONFIG_TIMEOUT=90
    fi

    SKIP_DEREGISTER="${SKIP_DEREGISTER:-false}"
    case "${SKIP_DEREGISTER,,}" in
        true|false) : ;;
        *) SKIP_DEREGISTER="false" ;;
    esac

    export LOG_WATCH_INTERVAL LISTENER_WAIT_TIMEOUT DIAG_WAIT_TIMEOUT \
           CONFIG_TIMEOUT SKIP_DEREGISTER
}

# ---------------------------------------------------------------------------
# 5. Runner identity defaults: name, labels, workdir
# ---------------------------------------------------------------------------
# When RUNNER_NAME is unset, derive one from balena fleet metadata if
# present (so devices in a fleet get human-readable names), or fall back
# to the container hostname. Always sanitizes to <=64 chars of
# [A-Za-z0-9._-].
gh_config_resolve_runner_name() {
    if [[ -n "${RUNNER_NAME:-}" ]]; then
        RUNNER_NAME_SOURCE="explicit: RUNNER_NAME env"
        log "info" "RUNNER_NAME provided explicitly via env: ${RUNNER_NAME}"
    else
        if [[ -n "${BALENA_DEVICE_NAME_AT_INIT:-}" ]]; then
            RUNNER_NAME="${BALENA_DEVICE_NAME_AT_INIT}${BALENA_SERVICE_HANDLE:+-${BALENA_SERVICE_HANDLE}}"
            RUNNER_NAME_SOURCE="auto: BALENA_DEVICE_NAME_AT_INIT"
        elif [[ -n "${RESIN_DEVICE_NAME_AT_INIT:-}" ]]; then
            RUNNER_NAME="${RESIN_DEVICE_NAME_AT_INIT}${BALENA_SERVICE_HANDLE:+-${BALENA_SERVICE_HANDLE}}"
            RUNNER_NAME_SOURCE="auto: RESIN_DEVICE_NAME_AT_INIT"
        elif [[ -n "${BALENA_SERVICE_HANDLE:-}" ]]; then
            RUNNER_NAME="$(hostname)-${BALENA_SERVICE_HANDLE}"
            RUNNER_NAME_SOURCE="auto: hostname-BALENA_SERVICE_HANDLE"
        else
            RUNNER_NAME="$(hostname)"
            RUNNER_NAME_SOURCE="auto: container hostname"
        fi
        RUNNER_NAME="$(printf '%s' "${RUNNER_NAME}" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-64)"
        log "info" "RUNNER_NAME not set, derived: ${RUNNER_NAME} (${RUNNER_NAME_SOURCE})"
    fi
    export RUNNER_NAME RUNNER_NAME_SOURCE
}

# AUTO_DOCKER_LABEL: append "docker" label when DOCKER_IN_DOCKER=true
# (so workflows can target `runs-on: [self-hosted, docker]`). Defaults
# to the value of DOCKER_IN_DOCKER; explicitly set AUTO_DOCKER_LABEL=false
# to keep DinD on without advertising the label.
#
# Sanitizes labels: trims each entry and drops empties (handles trailing
# commas / double commas).
gh_config_resolve_runner_labels() {
    if [[ -z "${RUNNER_LABELS:-}" ]]; then
        RUNNER_LABELS="self-hosted"
        log "info" "RUNNER_LABELS not set, defaulting to: ${RUNNER_LABELS}"
    fi

    # Note: Runner.Listener auto-injects `self-hosted`, OS, and arch labels
    # on top of whatever we pass via --labels. We deliberately do NOT add
    # our own `linux`/`arm64`/etc. to avoid duplicates in the GitHub UI.
    AUTO_DOCKER_LABEL="${AUTO_DOCKER_LABEL:-${DOCKER_IN_DOCKER:-false}}"
    if [[ "${AUTO_DOCKER_LABEL}" == "true" ]]; then
        local labels_lower="${RUNNER_LABELS,,}"
        if [[ "${labels_lower}" != *"docker"* ]]; then
            RUNNER_LABELS="${RUNNER_LABELS},docker"
            if [[ "${DOCKER_IN_DOCKER:-false}" == "true" ]]; then
                log "info" "Auto-appended label: docker (DOCKER_IN_DOCKER=true; disable with AUTO_DOCKER_LABEL=false)"
            else
                log "info" "Auto-appended label: docker (AUTO_DOCKER_LABEL=true)"
            fi
        fi
    fi

    RUNNER_LABELS="$(echo "${RUNNER_LABELS}" | tr ',' '\n' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | paste -sd ',' -)"
    export RUNNER_LABELS AUTO_DOCKER_LABEL
}

# Default RUNNER_WORKDIR to a per-runner isolated path so scaled replicas
# don't share the same _work tree.
gh_config_resolve_runner_workdir() {
    if [[ -z "${RUNNER_WORKDIR:-}" ]]; then
        RUNNER_WORKDIR="/config/work/${RUNNER_NAME}"
        log "info" "RUNNER_WORKDIR not set, using isolated default: ${RUNNER_WORKDIR}"
    fi
    mkdir -p "${RUNNER_WORKDIR}"
    chown abc:abc "${RUNNER_WORKDIR}" 2>/dev/null || true
    chmod 700 "${RUNNER_WORKDIR}" 2>/dev/null || true
    export RUNNER_WORKDIR
}
