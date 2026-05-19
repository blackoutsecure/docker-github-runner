#!/usr/bin/with-contenv bash
# shellcheck shell=bash
#
# Runtime helpers shared by every init/svc script:
#   - LSIO non-root mode detection + as_runner_user wrapper
#   - prefix_lines (stamp arbitrary command output with our service tag)
#   - stage_begin / stage_end (timed init progress markers)
#   - filesystem fix-ups (/tmp, runner dir, legacy paths)
#   - cleanup_stale_artifacts (diag logs, orphan workers, ephemeral .runner)
#   - load_env_file / load_secrets_dir (optional bulk env loading)
#

# ---------------------------------------------------------------------------
# Non-root mode detection
# ---------------------------------------------------------------------------
# Sets RUN_AS_NONROOT=1 when the container was started with --user (so we
# are not root and PUID/PGID/Mods/EXTRA_PACKAGES are ignored). When 0 we
# follow the LSIO default and drop to abc (uid 911) via s6-setuidgid.
#
# Reference: https://docs.linuxserver.io/misc/non-root/
gh_runtime_detect_user_mode() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        RUN_AS_NONROOT=1
        CURRENT_UID="$(id -u)"
        CURRENT_GID="$(id -g)"
        log "info" "Container is running as non-root (uid=${CURRENT_UID} gid=${CURRENT_GID}) -- LSIO non-root mode"
        log "info" "PUID/PGID, Docker Mods, and EXTRA_PACKAGES are ignored in this mode"
    else
        RUN_AS_NONROOT=0
        CURRENT_UID=0
        CURRENT_GID=0
    fi
    export RUN_AS_NONROOT CURRENT_UID CURRENT_GID
    mkdir -p /run/s6/container_environment 2>/dev/null || true
    printf '%s' "${RUN_AS_NONROOT}" > /run/s6/container_environment/RUN_AS_NONROOT 2>/dev/null || true
}

# as_runner_user <cmd> <args...>
# Run a command as the runner user. In root mode this is `s6-setuidgid abc`;
# in non-root mode (--user) we already are the right uid so just exec it.
as_runner_user() {
    if [[ "${RUN_AS_NONROOT:-0}" == "1" ]]; then
        "$@"
    else
        s6-setuidgid abc "$@"
    fi
}

# ---------------------------------------------------------------------------
# prefix_lines <tag>
# ---------------------------------------------------------------------------
# Stamp arbitrary stdout/stderr (e.g. from config.sh, the banner block,
# etc.) with a uniform `<ts> <LOG_TAG>[<tag>]:` header so external log
# shippers can identify which service the line came from. Drops blank
# lines and passes banner blocks (== or -- fences) through verbatim so
# the ASCII-art alignment survives.
#
# CRITICAL: wraps both stages in `stdbuf -oL` so the pipeline is
# line-buffered end-to-end. Without it, awk's libc stdio buffers ~4 KB
# before flushing and a mid-flight kill (e.g. healthcheck-driven
# orchestrator timeout) loses everything not yet flushed.
prefix_lines() {
    local tag="${1:-info}"
    # First sed pass: rewrite the most common UTF-8 glyphs from config.sh
    # (checkmarks, crosses, arrows) into readable ASCII and strip any
    # remaining non-printable bytes. LC_ALL=C makes sed treat multi-byte
    # sequences as raw bytes so the rewrites are deterministic regardless
    # of locale.
    LC_ALL=C stdbuf -oL sed -u \
        -e 's/\xe2\x9c\x93/[OK]/g' \
        -e 's/\xe2\x9c\x94/[OK]/g' \
        -e 's/\xe2\x9c\x97/[X]/g'  \
        -e 's/\xe2\x9c\x98/[X]/g'  \
        -e 's/\xe2\x86\x92/->/g'   \
        -e 's/[^[:print:]\t]//g' \
    | stdbuf -oL awk -v tag="${tag}" -v log_tag="${LOG_TAG}" '
        {
            if ($0 ~ /^[[:space:]]*$/) next

            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)

            is_eq_fence   = (line ~ /^={20,}$/)
            is_dash_fence = (line ~ /^-{20,}$/)

            if (is_eq_fence) {
                in_eq_banner = !in_eq_banner
                print line; fflush(); next
            }

            if (is_dash_fence) {
                if (in_eq_banner) { print line; fflush(); next }
                in_dash_banner = !in_dash_banner
                print line; fflush(); next
            }

            if (in_eq_banner || in_dash_banner) {
                print $0; fflush(); next
            }

            cmd = "date -u +%Y-%m-%dT%H:%M:%SZ"
            cmd | getline ts
            close(cmd)
            printf "%s %s[%s]: %s\n", ts, log_tag, tag, $0
            fflush()
        }
    '
}

