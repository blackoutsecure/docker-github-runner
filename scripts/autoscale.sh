#!/usr/bin/env bash
# =============================================================================
# gh-runner-autoscaler — Dynamic scaling for GitHub Actions self-hosted runners
#
# Polls the GitHub API for the busy/online runner ratio and asks a
# configurable BACKEND to adjust the runner pool size between
# SCALE_MIN and SCALE_MAX.
#
# The demand-detection loop (API polling, busy% math, cooldown, idle-name
# selection) is orchestrator-agnostic; only the per-backend scaling primitive
# changes. This makes the script work natively on Docker Compose AND on
# anything you can drive from a shell command — kubectl, balena-cli, docker
# swarm, nomad, your CI, etc. — without forking the script.
#
# Backends (SCALE_BACKEND env):
#   compose  (default) — Calls `docker compose --scale gh-runner=N`.
#                        Requires docker.sock + the rendered compose file.
#   exec               — Calls an operator-supplied command for every replica
#                        operation. Portable to ANY orchestrator. Required
#                        env: SCALE_EXEC=<path-or-command>. The command is
#                        invoked with one of three verbs:
#                          $SCALE_EXEC count            -> print current replica count to stdout
#                          $SCALE_EXEC scale <N>        -> scale the pool to N replicas
#                          $SCALE_EXEC remove <name>... -> graceful-down by runner name (optional)
#                        Set SCALE_EXEC_SUPPORTS_REMOVE=true to enable the
#                        graceful `remove` verb; otherwise the script falls
#                        back to naive `scale` for scale-in events.
#   emit               — Read-only "decision-as-a-service" mode. Writes a
#                        JSON state file each cycle and NEVER scales locally.
#                        External systems (GitHub Actions cron, balena-cli
#                        from a workstation, an Argo/Tekton pipeline) consume
#                        the file and apply the scaling action however they
#                        like. Required env: SCALE_EMIT_FILE=<path>.
#
# Required environment variables (always):
#   RUNNER_URL      — GitHub repo/org/enterprise URL
#   GITHUB_PAT      — PAT with admin:org or repo scope (for runner list API)
#
# Per-fleet scope filters (apply to ALL GitHub API queries; default = no filter):
#   RUNNER_SCOPE_LABELS      Comma-separated label set. Only runners whose
#                            label set is a SUPERSET of this list are counted.
#                            Match is case-insensitive. Example:
#                              RUNNER_SCOPE_LABELS="self-hosted,arm64,prod"
#                            CRITICAL when multiple runner fleets (e.g. an
#                            arm64 pool and an x64 pool) share the same
#                            org/repo — without this the autoscaler sees
#                            ALL runners and makes wrong scaling decisions
#                            for each fleet. The GitHub-auto labels `ARM64`
#                            / `X64` / `Linux` are reliable discriminators.
#   RUNNER_SCOPE_NAME_REGEX  Optional jq-flavor (PCRE) regex applied to the
#                            runner `.name` field. Useful when fleets share
#                            labels but use distinct name prefixes (e.g.
#                            "^arm-runner-"). AND-combined with the label
#                            filter above.
#
# Scaling variables (apply to all backends):
#   SCALE_MIN       — Minimum runners to keep alive (default: 1)
#   SCALE_MAX       — Maximum runners allowed       (default: 1)
#   SCALE_MODE      — "auto" (default) or "fixed"
#                     auto  = scale between MIN..MAX based on demand
#                     fixed = always run exactly SCALE_MAX runners
#   SCALE_INTERVAL  — Seconds between scaling checks (default: 30)
#   SCALE_COOLDOWN  — Seconds between scale events  (default: 60)
#   SCALE_UP_THRESHOLD   — Busy-ratio % to trigger scale-up   (default: 80)
#   SCALE_DOWN_THRESHOLD — Busy-ratio % to trigger scale-down (default: 20)
#
# Compose backend (SCALE_BACKEND=compose):
#   COMPOSE_SERVICE — Compose service name to scale (default: gh-runner)
#   COMPOSE_PROJECT — Optional compose project name
#   COMPOSE_FILE    — Compose file path (default: docker-compose.yml)
#
# Exec backend (SCALE_BACKEND=exec):
#   SCALE_EXEC                  — Required. Path or shell command.
#   SCALE_EXEC_SUPPORTS_REMOVE  — 'true' if your wrapper implements
#                                 `remove <name>...` for graceful scale-down.
#
# Emit backend (SCALE_BACKEND=emit):
#   SCALE_EMIT_FILE — Required. Path to write JSON state file.
#
# Usage:
#   Typically run as a compose service — see the Autoscaling section in README.md.
#   Can also be run standalone:  RUNNER_URL=... GITHUB_PAT=... ./scripts/autoscale.sh
# =============================================================================
set -uo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
SCALE_BACKEND="${SCALE_BACKEND:-compose}"
SCALE_MIN="${SCALE_MIN:-1}"
SCALE_MAX="${SCALE_MAX:-1}"
SCALE_MODE="${SCALE_MODE:-auto}"
SCALE_INTERVAL="${SCALE_INTERVAL:-30}"
SCALE_COOLDOWN="${SCALE_COOLDOWN:-60}"
SCALE_UP_THRESHOLD="${SCALE_UP_THRESHOLD:-80}"
SCALE_DOWN_THRESHOLD="${SCALE_DOWN_THRESHOLD:-20}"
# Compose backend
COMPOSE_SERVICE="${COMPOSE_SERVICE:-gh-runner}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
# Exec backend
SCALE_EXEC="${SCALE_EXEC:-}"
SCALE_EXEC_SUPPORTS_REMOVE="${SCALE_EXEC_SUPPORTS_REMOVE:-false}"
# Emit backend
SCALE_EMIT_FILE="${SCALE_EMIT_FILE:-}"
# Per-fleet scope filters
RUNNER_SCOPE_LABELS="${RUNNER_SCOPE_LABELS:-}"
RUNNER_SCOPE_NAME_REGEX="${RUNNER_SCOPE_NAME_REGEX:-}"

