#!/usr/bin/with-contenv bash
# shellcheck shell=bash
#
# Shared banner primitives for docker-github-runner.
#
# Goal: every long-form, multi-line log block in this image (startup
# banner, periodic health heartbeat, job lifecycle banner, autoscaler
# per-cycle status, etc.) renders with the exact same shape so an
# operator can scan `docker logs` / `balena logs` and recognise the
# blocks at a glance.
#
# All output is plain ASCII (no Unicode box-drawing chars). balenaCloud's
# dashboard log viewer mangles U+2500/U+2501/U+2550 into mojibake.
#
# Usage:
#
#     . /usr/local/bin/log-functions.sh
#     . /usr/local/bin/banner-functions.sh
#     LOG_TAG="autoscaler"
#
#     banner_top
#     banner_title "info" "AUTOSCALER STATUS (${RUNNER_NAME:-$(hostname)})"
#     banner_thin
#     banner_section "info" "Demand"
#     banner_kv     "info" "Online"       "${online}"
#     banner_kv     "info" "Busy"         "${busy}"
#     banner_section "info" "Pool"
#     banner_kv     "info" "Replicas"     "${current}"
#     banner_bottom
#
# All helpers accept the same first-arg severity convention as the shared
# log() function (debug|info|warn|error|fatal). Default severity is "info".
#
# Tunables (env, optional):
#     BANNER_KEY_WIDTH   Column width of the key field in banner_kv
#                        output. Default 17. Keys longer than this are
#                        printed as-is (not truncated).
#

# Long line of '=' used at top + bottom of major blocks. Matches the
# init-gh-runner-config banner width, the heartbeat, the worker banner,
# and the autoscaler header so they all line up in fixed-width log views.
: "${BANNER_LINE:======================================================================}"
: "${BANNER_THIN:=----------------------------------------------------------------------}"
: "${BANNER_KEY_WIDTH:=17}"

banner_top() {
    log "${1:-info}" "${BANNER_LINE}"
}

banner_bottom() {
    log "${1:-info}" "${BANNER_LINE}"
}

banner_thin() {
    log "${1:-info}" "${BANNER_THIN}"
}

# banner_title <level> <title text>
# Renders centered-ish title between the two heavy rules:
#   =======================================================================
#     *** TITLE TEXT ***
#   -----------------------------------------------------------------------
banner_title() {
    local level="$1"; shift
    log "${level}" "  *** $* ***"
}

# banner_kv <level> <key> <value>
# Emits a key:value row with the project-wide alignment. Keys longer than
# BANNER_KEY_WIDTH are NOT truncated — they extend the row, preserving the
# operator's ability to add new fields without breaking older ones.
banner_kv() {
    local level="$1" key="$2" value="$3" pad
    printf -v pad '%-*s' "${BANNER_KEY_WIDTH}" "${key}"
    log "${level}" "    ${pad}: ${value}"
}

# banner_section <level> <heading>
# Visual divider for grouping related key:value rows inside a single banner
# block. Output:
#   [Heading]
#   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
banner_section() {
    local level="$1" heading="$2"
    log "${level}" "  [${heading}]"
    log "${level}" "  - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
}
