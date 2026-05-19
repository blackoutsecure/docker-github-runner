#!/usr/bin/with-contenv bash
# shellcheck shell=bash
#
# Shared GitHub API primitives for docker-github-runner.
#
# This module is the SINGLE source of truth for:
#   - URL shape selection (repo / org / enterprise)
#   - HTTP wrappers for the runner+runner-group endpoints
#   - Registration token minting (with scope-aware diagnostics)
#   - Higher-level operations used at registration/heartbeat time
#     (list, get-metadata, set-labels, set-group, delete, ensure-group,
#     deduplicate-name)
#
# Callers (init-gh-runner-config, svc-gh-runner-logs, autoscale.sh) source
# this file via `. /usr/local/bin/gh-api.sh` and never roll their own URL
# selection or curl wiring.
#
# All helpers expect:
#   - RUNNER_URL   the registration URL ("https://github.com/<org>[/<repo>]"
#                  or "https://github.com/enterprises/<slug>")
#   - $auth_token  a Classic PAT / fine-grained PAT / GITHUB_TOKEN
#                  (callers usually `${GITHUB_PAT:-${GITHUB_TOKEN:-}}`)
#
# The log() function from log-functions.sh is used for human-readable
# diagnostics; LOG_TAG should be set by the caller.
#

# ---------------------------------------------------------------------------
# URL resolvers
# ---------------------------------------------------------------------------

# gh_api_runners_url <runner_url>
# Resolve the `/actions/runners` API endpoint from a runner registration
# URL. Accepts the three shapes the GitHub runner itself accepts:
#   - https://github.com/<org>/<repo>           -> /repos/<org>/<repo>/actions/runners
#   - https://github.com/<org>                  -> /orgs/<org>/actions/runners
#   - https://github.com/enterprises/<slug>     -> /enterprises/<slug>/actions/runners
# Trailing slashes are tolerated.
gh_api_runners_url() {
    local raw="${1:-${RUNNER_URL:-}}"
    local url_path="${raw#https://github.com/}"
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

# gh_api_runner_groups_url <runner_url>
# Runner groups are only available at org and enterprise levels.
# Returns an empty string for repo-scoped URLs.
gh_api_runner_groups_url() {
    local raw="${1:-${RUNNER_URL:-}}"
    local url_path="${raw#https://github.com/}"
    url_path="${url_path%/}"
    local api_base="https://api.github.com"

    if [[ "${url_path}" == enterprises/* ]]; then
        echo "${api_base}/enterprises/${url_path#enterprises/}/actions/runner-groups"
    elif [[ "${url_path}" == */* ]]; then
        echo ""
    else
        echo "${api_base}/orgs/${url_path}/actions/runner-groups"
    fi
}

# gh_api_scope_kind <runner_url>
# Classify a runner URL as one of: enterprise | org | repo.
gh_api_scope_kind() {
    local raw="${1:-${RUNNER_URL:-}}"
    local url_path="${raw#https://github.com/}"
    url_path="${url_path%/}"
    if [[ "${url_path}" == enterprises/* ]]; then echo enterprise
    elif [[ "${url_path}" == */* ]]; then echo repo
    else echo org
    fi
}

# ---------------------------------------------------------------------------
# Authentication helpers
# ---------------------------------------------------------------------------

# gh_api_auth_token
# Resolve the active auth token following the documented precedence:
#   GITHUB_PAT > GITHUB_TOKEN > (empty)
gh_api_auth_token() {
    echo "${GITHUB_PAT:-${GITHUB_TOKEN:-}}"
}

# gh_api_token_kind <token>
# Classify a token by its documented prefix. The token value is NEVER
# logged; only the kind is returned for operator-visible diagnostics.
gh_api_token_kind() {
    case "${1:-}" in
        ghp_*)        echo "classic-pat" ;;
        github_pat_*) echo "fine-grained-pat" ;;
        ghs_*)        echo "github-app-installation" ;;
        gho_*)        echo "oauth" ;;
        ghu_*)        echo "github-app-user-to-server" ;;
        ghr_*)        echo "github-app-refresh" ;;
        *)            echo "unknown" ;;
    esac
}

