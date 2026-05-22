#!/usr/bin/with-contenv bash
# shellcheck shell=bash
#
# Stale-runner cleanup.
#
# GitHub's API does not expose how long a runner has been offline, so we
# track the first time we see each offline runner in a small JSON state
# file under /config (persists across container restarts when /config is
# mounted as a volume). Any runner that has been continuously observed as
# offline for longer than CLEANUP_OFFLINE_AFTER seconds is removed via
# DELETE /actions/runners/{id}. Runners that come back online are pruned
# from the state file.
#
# Tunables (full reference in README):
#   CLEANUP_OFFLINE_RUNNERS     master toggle for the threshold-based sweep
#                               (default: false)
#   CLEANUP_OFFLINE_AFTER       seconds offline before eligible (default 86400, min 300)
#   CLEANUP_OFFLINE_NAME_REGEX  optional ERE filter (default: match all)
#   CLEANUP_OFFLINE_DRY_RUN     log only, no DELETE (default: false)
#   CLEANUP_OFFLINE_MAX         hard cap per sweep (default: 25)
#   CLEANUP_OFFLINE_IMMEDIATE   skip the timer (default: auto = true for ephemeral)
#
# Companion sweep (runs in the same function on the same fetched listing):
#   CLEANUP_SIMILAR_OFFLINE     remove offline runners whose name matches
#                               the dedup-suffix pattern derived from this
#                               container's RUNNER_NAME — i.e. names of the
#                               form `<RUNNER_NAME>-<digits>` — provided
#                               they advertise the SAME label set as this
#                               container would register with. These are
#                               stale leftovers from prior boots of THIS
#                               service that didn't run `config.sh remove`
#                               (SIGKILL, host reboot, balena replace).
#                               Removed immediately (no offline timer);
#                               CLEANUP_OFFLINE_MAX / CLEANUP_OFFLINE_DRY_RUN
#                               still apply.
#                               Default: true. Disable by setting to "false".
#   CLEANUP_SIMILAR_REQUIRE_LABEL_MATCH  When "true" (default), an offline
#                               similar-named runner is only removed if
#                               its label set is identical to this
#                               container's intended labels (sorted +
#                               lowercased + deduped). Defense-in-depth
#                               against an arm64 fleet accidentally
#                               culling an x64 peer that re-used the same
#                               base hostname.
#

CLEANUP_STATE_FILE="/config/.gh-runner-offline-state.json"

# clean_local_runner_config
# Wipe the local .runner/.credentials/.env/.path files so config.sh starts
# clean. Called after a remote-side runner deletion via the API, or when
# the local cached config no longer matches the requested URL/name.
clean_local_runner_config() {
    log "info" "Cleaning local runner configuration files"
    rm -f .runner .credentials .credentials_rsaparams .env .path
}

