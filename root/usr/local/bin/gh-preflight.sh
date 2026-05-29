#!/usr/bin/with-contenv bash
# shellcheck shell=bash
#
# Pre-flight permission / environment / API checks.
#
# Each check emits a single line with a [ OK ] / [WARN] / [FAIL] tag so
# they are easy to grep in container logs. FAIL increments PREFLIGHT_FAILED
# and aborts startup at the end of the block.
#
# The orchestrator runs in this order:
#   1. Required tools on PATH (curl, jq, tar)
#   2. Runner binary + scripts present and executable
#   3. abc can read the runner install dir / write the workdir
#   4. /config persistence dir is writable (warn if not)
#   5. Docker socket reachable (only when DOCKER_IN_DOCKER=true)
#   6. Auth token presence
#   7. GitHub API reachability + token scope inspection (parallel probes)
#   8. Cleanup-feature gate (when CLEANUP_OFFLINE_RUNNERS=true)
#

PREFLIGHT_FAILED=0
PREFLIGHT_WARNED=0

# preflight <status> <name> [<detail>]
# status: OK | WARN | FAIL
preflight() {
    local status="$1" name="$2" detail="${3:-}" tag
    case "${status}" in
        OK)   tag="[ OK ]" ;;
        WARN) tag="[WARN]"; PREFLIGHT_WARNED=$((PREFLIGHT_WARNED + 1)) ;;
        FAIL) tag="[FAIL]"; PREFLIGHT_FAILED=$((PREFLIGHT_FAILED + 1)) ;;
        *)    tag="[ ?? ]" ;;
    esac
    if [[ -n "${detail}" ]]; then
        log "info" "preflight ${tag} ${name} -- ${detail}"
    else
        log "info" "preflight ${tag} ${name}"
    fi
}