# ---------------------------------------------------------------------------
# Listing / lookup
# ---------------------------------------------------------------------------

# gh_api_list_runners
# Stream every registered runner as "name<TAB>status" lines on stdout.
# Best-effort across <=10 pages of 100 runners. Returns 1 if no token.
gh_api_list_runners() {
    local auth_token; auth_token="$(gh_api_auth_token)"
    [[ -n "${auth_token}" ]] || return 1

    local runners_url; runners_url="$(gh_api_runners_url)"
    local page=1
    while [[ "${page}" -le 10 ]]; do
        local resp
        resp="$(curl -fsSL \
            -H "Authorization: token ${auth_token}" \
            -H "Accept: application/vnd.github+json" \
            "${runners_url}?per_page=100&page=${page}" 2>/dev/null)" || break

        echo "${resp}" | jq -r '.runners[] | "\(.name)\t\(.status)"' 2>/dev/null

        local count
        count="$(echo "${resp}" | jq -r '.runners | length' 2>/dev/null)"
        [[ "${count}" -lt 100 ]] && break
        page=$((page + 1))
    done
}

# gh_api_is_runner_name_active <name> <runner_list>
# Literal-string match (so names containing regex metacharacters compare
# correctly). Returns 0 if the name is taken by an online runner.
gh_api_is_runner_name_active() {
    local name="$1" runner_list="$2" needle line
    needle="${name}"$'\t'"online"
    while IFS= read -r line; do
        [[ "${line}" == "${needle}" ]] && return 0
    done <<< "${runner_list}"
    return 1
}