log() {
    echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') autoscaler[$1]: $2"
}

# Clamp $1 into the inclusive range [$2, $3].
clamp() {
    local v="$1" lo="$2" hi="$3"
    if   [[ "${v}" -lt "${lo}" ]]; then echo "${lo}"
    elif [[ "${v}" -gt "${hi}" ]]; then echo "${hi}"
    else echo "${v}"
    fi
}

# ── Validation ────────────────────────────────────────────────────────────────
case "${SCALE_BACKEND}" in
    compose|exec|emit) ;;
    *)
        log "fatal" "SCALE_BACKEND='${SCALE_BACKEND}' is not supported. Valid: compose | exec | emit"
        exit 1
        ;;
esac

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

case "${SCALE_BACKEND}" in
    exec)
        if [[ -z "${SCALE_EXEC}" ]]; then
            log "fatal" "SCALE_BACKEND=exec requires SCALE_EXEC=<path or command>"
            exit 1
        fi
        ;;
    emit)
        if [[ -z "${SCALE_EMIT_FILE}" ]]; then
            log "fatal" "SCALE_BACKEND=emit requires SCALE_EMIT_FILE=<path>"
            exit 1
        fi
        # Ensure the emit file's parent dir exists. On Balena/balena-engine
        # (verified May 2026), tmpfs mount targets are NOT auto-created if
        # the path doesn't already exist in the image filesystem — the mount
        # silently fails to materialize and every write hits:
        #   line N: <path>.tmp.<pid>: No such file or directory
        # The Dockerfile pre-creates the default /scaler mountpoint, but a
        # caller-supplied SCALE_EMIT_FILE pointing elsewhere needs the same
        # guarantee. Failing fast here is safer than spinning for hours
        # logging mv errors every cycle.
        _emit_dir="$(dirname "${SCALE_EMIT_FILE}")"
        if ! mkdir -p "${_emit_dir}" 2>/dev/null; then
            log "fatal" "Cannot create SCALE_EMIT_FILE parent dir '${_emit_dir}' — check container filesystem mounts"
            exit 1
        fi
        if ! ( : > "${SCALE_EMIT_FILE}.writetest.$$" ) 2>/dev/null; then
            log "fatal" "SCALE_EMIT_FILE parent dir '${_emit_dir}' is not writable — check tmpfs mount mode (need owner-writable for container UID $(id -u))"
            exit 1
        fi
        rm -f "${SCALE_EMIT_FILE}.writetest.$$"
        unset _emit_dir
        ;;