# cleanup_stale_offline_runners
# Top-level sweep -- no-op unless CLEANUP_OFFLINE_RUNNERS=true and a token
# is present. See module header for tunables.
cleanup_stale_offline_runners() {
    # Both sweeps share the same fetched runners listing and the same
    # DELETE loop. Either or both can be disabled independently.
    local do_threshold="false" do_similar="false"
    [[ "${CLEANUP_OFFLINE_RUNNERS:-false}" == "true" ]] && do_threshold="true"
    case "${CLEANUP_SIMILAR_OFFLINE:-true}" in
        true|TRUE|1|yes|on) do_similar="true" ;;
        *)                  do_similar="false" ;;
    esac
    # Similar-name sweep requires a known RUNNER_NAME (resolved by
    # gh_config_resolve_runner_name earlier in init). Without one we have
    # nothing to derive the `<RUNNER_NAME>-<digits>` pattern from.
    if [[ "${do_similar}" == "true" && -z "${RUNNER_NAME:-}" ]]; then
        log "debug" "Stale-runner cleanup: CLEANUP_SIMILAR_OFFLINE=true but RUNNER_NAME is unset; skipping similar-name pass"
        do_similar="false"
    fi
    if [[ "${do_threshold}" == "false" && "${do_similar}" == "false" ]]; then
        return 0
    fi

    local auth_token; auth_token="$(gh_api_auth_token)"
    if [[ -z "${auth_token}" ]]; then
        if [[ "${do_threshold}" == "true" ]]; then
            log "warn" "CLEANUP_OFFLINE_RUNNERS=true but no PAT available -- skipping (need GITHUB_PAT or GITHUB_TOKEN)"
        else
            log "debug" "CLEANUP_SIMILAR_OFFLINE=true but no PAT available -- skipping similar-name sweep"
        fi
        return 0
    fi

    # Validate threshold (>=300s). A typo like "60" would otherwise let us
    # wipe runners that just briefly disconnected.
    local threshold="${CLEANUP_OFFLINE_AFTER:-86400}"
    if ! [[ "${threshold}" =~ ^[0-9]+$ ]] || (( threshold < 300 )); then
        log "warn" "CLEANUP_OFFLINE_AFTER='${CLEANUP_OFFLINE_AFTER:-}' invalid (must be >=300 seconds); using default 86400"
        threshold=86400
    fi

    local max_remove="${CLEANUP_OFFLINE_MAX:-25}"
    if ! [[ "${max_remove}" =~ ^[0-9]+$ ]] || (( max_remove < 1 )); then
        max_remove=25
    fi

    local name_regex="${CLEANUP_OFFLINE_NAME_REGEX:-}"
    local dry_run="${CLEANUP_OFFLINE_DRY_RUN:-false}"

    # Immediate mode defaults ON in ephemeral mode (offline ephemeral
    # runners are dead by definition) and OFF for persistent runners (so a
    # brief network blip doesn't mass-delete). Override either way.
    local immediate_default="false"
    [[ "${RUNNER_EPHEMERAL:-false}" == "true" ]] && immediate_default="true"
    local immediate="${CLEANUP_OFFLINE_IMMEDIATE:-${immediate_default}}"

    if [[ "${do_threshold}" == "true" ]]; then
        if [[ "${immediate}" == "true" ]]; then
            log "info" "Stale-runner cleanup: scanning offline runners (IMMEDIATE mode -- no offline-since grace, dry_run=${dry_run}, max=${max_remove}, regex='${name_regex:-<all>}')"
        else
            log "info" "Stale-runner cleanup: scanning offline runners (threshold=${threshold}s, dry_run=${dry_run}, max=${max_remove}, regex='${name_regex:-<all>}')"
        fi
    fi
    if [[ "${do_similar}" == "true" ]]; then
        log "info" "Stale-runner cleanup: similar-name sweep enabled (pattern='^${RUNNER_NAME}-[0-9]+\$', require_label_match=${CLEANUP_SIMILAR_REQUIRE_LABEL_MATCH:-true})"
    fi

    local runners_url; runners_url="$(gh_api_runners_url)"
    log "info" "Stale-runner cleanup: API endpoint ${runners_url}"

    # Fetch all runners (id+name+status+labels). Each network/jq step has
    # its own error branch so a hung enterprise listing is distinguishable
    # from a silent jq parse failure (which would otherwise terminate the
    # script under `set -euo pipefail` with no output). Labels are
    # included so the similar-name pass can compare label sets without a
    # per-runner second GET.
    local now current_json="[]" total_seen=0 page=1
    now="$(date +%s)"

    while [[ "${page}" -le 10 ]]; do
        local resp http_code curl_rc body_file="/tmp/.gh-runner-cleanup-page.$$"
        http_code="$(curl -sSL --max-time 12 \
            -o "${body_file}" -w "%{http_code}" \
            -H "Authorization: token ${auth_token}" \
            -H "Accept: application/vnd.github+json" \
            "${runners_url}?per_page=100&page=${page}" 2>/dev/null)"
        curl_rc=$?
        if [[ "${curl_rc}" -ne 0 ]]; then
            log "warn" "Stale-runner cleanup: curl failed listing runners (page ${page}, exit=${curl_rc}) -- aborting sweep"
            rm -f "${body_file}"
            return 0
        fi
        if [[ "${http_code}" != "200" ]]; then
            local err_msg
            err_msg="$(jq -r '.message // empty' < "${body_file}" 2>/dev/null || true)"
            log "warn" "Stale-runner cleanup: API returned HTTP ${http_code} on page ${page}${err_msg:+ -- ${err_msg}} -- aborting sweep"
            rm -f "${body_file}"
            return 0
        fi
        resp="$(cat "${body_file}")"
        rm -f "${body_file}"

        local page_items count
        if ! page_items="$(echo "${resp}" | jq -c '[.runners[]? | {id, name, status, labels: [.labels[]?.name // empty]}]' 2>/dev/null)" \
           || [[ -z "${page_items}" ]]; then
            log "warn" "Stale-runner cleanup: malformed API response on page ${page} (no .runners[]) -- aborting sweep"
            return 0
        fi

        count="$(echo "${page_items}" | jq 'length' 2>/dev/null || echo 0)"
        total_seen=$((total_seen + count))
        log "debug" "Stale-runner cleanup: page ${page} returned ${count} runner(s) (running total ${total_seen})"

        if ! current_json="$(jq -c --argjson a "${current_json}" --argjson b "${page_items}" -n '$a + $b' 2>/dev/null)"; then
            log "warn" "Stale-runner cleanup: jq concat failed on page ${page} -- aborting sweep"
            return 0
        fi

        [[ "${count}" -lt 100 ]] && break
        page=$((page + 1))
    done

    log "info" "Stale-runner cleanup: fetched ${total_seen} runner(s) across ${page} page(s)"

    # ------------------------------------------------------------------
    # Pass A — threshold-based stale sweep (CLEANUP_OFFLINE_RUNNERS=true)
    # ------------------------------------------------------------------
    # State file: { "<runner-name>": <epoch-first-seen-offline> }
    # Always maintained when either pass is active so the timer doesn't
    # silently reset when Pass A is later turned on for the first time
    # without a state file.
    local state_json="{}"
    if [[ -f "${CLEANUP_STATE_FILE}" ]]; then
        state_json="$(cat "${CLEANUP_STATE_FILE}" 2>/dev/null)"
        if ! echo "${state_json}" | jq -e . >/dev/null 2>&1; then
            log "warn" "Stale-runner cleanup: state file is corrupt, resetting"
            state_json="{}"
        fi
    fi

    # Build new state: every currently-offline runner carries forward its
    # first-seen ts (or gets seeded with `now`). Online / vanished runners
    # are pruned.
    local new_state
    if ! new_state="$(jq -c \
        --argjson runners "${current_json}" \
        --argjson now "${now}" \
        --argjson old "${state_json}" \
        -n '
            ($runners | map(select(.status == "offline") | .name)) as $offline_names
            | reduce $offline_names[] as $n ({}; . + { ($n): ($old[$n] // $now) })
        ' 2>/dev/null)"; then
        log "warn" "Stale-runner cleanup: jq failed building offline-state map -- aborting sweep"
        return 0
    fi

    local offline_count
    offline_count="$(echo "${current_json}" | jq -r '[.[] | select(.status == "offline")] | length' 2>/dev/null || echo 0)"
    log "info" "Stale-runner cleanup: ${offline_count} runner(s) currently offline (self='${RUNNER_NAME}' will be skipped)"

    # Victim selector emits TSV rows: id<TAB>name<TAB>offline_for<TAB>reason
    # where reason is `stale` (Pass A — time threshold) or `similar`
    # (Pass B — derived from RUNNER_NAME). `offline_for` is `-1` for
    # similar-name hits because the threshold doesn't apply and we want
    # the per-victim log line to read "similar" instead of a stale
    # seconds count.
    local victims_a="" victims_b=""

    if [[ "${do_threshold}" == "true" ]]; then
        # Select Pass A victims. IMMEDIATE mode replaces the threshold
        # filter with `>= 0` so every offline runner qualifies regardless
        # of timer state.
        local effective_threshold="${threshold}"
        [[ "${immediate}" == "true" ]] && effective_threshold=0

        if ! victims_a="$(jq -r \
            --argjson runners "${current_json}" \
            --argjson now "${now}" \
            --argjson threshold "${effective_threshold}" \
            --arg regex "${name_regex}" \
            --arg self_name "${RUNNER_NAME}" \
            --argjson state "${new_state}" \
            -n '
                $runners
                | map(select(.status == "offline"))
                | map(select(.name != $self_name))
                | map(select($regex == "" or (.name | test($regex))))
                | map({
                    id: .id,
                    name: .name,
                    offline_for: ($now - ($state[.name] // $now))
                  })
                | map(select(.offline_for >= $threshold))
                | .[]
                | "\(.id)\t\(.name)\t\(.offline_for)\tstale"
            ' 2>/dev/null)"; then
            log "warn" "Stale-runner cleanup: jq failed selecting Pass A (stale) victims -- aborting sweep"
            return 0
        fi
    fi

    # ------------------------------------------------------------------
    # Pass B — similar-name sweep (CLEANUP_SIMILAR_OFFLINE=true)
    # ------------------------------------------------------------------
    # Target: offline runners whose name matches `^<RUNNER_NAME>-[0-9]+$`
    # — the exact suffix scheme produced by gh_api_deduplicate_runner_name
    # when this image fails to deregister cleanly (SIGKILL, host reboot,
    # balena replace) and a subsequent boot bumps to -1, -2, ... while
    # the previous registrations linger as offline.
    #
    # Defense-in-depth label match: if a cross-architecture peer ever
    # accidentally shared the base name (it shouldn't, since base names
    # come from BALENA_DEVICE_NAME_AT_INIT + BALENA_SERVICE_NAME), the
    # label-set inequality (e.g. ARM64 vs X64) protects it. The check is
    # opt-out via CLEANUP_SIMILAR_REQUIRE_LABEL_MATCH=false for operators
    # who tag labels per-boot.
    if [[ "${do_similar}" == "true" ]]; then
        local require_label_match="${CLEANUP_SIMILAR_REQUIRE_LABEL_MATCH:-true}"
        # Build expected-labels JSON array (sorted, lowercased, deduped,
        # empty entries dropped). When RUNNER_LABELS is unset this comes
        # out as [] and the label-match check is effectively bypassed
        # (we DO log a warning so an empty RUNNER_LABELS doesn't silently
        # disable the guard for an operator who expected it on).
        local expected_labels_json
        expected_labels_json="$(printf '%s' "${RUNNER_LABELS:-}" \
            | tr ',' '\n' \
            | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
            | awk 'NF' \
            | tr '[:upper:]' '[:lower:]' \
            | sort -u \
            | jq -R . | jq -c -s '.' 2>/dev/null)"
        [[ -z "${expected_labels_json}" || "${expected_labels_json}" == "null" ]] && expected_labels_json='[]'

        if [[ "${require_label_match}" == "true" && "${expected_labels_json}" == "[]" ]]; then
            log "warn" "Stale-runner cleanup: CLEANUP_SIMILAR_OFFLINE=true with CLEANUP_SIMILAR_REQUIRE_LABEL_MATCH=true but RUNNER_LABELS resolved to empty -- the label guard cannot match and the sweep will treat all similar-named offline runners as eligible. Set CLEANUP_SIMILAR_REQUIRE_LABEL_MATCH=false to silence this warning if intentional."
        fi

        # Build the dedup-suffix regex from RUNNER_NAME, escaping any
        # regex metacharacters in the name itself (e.g. dots, plus signs)
        # so a base like `runner.local` doesn't act as a wildcard.
        local escaped_name
        escaped_name="$(printf '%s' "${RUNNER_NAME}" | sed 's/[][\.^$*+?(){}|/]/\\&/g')"
        local similar_regex="^${escaped_name}-[0-9]+$"

        if ! victims_b="$(jq -r \
            --argjson runners "${current_json}" \
            --arg regex "${similar_regex}" \
            --arg self_name "${RUNNER_NAME}" \
            --argjson expected "${expected_labels_json}" \
            --arg require_match "${require_label_match}" \
            -n '
                # Normalize a label array the same way the bash side did:
                # lowercase, dedupe, sort. Identical normalization on
                # both sides is critical — a single case-mismatch would
                # silently skip a real victim.
                def norm($arr): [$arr[] // empty | ascii_downcase] | unique;

                $runners
                | map(select(.status == "offline"))
                | map(select(.name != $self_name))
                | map(select(.name | test($regex)))
                | map(select(
                    $require_match != "true"
                    or norm(.labels) == norm($expected)
                  ))
                | .[]
                | "\(.id)\t\(.name)\t-1\tsimilar"
            ' 2>/dev/null)"; then
            log "warn" "Stale-runner cleanup: jq failed selecting Pass B (similar-name) victims -- continuing with Pass A only"
            victims_b=""
        fi
    fi

    # Merge victim lists, dedup by id (Pass A wins on tie so the log line
    # reports the timer-based reason). The simple `sort -u -k1,1` keeps
    # only the first occurrence per id when fed `victims_a` then
    # `victims_b`, since `sort -s -k1,1n` would be stable across the
    # whole record — we want first-by-id only.
    local combined
    combined="$(printf '%s\n%s\n' "${victims_a}" "${victims_b}" \
        | awk 'NF' \
        | awk -F'\t' '!seen[$1]++')"
    local victims="${combined}"

    # Persist new state (best-effort -- /config may be read-only).
    if [[ -w "/config" || ! -e "${CLEANUP_STATE_FILE}" ]]; then
        echo "${new_state}" > "${CLEANUP_STATE_FILE}.tmp" 2>/dev/null \
            && mv -f "${CLEANUP_STATE_FILE}.tmp" "${CLEANUP_STATE_FILE}" 2>/dev/null \
            || log "debug" "Stale-runner cleanup: could not persist state file"
        chown abc:abc "${CLEANUP_STATE_FILE}" 2>/dev/null || true
    fi

    if [[ -z "${victims}" ]]; then
        log "info" "Stale-runner cleanup: nothing to remove (0 candidates after filters)"
        return 0
    fi

    local victim_count count_a count_b
    victim_count="$(echo "${victims}" | wc -l | tr -d ' ')"
    count_a="$(printf '%s\n' "${victims_a}" | awk 'NF' | wc -l | tr -d ' ')"
    count_b="$(printf '%s\n' "${victims_b}" | awk 'NF' | wc -l | tr -d ' ')"
    log "info" "Stale-runner cleanup: ${victim_count} candidate(s) selected (stale=${count_a}, similar=${count_b}), capped at max=${max_remove}"

    local removed=0 skipped=0 failed=0 line rid rname rfor reason del_code del_body_file
    local IFS=$'\n'
    for line in ${victims}; do
        if (( removed >= max_remove )); then
            skipped=$((skipped + 1))
            continue
        fi
        rid="$(echo "${line}" | cut -f1)"
        rname="$(echo "${line}" | cut -f2)"
        rfor="$(echo "${line}" | cut -f3)"
        reason="$(echo "${line}" | cut -f4)"

        # Human-friendly suffix for the per-victim log line.
        local why
        if [[ "${reason}" == "similar" ]]; then
            why="similar-name leftover of '${RUNNER_NAME}'"
        elif [[ "${immediate}" == "true" ]]; then
            why="status=offline, immediate"
        else
            why="offline ${rfor}s"
        fi

        if [[ "${dry_run}" == "true" ]]; then
            log "info" "Stale-runner cleanup: [DRY RUN] would remove '${rname}' (id=${rid}, ${why})"
            removed=$((removed + 1))
            continue
        fi

        del_body_file="/tmp/.gh-runner-cleanup-del.$$"
        del_code="$(curl -sSL --max-time 6 -o "${del_body_file}" -w "%{http_code}" -X DELETE \
            -H "Authorization: token ${auth_token}" \
            -H "Accept: application/vnd.github+json" \
            "${runners_url}/${rid}" 2>/dev/null)" || del_code="000"

        if [[ "${del_code}" == "204" ]]; then
            log "info" "Stale-runner cleanup: removed '${rname}' (id=${rid}, ${why})"
            removed=$((removed + 1))
        else
            local del_msg
            del_msg="$(jq -r '.message // empty' < "${del_body_file}" 2>/dev/null || true)"
            log "warn" "Stale-runner cleanup: failed to remove '${rname}' (id=${rid}, HTTP ${del_code}${del_msg:+ -- ${del_msg}})"
            failed=$((failed + 1))
        fi
        rm -f "${del_body_file}"
    done
    unset IFS

    log "info" "Stale-runner cleanup: removed=${removed} failed=${failed} skipped(over-cap)=${skipped}"
}
