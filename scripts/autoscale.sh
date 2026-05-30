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
#                        like. Optional env: SCALE_EMIT_FILE=<path>
#                        (defaults to /scaler/state.json).
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
#   SCALE_EMIT_FILE — Default /scaler/state.json. Path to write JSON state file.
#
# Usage:
#   Typically run as a compose service — see the Autoscaling section in README.md.
#   Can also be run standalone:  RUNNER_URL=... GITHUB_PAT=... ./scripts/autoscale.sh
#
# Source layout vs runtime layout:
#   This file lives at `scripts/autoscale.sh` in the repo (single source of
#   truth, easy to clone-and-run on a developer workstation without building
#   the image first). The Dockerfile COPYs it to
#   `/usr/local/bin/gh-runner-autoscale` at image build time so it sits next
#   to the rest of the image's tooling (entrypoint, healthcheck, log /
#   banner / gh-api shared helpers). It is intentionally NOT an s6
#   service inside the runner container: it runs as a SEPARATE SIDECAR
#   container (RUNNER_ROLE=autoscaler) supervised by Docker / balena-engine
#   / k8s itself, so it can scale the runner pool from outside without
#   competing with the runner's own s6 supervision tree.
# =============================================================================
set -uo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
# Startup-only (changing these mid-loop is unsafe — they pick the whole code
# path, drive the loop sleep, or validate filesystem mounts that can't be
# moved at runtime). A Balena fleet/device variable change to any of these
# still applies — the supervisor restarts the scaler service (~30 s) and
# the new value takes effect on the next start.
SCALE_BACKEND="${SCALE_BACKEND:-compose}"
SCALE_INTERVAL="${SCALE_INTERVAL:-30}"
# Compose backend (startup-only)
COMPOSE_SERVICE="${COMPOSE_SERVICE:-gh-runner}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
# Exec backend (startup-only)
SCALE_EXEC="${SCALE_EXEC:-}"
SCALE_EXEC_SUPPORTS_REMOVE="${SCALE_EXEC_SUPPORTS_REMOVE:-false}"
# Emit backend (startup-only)
# Default to /scaler/state.json -- the Dockerfile pre-creates /scaler
# with mode 0700 so this Just Works without any extra compose config
# when SCALE_BACKEND=emit. Override to redirect to a bind-mounted
# volume shared with a workflow / sidecar that consumes the state.
SCALE_EMIT_FILE="${SCALE_EMIT_FILE:-/scaler/state.json}"

# ── Pure-policy defaults (re-read every cycle) ───────────────────────────────
# The variables in this block, the scope filters below, and the threshold
# defaults are re-read at the top of each loop iteration via
# `_refresh_policy_vars()` so a Balena dashboard change (or any other
# external env mutation visible to PID 1) takes effect on the NEXT
# SCALE_INTERVAL tick without waiting for the supervisor restart Balena
# auto-triggers on env-var changes. The startup assignments below give
# the initial values; `_refresh_policy_vars` re-applies the same
# `${VAR:-default}` + clamp logic each cycle and logs a one-line diff if
# anything changed.
SCALE_MIN="${SCALE_MIN:-1}"
SCALE_MAX="${SCALE_MAX:-1}"
SCALE_MODE="${SCALE_MODE:-auto}"
SCALE_COOLDOWN="${SCALE_COOLDOWN:-60}"
SCALE_UP_THRESHOLD="${SCALE_UP_THRESHOLD:-80}"
SCALE_DOWN_THRESHOLD="${SCALE_DOWN_THRESHOLD:-20}"
# Per-fleet scope filters (also re-read each cycle)
RUNNER_SCOPE_LABELS="${RUNNER_SCOPE_LABELS:-}"
RUNNER_SCOPE_NAME_REGEX="${RUNNER_SCOPE_NAME_REGEX:-}"

