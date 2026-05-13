#!/usr/bin/env bash
# =============================================================================
# gh-runner-autoscaler — Dynamic scaling for GitHub Actions self-hosted runners
#
# Monitors runner status via the GitHub API and scales the companion
# `gh-runner` compose service between SCALE_MIN and SCALE_MAX replicas.
#
# Required environment variables:
#   RUNNER_URL      — GitHub repo/org/enterprise URL
#   GITHUB_PAT      — PAT with admin:org or repo scope (for runner list API)
#
# Scaling variables:
#   SCALE_MIN       — Minimum runners to keep alive (default: 1)
#   SCALE_MAX       — Maximum runners allowed      (default: 1)
#   SCALE_MODE      — "auto" (default) or "fixed"
#                     auto  = scale between MIN..MAX based on demand
#                     fixed = always run exactly SCALE_MAX runners
#   SCALE_INTERVAL  — Seconds between scaling checks (default: 30)
#   SCALE_COOLDOWN  — Seconds to wait after a scale event before another (default: 60)
#   SCALE_UP_THRESHOLD   — Busy-ratio to trigger scale-up   (default: 0.8 = 80%)
#   SCALE_DOWN_THRESHOLD — Busy-ratio to trigger scale-down (default: 0.2 = 20%)
#
# Usage:
#   Typically run as a compose service — see the Autoscaling section in README.md
#   Can also be run standalone: ./scripts/autoscale.sh
# =============================================================================
set -uo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
SCALE_MIN="${SCALE_MIN:-1}"
SCALE_MAX="${SCALE_MAX:-1}"
SCALE_MODE="${SCALE_MODE:-auto}"
SCALE_INTERVAL="${SCALE_INTERVAL:-30}"
SCALE_COOLDOWN="${SCALE_COOLDOWN:-60}"
SCALE_UP_THRESHOLD="${SCALE_UP_THRESHOLD:-80}"
SCALE_DOWN_THRESHOLD="${SCALE_DOWN_THRESHOLD:-20}"
COMPOSE_SERVICE="${COMPOSE_SERVICE:-gh-runner}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"

log() {
    echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') autoscaler[$1]: $2"
}

# ── Validation ────────────────────────────────────────────────────────────────
if [[ -z "${GITHUB_PAT:-}" ]]; then
    log "fatal" "GITHUB_PAT is required for the autoscaler to query runner status"
    exit 1
fi

if [[ -z "${RUNNER_URL:-}" ]]; then
    log "fatal" "RUNNER_URL is required"
    exit 1
fi

if [[ "${SCALE_MIN}" -lt 1 ]]; then
    log "warn" "SCALE_MIN must be >= 1, setting to 1"
    SCALE_MIN=1
fi

if [[ "${SCALE_MAX}" -lt "${SCALE_MIN}" ]]; then
    log "warn" "SCALE_MAX (${SCALE_MAX}) < SCALE_MIN (${SCALE_MIN}), setting SCALE_MAX=${SCALE_MIN}"
    SCALE_MAX="${SCALE_MIN}"
fi

# ── Resolve API URL ──────────────────────────────────────────────────────────
resolve_runners_api_url() {
    local url_path="${RUNNER_URL#https://github.com/}"
    url_path="${url_path%/}"
    local api_base="https://api.github.com"

    if [[ "${url_path}" == enterprises/* ]]; then
        echo "${api_base}/enterprises/${url_path#enterprises/}/actions/runners"
    elif [[ "${url_path}" == */* ]]; then
        echo "${api_base}/repos/${url_path}/actions/runners"
    else
        echo "${api_base}/orgs/${url_path}/actions/runners"
    fi
}

RUNNERS_API_URL="$(resolve_runners_api_url)"

# ── Runner status query ──────────────────────────────────────────────────────
# Returns: total online busy
get_runner_counts() {
    local page=1 total_online=0 total_busy=0

    while [[ "${page}" -le 10 ]]; do
        local resp
        resp="$(curl -fsSL \
            -H "Authorization: token ${GITHUB_PAT}" \
            -H "Accept: application/vnd.github+json" \
            "${RUNNERS_API_URL}?per_page=100&page=${page}" 2>/dev/null)" || {
            echo "0 0"
            return 1
        }

        local online busy count
        online="$(echo "${resp}" | jq '[.runners[] | select(.status == "online")] | length' 2>/dev/null || echo 0)"
        busy="$(echo "${resp}" | jq '[.runners[] | select(.status == "online" and .busy == true)] | length' 2>/dev/null || echo 0)"
        count="$(echo "${resp}" | jq '.runners | length' 2>/dev/null || echo 0)"

        total_online=$((total_online + online))
        total_busy=$((total_busy + busy))

        if [[ "${count}" -lt 100 ]]; then
            break
        fi
        page=$((page + 1))
    done

    echo "${total_online} ${total_busy}"
}