# gh_api_get_runner_metadata <name>
# Returns TSV: "<id>\t<comma-labels>\t<group_id>" or empty when not found.
gh_api_get_runner_metadata() {
    local runner_name="$1"
    local auth_token; auth_token="$(gh_api_auth_token)"
    [[ -n "${auth_token}" ]] || return 1

    local runners_url; runners_url="$(gh_api_runners_url)"
    local page=1
    while [[ "${page}" -le 10 ]]; do
        local resp
        resp="$(curl -fsSL \
            -H "Authorization: token ${auth_token}" \
            -H "Accept: application/vnd.github+json" \
            "${runners_url}?per_page=100&page=${page}" 2>/dev/null)" || return 1

        local match
        match="$(echo "${resp}" | jq -r \
            --arg name "${runner_name}" '
                .runners[]
                | select(.name == $name)
                | [
                    (.id | tostring),
                    ([.labels[] | select(.type == "custom") | .name] | join(",")),
                    ((.runner_group_id // 1) | tostring)
                  ]
                | @tsv
            ' 2>/dev/null | head -n1)"

        if [[ -n "${match}" ]]; then
            echo "${match}"
            return 0
        fi

        local count
        count="$(echo "${resp}" | jq -r '.runners | length' 2>/dev/null)"
        [[ "${count}" -lt 100 ]] && break
        page=$((page + 1))
    done
}

# ---------------------------------------------------------------------------
# Mutations: labels / groups / delete
# ---------------------------------------------------------------------------

# gh_api_set_runner_labels <runner_id> <comma-separated labels>
gh_api_set_runner_labels() {
    local runner_id="$1" labels_csv="$2"
    local auth_token; auth_token="$(gh_api_auth_token)"
    if [[ -z "${auth_token}" ]]; then
        log "warn" "No PAT available to update runner labels via API"
        return 1
    fi

    local runners_url; runners_url="$(gh_api_runners_url)"
    local payload
    payload="$(echo "${labels_csv}" | jq -R -c 'split(",") | map(select(length > 0)) | {labels: .}')"

    local resp code
    resp="$(curl -fsSL -w "\n%{http_code}" -X PUT \
        -H "Authorization: token ${auth_token}" \
        -H "Accept: application/vnd.github+json" \
        -d "${payload}" \
        "${runners_url}/${runner_id}/labels" 2>&1)" || true

    code="$(echo "${resp}" | tail -n 1)"
    if [[ "${code}" == "200" ]]; then
        return 0
    fi

    log "warn" "GitHub API returned HTTP ${code} when updating runner labels"
    log "warn" "Response: $(echo "${resp}" | head -n -1)"
    return 1
}

# gh_api_get_runner_group_id <group_name>
gh_api_get_runner_group_id() {
    local group_name="$1"
    local auth_token; auth_token="$(gh_api_auth_token)"
    [[ -n "${auth_token}" ]] || return 1

    local groups_url; groups_url="$(gh_api_runner_groups_url)"
    [[ -n "${groups_url}" ]] || return 1

    local page=1
    while [[ "${page}" -le 10 ]]; do
        local resp
        resp="$(curl -fsSL \
            -H "Authorization: token ${auth_token}" \
            -H "Accept: application/vnd.github+json" \
            "${groups_url}?per_page=100&page=${page}" 2>/dev/null)" || return 1

        local gid
        gid="$(echo "${resp}" | jq -r \
            --arg name "${group_name}" \
            '.runner_groups[] | select(.name == $name) | .id // empty' 2>/dev/null | head -n1)"

        if [[ -n "${gid}" ]]; then
            echo "${gid}"
            return 0
        fi

        local count
        count="$(echo "${resp}" | jq -r '.runner_groups | length' 2>/dev/null)"
        [[ "${count}" -lt 100 ]] && break
        page=$((page + 1))
    done
}

# gh_api_set_runner_group <runner_id> <group_id>
gh_api_set_runner_group() {
    local runner_id="$1" group_id="$2"
    local auth_token; auth_token="$(gh_api_auth_token)"
    if [[ -z "${auth_token}" ]]; then
        log "warn" "No PAT available to move runner to a different group"
        return 1
    fi

    local groups_url; groups_url="$(gh_api_runner_groups_url)"
    if [[ -z "${groups_url}" ]]; then
        log "warn" "Runner groups are not supported at the repo level"
        return 1
    fi

    local resp code
    resp="$(curl -fsSL -w "\n%{http_code}" -X PUT \
        -H "Authorization: token ${auth_token}" \
        -H "Accept: application/vnd.github+json" \
        "${groups_url}/${group_id}/runners/${runner_id}" 2>&1)" || true

    code="$(echo "${resp}" | tail -n 1)"
    if [[ "${code}" == "204" ]]; then
        return 0
    fi

    log "warn" "GitHub API returned HTTP ${code} when moving runner to group ${group_id}"
    log "warn" "Response: $(echo "${resp}" | head -n -1)"
    return 1
}

# gh_api_remove_runner_by_name <name>
# Look up the runner id and DELETE it. Returns 0 on success or when no
# such runner exists; non-zero on lookup/DELETE failure.
gh_api_remove_runner_by_name() {
    local runner_name="$1"
    local auth_token; auth_token="$(gh_api_auth_token)"

    if [[ -z "${auth_token}" ]]; then
        log "warn" "No PAT available to query the API for conflicting runners"
        return 1
    fi

    local runners_url; runners_url="$(gh_api_runners_url)"

    local page=1 runner_id=""
    while [[ "${page}" -le 10 ]]; do
        local resp
        resp="$(curl -fsSL \
            -H "Authorization: token ${auth_token}" \
            -H "Accept: application/vnd.github+json" \
            "${runners_url}?per_page=100&page=${page}" 2>/dev/null)" || break

        runner_id="$(echo "${resp}" | jq -r \
            --arg name "${runner_name}" \
            '.runners[] | select(.name == $name) | .id // empty' 2>/dev/null | head -n1)"

        if [[ -n "${runner_id}" ]]; then
            break
        fi

        local count
        count="$(echo "${resp}" | jq -r '.runners | length' 2>/dev/null)"
        [[ "${count}" -lt 100 ]] && break
        page=$((page + 1))
    done

    if [[ -z "${runner_id}" ]]; then
        log "info" "No existing runner named '${runner_name}' found via API"
        return 0
    fi

    log "info" "Found existing runner '${runner_name}' (id: ${runner_id}), removing via API..."
    local del_code
    del_code="$(curl -fsSL -o /dev/null -w "%{http_code}" -X DELETE \
        -H "Authorization: token ${auth_token}" \
        -H "Accept: application/vnd.github+json" \
        "${runners_url}/${runner_id}" 2>/dev/null)" || true

    if [[ "${del_code}" == "204" ]]; then
        log "info" "Successfully removed conflicting runner '${runner_name}' (id: ${runner_id}) via API"
        return 0
    fi

    log "warn" "API DELETE returned HTTP ${del_code} for runner id ${runner_id}"
    return 1
}

# ---------------------------------------------------------------------------
# Runner groups
# ---------------------------------------------------------------------------

# gh_api_ensure_runner_group <group_name>
# Verify the named group exists and create it (with visibility=all) when
# it doesn't. No-op for the built-in "Default". Warns and returns 0 when
# no auth token is available so registration can still fall through.
gh_api_ensure_runner_group() {
    local group_name="${1:-Default}"

    log "info" "Runner group check: verifying group '${group_name}'"

    if [[ "${group_name}" == "Default" ]]; then
        log "info" "Runner group check: 'Default' is built-in, no action required"
        return 0
    fi

    local auth_token; auth_token="$(gh_api_auth_token)"
    if [[ -z "${auth_token}" ]]; then
        log "warn" "Runner group check: no PAT available to verify/create '${group_name}'"
        log "warn" "  Group creation requires PAT with 'admin:org' (org) or 'manage_runners:enterprise' (enterprise)"
        log "warn" "  Without it, registration will fall back to whatever group config.sh resolves (usually Default)"
        return 0
    fi

    local groups_url; groups_url="$(gh_api_runner_groups_url)"
    if [[ -z "${groups_url}" ]]; then
        log "warn" "Runner group check: groups are not supported at the repo level -- ignoring RUNNER_GROUP='${group_name}'"
        return 0
    fi

    local page=1 found="false"
    while [[ "${page}" -le 10 ]]; do
        local resp
        resp="$(curl -fsSL \
            -H "Authorization: token ${auth_token}" \
            -H "Accept: application/vnd.github+json" \
            "${groups_url}?per_page=100&page=${page}" 2>/dev/null)" || {
            log "warn" "Failed to list runner groups via API"
            return 1
        }

        if echo "${resp}" | jq -e --arg name "${group_name}" \
            '.runner_groups[] | select(.name == $name)' >/dev/null 2>&1; then
            found="true"
            break
        fi

        local count
        count="$(echo "${resp}" | jq -r '.runner_groups | length' 2>/dev/null)"
        [[ "${count}" -lt 100 ]] && break
        page=$((page + 1))
    done

    if [[ "${found}" == "true" ]]; then
        log "info" "Runner group check: '${group_name}' already exists -- no changes needed"
        return 0
    fi

    log "info" "Runner group check: '${group_name}' not found -- attempting to create it via API"

    local create_resp body code
    create_resp="$(curl -fsSL -w "\n%{http_code}" -X POST \
        -H "Authorization: token ${auth_token}" \
        -H "Accept: application/vnd.github+json" \
        -d "$(jq -nc --arg name "${group_name}" '{name: $name, visibility: "all"}')" \
        "${groups_url}" 2>&1)" || {
        log "warn" "Failed to create runner group '${group_name}'"
        return 1
    }

    body="$(echo "${create_resp}" | head -n -1)"
    code="$(echo "${create_resp}" | tail -n 1)"

    if [[ "${code}" == "201" ]]; then
        log "info" "Runner group check: '${group_name}' created successfully"
        return 0
    fi

    log "warn" "Runner group check: GitHub API returned HTTP ${code} when creating '${group_name}'"
    log "warn" "  Response: ${body}"
    log "warn" "  Required privileges: PAT with 'admin:org' (org-level) or 'manage_runners:enterprise' (enterprise-level)"
    return 1
}

# ---------------------------------------------------------------------------
# Registration token minting (with scope-aware diagnostics)
# ---------------------------------------------------------------------------

# Internal: print scope-specific required-permissions guidance.
_gh_api_print_required_scope() {
    local kind="$1"
    log "fatal" "  Required token permissions for ${kind}-level runner registration:"
    case "${kind}" in
        enterprise)
            log "fatal" "    - Classic PAT: 'manage_runners:enterprise' scope (REQUIRED -- 'repo' and 'admin:org' do NOT work)"
            log "fatal" "    - Fine-grained PAT: NOT SUPPORTED for enterprise runners"
            log "fatal" "    - GITHUB_TOKEN (Actions): NOT SUPPORTED for enterprise runners"
            log "fatal" "    - The PAT owner must be an enterprise owner."
            ;;
        org)
            log "fatal" "    - Classic PAT: 'admin:org' scope"
            log "fatal" "    - Fine-grained PAT: org 'Self-hosted runners' permission (read & write), token issued by an org owner"
            log "fatal" "    - GITHUB_TOKEN (Actions): NOT SUPPORTED for org runners"
            ;;
        repo)
            log "fatal" "    - Classic PAT: 'repo' scope"
            log "fatal" "    - Fine-grained PAT: repo 'Administration' permission (read & write)"
            log "fatal" "    - GITHUB_TOKEN (Actions): permissions: { actions: write } in the workflow"
            ;;
    esac
}