# ---------------------------------------------------------------------------
# Logging
#
# Prefer the shared /usr/local/bin/log-functions.sh that the rest of the
# runner image uses, so the scaler sidecar logs in the same format and
# respects the same LOG_LEVEL knob as the s6 init/svc scripts. Falls back
# to an inline minimal `log()` if the shared helper is missing (e.g. when
# running this script standalone on a developer workstation for testing).
#
# Format (both implementations):
#     <RFC3339 UTC timestamp> autoscaler[<level>]: <message>
#
# All scaler output goes to stdout (the entrypoint's stdout is what
# `docker logs` / balenaCloud captures); diagnostic failure paths inside
# `_fetch_runners_json` deliberately redirect to stderr so they bypass the
# `$()` JSON capture in `refresh_runners_cache` while still landing in the
# same combined log stream the operator sees.
# ---------------------------------------------------------------------------
LOG_TAG="autoscaler"
if [[ -r /usr/local/bin/log-functions.sh ]]; then
    # shellcheck disable=SC1091
    . /usr/local/bin/log-functions.sh
else
    log() {
        printf '%s %s[%s]: %s\n' \
            "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
            "${LOG_TAG:-autoscaler}" \
            "$1" \
            "$2"
    }
fi

# Banner primitives -- shared with the runner heartbeat so AUTOSCALER STATUS
# blocks have the same shape as HEALTH HEARTBEAT blocks in the same log
# stream. Standalone (dev workstation) execution falls back to inline
# definitions so the script stays self-contained.
if [[ -r /usr/local/bin/banner-functions.sh ]]; then
    # shellcheck disable=SC1091
    . /usr/local/bin/banner-functions.sh
else
    : "${BANNER_LINE:======================================================================}"
    : "${BANNER_THIN:=----------------------------------------------------------------------}"
    : "${BANNER_KEY_WIDTH:=17}"
    banner_top()    { log "${1:-info}" "${BANNER_LINE}"; }
    banner_bottom() { log "${1:-info}" "${BANNER_LINE}"; }
    banner_thin()   { log "${1:-info}" "${BANNER_THIN}"; }
    banner_title()  { local _l="$1"; shift; log "${_l}" "  *** $* ***"; }
    banner_kv() {
        local _l="$1" _k="$2" _v="$3" _p
        printf -v _p '%-*s' "${BANNER_KEY_WIDTH}" "${_k}"
        log "${_l}" "    ${_p}: ${_v}"
    }
    banner_section() {
        local _l="$1" _h="$2"
        log "${_l}" "  [${_h}]"
        log "${_l}" "  - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
    }
fi

# Runners-URL resolver -- shared with the runner heartbeat probe and the
# init-time registration helpers. Standalone fallback for dev workstations
# that run autoscale.sh outside the container image.
if [[ -r /usr/local/bin/gh-api.sh ]]; then
    # shellcheck disable=SC1091
    . /usr/local/bin/gh-api.sh