esac

# Validate the scope regex compiles before entering the loop, so a typo
# becomes a startup fatal instead of a per-cycle silent no-op.
if [[ -n "${RUNNER_SCOPE_NAME_REGEX}" ]]; then
    if ! echo "x" | jq -Rr --arg r "${RUNNER_SCOPE_NAME_REGEX}" '. | test($r)' >/dev/null 2>&1; then
        log "fatal" "RUNNER_SCOPE_NAME_REGEX='${RUNNER_SCOPE_NAME_REGEX}' is not a valid jq regex"
        exit 1
    fi
fi

# Normalize the required-label set ONCE: trim, drop empties, lowercase,
# JSON-encode as a string array. Empty array = no label filter.
_SCOPE_LABELS_JSON='[]'
if [[ -n "${RUNNER_SCOPE_LABELS}" ]]; then
    _SCOPE_LABELS_JSON="$(printf '%s' "${RUNNER_SCOPE_LABELS}" \
        | tr ',' '\n' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | awk 'NF' \
        | tr '[:upper:]' '[:lower:]' \
        | jq -R . | jq -c -s '.')"
    if [[ -z "${_SCOPE_LABELS_JSON}" || "${_SCOPE_LABELS_JSON}" == "null" ]]; then
        _SCOPE_LABELS_JSON='[]'
    fi
fi

# Pre-compute compose CLI args once (never change at runtime).
COMPOSE_ARGS=(-f "${COMPOSE_FILE}")
[[ -n "${COMPOSE_PROJECT}" ]] && COMPOSE_ARGS+=(-p "${COMPOSE_PROJECT}")

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

# ── Runner status query (per-cycle cached) ──────────────────────────────────
# A single paginated GET /actions/runners fetch per scaling cycle feeds both
# the count summary AND the idle-name selector. Caching here halves API calls
# per cycle (rate-limit friendly) and avoids racing between two fetches.
# Capped at 10 pages × 100 = 1000 runners — far above any realistic
# self-hosted fleet size.

RUNNERS_JSON_CACHE='[]'