# gh_api_generate_registration_token <auth_token> <token_source_label>
# On success: exports RUNNER_TOKEN and logs the expiry.
# On failure: emits a detailed scope/diagnostic block and exits 1.
gh_api_generate_registration_token() {
    local auth_token="$1" token_source="$2"

    if [[ -z "${RUNNER_URL:-}" ]]; then
        log "fatal" "RUNNER_URL is required when using ${token_source} to generate a registration token"
        exit 1
    fi

    local url_path="${RUNNER_URL#https://github.com/}"
    url_path="${url_path%/}"
    local api_base="https://api.github.com"
    local token_url scope_desc scope_kind

    if [[ "${url_path}" == enterprises/* ]]; then
        local ent_name="${url_path#enterprises/}"
        token_url="${api_base}/enterprises/${ent_name}/actions/runners/registration-token"
        scope_desc="enterprise/${ent_name}"
        scope_kind="enterprise"
    elif [[ "${url_path}" == */* ]]; then
        token_url="${api_base}/repos/${url_path}/actions/runners/registration-token"
        scope_desc="repo/${url_path}"
        scope_kind="repo"
    else
        token_url="${api_base}/orgs/${url_path}/actions/runners/registration-token"
        scope_desc="org/${url_path}"
        scope_kind="org"
    fi

    local token_kind; token_kind="$(gh_api_token_kind "${auth_token}")"

    log "info" "Generating registration token via GitHub API (${scope_desc}) using ${token_source} [token-kind=${token_kind}]"

    if [[ "${scope_kind}" == "enterprise" ]]; then
        case "${token_kind}" in
            fine-grained-pat)
                log "warn" "Enterprise-level runner registration is NOT supported with fine-grained PATs"
                log "warn" "Use a Classic PAT with the 'manage_runners:enterprise' scope instead"
                ;;
            github-app-installation|oauth|github-app-user-to-server|github-app-refresh)
                log "warn" "Enterprise-level runner registration requires a Classic PAT with 'manage_runners:enterprise'"
                log "warn" "Detected token kind '${token_kind}' is unlikely to be accepted at the enterprise tier"
                ;;
        esac
    fi

    # Deliberately not using `curl -f` so we can distinguish 401 / 403 /
    # 404 / 422 / 429 / 5xx for diagnostics. Body+status captured separately.
    local tmp_body curl_stderr
    tmp_body="$(mktemp)"
    curl_stderr="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '${tmp_body}' '${curl_stderr}'" RETURN

    local http_code curl_exit=0
    http_code="$(curl -sS -X POST \
        -H "Authorization: token ${auth_token}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -o "${tmp_body}" \
        -w '%{http_code}' \
        "${token_url}" 2>"${curl_stderr}")" || curl_exit=$?

    if [[ "${curl_exit}" -ne 0 ]]; then
        log "fatal" "curl failed to reach the GitHub API (exit ${curl_exit})"
        log "fatal" "URL:    ${token_url}"
        log "fatal" "Source: ${token_source}"
        local stderr_detail; stderr_detail="$(cat "${curl_stderr}" 2>/dev/null || true)"
        [[ -n "${stderr_detail}" ]] && log "fatal" "Detail: ${stderr_detail}"
        log "fatal" "Likely causes: DNS resolution failure, blocked egress to api.github.com, TLS interception/MITM proxy, or HTTP_PROXY/HTTPS_PROXY misconfiguration"
        exit 1
    fi

    if [[ "${http_code}" == "201" ]]; then
        local http_body; http_body="$(cat "${tmp_body}")"
        RUNNER_TOKEN="$(echo "${http_body}" | jq -r '.token // empty')"
        if [[ -z "${RUNNER_TOKEN}" ]]; then
            log "fatal" "GitHub API returned 201 but the response did not contain a token"
            log "fatal" "Response: ${http_body}"
            exit 1
        fi
        export RUNNER_TOKEN
        local expires_at expires_utc
        expires_at="$(echo "${http_body}" | jq -r '.expires_at // "unknown"')"
        if [[ "${expires_at}" != "unknown" ]]; then
            expires_utc="$(date -u -d "${expires_at}" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "${expires_at}")"
        else
            expires_utc="unknown"
        fi
        log "info" "Registration token generated successfully (expires: ${expires_utc})"
        return 0
    fi

    # Non-201: build a focused, scope-aware diagnostic.
    local http_body gh_message
    http_body="$(cat "${tmp_body}" 2>/dev/null || true)"
    gh_message="$(echo "${http_body}" | jq -r '.message // empty' 2>/dev/null || true)"

    log "fatal" "GitHub API returned HTTP ${http_code} when generating registration token"
    log "fatal" "URL:    ${token_url}"
    log "fatal" "Scope:  ${scope_desc}"
    log "fatal" "Source: ${token_source} (token-kind=${token_kind})"
    if [[ -n "${gh_message}" ]]; then
        log "fatal" "GitHub: ${gh_message}"
    elif [[ -n "${http_body}" ]]; then
        log "fatal" "Response: ${http_body}"
    fi

    case "${http_code}" in
        401)
            log "fatal" "401 Unauthorized -- the token itself was rejected by GitHub (the credential is invalid)."
            log "fatal" "  Most common causes, in order of likelihood:"
            log "fatal" "    1. The PAT has expired or been revoked. Generate a new one and update ${token_source}."
            log "fatal" "    2. The token value is malformed: stray whitespace, wrong env var, or an empty file mounted via ${token_source}_FILE."
            log "fatal" "    3. SAML SSO session lapsed for this PAT. Re-authorize it under PAT settings -> 'Configure SSO'."
            log "fatal" "  Quick check (run from any host with the same token):"
            log "fatal" "    curl -i -H \"Authorization: token <PAT>\" https://api.github.com/user"
            log "fatal" "    -- HTTP 200 means the credential is alive; HTTP 401 confirms it is dead."
            ;;
        403)
            log "fatal" "403 Forbidden -- the token authenticated, but it is not allowed to perform this action."
            log "fatal" "  Likely causes: missing scope, SSO not authorized for this enterprise/org, IP allow list, or a secondary rate / abuse limit."
            _gh_api_print_required_scope "${scope_kind}"
            ;;
        404)
            log "fatal" "404 Not Found -- either RUNNER_URL is wrong, or the token cannot see the target."
            log "fatal" "  Verify RUNNER_URL=${RUNNER_URL} matches an existing ${scope_kind}."
            if [[ "${scope_kind}" == "enterprise" ]]; then
                log "fatal" "  Note: GitHub returns 404 (not 403) when a token lacks visibility into an enterprise."
                log "fatal" "  This usually means the PAT is missing the 'manage_runners:enterprise' scope, or the user is not an enterprise owner."
                _gh_api_print_required_scope "${scope_kind}"
            fi
            ;;
        422)
            log "fatal" "422 Unprocessable Entity -- GitHub rejected the request payload or scope target."
            log "fatal" "  Check that ${scope_desc} is a valid Actions runner registration target (Actions enabled, runner groups configured, etc.)."
            ;;
        429|5*)
            log "fatal" "GitHub API is rate-limited or unhealthy (HTTP ${http_code}). Retry after a short delay; check https://www.githubstatus.com/."
            ;;
        *)
            log "fatal" "Unexpected status. Treating as a permission/configuration error."
            _gh_api_print_required_scope "${scope_kind}"
            ;;
    esac

    exit 1
}