else
    gh_api_runners_url() {
        local raw="${1:-}" url_path
        url_path="${raw#https://github.com/}"
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
fi

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

if [[ "${SCALE_INTERVAL}" -lt 1 ]] 2>/dev/null; then
    log "warn" "SCALE_INTERVAL must be >= 1, setting to 1"
    SCALE_INTERVAL=1
fi

# ---------------------------------------------------------------------------
# Pure-policy refresher
#
# Re-reads the SCALE_* policy knobs and per-fleet scope filters from the
# current environment, re-applies clamping/normalization, and (on change)
# logs a one-line diff so operators see when a Balena dashboard tweak
# took effect mid-loop. Idempotent: safe to call once at startup and again
# at the top of every scaling cycle.
#
# Strictly off-limits for this helper (they live above as startup-only):
#   SCALE_BACKEND      — selects whole code path (compose/exec/emit
#                        validation + emit-file mount check happen once)
#   SCALE_INTERVAL     — the in-flight `sleep` is already scheduled; a
#                        change to the next sleep only takes effect on
#                        the cycle after that, so just defer to the
#                        supervisor restart Balena triggers anyway
#   SCALE_EMIT_FILE / SCALE_EXEC / SCALE_EXEC_SUPPORTS_REMOVE / COMPOSE_*
#                      — validated at startup or used in pre-computed
#                        arg arrays; restart-on-change is correct
#   RUNNER_URL / GITHUB_PAT — security-sensitive; restart is appropriate
#
# Vars covered (all are pure policy with zero side effects when re-read):
#   SCALE_MIN, SCALE_MAX, SCALE_MODE, SCALE_COOLDOWN,
#   SCALE_UP_THRESHOLD, SCALE_DOWN_THRESHOLD,
#   RUNNER_SCOPE_LABELS, RUNNER_SCOPE_NAME_REGEX
# ---------------------------------------------------------------------------

# Module-global snapshot for change detection. Initialized empty so the
# first call logs the resolved values (operator confirmation that the
# refresher saw the startup env). After that we only log on actual change.
_POLICY_VARS_SNAPSHOT=""
_SCOPE_LABELS_JSON='[]'

_refresh_policy_vars() {
    # --- SCALE_MIN ---
    local new_min="${SCALE_MIN:-1}"
    if ! [[ "${new_min}" =~ ^[0-9]+$ ]] || [[ "${new_min}" -lt 1 ]]; then
        new_min=1
    fi
    # --- SCALE_MAX (>= SCALE_MIN) ---
    local new_max="${SCALE_MAX:-1}"
    if ! [[ "${new_max}" =~ ^[0-9]+$ ]] || [[ "${new_max}" -lt 1 ]]; then
        new_max=1
    fi
    if [[ "${new_max}" -lt "${new_min}" ]]; then
        new_max="${new_min}"
    fi
    # --- SCALE_MODE (auto|fixed; anything else falls back to auto) ---
    local new_mode="${SCALE_MODE:-auto}"
    case "${new_mode}" in
        auto|fixed) : ;;
        *)          new_mode="auto" ;;
    esac
    # --- SCALE_COOLDOWN ---
    local new_cooldown="${SCALE_COOLDOWN:-60}"
    if ! [[ "${new_cooldown}" =~ ^[0-9]+$ ]]; then
        new_cooldown=60
    fi
    # --- SCALE_UP_THRESHOLD (0..100 inclusive) ---
    local new_up="${SCALE_UP_THRESHOLD:-80}"
    if ! [[ "${new_up}" =~ ^[0-9]+$ ]] || [[ "${new_up}" -gt 100 ]]; then
        new_up=80
    fi
    # --- SCALE_DOWN_THRESHOLD (0..SCALE_UP_THRESHOLD) ---
    local new_down="${SCALE_DOWN_THRESHOLD:-20}"
    if ! [[ "${new_down}" =~ ^[0-9]+$ ]] || [[ "${new_down}" -gt "${new_up}" ]]; then
        new_down=20
        if [[ "${new_down}" -gt "${new_up}" ]]; then
            new_down="${new_up}"
        fi
    fi
    # --- Scope: name regex (validate against jq; bad regex → drop filter) ---
    local new_regex="${RUNNER_SCOPE_NAME_REGEX:-}"
    if [[ -n "${new_regex}" ]]; then
        if ! echo "x" | jq -Rr --arg r "${new_regex}" '. | test($r)' >/dev/null 2>&1; then
            log "warn" "RUNNER_SCOPE_NAME_REGEX='${new_regex}' is not a valid jq regex — ignoring filter for this cycle"
            new_regex=""
        fi
    fi
    # --- Scope: required label set (normalize → JSON array of lowercased) ---
    local new_labels_json='[]'
    if [[ -n "${RUNNER_SCOPE_LABELS:-}" ]]; then
        new_labels_json="$(printf '%s' "${RUNNER_SCOPE_LABELS}" \
            | tr ',' '\n' \
            | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
            | awk 'NF' \
            | tr '[:upper:]' '[:lower:]' \
            | jq -R . | jq -c -s '.')"
        if [[ -z "${new_labels_json}" || "${new_labels_json}" == "null" ]]; then
            new_labels_json='[]'
        fi
    fi

    # Snapshot for change detection — single | -delimited line so we
    # don't have to compare 8 vars individually each cycle.
    local snap="${new_min}|${new_max}|${new_mode}|${new_cooldown}|${new_up}|${new_down}|${new_labels_json}|${new_regex}"
    if [[ "${snap}" != "${_POLICY_VARS_SNAPSHOT}" ]]; then
        if [[ -z "${_POLICY_VARS_SNAPSHOT}" ]]; then
            log "info" "policy: MIN=${new_min} MAX=${new_max} MODE=${new_mode} COOLDOWN=${new_cooldown}s UP=${new_up}% DOWN=${new_down}% scope_labels=${new_labels_json} scope_name_regex='${new_regex}'"
        else
            log "info" "policy changed: MIN=${SCALE_MIN}->${new_min} MAX=${SCALE_MAX}->${new_max} MODE=${SCALE_MODE}->${new_mode} COOLDOWN=${SCALE_COOLDOWN}->${new_cooldown}s UP=${SCALE_UP_THRESHOLD}->${new_up}% DOWN=${SCALE_DOWN_THRESHOLD}->${new_down}% scope_labels=${_SCOPE_LABELS_JSON}->${new_labels_json} scope_name_regex='${RUNNER_SCOPE_NAME_REGEX}'->'${new_regex}'"
        fi
        _POLICY_VARS_SNAPSHOT="${snap}"
    fi

    # Commit normalized values back to the module globals every cycle.
    SCALE_MIN="${new_min}"
    SCALE_MAX="${new_max}"
    SCALE_MODE="${new_mode}"
    SCALE_COOLDOWN="${new_cooldown}"
    SCALE_UP_THRESHOLD="${new_up}"
    SCALE_DOWN_THRESHOLD="${new_down}"
    RUNNER_SCOPE_NAME_REGEX="${new_regex}"
    _SCOPE_LABELS_JSON="${new_labels_json}"
}