# Narrow a runners[] JSON blob (stdin) to just this fleet's runners, using
# the pre-normalized RUNNER_SCOPE_LABELS subset match AND the optional
# RUNNER_SCOPE_NAME_REGEX. No-op when both filters are empty.
_apply_scope_filter() {
    jq -c \
        --argjson required "${_SCOPE_LABELS_JSON}" \
        --arg regex "${RUNNER_SCOPE_NAME_REGEX}" \
        '
        map(
            (([.labels[]?.name // ""] | map(ascii_downcase)) as $have
             | (if ($required | length) == 0 then true
                else ($required | all(. as $w | $have | index($w))) end) as $label_ok
             | (if $regex == "" then true
                else (.name | test($regex)) end) as $name_ok
             | select($label_ok and $name_ok))
        )
        '
}

# Returns the merged + scope-filtered runners[] array on stdout, exit 0 on
# success. On failure, logs a human-readable diagnostic (HTTP status +
# curl exit + hint) directly to stderr and returns 1.
#
# Why log from inside the function rather than setting a module-global +
# logging from the caller: this function is invoked via `$(...)` (command
# substitution) so its body runs in a SUBSHELL. Any variable mutation
# (e.g. `_LAST_FETCH_ERR=...`) dies with the subshell and is invisible to
# the parent. The earlier indirection silently produced `<no diagnostic>`
# on every failure. Writing to stderr from inside the subshell side-steps
# this entirely: stderr from the entrypoint process is captured by docker/
# s6 alongside stdout, so the operator sees the full diagnostic in the
# usual log stream while the `$()` only captures stdout (the JSON).
_fetch_runners_json() {
    local page=1 acc='[]' resp body http curl_exit curl_err page_runners count err
    local tmp_err
    tmp_err="$(mktemp 2>/dev/null || echo /tmp/autoscale-curl-err.$$)"
    while [[ "${page}" -le 10 ]]; do
        # `-w '\nHTTPSTATUS:%{http_code}'` appends the final HTTP status on
        # its own line so we can tease it apart even when curl exits 0.
        # Drop `-f` so curl returns 4xx/5xx bodies (useful for error text)
        # but still exits non-zero — handled below.
        resp="$(curl -sSL \
            -w '\nHTTPSTATUS:%{http_code}' \
            -H "Authorization: token ${GITHUB_PAT}" \
            -H "Accept: application/vnd.github+json" \
            "${RUNNERS_API_URL}?per_page=100&page=${page}" 2>"${tmp_err}")"
        curl_exit=$?
        http="${resp##*HTTPSTATUS:}"
        body="${resp%$'\n'HTTPSTATUS:*}"
        curl_err="$(tr -d '\r' < "${tmp_err}" | head -c 200)"

        if [[ "${curl_exit}" -ne 0 ]]; then
            local hint=''
            case "${curl_exit}" in
                6)  hint=' (DNS resolution failed — check container egress / DNS)' ;;
                7)  hint=' (connection refused — check egress firewall to api.github.com:443)' ;;
                28) hint=' (request timed out — slow or blocked egress)' ;;
                35|60) hint=' (TLS error — check time sync / CA bundle)' ;;
            esac
            err="curl exit ${curl_exit}${hint}: ${curl_err:-<no stderr>}"
            log "warn" "GitHub runners API fetch failed: ${err}" >&2
            rm -f "${tmp_err}"
            return 1
        fi

        if [[ "${http}" != 2* ]]; then
            local hint=''
            # shellcheck disable=SC2016  # backticks in hints are markdown-style docs, not command subs
            case "${http}" in
                401) hint=' — token is invalid, expired, or revoked. Rotate GITHUB_PAT (`balena env set GITHUB_PAT ...`).' ;;
                403) hint=' — likely SAML enforcement on a classic PAT (open https://github.com/settings/tokens, edit PAT, Configure SSO → Authorize for the org) OR primary rate limit. Check `X-RateLimit-Remaining` from `curl -I` if SSO is already authorized.' ;;
                404) hint=' — RUNNERS_API_URL not found. Verify RUNNER_URL points at a real org/repo/enterprise that the token can see.' ;;
                5*) hint=' — GitHub API server error. Usually transient; check https://www.githubstatus.com.' ;;
            esac
            local body_excerpt
            body_excerpt="$(printf '%s' "${body}" | tr -d '\r\n' | head -c 200)"
            err="HTTP ${http}${hint} body=\"${body_excerpt}\""
            log "warn" "GitHub runners API fetch failed: ${err}" >&2
            rm -f "${tmp_err}"
            return 1
        fi

        page_runners="$(jq -c '.runners // []' <<< "${body}" 2>/dev/null)" || {
            log "warn" "GitHub runners API fetch failed: jq parse error on page ${page} (body not JSON)" >&2
            rm -f "${tmp_err}"
            return 1
        }
        count="$(jq 'length' <<< "${page_runners}" 2>/dev/null || echo 0)"
        acc="$(jq -c -s 'add' <<< "${acc}${page_runners}" 2>/dev/null)" || {
            log "warn" "GitHub runners API fetch failed: jq merge error on page ${page}" >&2
            rm -f "${tmp_err}"
            return 1
        }
        [[ "${count}" -lt 100 ]] && break
        page=$((page + 1))
    done
    rm -f "${tmp_err}"
    printf '%s' "${acc}" | _apply_scope_filter
}