# ---------------------------------------------------------------------------
# Higher-level operations
# ---------------------------------------------------------------------------

# gh_api_deduplicate_runner_name <base_name>
# If the base name is taken by an ACTIVE (online) runner, append -1..-99
# until a free slot is found. Offline runners with the same name are
# replaced by config.sh's --replace, so they don't bump the suffix.
# Logs progress on stderr; prints the chosen name on stdout.
gh_api_deduplicate_runner_name() {
    local base_name="$1"
    local auth_token; auth_token="$(gh_api_auth_token)"
    if [[ -z "${auth_token}" ]]; then
        log "info" "No PAT available to check for active runners -- using name as-is" >&2
        echo "${base_name}"
        return 0
    fi

    local runner_list
    runner_list="$(gh_api_list_runners 2>/dev/null)" || {
        log "warn" "Failed to list runners via API -- using name as-is" >&2
        echo "${base_name}"
        return 0
    }

    if ! gh_api_is_runner_name_active "${base_name}" "${runner_list}"; then
        echo "${base_name}"
        return 0
    fi

    local suffix=1
    while [[ "${suffix}" -le 99 ]]; do
        local candidate="${base_name}-${suffix}"
        if ! gh_api_is_runner_name_active "${candidate}" "${runner_list}"; then
            log "info" "Runner '${base_name}' is already online, using '${candidate}' instead" >&2
            echo "${candidate}"
            return 0
        fi
        suffix=$((suffix + 1))
    done

    log "warn" "All suffixes ${base_name}-1 through ${base_name}-99 are active -- using base name with --replace" >&2
    echo "${base_name}"
}