# Initial population: runs ONCE before the loop so the validation/clamping
# is applied to startup-time values and the snapshot is seeded. Cycle-time
# calls happen at the top of each scaling loop iteration below.
_refresh_policy_vars

case "${SCALE_BACKEND}" in
    exec)
        if [[ -z "${SCALE_EXEC}" ]]; then
            log "fatal" "SCALE_BACKEND=exec requires SCALE_EXEC=<path or command>"
            exit 1
        fi
        ;;
    emit)
        # SCALE_EMIT_FILE has a built-in default of /scaler/state.json
        # (see defaults block above) so the empty-string fatal would be
        # dead code -- but we still need to fail fast if an operator
        # explicitly cleared it via `-e SCALE_EMIT_FILE=` (which the
        # `${VAR:-default}` form would NOT catch had they passed it as
        # an arg that bash sees as unset; defensive check kept for
        # cases where the default block is bypassed).
        if [[ -z "${SCALE_EMIT_FILE}" ]]; then
            log "fatal" "SCALE_BACKEND=emit requires SCALE_EMIT_FILE=<path>"
            exit 1
        fi
        # Ensure the emit file's parent dir exists. On Balena/balena-engine,
        # tmpfs mount targets are NOT auto-created if the path doesn't
        # already exist in the image filesystem — the mount silently fails
        # to materialize and every write hits:
        #   line N: <path>.tmp.<pid>: No such file or directory
        # The Dockerfile pre-creates the default /scaler mountpoint, but a
        # caller-supplied SCALE_EMIT_FILE pointing elsewhere needs the same
        # guarantee. Failing fast here is safer than spinning for hours
        # logging mv errors every cycle.
        _emit_dir="$(dirname "${SCALE_EMIT_FILE}")"
        if ! mkdir -p "${_emit_dir}" 2>/dev/null; then
            log "fatal" "Cannot create SCALE_EMIT_FILE parent dir '${_emit_dir}' -- check container filesystem mounts"
            exit 1
        fi
        if ! ( : > "${SCALE_EMIT_FILE}.writetest.$$" ) 2>/dev/null; then
            log "fatal" "SCALE_EMIT_FILE parent dir '${_emit_dir}' is not writable -- check tmpfs mount mode (need owner-writable for container UID $(id -u))"
            exit 1
        fi
        rm -f "${SCALE_EMIT_FILE}.writetest.$$"
        unset _emit_dir
        ;;
