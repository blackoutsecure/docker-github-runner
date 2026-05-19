#!/usr/bin/with-contenv bash
# shellcheck shell=bash
#
# Worker lifecycle + health banner helpers shared by svc-gh-runner-logs.
#
# Globals shared with the orchestrator:
#   WORKER_START_TS  - associative array (worker pid -> epoch start ts)
#

# Per-worker start timestamps; consumed by emit_health_banner and the
# FINISHED banner so we can report job duration.
declare -A WORKER_START_TS=()

# emit_worker_banner <STARTED|FINISHED> <pid> <extra>
# Multi-line banner styled like the init startup block so each job sticks
# out in `docker logs`. STARTED also dumps the worker cmdline at debug level.
emit_worker_banner() {
    local kind="$1" pid="$2" extra="$3"
    local now_iso parent_pid worker_log cmdline=""
    now_iso="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

    parent_pid="$(ps -o ppid= -p "${pid}" 2>/dev/null | tr -d ' ' || true)"

    # cmdline only on STARTED. On FINISHED the pid is gone and the shell's
    # input redirect prints "No such file" to ITS OWN stderr (not tr's), so
    # the brace-group redirect below covers both.
    if [[ "${kind}" == "STARTED" ]]; then
        cmdline="$({ tr '\0' ' ' < "/proc/${pid}/cmdline"; } 2>/dev/null | sed 's/  *$//')"
    fi
    worker_log="$(ls -1t "${DIAG_DIR}"/Worker_*.log 2>/dev/null | head -n1)"
    worker_log="${worker_log##*/}"
    [[ -z "${worker_log}" ]] && worker_log="(pending)"

    banner_top "info"
    if [[ "${kind}" == "STARTED" ]]; then
        banner_title "info" ">>> JOB STARTED on ${RUNNER_NAME:-$(hostname)}"
    else
        banner_title "info" "<<< JOB FINISHED on ${RUNNER_NAME:-$(hostname)}"
    fi
    banner_thin "info"
    banner_kv "info" "Worker PID" "${pid}"
    [[ -n "${parent_pid}" ]] && banner_kv "info" "Parent" "Listener pid ${parent_pid}"
    banner_kv "info" "Started At" "${now_iso}"
    banner_kv "info" "Worker Log" "_diag/${worker_log}"
    if [[ "${kind}" == "STARTED" && -n "${cmdline}" ]]; then
        banner_kv "debug" "Command" "${cmdline}"
    fi
    [[ -n "${extra}" ]] && log "info" "    ${extra}"
    banner_bottom "info"
}

# collect_descendant_pids <pid>
# Recursively gather every descendant pid of a worker (space-separated).
# Used by detect_worker_workspace + child-count reporting.
collect_descendant_pids() {
    local root_pid="$1" child out=""
    for child in $(pgrep -P "${root_pid}" 2>/dev/null); do
        out+=" ${child}"
        out+="$(collect_descendant_pids "${child}")"
    done
    echo "${out}"
}

# detect_worker_workspace <worker_pid> <RUNNER_WORKDIR>
# Best-effort: walk worker + descendants looking for a cwd rooted under
# <RUNNER_WORKDIR>/_work/... -- that's the active checkout path.
detect_worker_workspace() {
    local worker_pid="$1" work_dir="$2" pid cwd
    for pid in "${worker_pid}" $(collect_descendant_pids "${worker_pid}"); do
        [[ -r "/proc/${pid}/cwd" ]] || continue
        cwd="$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"
        if [[ -n "${cwd}" && "${cwd}" == "${work_dir}/_work/"* ]]; then
            echo "${cwd}"
            return 0
        fi
    done
    echo "${work_dir}/_work (pending)"
    return 1
}