# gh_preflight_check_api
# Two parallel probes to api.github.com to collapse two sequential RTTs
# into one. Distinguishes auth (401/403) from scope (200 vs 403 on the
# scope-specific runners endpoint). When no token is supplied, falls back
# to a single unauth ping just to confirm DNS/egress.
gh_preflight_check_api() {
    local auth_token; auth_token="$(gh_api_auth_token)"

    if [[ -z "${auth_token}" ]]; then
        local conn_code
        conn_code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 6 \
            https://api.github.com 2>/dev/null || echo "000")"
        if [[ "${conn_code}" =~ ^(200|301|302)$ ]]; then
            preflight OK "github-api-reachable" "https://api.github.com (HTTP ${conn_code})"
        else
            preflight FAIL "github-api-reachable" "could not reach api.github.com (HTTP ${conn_code})"
            return
        fi
        preflight WARN "github-api-auth" \
            "no PAT/GITHUB_TOKEN -- runner-group sync, label sync, and stale-runner cleanup are disabled"
        return
    fi

    # Probe URL = scope-specific runners endpoint; reuses the same URL
    # resolver everything else uses.
    local probe_url scope_label
    probe_url="$(gh_api_runners_url)"
    case "$(gh_api_scope_kind)" in
        enterprise) scope_label="enterprise/${RUNNER_URL##*/}" ;;
        repo)       scope_label="repo/${RUNNER_URL#https://github.com/}" ;;
        org)        scope_label="org/${RUNNER_URL##*/}" ;;
    esac

    local user_hdr user_body_file scope_body_file
    user_hdr="$(mktemp)"
    user_body_file="$(mktemp)"
    scope_body_file="$(mktemp)"

    local t_start t_end t_ms
    t_start="$(date +%s%N)"

    # -f intentionally OMITTED: with -f, curl exits non-zero on 4xx and
    # never writes %{http_code}, masking auth/scope failures as '000'.
    ( curl -sS -o "${user_body_file}" -D "${user_hdr}" -w '%{http_code}' --max-time 6 \
        -H "Authorization: token ${auth_token}" \
        -H "Accept: application/vnd.github+json" \
        https://api.github.com/user 2>/dev/null > "${user_body_file}.code" ) &
    local user_pid=$!

    ( curl -sS -o "${scope_body_file}" -w '%{http_code}' --max-time 6 \
        -H "Authorization: token ${auth_token}" \
        -H "Accept: application/vnd.github+json" \
        "${probe_url}" 2>/dev/null > "${scope_body_file}.code" ) &
    local scope_pid=$!

    wait "${user_pid}"  2>/dev/null || true
    wait "${scope_pid}" 2>/dev/null || true

    t_end="$(date +%s%N)"
    t_ms=$(( (t_end - t_start) / 1000000 ))

    local body_code probe_code
    body_code="$(cat "${user_body_file}.code"  2>/dev/null || echo "000")"
    probe_code="$(cat "${scope_body_file}.code" 2>/dev/null || echo "000")"
    [[ -z "${body_code}"  ]] && body_code="000"
    [[ -z "${probe_code}" ]] && probe_code="000"

    if [[ "${body_code}" == "000" && "${probe_code}" == "000" ]]; then
        preflight FAIL "github-api-reachable" "could not reach api.github.com (both probes timed out / DNS failure)"
        rm -f "${user_hdr}" "${user_body_file}" "${user_body_file}.code" \
              "${scope_body_file}" "${scope_body_file}.code"
        return
    fi
    preflight OK "github-api-reachable" "https://api.github.com (parallel probes completed in ${t_ms} ms)"

    if [[ "${body_code}" != "200" ]]; then
        preflight FAIL "github-api-auth" \
            "token rejected by GitHub API (HTTP ${body_code}) -- token may be expired or invalid"
    else
        local scopes
        scopes="$(grep -i '^x-oauth-scopes:' "${user_hdr}" \
            | sed 's/^[^:]*://; s/^[[:space:]]*//; s/[[:space:]]*$//' | tr -d '\r')"
        if [[ -z "${scopes}" ]]; then
            preflight OK "github-api-auth" "token accepted (fine-grained PAT or GITHUB_TOKEN; scopes opaque)"
        else
            preflight OK "github-api-auth" "token accepted; scopes: ${scopes}"
        fi
    fi

    rm -f "${user_hdr}" "${user_body_file}" "${user_body_file}.code" \
          "${scope_body_file}" "${scope_body_file}.code"

    case "${probe_code}" in
        200) preflight OK   "github-runners-scope" "${scope_label} runners API readable" ;;
        401) preflight FAIL "github-runners-scope" "${scope_label} returned 401 -- token is invalid or expired" ;;
        403) preflight FAIL "github-runners-scope" "${scope_label} returned 403 -- token lacks 'admin:org'/'manage_runners' or repo 'administration' permission" ;;
        404) preflight FAIL "github-runners-scope" "${scope_label} returned 404 -- wrong RUNNER_URL or token cannot see this scope" ;;
        *)   preflight WARN "github-runners-scope" "${scope_label} returned HTTP ${probe_code} -- proceeding but registration may fail" ;;
    esac
}