esac

# Scope regex / labels validation + `_SCOPE_LABELS_JSON` normalization
# both moved up into `_refresh_policy_vars()` (callable each cycle).
# Bad regex no longer aborts startup — it now drops the filter for that
# cycle with a warn log, so a typo in the Balena dashboard is recoverable
# without losing the running sidecar.

# Pre-compute compose CLI args once (never change at runtime).
COMPOSE_ARGS=(-f "${COMPOSE_FILE}")
[[ -n "${COMPOSE_PROJECT}" ]] && COMPOSE_ARGS+=(-p "${COMPOSE_PROJECT}")

# ── Resolve API URL ──────────────────────────────────────────────────────────
# Delegated to the shared gh_api_runners_url helper so the heartbeat probe,
# the init-time registration helpers, and this autoscaler all agree on the
# URL shape for repo/org/enterprise runners.
RUNNERS_API_URL="$(gh_api_runners_url "${RUNNER_URL}")"

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
    local attempt curl_exit_first
    local tmp_err
    tmp_err="$(mktemp 2>/dev/null || echo /tmp/autoscale-curl-err.$$)"
    while [[ "${page}" -le 10 ]]; do
        # `-w '\nHTTPSTATUS:%{http_code}'` appends the final HTTP status on
        # its own line so we can tease it apart even when curl exits 0.
        # Drop `-f` so curl returns 4xx/5xx bodies (useful for error text)
        # but still exits non-zero — handled below.
        #
        # Single in-cycle retry on transient connection-reset curl codes
        # (18 partial file, 52 empty reply, 55 send error, 56 recv error).
        # These are typically intermediate NAT keepalive timeouts or
        # GitHub edge sockets recycling mid-request and self-heal on the
        # next attempt. Other curl error classes (DNS/connect/TLS/timeout)
        # are NOT retried so genuine misconfiguration surfaces promptly.
        curl_exit_first=0
        for attempt in 1 2; do
            resp="$(curl -sSL \
                -w '\nHTTPSTATUS:%{http_code}' \
                -H "Authorization: token ${GITHUB_PAT}" \
                -H "Accept: application/vnd.github+json" \
                "${RUNNERS_API_URL}?per_page=100&page=${page}" 2>"${tmp_err}")"
            curl_exit=$?
            if [[ "${attempt}" -eq 1 ]]; then
                case "${curl_exit}" in
                    18|52|55|56)
                        curl_exit_first="${curl_exit}"
                        sleep 1
                        continue
                        ;;
                esac
            fi
            break
        done
        if [[ "${curl_exit_first}" -ne 0 && "${curl_exit}" -eq 0 ]]; then
            log "info" "GitHub runners API recovered after transient curl exit ${curl_exit_first} (one retry succeeded)" >&2
        fi
        http="${resp##*HTTPSTATUS:}"
        body="${resp%$'\n'HTTPSTATUS:*}"
        curl_err="$(tr -d '\r' < "${tmp_err}" | head -c 200)"

        if [[ "${curl_exit}" -ne 0 ]]; then
            local hint=''
            local retry_note=''
            [[ "${curl_exit_first}" -ne 0 ]] && retry_note=' (retried once after initial transient failure)'
            case "${curl_exit}" in
                6)  hint=' (DNS resolution failed — check container egress / DNS)' ;;
                7)  hint=' (connection refused — check egress firewall to api.github.com:443)' ;;
                18|52|55|56) hint=' (transient connection reset by GitHub edge or intermediate NAT — usually self-heals; investigate egress if persistent across multiple cycles)' ;;
                28) hint=' (request timed out — slow or blocked egress)' ;;
                35|60) hint=' (TLS error — check time sync / CA bundle)' ;;
            esac
            err="curl exit ${curl_exit}${hint}${retry_note}: ${curl_err:-<no stderr>}"
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