# Refresh RUNNERS_JSON_CACHE. Returns non-zero on API failure so the caller
# can skip the cycle cleanly (fixes the pre-existing silent-failure where
# `read <<< "$(get_runner_counts)"` always succeeded even when the API was
# unreachable, masking outages as "0 online, 0 busy"). `_fetch_runners_json`
# has already logged the detailed diagnostic to stderr before returning, so
# this function stays quiet on the failure path to avoid double-logging.
refresh_runners_cache() {
    local fresh
    if ! fresh="$(_fetch_runners_json)"; then
        return 1
    fi
    RUNNERS_JSON_CACHE="${fresh}"
}

# Echoes "online busy" from the cache.
cached_runner_counts() {
    local online busy
    online="$(jq '[ .[] | select(.status == "online") ] | length' <<< "${RUNNERS_JSON_CACHE}" 2>/dev/null || echo 0)"
    busy="$(jq   '[ .[] | select(.status == "online" and .busy == true) ] | length' <<< "${RUNNERS_JSON_CACHE}" 2>/dev/null || echo 0)"
    echo "${online} ${busy}"
}

# Newline-separated names of online + idle (busy=false) runners.
cached_idle_runner_names() {
    jq -r '.[] | select(.status == "online" and .busy == false) | .name' \
        <<< "${RUNNERS_JSON_CACHE}" 2>/dev/null
}

# ── Backend: compose ─────────────────────────────────────────────────────────
_compose_get_current_replicas() {
    docker compose "${COMPOSE_ARGS[@]}" ps --format json "${COMPOSE_SERVICE}" 2>/dev/null \
        | jq -s 'length' 2>/dev/null || echo 0
}

_compose_scale_to() {
    local target="$1"
    log "info" "Scaling ${COMPOSE_SERVICE} to ${target} replicas (compose)..."
    if docker compose "${COMPOSE_ARGS[@]}" up -d --scale "${COMPOSE_SERVICE}=${target}" --no-recreate 2>&1; then
        log "info" "Scale to ${target} successful"
        return 0
    fi
    log "warn" "Scale command failed"
    return 1
}

# Stop specific replicas by GitHub runner name. Resolves each name to a local
# container ID via container hostname / explicit name, then `docker stop`s it.
# Prints the number of actually-retired containers to stdout (0 on full fail).
_compose_remove_by_names() {
    local retired=0 name cid
    for name in "$@"; do
        [[ -z "${name}" ]] && continue
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
    done
    # Reconcile compose's view; stopped containers still count as replicas in
    # `compose ps` until reaped.
    if [[ "${retired}" -gt 0 ]]; then
        docker compose "${COMPOSE_ARGS[@]}" rm -fsv "${COMPOSE_SERVICE}" >/dev/null 2>&1 || true
    fi
    echo "${retired}"
}

# ── Backend: exec ────────────────────────────────────────────────────────────
# SCALE_EXEC is operator-supplied (set via env when launching the sidecar) and
# may legitimately contain arguments (e.g. SCALE_EXEC="kubectl -n ci"), so we
# intentionally leave it unquoted to allow word-splitting. It is NEVER derived
# from runner-supplied input.
_exec_get_current_replicas() {
    local out
    # shellcheck disable=SC2086
    if out="$(${SCALE_EXEC} count 2>/dev/null)"; then
        out="${out//[[:space:]]/}"
        if [[ "${out}" =~ ^[0-9]+$ ]]; then
            echo "${out}"
            return 0
        fi
    fi
    log "warn" "exec backend: '${SCALE_EXEC} count' did not return a non-negative integer (got: '${out:-}')"
    echo 0
}

_exec_scale_to() {
    local target="$1"
    log "info" "Scaling to ${target} replicas via SCALE_EXEC scale ${target}"
    # shellcheck disable=SC2086
    if ${SCALE_EXEC} scale "${target}"; then
        log "info" "Scale to ${target} successful"
        return 0
    fi
    log "warn" "exec backend: scale ${target} failed"
    return 1
}