# gh_preflight_check_cleanup
# Validate the CLEANUP_OFFLINE_RUNNERS feature gate when enabled. Skipped
# entirely when the feature is off.
gh_preflight_check_cleanup() {
    local do_threshold="false" do_anyname="false"
    [[ "${CLEANUP_OFFLINE_RUNNERS:-false}" == "true" ]] && do_threshold="true"
    case "${CLEANUP_OFFLINE_ANY_NAME:-false}" in
        true|TRUE|1|yes|on) do_anyname="true" ;;
    esac
    [[ "${do_threshold}" == "true" || "${do_anyname}" == "true" ]] || return 0

    # DELETE on /actions/runners/{id} requires the same scope as registration
    # (admin:org / manage_runners:enterprise / repo administration), which
    # the github-runners-scope check above already validates. We just need
    # to confirm a token is even present here.
    if [[ -z "${GITHUB_PAT:-}" && -z "${GITHUB_TOKEN:-}" ]]; then
        local missing_for
        if [[ "${do_threshold}" == "true" && "${do_anyname}" == "true" ]]; then
            missing_for="CLEANUP_OFFLINE_RUNNERS / CLEANUP_OFFLINE_ANY_NAME"
        elif [[ "${do_threshold}" == "true" ]]; then
            missing_for="CLEANUP_OFFLINE_RUNNERS"
        else
            missing_for="CLEANUP_OFFLINE_ANY_NAME"
        fi
        preflight FAIL "cleanup-offline-runners" \
            "${missing_for}=true but no GITHUB_PAT / GITHUB_TOKEN -- cleanup cannot call DELETE without an authenticated token"
    else
        local enabled_passes=""
        [[ "${do_threshold}" == "true" ]] && enabled_passes="threshold"
        [[ "${do_anyname}" == "true" ]] && enabled_passes="${enabled_passes:+${enabled_passes}+}any-name"
        preflight OK "cleanup-offline-runners" "enabled (${enabled_passes})"
    fi

    if [[ "${do_threshold}" == "true" ]]; then
        local cleanup_after="${CLEANUP_OFFLINE_AFTER:-86400}"
        if ! [[ "${cleanup_after}" =~ ^[0-9]+$ ]] || (( cleanup_after < 300 )); then
            preflight WARN "cleanup-offline-after" \
                "CLEANUP_OFFLINE_AFTER='${CLEANUP_OFFLINE_AFTER:-}' invalid (must be integer >=300); will use default 86400"
        else
            preflight OK "cleanup-offline-after" "${cleanup_after}s"
        fi
    fi

    if [[ "${do_anyname}" == "true" ]]; then
        local anyname_after="${CLEANUP_OFFLINE_ANY_NAME_AFTER:-604800}"
        if ! [[ "${anyname_after}" =~ ^[0-9]+$ ]] || (( anyname_after < 86400 )); then
            preflight WARN "cleanup-anyname-after" \
                "CLEANUP_OFFLINE_ANY_NAME_AFTER='${CLEANUP_OFFLINE_ANY_NAME_AFTER:-}' invalid or below 86400s (24h) floor; will clamp to 86400"
        else
            preflight OK "cleanup-anyname-after" "${anyname_after}s"
        fi
    fi

    if [[ -n "${CLEANUP_OFFLINE_NAME_REGEX:-}" ]]; then
        if echo "test-name" | jq -Rr --arg r "${CLEANUP_OFFLINE_NAME_REGEX}" \
            'test($r) | tostring' >/dev/null 2>&1; then
            preflight OK "cleanup-name-regex" "pattern compiles ('${CLEANUP_OFFLINE_NAME_REGEX}')"
        else
            preflight FAIL "cleanup-name-regex" \
                "CLEANUP_OFFLINE_NAME_REGEX='${CLEANUP_OFFLINE_NAME_REGEX}' is not a valid jq regex"
        fi
    fi

    # The state file lives under /config so offline streaks survive
    # container restarts. If /config is not writable the streak resets
    # every restart and nothing ever exceeds the threshold -- warn (not
    # fail) so the feature still functions in best-effort mode.
    if as_runner_user bash -c "touch /config/.cleanup-state.rwtest && rm -f /config/.cleanup-state.rwtest" 2>/dev/null; then
        preflight OK "cleanup-state-writable" "/config writable for /config/.gh-runner-offline-state.json"
    else
        preflight WARN "cleanup-state-writable" \
            "abc cannot write /config -- offline-since timestamps will reset every restart and runners may never exceed CLEANUP_OFFLINE_AFTER"
    fi

    if [[ "${CLEANUP_OFFLINE_DRY_RUN:-false}" == "true" ]]; then
        preflight OK "cleanup-dry-run" "DRY RUN active -- no DELETE calls will be made"
    fi
}

# gh_preflight_check_docker
# DOCKER_IN_DOCKER socket reachability check. Reads DOCKER_SOCK_PATH set
# by gh-dind.sh.
gh_preflight_check_docker() {
    if [[ "${DOCKER_IN_DOCKER:-false}" == "true" ]]; then
        # Try once more in case the socket appeared late (host-side service
        # still starting). gh_dind_resolve_sock is idempotent.
        [[ -z "${DOCKER_SOCK_PATH:-}" ]] && gh_dind_resolve_sock || true

        if [[ -n "${DOCKER_SOCK_PATH:-}" && -S "${DOCKER_SOCK_PATH}" ]]; then
            if as_runner_user bash -c "curl -fsS --unix-socket '${DOCKER_SOCK_PATH}' http://localhost/_ping >/dev/null 2>&1"; then
                preflight OK "docker-in-docker" "runner user can access ${DOCKER_SOCK_PATH}"
            else
                local sock_gid
                sock_gid="$(stat -c '%g' "${DOCKER_SOCK_PATH}" 2>/dev/null || echo unknown)"
                preflight FAIL "docker-in-docker" \
                    "DOCKER_IN_DOCKER=true and ${DOCKER_SOCK_PATH} is mounted, but the runner user cannot reach the Docker API (socket gid=${sock_gid}); container-based jobs will fail"
            fi
        else
            preflight FAIL "docker-in-docker" \
                "DOCKER_IN_DOCKER=true but no engine socket is mounted (checked DOCKER_HOST_SOCK, /var/run/docker.sock, /var/run/balena-engine.sock, /var/run/balena.sock, /run/docker.sock); bind-mount one from the host or set DOCKER_IN_DOCKER=false"
        fi
    elif [[ -S /var/run/docker.sock ]]; then
        preflight OK "docker-in-docker" "DOCKER_IN_DOCKER=false; docker.sock is mounted but unused (set DOCKER_IN_DOCKER=true to enable container-based jobs)"
    else
        preflight OK "docker-in-docker" "disabled (DOCKER_IN_DOCKER=false, no socket mounted)"
    fi
}