# Echoes "online busy offline" from the cache. `offline` is the count of
# runners whose GitHub-reported status is "offline" within the in-scope
# fleet -- typically stale registrations from earlier boots that crashed
# before deregistering (SIGKILL, host reboot, balena replace). The
# autoscaler does NOT delete them itself (that's the runner container's
# init-time `cleanup_stale_offline_runners` job), but it surfaces the
# count + names so operators can see them in the status banner and the
# emit-mode JSON state file consumed by external orchestrators.
cached_runner_counts() {
    local online busy offline
    online="$(jq  '[ .[] | select(.status == "online") ] | length' <<< "${RUNNERS_JSON_CACHE}" 2>/dev/null || echo 0)"
    busy="$(jq    '[ .[] | select(.status == "online" and .busy == true) ] | length' <<< "${RUNNERS_JSON_CACHE}" 2>/dev/null || echo 0)"
    offline="$(jq '[ .[] | select(.status == "offline") ] | length' <<< "${RUNNERS_JSON_CACHE}" 2>/dev/null || echo 0)"
    echo "${online} ${busy} ${offline}"
}

# Newline-separated names of online + idle (busy=false) runners.
cached_idle_runner_names() {
    jq -r '.[] | select(.status == "online" and .busy == false) | .name' \
        <<< "${RUNNERS_JSON_CACHE}" 2>/dev/null
}

# Newline-separated names of offline runners (any name, any labels within
# the active scope filter). Surfaced in the status banner and emit JSON
# so operators can spot dedup-suffix leftovers (e.g. `defiant-time-gh-runner-1`
# lingering after a SIGKILL'd previous boot). The runner container's init
# stage handles the actual DELETE via `cleanup_stale_offline_runners`.
cached_offline_runner_names() {
    jq -r '.[] | select(.status == "offline") | .name' \
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
    local target="$1" current="$2" online="$3" busy="$4" idle_names="$5" offline="${6:-0}" offline_names="${7:-}"
    local idle_json='[]'
    if [[ -n "${idle_names}" ]]; then
        idle_json="$(printf '%s\n' "${idle_names}" \
            | awk 'NF' \
            | jq -R . | jq -s . 2>/dev/null || echo '[]')"
    fi
    local offline_json='[]'
    if [[ -n "${offline_names}" ]]; then
        offline_json="$(printf '%s\n' "${offline_names}" \
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
  "offline": ${offline},
  "idle_runner_names": ${idle_json},
  "offline_runner_names": ${offline_json}
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

# Banner. ASCII '=' only -- balenaCloud's dashboard log viewer mangles
# Unicode box-drawing characters (U+2550 etc.) into 'a-circumflex' single-
# byte rendering. Uses the same shared banner helpers as the runner's
# HEALTH HEARTBEAT block so all multi-line log blocks look alike.
banner_top   "info"
banner_title "info" "GITHUB ACTIONS RUNNER AUTOSCALER"
banner_thin  "info"
banner_section "info" "Policy"
banner_kv "info" "Backend"       "${SCALE_BACKEND}"
banner_kv "info" "Mode"          "${SCALE_MODE}"
banner_kv "info" "Min replicas"  "${SCALE_MIN}"
banner_kv "info" "Max replicas"  "${SCALE_MAX}"
banner_kv "info" "Interval"      "${SCALE_INTERVAL}s"
banner_kv "info" "Cooldown"      "${SCALE_COOLDOWN}s"
if [[ "${SCALE_MODE}" == "auto" ]]; then
    banner_kv "info" "Scale-up at"   "${SCALE_UP_THRESHOLD}% busy"
    banner_kv "info" "Scale-down at" "${SCALE_DOWN_THRESHOLD}% busy"
fi
banner_section "info" "Scope"
banner_kv "info" "Runner URL"    "${RUNNER_URL}"
if [[ -n "${RUNNER_SCOPE_LABELS}" || -n "${RUNNER_SCOPE_NAME_REGEX}" ]]; then
    banner_kv "info" "Scope labels"  "${RUNNER_SCOPE_LABELS:-<none>}"
    banner_kv "info" "Scope regex"   "${RUNNER_SCOPE_NAME_REGEX:-<none>}"
else
    banner_kv "info" "Scope filter"  "<none> -- counting ALL runners in ${RUNNER_URL}"
fi
banner_section "info" "Backend Detail"
case "${SCALE_BACKEND}" in
    compose) banner_kv "info" "Compose svc"   "${COMPOSE_SERVICE} (file: ${COMPOSE_FILE})" ;;
    exec)    banner_kv "info" "Exec cmd"      "${SCALE_EXEC} (supports_remove=${SCALE_EXEC_SUPPORTS_REMOVE})" ;;
    emit)    banner_kv "info" "Emit file"     "${SCALE_EMIT_FILE}" ;;
