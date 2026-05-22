#!/usr/bin/env bash
# Managed by https://github.com/blackoutsecure/bos-automation-hub —
# do not edit. To modify, update the `logger` service in
# .github/actions/sync-managed-files/sync.py.
#
# shellcheck shell=bash
#
# Canonical shared logging library for s6-overlay init and svc scripts
# across the blackoutsecure container fleet.
#
# Sourced (not executed). Provides one consistent log line format:
#
#     <RFC3339 UTC> <tag>[<level>]: <message>
#
# Two API styles are supported (mix freely; pick whichever reads best
# at the call site):
#
#   1. Function-per-level:
#          SVC_NAME="svc-readsb"      # OR: LOG_TAG="svc-readsb"
#          . /usr/local/bin/log-functions.sh
#          log_info  "starting up"
#          log_warn  "degraded"
#          log_error "connection refused"
#          log_fatal "cannot continue"
#          log_debug "fyi"            # gated by LOG_LEVEL
#      warn/error/fatal route to stderr; debug/info to stdout.
#
#   2. Generic dispatcher:
#          LOG_TAG="svc-gh-runner"    # OR: SVC_NAME="svc-gh-runner"
#          . /usr/local/bin/log-functions.sh
#          log info  "starting up"
#          log warn  "degraded"
#          log error "connection refused"
#          log fatal "cannot continue"
#      All levels route to stdout (legacy docker-github-runner shape).
#      Callers that want stderr add `>&2` at the call site.
#
# Severity ordering (case-insensitive):
#     debug < info < warn < error < fatal
# Lines below ${LOG_LEVEL:-info} are dropped; `fatal` is always emitted.
#
# Tag resolution: SVC_NAME wins, then LOG_TAG, then "unknown" (with a
# one-shot warning on stderr) so a misconfigured caller is noisy but not
# fatal.
#
# Extras (readsb provenance):
#   log_kv KEY value             # pretty key/value (gated at info)
#   log_pipe_cmd [priority]      # awk pipe that prefixes each stdin
#                                # line with the syslog format. Usage:
#                                #   exec mybinary 2>&1 \
#                                #     | eval "$(log_pipe_cmd decoder)"

if [[ -z "${SVC_NAME:-}" && -z "${LOG_TAG:-}" ]]; then
    printf '%s log-functions.sh[warn]: neither SVC_NAME nor LOG_TAG set; using "unknown"\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >&2
fi

_log_tag() {
    printf '%s' "${SVC_NAME:-${LOG_TAG:-unknown}}"
}

_log_severity() {
    case "${1,,}" in
        debug) printf '10' ;;
        info)  printf '20' ;;
        warn)  printf '30' ;;
        error) printf '40' ;;
        fatal) printf '50' ;;
        *)     printf '20' ;;
    esac
}

_log_should_emit() {
    # _log_should_emit <level> -> 0 if yes, 1 if no
    local level="${1,,}" cur min
    [[ "${level}" == "fatal" ]] && return 0
    cur=$(_log_severity "${level}")
    min=$(_log_severity "${LOG_LEVEL:-info}")
    [[ "${cur}" -ge "${min}" ]]
}

_log_emit() {
    # _log_emit <level> <fd> <msg ...>
    local level="$1" fd="$2"; shift 2
    printf '%s %s[%s]: %s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        "$(_log_tag)" \
        "${level}" \
        "$*" >&"${fd}"
}

# Generic dispatcher (docker-github-runner API). All levels to stdout to
# preserve legacy behavior; callers add `>&2` when they want stderr.
log() {
    local level="$1"; shift
    _log_should_emit "${level}" || return 0
    _log_emit "${level}" 1 "$*"
}

# Function-per-level (readsb / mlat-hub API). warn/error/fatal -> stderr.
log_debug() { _log_should_emit debug && _log_emit debug 1 "$@"; return 0; }
log_info()  { _log_should_emit info  && _log_emit info  1 "$@"; return 0; }
log_warn()  { _log_should_emit warn  && _log_emit warn  2 "$@"; return 0; }
log_error() { _log_should_emit error && _log_emit error 2 "$@"; return 0; }
log_fatal() { _log_emit fatal 2 "$@"; }

# Pretty key/value (readsb provenance). Gated at info.
log_kv() {
    _log_should_emit info || return 0
    local key="$1" value="$2"
    printf '%s %s[%s]: %-15s %s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        "$(_log_tag)" \
        "info" \
        "${key}:" \
        "${value}"
}

# Returns an awk pipeline string for prefixing each stdin line with the
# syslog format. fflush() avoids buffering so log lines surface in real
# time. Usage:
#     exec some-binary 2>&1 | eval "$(log_pipe_cmd decoder)"
log_pipe_cmd() {
    local priority="${1:-stdout}"
    local tag
    tag="$(_log_tag)"
    printf "awk '{ printf \"%%s %s[%s]: %%s\\\\n\", strftime(\"%%Y-%%m-%%dT%%H:%%M:%%SZ\", systime(), 1), \$0; fflush() }'" \
        "${tag}" "${priority}"
}