# Optional graceful-down. If SCALE_EXEC_SUPPORTS_REMOVE=true, invoke
# `$SCALE_EXEC remove <name>...`. Print retired count on success, return
# non-zero (with no stdout) to signal the caller to fall back to naive
# scale-to-target.
_exec_remove_by_names() {
    if [[ "${SCALE_EXEC_SUPPORTS_REMOVE}" != "true" ]]; then
        return 1
    fi
    log "info" "Retiring ${#} idle runner(s) via SCALE_EXEC remove"
    # shellcheck disable=SC2086
    if ${SCALE_EXEC} remove "$@"; then
        echo "${#}"
        return 0
    fi
    log "warn" "exec backend: remove failed"
    return 1
}

# ── Backend: emit ────────────────────────────────────────────────────────────
# Emit mode never scales locally; the main loop calls _emit_state directly
# each cycle. Dispatchers below handle emit with inline no-ops, so there are
# no `_emit_get_current_replicas`-style stubs to maintain.
_emit_state() {
    local target="$1" current="$2" online="$3" busy="$4" idle_names="$5"
    local idle_json='[]'
    if [[ -n "${idle_names}" ]]; then
        idle_json="$(printf '%s\n' "${idle_names}" \
            | awk 'NF' \
            | jq -R . | jq -s . 2>/dev/null || echo '[]')"
    fi
    local tmp="${SCALE_EMIT_FILE}.tmp.$$"
    cat > "${tmp}" <<JSON
{
  "ts": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')",
  "backend": "emit",
  "target": ${target},
  "current": ${current},
  "online": ${online},
  "busy": ${busy},
  "idle_runner_names": ${idle_json}
}
JSON
    mv -f "${tmp}" "${SCALE_EMIT_FILE}"
}

# ── Backend dispatchers ──────────────────────────────────────────────────────
backend_get_current_replicas() {
    case "${SCALE_BACKEND}" in
        compose) _compose_get_current_replicas ;;
        exec)    _exec_get_current_replicas ;;
        emit)    echo 0 ;;
    esac
}

backend_scale_to() {
    case "${SCALE_BACKEND}" in
        compose) _compose_scale_to "$1" ;;
        exec)    _exec_scale_to "$1" ;;
        emit)    return 0 ;;
    esac
}

# Returns retired count via stdout on success; non-zero exit (with no stdout)
# means "backend does not support targeted removal; caller should fall back
# to naive scale_to(target)."
backend_remove_by_names() {
    case "${SCALE_BACKEND}" in
        compose) _compose_remove_by_names "$@" ;;
        exec)    _exec_remove_by_names "$@" ;;
        emit)    return 1 ;;
    esac
}