# ---------------------------------------------------------------------------
# stage_begin / stage_end
# ---------------------------------------------------------------------------
# Long-running silent init steps (recursive chown over ~9000 files on
# overlayfs, GitHub API pagination, etc.) make the container look hung.
# Bracket each long step with stage_begin/stage_end to emit a clearly
# tagged line and elapsed-ms measurement.
_STAGE_NAME=""
_STAGE_START_NS=0
stage_begin() {
    _STAGE_NAME="$1"
    _STAGE_START_NS="$(date +%s%N)"
    log "info" "==> [stage] ${_STAGE_NAME} ..."
    sync 2>/dev/null || true
}
stage_end() {
    local end_ns ms
    end_ns="$(date +%s%N)"
    ms=$(( (end_ns - _STAGE_START_NS) / 1000000 ))
    log "info" "<== [stage] ${_STAGE_NAME} done in ${ms} ms"
    sync 2>/dev/null || true
    _STAGE_NAME=""
}

# ---------------------------------------------------------------------------
# /tmp + runner dir fix-ups (root mode only)
# ---------------------------------------------------------------------------
# When operators mount /tmp as tmpfs (common in hardened compose examples,
# required with read_only:true) Docker creates it 1755 unless mode=1777 is
# passed. CI workloads running as abc (uid 911) -- notably
# docker/setup-buildx-action -- then fail with EPERM on /tmp/buildkitd-*.
# We re-apply 1777 here (we're still root and have DAC_OVERRIDE).
gh_runtime_fix_tmp() {
    if [[ -d /tmp ]]; then
        if ! chmod 1777 /tmp 2>/dev/null; then
            log "warn" "Could not chmod 1777 /tmp -- buildx and other CI tooling running as the runner user may fail with permission errors; mount /tmp tmpfs with mode=1777"
        fi
    fi
}