esac
banner_bottom "info"

# _log_status_banner -- per-cycle status block matching the runner heartbeat
# shape. Reads loop globals (SCALE_BACKEND, SCALE_MODE, CURRENT, ONLINE,
# BUSY, IDLE, BUSY_PCT, LAST_SCALE_TIME, NOW). Called once per scaling
# cycle from both the auto and emit-in-auto paths.
_log_status_banner() {
    local cooldown_field="" last_action_field=""
    if [[ "${SCALE_BACKEND}" != "emit" ]]; then
        if (( LAST_SCALE_TIME > 0 )); then
            local since=$(( NOW - LAST_SCALE_TIME ))
            last_action_field="${since}s ago"
            if (( since < SCALE_COOLDOWN )); then
                cooldown_field="$(( SCALE_COOLDOWN - since ))s remaining"
            else
                cooldown_field="ready"
            fi
        else
            cooldown_field="ready (no action yet)"
            last_action_field="never"
        fi
    fi

    banner_top   "info"
    banner_title "info" "AUTOSCALER STATUS (${HOSTNAME:-$(hostname)})"
    banner_thin  "info"
    banner_section "info" "Pool"
    banner_kv "info" "Backend"         "${SCALE_BACKEND}"
    banner_kv "info" "Mode"            "${SCALE_MODE}"
    if [[ "${SCALE_BACKEND}" == "emit" ]]; then
        banner_kv "info" "Replicas"    "${CURRENT} (managed externally; min=${SCALE_MIN} max=${SCALE_MAX})"
    else
        banner_kv "info" "Replicas"    "${CURRENT} / max ${SCALE_MAX} (min ${SCALE_MIN})"
    fi
    banner_section "info" "Runners"
    banner_kv "info" "Online"          "${ONLINE}"
    banner_kv "info" "Busy"            "${BUSY}"
    banner_kv "info" "Idle"            "${IDLE}"
    banner_kv "info" "Offline"         "${OFFLINE:-0}"
    if [[ "${OFFLINE:-0}" -gt 0 && -n "${OFFLINE_NAMES_PREVIEW:-}" ]]; then
        banner_kv "info" "Offline names"   "${OFFLINE_NAMES_PREVIEW}"
    fi
    if [[ "${SCALE_MODE}" == "auto" ]]; then
        banner_kv "info" "Busy Percentage" "${BUSY_PCT}% (up>=${SCALE_UP_THRESHOLD}% / down<=${SCALE_DOWN_THRESHOLD}%)"
    else
        banner_kv "info" "Busy Percentage" "${BUSY_PCT}%"
    fi
    if [[ "${SCALE_BACKEND}" != "emit" ]]; then
        banner_section "info" "Scaling"
        banner_kv "info" "Cooldown"        "${cooldown_field}"
        banner_kv "info" "Last Action"     "${last_action_field}"
    fi
    banner_bottom "info"
}