# ── Graceful scale-down ──────────────────────────────────────────────────────
# In ephemeral mode each container handles exactly ONE job and then exits;
# capacity for concurrent jobs is the replica count. A naive scale-to=N call
# typically removes replicas in the orchestrator's own index order, NOT by
# busy/idle state — so it can abort an in-flight job. This function:
#
#   1. Asks GitHub which runners are currently online + idle (busy=false).
#   2. Selects the first `need` idle runner names.
#   3. Asks the active backend to remove those specific replicas via
#      `backend_remove_by_names`. Backends signal lack of support by
#      returning non-zero — in that case we fall back to a naive
#      `backend_scale_to(target)` which the operator should configure to be
#      safe for their orchestrator (e.g. `kubectl delete pod` of the picked
#      pod and let the Deployment reconcile).
#   4. If no idle runners are available we DO NOT kill busy containers; we
#      keep the current count and retry next interval. This trades a slower
#      scale-down for never aborting a user's workflow.
graceful_scale_down() {
    local target="$1"
    local current="$2"
    local need=$(( current - target ))

    if [[ "${need}" -le 0 ]]; then
        return 0
    fi

    log "info" "Graceful scale-down: need to retire ${need} idle replica(s) (target=${target})"

    local idle_names
    idle_names="$(cached_idle_runner_names)"
    if [[ -z "${idle_names}" ]]; then
        log "info" "No idle runners available to retire -- deferring scale-down"
        return 1
    fi

    # Pick the first `need` idle names.
    local picked=()
    local name
    while IFS= read -r name; do
        [[ -z "${name}" ]] && continue
        picked+=("${name}")
        [[ "${#picked[@]}" -ge "${need}" ]] && break
    done <<< "${idle_names}"

    if [[ "${#picked[@]}" -eq 0 ]]; then
        log "info" "No idle runners selectable -- deferring scale-down"
        return 1
    fi

    # Try backend-native targeted removal first.
    local retired
    if retired="$(backend_remove_by_names "${picked[@]}")" \
        && [[ -n "${retired}" ]] && [[ "${retired}" -gt 0 ]]; then
        local new_target=$(( current - retired ))
        if [[ "${new_target}" -lt "${target}" ]]; then
            new_target="${target}"
        fi
        backend_scale_to "${new_target}"
        return 0
    fi

    log "info" "Backend ${SCALE_BACKEND} does not support targeted removal -- falling back to naive scale_to(${target})"
    backend_scale_to "${target}"
}

# ── Banner ────────────────────────────────────────────────────────────────────
log "info" "═══════════════════════════════════════════════════════"
log "info" "  GitHub Actions Runner Autoscaler"
log "info" "═══════════════════════════════════════════════════════"
log "info" "  Backend      : ${SCALE_BACKEND}"
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
if [[ -n "${RUNNER_SCOPE_LABELS}" || -n "${RUNNER_SCOPE_NAME_REGEX}" ]]; then
    log "info" "  Scope labels : ${RUNNER_SCOPE_LABELS:-<none>}"
    log "info" "  Scope regex  : ${RUNNER_SCOPE_NAME_REGEX:-<none>}"
else
    log "info" "  Scope filter : <none> -- counting ALL runners in ${RUNNER_URL}"
fi
case "${SCALE_BACKEND}" in
    compose) log "info" "  Compose svc  : ${COMPOSE_SERVICE} (file: ${COMPOSE_FILE})" ;;
    exec)    log "info" "  Exec cmd     : ${SCALE_EXEC} (supports_remove=${SCALE_EXEC_SUPPORTS_REMOVE})" ;;
    emit)    log "info" "  Emit file    : ${SCALE_EMIT_FILE}" ;;
esac
log "info" "═══════════════════════════════════════════════════════"

# ── Fixed mode: set to MAX and hold ──────────────────────────────────────────
if [[ "${SCALE_MODE}" == "fixed" ]]; then
    log "info" "Fixed mode: scaling to SCALE_MAX=${SCALE_MAX} and holding"
    backend_scale_to "${SCALE_MAX}"

    while true; do
        sleep "${SCALE_INTERVAL}"

        if [[ "${SCALE_BACKEND}" == "emit" ]]; then
            # Emit mode: publish state every cycle. No replica enforcement.
            if refresh_runners_cache; then
                read -r ONLINE BUSY <<< "$(cached_runner_counts)"
                _emit_state "${SCALE_MAX}" 0 "${ONLINE}" "${BUSY}" "$(cached_idle_runner_names)"
            fi
            # refresh_runners_cache logs its own detailed diagnostic on
            # failure; no generic skip-cycle warning needed here.
            continue
        fi

        current="$(backend_get_current_replicas)"
        if [[ "${current}" -ne "${SCALE_MAX}" ]]; then
            log "warn" "Expected ${SCALE_MAX} replicas but found ${current}, correcting..."
            backend_scale_to "${SCALE_MAX}"
        fi
    done
fi

# ── Auto mode: main scaling loop ─────────────────────────────────────────────
LAST_SCALE_TIME=0

# Ensure minimum runners are up (no-op for emit backend).
backend_scale_to "${SCALE_MIN}"