# Returns newline-separated names of online + idle (busy=false) runners.
# Used by graceful_scale_down to pick safe scale-in targets in ephemeral mode.
get_idle_runner_names() {
    local page=1
    while [[ "${page}" -le 10 ]]; do
        local resp
        resp="$(curl -fsSL \
            -H "Authorization: token ${GITHUB_PAT}" \
            -H "Accept: application/vnd.github+json" \
            "${RUNNERS_API_URL}?per_page=100&page=${page}" 2>/dev/null)" || return 1

        echo "${resp}" | jq -r '.runners[] | select(.status == "online" and .busy == false) | .name' 2>/dev/null

        local count
        count="$(echo "${resp}" | jq '.runners | length' 2>/dev/null || echo 0)"
        if [[ "${count}" -lt 100 ]]; then
            break
        fi
        page=$((page + 1))
    done
}

# ── Compose scaling ──────────────────────────────────────────────────────────
get_current_replicas() {
    local compose_args=(-f "${COMPOSE_FILE}")
    if [[ -n "${COMPOSE_PROJECT}" ]]; then
        compose_args+=(-p "${COMPOSE_PROJECT}")
    fi

    docker compose "${compose_args[@]}" ps --format json "${COMPOSE_SERVICE}" 2>/dev/null \
        | jq -s 'length' 2>/dev/null || echo 0
}

scale_to() {
    local target="$1"
    local compose_args=(-f "${COMPOSE_FILE}")
    if [[ -n "${COMPOSE_PROJECT}" ]]; then
        compose_args+=(-p "${COMPOSE_PROJECT}")
    fi

    log "info" "Scaling ${COMPOSE_SERVICE} to ${target} replicas..."

    if docker compose "${compose_args[@]}" up -d --scale "${COMPOSE_SERVICE}=${target}" --no-recreate 2>&1; then
        log "info" "Scale to ${target} successful"
        return 0
    else
        log "warn" "Scale command failed"
        return 1
    fi
}

# Graceful scale-down for ephemeral runners.
#
# In ephemeral mode each container handles exactly ONE job and then exits;
# capacity for concurrent jobs is the replica count. A naive
# `compose --scale=N` removes containers in compose's index order, NOT by
# busy/idle state -- so it can abort an in-flight job. This function:
#
#   1. Asks GitHub which runners are currently online + idle (busy=false).
#   2. Resolves each idle runner name -> local docker container ID by
#      hostname (the runner registers with its container hostname when
#      RUNNER_NAME is unset, the recommended ephemeral pattern).
#   3. `docker stop`s the chosen idle containers so the s6 finish hook
#      runs (clean GitHub deregister) and Docker honours the stop intent
#      (won't be auto-restarted by `restart: always`).
#   4. Reconciles compose's view with `compose up --scale=target`.
#
# If we cannot find enough idle runners (e.g. they all just picked up
# jobs between the API poll and now), we DO NOT fall back to killing
# busy containers; we keep the current count and try again next interval.
# This trades a slower scale-down for never aborting a user's workflow.
graceful_scale_down() {
    local target="$1"
    local current="$2"
    local need=$(( current - target ))

    if [[ "${need}" -le 0 ]]; then
        return 0
    fi

    log "info" "Graceful scale-down: need to retire ${need} idle replica(s) (target=${target})"

    local idle_names
    idle_names="$(get_idle_runner_names || true)"
    if [[ -z "${idle_names}" ]]; then
        log "info" "No idle runners available to retire -- deferring scale-down"
        return 1
    fi

    local retired=0
    local cid
    while IFS= read -r name; do
        [[ -z "${name}" ]] && continue
        [[ "${retired}" -ge "${need}" ]] && break

        # When RUNNER_NAME is unset, the runner registers with its container
        # hostname (= short container ID, 12 chars). Match by container ID
        # prefix OR by container name (covers explicit RUNNER_NAME too).
        cid="$(docker ps --no-trunc \
            --filter "label=com.docker.compose.service=${COMPOSE_SERVICE}" \
            --format '{{.ID}} {{.Names}}' 2>/dev/null \
            | awk -v n="${name}" '$1 ~ "^"n || $2 == n {print $1; exit}')"

        if [[ -z "${cid}" ]]; then
            log "warn" "Idle runner '${name}' has no matching local container -- skipping"
            continue
        fi

        log "info" "Retiring idle runner '${name}' (container ${cid:0:12})"
        if docker stop "${cid}" >/dev/null 2>&1; then
            retired=$((retired + 1))
        else
            log "warn" "docker stop ${cid:0:12} failed -- skipping"
        fi
    done <<< "${idle_names}"

    if [[ "${retired}" -eq 0 ]]; then
        log "warn" "Could not retire any idle runners -- deferring scale-down"
        return 1
    fi

    # Reconcile compose's view. Stopped containers still count as replicas
    # in `compose ps`; without this step compose would resurrect them on
    # the next `up` call.
    local compose_args=(-f "${COMPOSE_FILE}")
    if [[ -n "${COMPOSE_PROJECT}" ]]; then
        compose_args+=(-p "${COMPOSE_PROJECT}")
    fi
    docker compose "${compose_args[@]}" rm -fsv "${COMPOSE_SERVICE}" >/dev/null 2>&1 || true

    local new_target=$(( current - retired ))
    if [[ "${new_target}" -lt "${target}" ]]; then
        new_target="${target}"
    fi
    scale_to "${new_target}"
}