# ── Fixed mode: set to MAX and hold ──────────────────────────────────────────
if [[ "${SCALE_MODE}" == "fixed" ]]; then
    log "info" "Fixed mode: scaling to SCALE_MAX=${SCALE_MAX} and holding"
    backend_scale_to "${SCALE_MAX}"

    while true; do
        sleep "${SCALE_INTERVAL}"

        # Re-read policy vars so a Balena dashboard change to SCALE_MIN/MAX
        # etc. applies on the next tick. In fixed mode SCALE_MAX is the
        # interesting one (target replica count); a mid-flight bump from 3
        # to 5 will be applied by the `current != SCALE_MAX` correction
        # block below within ONE cycle. SCALE_MODE flipping fixed->auto
        # is NOT honoured mid-loop on purpose — that's a structural change
        # and the supervisor restart Balena auto-triggers will pick it up
        # cleanly via the SCALE_MODE branch above.
        _refresh_policy_vars

        if [[ "${SCALE_BACKEND}" == "emit" ]]; then
            # Emit mode: publish state every cycle. No replica enforcement.
            if refresh_runners_cache; then
                read -r ONLINE BUSY OFFLINE <<< "$(cached_runner_counts)"
                OFFLINE_NAMES_FIXED="$(cached_offline_runner_names)"
                _emit_state "${SCALE_MAX}" 0 "${ONLINE}" "${BUSY}" "$(cached_idle_runner_names)" "${OFFLINE}" "${OFFLINE_NAMES_FIXED}"
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

    # Re-read pure-policy vars (SCALE_MIN/MAX/MODE/COOLDOWN/UP/DOWN +
    # RUNNER_SCOPE_*) so a Balena dashboard tweak applies on the next
    # tick without waiting for the supervisor restart. Startup-only vars
    # (SCALE_BACKEND, SCALE_INTERVAL, SCALE_EMIT_FILE, SCALE_EXEC,
    # COMPOSE_*, RUNNER_URL, GITHUB_PAT) deliberately stay snapshotted
    # at process start — see `_refresh_policy_vars` header for why.
    _refresh_policy_vars

    NOW="$(date +%s)"

    if ! refresh_runners_cache; then
        # refresh_runners_cache logged the detailed reason already.
        continue
    fi

    CURRENT="$(backend_get_current_replicas)"
    read -r ONLINE BUSY OFFLINE <<< "$(cached_runner_counts)"
    IDLE=$((ONLINE - BUSY))
    OFFLINE_NAMES="$(cached_offline_runner_names)"
    # Build a short comma-separated preview for the status banner (first
    # 5 names; truncate long lists with an ellipsis count). The full list
    # still goes into the emit JSON for downstream tooling.
    OFFLINE_NAMES_PREVIEW=""
    if [[ "${OFFLINE}" -gt 0 && -n "${OFFLINE_NAMES}" ]]; then
        OFFLINE_NAMES_PREVIEW="$(printf '%s\n' "${OFFLINE_NAMES}" | awk 'NF' | head -n 5 | paste -sd ',' -)"
        if [[ "${OFFLINE}" -gt 5 ]]; then
            OFFLINE_NAMES_PREVIEW="${OFFLINE_NAMES_PREVIEW} (+$((OFFLINE - 5)) more)"
        fi
    fi

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

    _log_status_banner

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
        _emit_state "${TARGET_FOR_EMIT}" "${CURRENT}" "${ONLINE}" "${BUSY}" "$(cached_idle_runner_names)" "${OFFLINE}" "${OFFLINE_NAMES}"
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
        log "info" "Busy ratio ${BUSY_PCT}% >= ${SCALE_UP_THRESHOLD}% -> scaling up to ${NEW_COUNT}"
        if backend_scale_to "${NEW_COUNT}"; then
            LAST_SCALE_TIME="${NOW}"
        fi
        continue
    fi

    # Scale-down: if busy ratio is below threshold and we're above MIN
    if [[ "${BUSY_PCT}" -le "${SCALE_DOWN_THRESHOLD}" && "${CURRENT}" -gt "${SCALE_MIN}" ]]; then
        NEW_COUNT="$(clamp $((CURRENT - 1)) "${SCALE_MIN}" "${SCALE_MAX}")"
        log "info" "Busy ratio ${BUSY_PCT}% <= ${SCALE_DOWN_THRESHOLD}% -> graceful scale-down to ${NEW_COUNT}"
        if graceful_scale_down "${NEW_COUNT}" "${CURRENT}"; then
            LAST_SCALE_TIME="${NOW}"
        fi
        continue
    fi
done
