#!/usr/bin/with-contenv bash
# shellcheck shell=bash
#
# Operator-visible startup banner. Pulls every relevant config value into
# a single block printed once at the end of init so the operator can
# verify what the runner actually resolved without scrolling through
# 200 lines of preflight / config.sh output.
#
# The banner is emitted via `prefix_lines banner` (defined in
# gh-runtime.sh), which keeps the `==`/`--` fences aligned in the console.
#

# mask_secret <value>
# Print "(set)" / "(not set)" without ever revealing the value itself.
mask_secret() {
    if [[ -z "${1:-}" ]]; then echo "(not set)"; else echo "(set)"; fi
}

# show_or_unset <value>
# Show the value, or "(not set)" when empty, keeping banner alignment.
show_or_unset() {
    if [[ -z "${1:-}" ]]; then echo "(not set)"; else echo "$1"; fi
}

# auth_method_summary
# Identify which credential will actually be used, in priority order
# (RUNNER_TOKEN > GITHUB_PAT > GITHUB_TOKEN). Never prints the value.
auth_method_summary() {
    if   [[ -n "${RUNNER_TOKEN:-}" ]]; then echo "RUNNER_TOKEN (registration token)"
    elif [[ -n "${GITHUB_PAT:-}"   ]]; then echo "GITHUB_PAT (Personal Access Token -> mints registration token)"
    elif [[ -n "${GITHUB_TOKEN:-}" ]]; then echo "GITHUB_TOKEN (repo secret / app token -> mints registration token)"
    else echo "(none -- registration will fail)"
    fi
}

# runtime_mode_summary
# Compact description of how the runner is actually running:
#   - root (default) vs --user (non-root LSIO mode)
#   - tmpfs-mounted runtime tree (read-only-friendly setup)
runtime_mode_summary() {
    local parts=()
    if [[ "${RUN_AS_NONROOT:-0}" == "1" ]]; then
        parts+=("non-root (--user uid=${CURRENT_UID:-?})")
    else
        parts+=("root -> drops to abc (uid 911)")
    fi
    # Compare device numbers of /opt/runner-bin vs /opt -- different means
    # an overlay/tmpfs is mounted (used by read_only:true compose setups).
    local rt_dev img_dev
    rt_dev="$(stat -c '%d' /opt/runner-bin 2>/dev/null || echo 0)"
    img_dev="$(stat -c '%d' /opt              2>/dev/null || echo 0)"
    if [[ "${rt_dev}" != "0" && "${img_dev}" != "0" && "${rt_dev}" != "${img_dev}" ]]; then
        parts+=("read-only friendly (tmpfs runtime)")
    fi
    (IFS=,; echo "${parts[*]}")
}