# ── Banner ────────────────────────────────────────────────────────────────────
log "info" "═══════════════════════════════════════════════════════"
log "info" "  GitHub Actions Runner Autoscaler"
log "info" "═══════════════════════════════════════════════════════"
log "info" "  Mode         : ${SCALE_MODE}"
log "info" "  Min replicas : ${SCALE_MIN}"
log "info" "  Max replicas : ${SCALE_MAX}"
log "info" "  Interval     : ${SCALE_INTERVAL}s"
log "info" "  Cooldown     : ${SCALE_COOLDOWN}s"
if [[ "${SCALE_MODE}" == "auto" ]]; then
    log "info" "  Scale-up at  : ${SCALE_UP_THRESHOLD}% busy"
    log "info" "  Scale-down at: ${SCALE_DOWN_THRESHOLD}% busy"
fi
log "info" "  Runner URL   : ${RUNNER_URL}"
log "info" "  Service      : ${COMPOSE_SERVICE}"
log "info" "═══════════════════════════════════════════════════════"

# ── Fixed mode: set to MAX and exit loop ──────────────────────────────────────
if [[ "${SCALE_MODE}" == "fixed" ]]; then
    log "info" "Fixed mode: scaling to SCALE_MAX=${SCALE_MAX} and holding"
    scale_to "${SCALE_MAX}"

    # Stay alive and periodically verify the count
    while true; do
        sleep "${SCALE_INTERVAL}"
        current="$(get_current_replicas)"
        if [[ "${current}" -ne "${SCALE_MAX}" ]]; then
            log "warn" "Expected ${SCALE_MAX} replicas but found ${current}, correcting..."
            scale_to "${SCALE_MAX}"
        fi
    done
fi

# ── Auto mode: main scaling loop ─────────────────────────────────────────────
LAST_SCALE_TIME=0

# Ensure minimum runners are up
scale_to "${SCALE_MIN}"

while true; do
    sleep "${SCALE_INTERVAL}"

    NOW="$(date +%s)"
    CURRENT="$(get_current_replicas)"

    read -r ONLINE BUSY <<< "$(get_runner_counts)" || {
        log "warn" "Failed to query runner status, skipping cycle"
        continue
    }

    IDLE=$((ONLINE - BUSY))

    # Calculate busy percentage (avoid division by zero)
    if [[ "${CURRENT}" -gt 0 ]]; then
        BUSY_PCT=$(( (BUSY * 100) / CURRENT ))
    else
        BUSY_PCT=0
    fi

    log "info" "Status: replicas=${CURRENT} online=${ONLINE} busy=${BUSY} idle=${IDLE} busy%=${BUSY_PCT}%"

    # Cooldown check
    SINCE_LAST=$(( NOW - LAST_SCALE_TIME ))
    if [[ "${SINCE_LAST}" -lt "${SCALE_COOLDOWN}" ]]; then
        continue
    fi

    # Scale-up: if busy ratio exceeds threshold and we're below MAX
    if [[ "${BUSY_PCT}" -ge "${SCALE_UP_THRESHOLD}" && "${CURRENT}" -lt "${SCALE_MAX}" ]]; then
        NEW_COUNT=$((CURRENT + 1))
        log "info" "Busy ratio ${BUSY_PCT}% >= ${SCALE_UP_THRESHOLD}% → scaling up to ${NEW_COUNT}"
        if scale_to "${NEW_COUNT}"; then
            LAST_SCALE_TIME="${NOW}"
        fi
        continue
    fi

    # Scale-down: if busy ratio is below threshold and we're above MIN
    if [[ "${BUSY_PCT}" -le "${SCALE_DOWN_THRESHOLD}" && "${CURRENT}" -gt "${SCALE_MIN}" ]]; then
        NEW_COUNT=$((CURRENT - 1))
        # Never go below MIN
        if [[ "${NEW_COUNT}" -lt "${SCALE_MIN}" ]]; then
            NEW_COUNT="${SCALE_MIN}"
        fi
        log "info" "Busy ratio ${BUSY_PCT}% <= ${SCALE_DOWN_THRESHOLD}% → graceful scale-down to ${NEW_COUNT}"
        if graceful_scale_down "${NEW_COUNT}" "${CURRENT}"; then
            LAST_SCALE_TIME="${NOW}"
        fi
        continue
    fi
done