# emit_health_banner <kind> <status> <status_note> <uptime_hr> <uptime_min> <worker_pids> <state_age>
#   kind        : HEARTBEAT | JOB-HEARTBEAT
#   status      : idle | running job | offline
#   status_note : free-form GitHub API verification note (may be empty)
emit_health_banner() {
    local kind="$1" status="$2" status_note="$3"
    local uptime_hr="$4" uptime_min="$5" worker_pids="$6" state_age="$7"
    local listener_pid load_avg disk_free disk_pct work_dir
    local worker_count=0 child_total=0 idle_count=0 c wpid

    listener_pid="$(pgrep -f 'Runner.Listener' 2>/dev/null | head -n1)"
    [[ -z "${listener_pid}" ]] && listener_pid="(none)"

    load_avg="$(awk '{printf "%s %s %s", $1, $2, $3}' /proc/loadavg 2>/dev/null)"
    [[ -z "${load_avg}" ]] && load_avg="(unavailable)"

    work_dir="${RUNNER_WORKDIR:-/config/work}"
    if [[ -d "${work_dir}" ]]; then
        # df -P columns: filesystem size used avail use% mount
        read -r _ _ _ disk_free disk_pct _ < <(df -P "${work_dir}" 2>/dev/null | tail -n1)
        [[ -n "${disk_free}" ]] && disk_free="$(numfmt --to=iec --from-unit=1024 "${disk_free}" 2>/dev/null || echo "${disk_free}K")"
    fi
    [[ -z "${disk_free}" ]] && disk_free="(unavailable)"
    [[ -z "${disk_pct}"  ]] && disk_pct="?"

    if [[ -n "${worker_pids}" ]]; then
        worker_count="$(echo "${worker_pids}" | wc -w)"
        for wpid in ${worker_pids}; do
            c="$(pgrep -P "${wpid}" 2>/dev/null | wc -l)"
            child_total=$(( child_total + c ))
        done
    fi

    # Idle slots: for the ephemeral single-slot runner model this is 0 or
    # 1. Generalises to N-slot configurations if multi-job hosting is ever
    # added. Reported as 0 when listener is dead so it matches what
    # GitHub's org-runners UI shows.
    if [[ "${listener_pid}" != "(none)" ]]; then
        idle_count=$(( 1 - worker_count ))
        (( idle_count < 0 )) && idle_count=0
    fi

    banner_top "info"
    if [[ "${kind}" == "JOB-HEARTBEAT" ]]; then
        banner_title "info" "JOB HEARTBEAT (${RUNNER_NAME:-$(hostname)})"
    else
        banner_title "info" "HEALTH HEARTBEAT (${RUNNER_NAME:-$(hostname)})"
    fi
    banner_thin "info"
    banner_section "info" "Runner"
    banner_kv "info" "Status"          "${status}"
    banner_kv "info" "State Duration"  "${state_age}"
    [[ -n "${status_note}" ]] && \
        banner_kv "info" "GitHub API Check" "${status_note}"
    banner_section "info" "Process"
    banner_kv "info" "Uptime"          "${uptime_hr}h ${uptime_min}m"
    banner_kv "info" "Listener PID"    "${listener_pid}"
    banner_kv "info" "Load Avg (1/5/15)" "${load_avg}"
    banner_section "info" "Storage"
    banner_kv "info" "Work Dir"        "${work_dir} (free: ${disk_free}, used: ${disk_pct})"
    banner_section "info" "Workers"
    banner_kv "info" "Active Workers"  "${worker_count}"
    banner_kv "info" "Idle Workers"    "${idle_count}"
    if (( worker_count > 0 )); then
        banner_kv "info" "Child Processes" "${child_total} (across all workers)"
        local now_epoch wstart wdur_s wdur_m wdur_sec wchildren workspace_dir
        now_epoch="$(date +%s)"
        for wpid in ${worker_pids}; do
            wstart="${WORKER_START_TS[$wpid]:-0}"
            if (( wstart > 0 )); then
                wdur_s=$(( now_epoch - wstart ))
                wdur_m=$(( wdur_s / 60 ))
                wdur_sec=$(( wdur_s % 60 ))
            else
                wdur_m=0; wdur_sec=0
            fi
            wchildren="$(pgrep -P "${wpid}" 2>/dev/null | wc -l)"
            workspace_dir="$(detect_worker_workspace "${wpid}" "${work_dir}")"
            log "info" "      - Worker pid=${wpid}  elapsed=${wdur_m}m ${wdur_sec}s  children=${wchildren}  workspace=${workspace_dir}"
        done
    fi
    banner_bottom "info"
}
