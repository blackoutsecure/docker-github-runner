#!/usr/bin/with-contenv bash
# shellcheck shell=bash
#
# Shared logging primitives for docker-github-runner s6 init/svc scripts.
#
# Usage:
#     # shellcheck disable=SC1091
#     . /usr/local/bin/log-functions.sh
#     LOG_TAG="init-gh-runner-config"
#     log info "hello"
#
# Output format (single line):
#     <RFC3339 UTC timestamp> <LOG_TAG>[<level>]: <message>
#
# Severity ordering (case-insensitive):  debug < info < warn < error < fatal
# Lines below ${LOG_LEVEL:-info} are dropped. 'fatal' is always emitted.

_log_severity() {
    case "${1,,}" in
        debug) echo 10 ;;
        info)  echo 20 ;;
        warn)  echo 30 ;;
        error) echo 40 ;;
        fatal) echo 50 ;;
        *)     echo 20 ;;
    esac
}

log() {
    local level="$1"; shift
    local cur min
    cur=$(_log_severity "${level}")
    min=$(_log_severity "${LOG_LEVEL:-info}")
    if [[ "${level,,}" != "fatal" && "${cur}" -lt "${min}" ]]; then
        return 0
    fi
    printf '%s %s[%s]: %s\n' \
        "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
        "${LOG_TAG:-runner}" \
        "${level}" \
        "$*"
}
