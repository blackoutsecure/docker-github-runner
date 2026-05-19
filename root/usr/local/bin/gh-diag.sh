#!/usr/bin/with-contenv bash
# shellcheck shell=bash
#
# Runner _diag/*.log tailing + noise suppression.
#
# Exports two constants used by the awk filter and one entry function:
#   NOISE_RE          - blanket suppression of internal log classes at
#                       INFO/VERB/DEBUG/TRACE.
#   BENIGN_WARN_RE    - exact-shape suppression for known-benign WARNs the
#                       runner itself marks "Ignore exception".
#   gh_diag_tail_file <file>
#                     - launches `tail -F` piped through the awk multi-line
#                       suppression + LOG_LEVEL severity gating filter. The
#                       caller is expected to background the call ( & ).
#
# Why awk and not `grep -v`:
#   The runner emits multi-line records (notably
#   ActionManifestManagerLegacy dumping JSON value trees). A plain
#   `grep -v <header>` drops only the header and lets the continuation
#   lines through, defeating the entire suppression. The awk pass tracks
#   suppress state across continuation lines.
#

# IMPORTANT: runner log format is `[YYYY-MM-DD HH:MM:SSZ LEVEL ClassName] message`.
# An earlier revision had the order reversed (`CLASS LEVEL`) so nothing
# was ever actually filtered. The regex below correctly anchors on
# ` LEVEL ClassName]` with a leading space and a trailing `]` (portable
# across gawk and mawk; `\b` is not).
#
# We INTENTIONALLY keep ProcessInvokerWrapper *INFO* because Worker_*.log
# uses it for "Starting process: ..." entries -- the only easy way to see
# what a job is doing from `docker logs`. VERB/DEBUG/TRACE from the same
# class is still dropped.
NOISE_RE=' (INFO|VERB|VERBOSE|DEBUG|TRACE) (HostContext|CommandSettings|ConfigurationStore|CredentialManager|RSAFileKeyManager|UnixUtil|CommandLineParser|SystemDControlManager|RunnerService|Terminal|GitHubActionsService|ActionManifestManagerLegacy|ActionManifestManager|ExtensionManager|ActionCommandManager|ExecutionContext|JobServerQueue|Worker|JobRunner|Variables|StepsRunner|ContainerOperationProvider)]| (VERB|VERBOSE|DEBUG|TRACE) ProcessInvokerWrapper]'

# Known-benign WARNs the runner already swallowed. Anchored on class +
# message prefix so any NEW or genuinely different WARN from the same
# class still surfaces verbatim.
#
# Currently:
#   - JobExtension "Ignore exception during read process environment
#     variables: Access to the path '/proc/<pid>/environ' is denied."
#     Fires once per job finish in hardened containers (cap_drop=ALL, no
#     CAP_SYS_PTRACE) when child processes are owned by a different UID
#     -- typically dockerd / containerd-shim under DOCKER_IN_DOCKER=true.
#     Granting CAP_SYS_PTRACE just to silence this would be a security
#     regression; the full payload is still in _diag/Worker_*.log.
BENIGN_WARN_RE=' WARN JobExtension] Ignore exception during read process environment variables:'

# gh_diag_tail_file <file>
# Tail one diag file with multi-line aware suppression + per-line severity
# gating against LOG_LEVEL. Re-emits each surviving line with a uniform
# `runner-diag[<lvl>] (<basename>):` prefix and visual flags for warn/error.
#
# Caller MUST background the call ( gh_diag_tail_file "$f" & ) so multiple
# files can be tailed concurrently from the main loop.
gh_diag_tail_file() {
    local f="$1"
    local min_sev; min_sev="$(_log_severity "${LOG_LEVEL:-info}")"

    tail -n 50 -F "${f}" 2>/dev/null \
        | awk -v src="${f##*/}" -v min_sev="${min_sev}" \
              -v noise_re="${NOISE_RE}" -v benign_warn_re="${BENIGN_WARN_RE}" '
            BEGIN { suppress = 0 }
            {
                # Header line = starts with a runner timestamp + level marker.
                # Format: [YYYY-MM-DD HH:MM:SSZ LEVEL ClassName] message
                is_header = ($0 ~ /^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}Z (DEBUG|TRACE|VERB|VERBOSE|INFO|WARN|WARNING|ERR|ERROR|FATAL) /)

                if (is_header) {
                    # New record -- decide whether to suppress this one AND
                    # any continuation lines that follow.
                    if ($0 ~ noise_re)        { suppress = 1; next }
                    if ($0 ~ benign_warn_re)  { suppress = 1; next }
                    suppress = 0
                } else {
                    # Continuation of previous record -- inherit suppression
                    # so multi-line JSON dumps don'\''t leak.
                    if (suppress) next

                    # BACKSTOP: even when the header escaped NOISE_RE (a
                    # new runner version added a class we have not seen,
                    # or upstream renamed an existing one), continuation
                    # lines that look like pretty-printed JSON value-tree
                    # fragments are never useful in `docker logs`. They
                    # are still preserved in _diag/Worker_*.log on disk;
                    # suppressing the firehose here prevents balena
                    # per-service log rate-limit hits AND keeps PAT
                    # scopes / org metadata from leaking to log shippers.
                    if ($0 ~ /^[[:space:]]*[{}\[\],]/) next
                    if ($0 ~ /^[[:space:]]*"[a-zA-Z_]+"[[:space:]]*:[[:space:]]/) next
                }

                padded = " " $0 " "
                lvl = "info"; sev = 20
                if      (padded ~ /[ \[](FATAL)[ \]]/)                    { lvl="fatal"; sev=50 }
                else if (padded ~ /[ \[](ERR|ERROR)[ \]]/)                { lvl="error"; sev=40 }
                else if (padded ~ /[ \[]WARN(ING)?[ \]]/)                 { lvl="warn";  sev=30 }
                else if (padded ~ /[ \[](VERB|VERBOSE|DEBUG|TRACE)[ \]]/) { lvl="debug"; sev=10 }

                if (sev < min_sev && lvl != "fatal") next

                cmd = "date -u +%Y-%m-%dT%H:%M:%SZ"
                cmd | getline ts
                close(cmd)

                flag = ""
                if      (lvl == "fatal" || lvl == "error") flag = "!! RUNNER ERROR !! "
                else if (lvl == "warn")                    flag = "!  RUNNER WARN  !  "

                printf "%s runner-diag[%s] (%s): %s%s\n", ts, lvl, src, flag, $0
                fflush()
            }
        '
}