# gh_api_sync_existing_runner_metadata <name> <desired_labels_csv> <desired_group>
# Reconcile the live runner's custom labels and group with what the
# environment requests. Used when a .runner config from an earlier
# container run is reused (avoids unnecessary re-registration).
gh_api_sync_existing_runner_metadata() {
    local runner_name="$1" desired_labels="$2" desired_group="${3:-Default}"

    local auth_token; auth_token="$(gh_api_auth_token)"
    if [[ -z "${auth_token}" ]]; then
        log "info" "No PAT available -- skipping label/group sync for existing runner"
        return 0
    fi

    local meta
    meta="$(gh_api_get_runner_metadata "${runner_name}" 2>/dev/null)" || {
        log "warn" "Failed to query GitHub API for runner '${runner_name}' metadata"
        return 0
    }

    if [[ -z "${meta}" ]]; then
        log "warn" "Runner '${runner_name}' not found via API -- it may need re-registration"
        return 0
    fi

    local runner_id current_labels current_group_id
    runner_id="$(echo "${meta}" | cut -f1)"
    current_labels="$(echo "${meta}" | cut -f2)"
    current_group_id="$(echo "${meta}" | cut -f3)"

    local normalize='tr "," "\n" | sed "s/^[[:space:]]*//;s/[[:space:]]*$//" | grep -v "^$" | sort -u | paste -sd "," -'
    local desired_norm current_norm
    desired_norm="$(echo "${desired_labels}" | eval "${normalize}")"
    current_norm="$(echo "${current_labels}" | eval "${normalize}")"

    if [[ "${desired_norm}" != "${current_norm}" ]]; then
        log "info" "Custom labels differ -- updating via API"
        log "info" "  current: ${current_norm:-(none)}"
        log "info" "  desired: ${desired_norm:-(none)}"
        if gh_api_set_runner_labels "${runner_id}" "${desired_norm}"; then
            log "info" "Runner labels updated successfully"
        else
            log "warn" "Failed to update runner labels -- they will only be refreshed on next re-registration"
        fi
    else
        log "info" "Runner labels already up to date"
    fi

    # Group sync is org/enterprise-only.
    local groups_url; groups_url="$(gh_api_runner_groups_url)"
    [[ -n "${groups_url}" ]] || return 0

    local desired_group_id
    desired_group_id="$(gh_api_get_runner_group_id "${desired_group}" 2>/dev/null)"
    if [[ -z "${desired_group_id}" ]]; then
        log "warn" "Runner group '${desired_group}' not found -- cannot sync group membership"
        return 0
    fi

    if [[ "${desired_group_id}" != "${current_group_id}" ]]; then
        log "info" "Runner group differs -- moving runner to '${desired_group}' (id: ${desired_group_id})"
        if gh_api_set_runner_group "${runner_id}" "${desired_group_id}"; then
            log "info" "Runner group updated successfully"
        else
            log "warn" "Failed to move runner to group '${desired_group}'"
        fi
    else
        log "info" "Runner group already up to date ('${desired_group}')"
    fi
}