# gh_runtime_fix_runner_dir [<runner_dir>]
# Defensive ownership/permission fix-up for the runner install tree.
# The build-time install drops `.ownership-baked` (owned abc:abc, 0444);
# when present we trust it and skip the recursive walks -- on slow ARM
# storage these take 60-130s of silent cold-start. Force the walk with
# FORCE_RUNNER_PERMISSIONS_FIX=true.
#
# Also migrates a legacy /opt/actions-runner tree left over from earlier
# image revisions.
gh_runtime_fix_runner_dir() {
    local runner_dir="${1:-${RUNNER_DIR:-/opt/runner-bin}}"

    if [[ -d "${runner_dir}" ]]; then
        local force="${FORCE_RUNNER_PERMISSIONS_FIX:-false}"
        local marker="${runner_dir}/.ownership-baked"
        if [[ "${force,,}" != "true" && -f "${marker}" ]]; then
            log "debug" "Runner dir ${runner_dir} carries build-time ownership marker -- skipping recursive chown/chmod (set FORCE_RUNNER_PERMISSIONS_FIX=true to override)"
        else
            if [[ "${force,,}" == "true" ]]; then
                log "info" "FORCE_RUNNER_PERMISSIONS_FIX=true -- running defensive chown/chmod over ${runner_dir}"
            else
                log "info" "No ownership marker at ${marker} -- running defensive chown/chmod over ${runner_dir} (~9000 files, may take a few seconds on slow storage)"
            fi
            local t0; t0="$(date +%s%N)"
            if ! chown -R abc:abc "${runner_dir}" 2>/dev/null; then
                log "warn" "chown -R abc:abc ${runner_dir} failed (cap CHOWN missing or read-only mount?) -- runner may hit permission errors"
            else
                log "info" "Ownership fix completed in $(( ($(date +%s%N) - t0) / 1000000 )) ms"
            fi
            t0="$(date +%s%N)"
            find "${runner_dir}" -type d -exec chmod u+wx {} + 2>/dev/null || true
            log "info" "Directory mode fix completed in $(( ($(date +%s%N) - t0) / 1000000 )) ms"
        fi
    fi

    # Migration: drop a legacy /opt/actions-runner tree from an earlier image.
    if [[ -d /opt/actions-runner && ! -L /opt/actions-runner ]]; then
        log "info" "Removing legacy /opt/actions-runner tree (no longer used; runner now runs from ${runner_dir})"
        rm -rf /opt/actions-runner 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# cleanup_stale_artifacts
# ---------------------------------------------------------------------------
# Trim old diag logs (>7d), kill orphaned Runner.Worker processes from a
# previous hard kill, and clear stale ephemeral .runner config so the next
# registration starts clean.
cleanup_stale_artifacts() {
    local runner_dir="${RUNNER_DIR:-/opt/runner-bin}"

    if [[ -d "${runner_dir}/_diag" ]]; then
        local count
        count="$(find "${runner_dir}/_diag" -name '*.log' -mtime +7 -type f 2>/dev/null | wc -l)"
        if [[ "${count}" -gt 0 ]]; then
            find "${runner_dir}/_diag" -name '*.log' -mtime +7 -type f -delete
            log "info" "Cleaned up ${count} stale diagnostic log(s) older than 7 days"
        fi
    fi

    local stale_pids
    stale_pids="$(pgrep -f 'Runner.Worker' 2>/dev/null || true)"
    if [[ -n "${stale_pids}" ]]; then
        log "warn" "Found orphaned Runner.Worker processes, terminating: ${stale_pids}"
        echo "${stale_pids}" | xargs kill -9 2>/dev/null || true
    fi

    if [[ "${RUNNER_EPHEMERAL:-false}" == "true" && -f "${runner_dir}/.runner" ]]; then
        log "info" "Ephemeral mode: removing stale .runner config from previous run"
        rm -f "${runner_dir}/.runner" \
              "${runner_dir}/.credentials" \
              "${runner_dir}/.credentials_rsaparams"
    fi
}

# ---------------------------------------------------------------------------
# Env file / secrets dir loading
# ---------------------------------------------------------------------------
# RUNNER_ENV_FILE: parse a simple KEY=value file (with # comments, optional
#   quoting) and export each entry. Validates KEY syntax and skips obviously
#   malformed lines.
# RUNNER_SECRETS_DIR: every file in the directory whose name is a valid
#   identifier is exported with its contents (trailing newline trimmed).
#
# Both also write the value to /run/s6/container_environment so downstream
# services see it.
gh_runtime_load_env_file() {
    [[ -n "${RUNNER_ENV_FILE:-}" ]] || return 0

    if [[ ! -f "${RUNNER_ENV_FILE}" || ! -r "${RUNNER_ENV_FILE}" ]]; then
        log "fatal" "RUNNER_ENV_FILE is set to '${RUNNER_ENV_FILE}' but the file does not exist or is not readable"
        exit 1
    fi

    log "info" "Loading environment variables from ${RUNNER_ENV_FILE}"
    local count=0 line key val
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        line="${line%%[[:space:]]#*}"
        if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            if [[ "${val}" =~ ^\"(.*)\"$ ]] || [[ "${val}" =~ ^\'(.*)\'$ ]]; then
                val="${BASH_REMATCH[1]}"
            fi
            export "${key}=${val}"
            printf '%s' "${val}" > "/run/s6/container_environment/${key}"
            count=$((count + 1))
        else
            log "warn" "Skipping invalid line in env file: ${line}"
        fi
    done < "${RUNNER_ENV_FILE}"
    log "info" "Loaded ${count} environment variable(s) from env file"
}

gh_runtime_load_secrets_dir() {
    [[ -n "${RUNNER_SECRETS_DIR:-}" ]] || return 0

    if [[ ! -d "${RUNNER_SECRETS_DIR}" || ! -r "${RUNNER_SECRETS_DIR}" ]]; then
        log "fatal" "RUNNER_SECRETS_DIR is set to '${RUNNER_SECRETS_DIR}' but the directory does not exist or is not readable"
        exit 1
    fi

    log "info" "Loading secrets from directory ${RUNNER_SECRETS_DIR}"
    local count=0 secret_file key val
    for secret_file in "${RUNNER_SECRETS_DIR}"/*; do
        [[ -f "${secret_file}" && -r "${secret_file}" ]] || continue
        key="$(basename "${secret_file}")"
        if ! [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            log "warn" "Skipping '${key}' -- not a valid env var name"
            continue
        fi
        val="$(< "${secret_file}")"
        val="${val%%$'\n'}"
        export "${key}=${val}"
        printf '%s' "${val}" > "/run/s6/container_environment/${key}"
        count=$((count + 1))
    done
    log "info" "Loaded ${count} secret(s) from directory"
}

# ---------------------------------------------------------------------------
# format_duration_human <seconds>
# ---------------------------------------------------------------------------
# Compact "[<h>h ]<m>m <s>s" or "<s>s" formatting. Used by the heartbeat
# banners and the worker-finished message.
format_duration_human() {
    local total="${1:-0}" h m s
    (( total < 0 )) && total=0
    h=$(( total / 3600 ))
    m=$(( (total % 3600) / 60 ))
    s=$(( total % 60 ))
    if (( h > 0 )); then echo "${h}h ${m}m ${s}s"
    elif (( m > 0 )); then echo "${m}m ${s}s"
    else echo "${s}s"
    fi
}