# gh_banner_emit
# Print the full startup banner. Assumes all values are already resolved
# (call AFTER gh_config_* and registration are done). Caller is expected
# to pipe through `prefix_lines banner` for proper formatting.
gh_banner_emit() {
    local APP_VERSION_BANNER="unknown"
    local RUNNER_ARCH_BANNER; RUNNER_ARCH_BANNER="$(uname -m)"
    local BUILD_DATE_BANNER="unknown"
    if [[ -r /etc/gh-runner/build-info ]]; then
        # shellcheck disable=SC1091
        . /etc/gh-runner/build-info
        APP_VERSION_BANNER="${APP_VERSION:-unknown}"
        RUNNER_ARCH_BANNER="${RUNNER_ARCH:-$(uname -m)}"
        BUILD_DATE_BANNER="${BUILD_DATE:-unknown}"
    fi

    local LINE="======================================================================="
    local THIN="-----------------------------------------------------------------------"

    echo ""
    echo "${LINE}"
    echo "  blackoutsecure/docker-github-runner -- GitHub Actions Self-Hosted Runner"
    echo "  Image v${APP_VERSION_BANNER} (${RUNNER_ARCH_BANNER})  |  built ${BUILD_DATE_BANNER}"
    echo "  Sponsored by Blackout Secure (https://blackoutsecure.app)"
    echo "  Licensed MIT  |  https://github.com/blackoutsecure/docker-github-runner"
    echo "${THIN}"
    echo "  Runtime"
    echo "    Mode             : $(runtime_mode_summary)"
    echo "    Container Host   : $(hostname)"
    echo "    Started At       : $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "    Timezone         : $(show_or_unset "${TZ:-}")"
    echo "    Log Level        : ${LOG_LEVEL:-info}"
    echo "${THIN}"
    echo "  Runner identity"
    echo "    Name             : ${RUNNER_NAME:-$(hostname)} (${RUNNER_NAME_SOURCE:-unknown})"
    echo "    URL              : $(show_or_unset "${RUNNER_URL:-}")"
    echo "    Group            : ${RUNNER_GROUP:-Default}"
    echo "    Labels           : ${RUNNER_LABELS:-(default)}"
    echo "    Work Directory   : ${RUNNER_WORKDIR:-/config/work}"
    echo "${THIN}"
    echo "  Behavior"
    echo "    Ephemeral        : ${RUNNER_EPHEMERAL:-false}"
    echo "    Replace Existing : ${RUNNER_REPLACE_EXISTING:-true}"
    echo "    Disable Update   : ${DISABLE_RUNNER_UPDATE:-false}"
    echo "    Auto Docker Label: ${AUTO_DOCKER_LABEL:-${DOCKER_IN_DOCKER:-false}}"
    echo "    Docker-in-Docker : ${DOCKER_IN_DOCKER:-false}"
    echo "${THIN}"
    echo "  Health & recovery"
    echo "    Heartbeat        : every ${HEARTBEAT_INTERVAL:-120}s (HEARTBEAT_INTERVAL)"
    echo "    Job Heartbeat    : every ${JOB_HEARTBEAT_INTERVAL:-120}s while a job runs (0=off; JOB_HEARTBEAT_INTERVAL)"
    echo "    Online Probe     : every ${ONLINE_PROBE_EVERY:-1} heartbeat(s)"
    echo "    Offline Threshold: ${ONLINE_FAIL_THRESHOLD:-3}"
    echo "    On Offline       : ${ON_OFFLINE_ACTION:-restart}"
    echo "    Idle Recycle After: ${IDLE_RECYCLE_AFTER:-0}s [${IDLE_RECYCLE_AFTER_SOURCE:-default}]$( [[ "${IDLE_RECYCLE_AFTER:-0}" == "0" ]] && echo " (disabled)" )"
    echo "    Idle Recycle Action: ${IDLE_RECYCLE_ACTION:-shutdown}"
    echo "    Stale After      : ${HEALTH_STALE_AFTER:-300}s"
    echo "    s6 Gracetime     : svc=${S6_SERVICES_GRACETIME:-30000}ms kill=${S6_KILL_GRACETIME:-30000}ms"
    echo "${THIN}"
    echo "  Runtime tunables"
    echo "    Log Watch Tick   : ${LOG_WATCH_INTERVAL:-2}s (worker-transition reporting latency)"
    echo "    Listener Wait    : ${LISTENER_WAIT_TIMEOUT:-600}s$( [[ "${LISTENER_WAIT_TIMEOUT:-600}" == "0" ]] && echo " (wait forever)" )"
    echo "    Diag Wait        : ${DIAG_WAIT_TIMEOUT:-120}s$( [[ "${DIAG_WAIT_TIMEOUT:-120}" == "0" ]] && echo " (wait forever)" )"
    echo "    Config Timeout   : ${CONFIG_TIMEOUT:-90}s$( [[ "${CONFIG_TIMEOUT:-90}" == "0" ]] && echo " (disabled -- legacy)" )"
    echo "    Skip Deregister  : ${SKIP_DEREGISTER:-false}"
    echo "${THIN}"
    echo "  Stale offline-runner cleanup"
    echo "    Enabled          : ${CLEANUP_OFFLINE_RUNNERS:-false}"
    echo "    Offline After    : ${CLEANUP_OFFLINE_AFTER:-86400}s"
    echo "    Immediate Mode   : ${CLEANUP_OFFLINE_IMMEDIATE:-(auto: $( [[ "${RUNNER_EPHEMERAL:-false}" == "true" ]] && echo true || echo false ))}"
    echo "    Name Regex       : $(show_or_unset "${CLEANUP_OFFLINE_NAME_REGEX:-}")"
    echo "    Any-Name Sweep   : ${CLEANUP_OFFLINE_ANY_NAME:-false} (after ${CLEANUP_OFFLINE_ANY_NAME_AFTER:-604800}s, threshold-mode only)"
    echo "    Dry Run          : ${CLEANUP_OFFLINE_DRY_RUN:-false}"
    echo "    Max Per Sweep    : ${CLEANUP_OFFLINE_MAX:-25}"
    echo "${THIN}"
    echo "  Custom init (optional, runs as root before runner)"
    echo "    EXTRA_PACKAGES   : $(show_or_unset "${EXTRA_PACKAGES:-}")"
    echo "    EXTRA_APT_REPOS  : $(mask_secret "${EXTRA_APT_REPOS:-}")"
    echo "    EXTRA_INIT_SCRIPT: $(show_or_unset "${EXTRA_INIT_SCRIPT:-}")"
    echo "${THIN}"
    echo "  Authentication (values masked)"
    echo "    Method           : $(auth_method_summary)"
    echo "    RUNNER_TOKEN     : $(mask_secret "${RUNNER_TOKEN:-}")"
    echo "    GITHUB_PAT       : $(mask_secret "${GITHUB_PAT:-}")"
    echo "    GITHUB_TOKEN     : $(mask_secret "${GITHUB_TOKEN:-}")"
    echo "    RUNNER_ENV_FILE  : $(show_or_unset "${RUNNER_ENV_FILE:-}")"
    echo "    RUNNER_SECRETS_DIR: $(show_or_unset "${RUNNER_SECRETS_DIR:-}")"
    echo "${LINE}"
    echo ""
}