# ---------------------------------------------------------------------------
# Heartbeat probe (used by svc-gh-runner-logs)
# ---------------------------------------------------------------------------

# gh_api_probe_runner_online <runner_name>
# Returns: 0 online, 1 offline/not-found, 2 skipped (no token / no URL / curl failure).
gh_api_probe_runner_online() {
    local runner_name="${1:-${RUNNER_NAME:-}}"
    local auth_token; auth_token="$(gh_api_auth_token)"
    [[ -n "${auth_token}" ]] || return 2
    [[ -n "${RUNNER_URL:-}" && -n "${runner_name}" ]] || return 2

    local runners_url; runners_url="$(gh_api_runners_url)"

    local page=1 status=""
    while [[ "${page}" -le 5 ]]; do
        local resp
        resp="$(curl -fsS --max-time 6 \
            -H "Authorization: token ${auth_token}" \
            -H "Accept: application/vnd.github+json" \
            "${runners_url}?per_page=100&page=${page}" 2>/dev/null)" || return 2

        status="$(echo "${resp}" | jq -r \
            --arg name "${runner_name}" \
            '.runners[] | select(.name == $name) | .status // empty' 2>/dev/null | head -n1)"
        [[ -n "${status}" ]] && break

        local count
        count="$(echo "${resp}" | jq -r '.runners | length' 2>/dev/null)"
        [[ "${count}" -lt 100 ]] && break
        page=$((page + 1))
    done

    [[ "${status}" == "online" ]] && return 0
    return 1
}

# Backwards-compat alias for callers that pre-dated the rename. Cheap to
# keep; removes the upgrade footgun for forks/derivative images that
# sourced /usr/local/bin/github-api.sh directly.
gh_api_runners_url_legacy_alias() { gh_api_runners_url "$@"; }