# gh_preflight_run
# Top-level orchestrator. Aborts on any FAIL, warns and continues otherwise.
gh_preflight_run() {
    local bin
    log "info" "Running pre-flight permission and environment checks..."

    for bin in curl jq tar; do
        if command -v "${bin}" >/dev/null 2>&1; then
            preflight OK "tool:${bin}"
        else
            preflight FAIL "tool:${bin}" "binary not found on PATH"
        fi
    done

    if [[ -x /opt/runner-bin/bin/Runner.Listener ]]; then
        preflight OK "runner-binary" "/opt/runner-bin/bin/Runner.Listener"
    else
        preflight FAIL "runner-binary" "Runner.Listener missing or not executable"
    fi
    if [[ -x /opt/runner-bin/config.sh && -x /opt/runner-bin/run.sh ]]; then
        preflight OK "runner-scripts" "config.sh, run.sh executable"
    else
        preflight FAIL "runner-scripts" "config.sh / run.sh missing or not executable"
    fi

    if as_runner_user test -r /opt/runner-bin/bin/Runner.Listener; then
        preflight OK "runner-readable-by-abc"
    else
        preflight FAIL "runner-readable-by-abc" "abc cannot read /opt/runner-bin -- fix ownership"
    fi
    if as_runner_user bash -c "touch /opt/runner-bin/.preflight-write && rm -f /opt/runner-bin/.preflight-write" 2>/dev/null; then
        preflight OK "runner-writable-by-abc"
    else
        preflight FAIL "runner-writable-by-abc" "abc cannot write to /opt/runner-bin -- config.sh will fail when it tries to create .env / .runner / _diag (check chown abc:abc /opt/runner-bin and that the path isn't a read-only mount)"
    fi
    if as_runner_user bash -c "touch '${RUNNER_WORKDIR}/.preflight' && rm -f '${RUNNER_WORKDIR}/.preflight'" 2>/dev/null; then
        preflight OK "workdir-writable" "${RUNNER_WORKDIR} writable by abc (uid 911)"
    else
        preflight FAIL "workdir-writable" "abc cannot write to ${RUNNER_WORKDIR}"
    fi

    if as_runner_user bash -c "touch /config/.preflight && rm -f /config/.preflight" 2>/dev/null; then
        preflight OK "config-dir-writable" "/config writable by abc"
    else
        preflight WARN "config-dir-writable" "/config not writable by abc -- runner state will not persist"
    fi

    gh_preflight_check_docker

    if [[ -n "${RUNNER_TOKEN:-}" ]]; then
        preflight OK "auth-token" "registration token present"
    elif [[ -n "${GITHUB_PAT:-}" ]]; then
        preflight OK "auth-token" "GITHUB_PAT present (registration token will be minted)"
    elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
        preflight OK "auth-token" "GITHUB_TOKEN present (registration token will be minted)"
    else
        preflight FAIL "auth-token" "no RUNNER_TOKEN / GITHUB_PAT / GITHUB_TOKEN provided"
    fi

    gh_preflight_check_api
    gh_preflight_check_cleanup

    if [[ "${PREFLIGHT_FAILED}" -gt 0 ]]; then
        log "fatal" "Pre-flight checks failed: ${PREFLIGHT_FAILED} error(s), ${PREFLIGHT_WARNED} warning(s) -- aborting"
        exit 1
    fi
    if [[ "${PREFLIGHT_WARNED}" -gt 0 ]]; then
        log "warn" "Pre-flight completed with ${PREFLIGHT_WARNED} warning(s) -- continuing"
    else
        log "info" "Pre-flight checks passed"
    fi
}