while true; do
    sleep "${SCALE_INTERVAL}"

    NOW="$(date +%s)"

    if ! refresh_runners_cache; then
        # refresh_runners_cache logged the detailed reason already.
        continue
    fi

    CURRENT="$(backend_get_current_replicas)"
    read -r ONLINE BUSY <<< "$(cached_runner_counts)"
    IDLE=$((ONLINE - BUSY))

    # Calculate busy percentage (avoid division by zero). In emit mode CURRENT
    # is always 0, so fall back to ONLINE as the denominator so the threshold
    # logic still produces a sensible target count in the emitted state file.
    if [[ "${CURRENT}" -gt 0 ]]; then
        BUSY_PCT=$(( (BUSY * 100) / CURRENT ))
    elif [[ "${SCALE_BACKEND}" == "emit" && "${ONLINE}" -gt 0 ]]; then
        BUSY_PCT=$(( (BUSY * 100) / ONLINE ))
    else
        BUSY_PCT=0
    fi

    log "info" "Status: backend=${SCALE_BACKEND} replicas=${CURRENT} online=${ONLINE} busy=${BUSY} idle=${IDLE} busy%=${BUSY_PCT}%"

    # Emit mode: compute the proposed target using ONLINE (since CURRENT=0)
    # and publish state every cycle regardless of cooldown. External systems
    # decide whether to act.
    if [[ "${SCALE_BACKEND}" == "emit" ]]; then
        TARGET_FOR_EMIT="${ONLINE}"
        if [[ "${BUSY_PCT}" -ge "${SCALE_UP_THRESHOLD}" && "${ONLINE}" -lt "${SCALE_MAX}" ]]; then
            TARGET_FOR_EMIT=$(( ONLINE + 1 ))
        elif [[ "${BUSY_PCT}" -le "${SCALE_DOWN_THRESHOLD}" && "${ONLINE}" -gt "${SCALE_MIN}" ]]; then
            TARGET_FOR_EMIT=$(( ONLINE - 1 ))
        fi
        TARGET_FOR_EMIT="$(clamp "${TARGET_FOR_EMIT}" "${SCALE_MIN}" "${SCALE_MAX}")"
        _emit_state "${TARGET_FOR_EMIT}" "${CURRENT}" "${ONLINE}" "${BUSY}" "$(cached_idle_runner_names)"
        continue
    fi

    # Cooldown check (skip scaling action, but status was already logged)
    SINCE_LAST=$(( NOW - LAST_SCALE_TIME ))
    if [[ "${SINCE_LAST}" -lt "${SCALE_COOLDOWN}" ]]; then
        continue
    fi

    # Scale-up: if busy ratio exceeds threshold and we're below MAX
    if [[ "${BUSY_PCT}" -ge "${SCALE_UP_THRESHOLD}" && "${CURRENT}" -lt "${SCALE_MAX}" ]]; then
        NEW_COUNT="$(clamp $((CURRENT + 1)) "${SCALE_MIN}" "${SCALE_MAX}")"
        log "info" "Busy ratio ${BUSY_PCT}% >= ${SCALE_UP_THRESHOLD}% → scaling up to ${NEW_COUNT}"
        if backend_scale_to "${NEW_COUNT}"; then
            LAST_SCALE_TIME="${NOW}"
        fi
        continue
    fi

    # Scale-down: if busy ratio is below threshold and we're above MIN
    if [[ "${BUSY_PCT}" -le "${SCALE_DOWN_THRESHOLD}" && "${CURRENT}" -gt "${SCALE_MIN}" ]]; then
        NEW_COUNT="$(clamp $((CURRENT - 1)) "${SCALE_MIN}" "${SCALE_MAX}")"
        log "info" "Busy ratio ${BUSY_PCT}% <= ${SCALE_DOWN_THRESHOLD}% → graceful scale-down to ${NEW_COUNT}"
        if graceful_scale_down "${NEW_COUNT}" "${CURRENT}"; then
            LAST_SCALE_TIME="${NOW}"
        fi
        continue
    fi
done
