#!/usr/bin/env bash
# pomelo-deploy — push an OCI image tarball to client-driver and trigger a deploy.
#
# v1 (bash). A Go binary version is planned; the CLI surface (flags, exit codes,
# stdout/stderr contract) is stable so the swap is a drop-in for tenants.
#
# Runtime requirements: bash >= 4, curl, jq.
# Tested on: Ubuntu 22.04/24.04, macOS 13+ (Homebrew bash + jq), Alpine 3.18+.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults / globals
# ---------------------------------------------------------------------------

# All API paths are derived from this single base; bumping the major rev means
# updating one constant.
API_VERSION="v1"

URL=""
TOKEN=""
ORG=""
APP=""
SERVICE=""
IMAGE=""
ENV_FILE=""
WAIT="true"
SUBCOMMAND=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { printf '%s\n' "$*" >&2; }
die()  { log "error: $*"; exit 1; }
info() { log "==> $*"; }

usage() {
    cat <<'EOF'
pomelo — deploy an image to the Pomelo client-driver controller

USAGE
    # Preferred — deploy by Service id (org-owned; carries its own K8s target):
    pomelo deploy --url <URL> --token <TOKEN> --service <ID> \
                  --image <PATH> [--env-file <PATH>] [--no-wait]

    # Deprecated — deploy by org + app slug (only works for apps that follow
    # the namespace==slug / {slug}-api / container=api convention):
    pomelo deploy --url <URL> --token <TOKEN> --org <ORG> --app <APP> \
                  --image <PATH> [--env-file <PATH>] [--no-wait]

    pomelo --help
    pomelo --version

FLAGS
    --url        Base URL of the controller (e.g. https://controller.driver.pomelo.io)
    --token      Deploy token (Bearer secret; starts with pkd_)
    --service    Service id (numeric). Preferred. Resolves the exact K8s deploy
                 target from the org-owned Service record. Supersedes --org/--app.
    --org        (deprecated) Tenant org slug (e.g. equity-creative)
    --app        (deprecated) App slug within the org (e.g. cnh-merchandising)
    --image      Path to a gzipped OCI image tarball (output of `docker save | gzip`)
    --env-file   (ignored) Deprecated. The upload is async and no longer takes
                 env; manage deploy-time env via the controller's per-service
                 secrets store instead. Accepted for backward compatibility.
    --no-wait    Return after starting the deploy instead of streaming logs

FLOW
    The upload endpoint is asynchronous: a single POST to /images stages the
    tarball, returns 202 with a deploy id, and the server chains the skopeo
    push then the deploy. There is no separate deploy call.

    The CLI then WAITS for the outcome by POLLING the deploy's status (not by
    trusting a single long-lived log stream). The deploy's status is the single
    source of truth for success/failure; the live log stream is shown purely as
    a best-effort convenience and never decides the exit code. A dropped, stalled
    or fully-buffered log stream can therefore no longer turn a successful deploy
    red — the status poll still observes `ready` and exits 0.

OUTPUTS
    Prints `deploy_id=...` and `image_ref=...` to stdout (and to $GITHUB_OUTPUT
    when running inside a GitHub Actions step). NOTE: with the async flow the
    image_ref is computed server-side (the digest isn't known at upload time),
    so `image_ref` may be empty in the output.

EXIT
    0  deploy succeeded (reached `ready`), or --no-wait was set and it started
    1  any failure: auth/upload/build error, deploy `failed`, a gated
       `available` status awaiting promotion, or the wait exceeded
       POMELO_POLL_TIMEOUT before the status became terminal

ENVIRONMENT (status-poll wait tuning)
    POMELO_POLL_TIMEOUT     Total seconds to wait for a TERMINAL status (default
                            900). A slow-but-healthy rollout still reaches `ready`
                            within this budget; only staying non-terminal past it
                            is a (non-zero) timeout.
    POMELO_POLL_INTERVAL    Seconds between status polls (default 3).
    POMELO_CONNECT_TIMEOUT  Per-connect curl --max-time in seconds (default 120).
                            Bounds both a single status probe and a single live-log
                            connect, so a hung socket becomes a retry, not a hang.
    POMELO_RECONNECT_DELAY  Seconds to wait between live-log reconnect attempts
                            (default 2). Cosmetic only — never affects the outcome.
    POMELO_LIVE_LOGS        Set to 0 to disable the best-effort live log tail and
                            poll status silently (default 1 = show logs).
EOF
}

version() { echo "pomelo-deploy 0.1.0 (bash)"; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

# Emit a key=value pair to stdout, and also to $GITHUB_OUTPUT when set, so the
# composite Action can surface it as a step output.
emit_output() {
    local key="$1" value="$2"
    printf '%s=%s\n' "$key" "$value"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
    fi
}

# Strip a trailing slash from a URL so we can concatenate paths cleanly.
trim_slash() { printf '%s' "${1%/}"; }

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------

parse_args() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    SUBCOMMAND="$1"
    shift || true

    case "$SUBCOMMAND" in
        -h|--help|help) usage; exit 0 ;;
        -v|--version|version) version; exit 0 ;;
        deploy) ;;
        *) die "unknown subcommand: $SUBCOMMAND (try 'pomelo --help')" ;;
    esac

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url)       URL="${2:?--url requires a value}"; shift 2 ;;
            --token)     TOKEN="${2:?--token requires a value}"; shift 2 ;;
            --service)   SERVICE="${2:?--service requires a value}"; shift 2 ;;
            --org)       ORG="${2:?--org requires a value}"; shift 2 ;;
            --app)       APP="${2:?--app requires a value}"; shift 2 ;;
            --image)     IMAGE="${2:?--image requires a value}"; shift 2 ;;
            --env-file)  ENV_FILE="${2:?--env-file requires a value}"; shift 2 ;;
            --no-wait)   WAIT="false"; shift ;;
            --wait)      WAIT="true"; shift ;;
            -h|--help)   usage; exit 0 ;;
            *) die "unknown flag: $1" ;;
        esac
    done

    # Fall back to env vars for the most-likely-to-be-secret / CI-injected values.
    URL="${URL:-${POMELO_URL:-}}"
    TOKEN="${TOKEN:-${POMELO_TOKEN:-}}"
    SERVICE="${SERVICE:-${POMELO_SERVICE:-}}"
    ORG="${ORG:-${POMELO_ORG:-}}"
    APP="${APP:-${POMELO_APP:-}}"

    [[ -n "$URL"   ]] || die "--url is required (or set POMELO_URL)"
    [[ -n "$TOKEN" ]] || die "--token is required (or set POMELO_TOKEN)"
    [[ -n "$IMAGE" ]] || die "--image is required"

    # Target resolution: --service (preferred) wins. Else require the legacy
    # --org + --app slug pair.
    if [[ -n "$SERVICE" ]]; then
        [[ "$SERVICE" =~ ^[0-9]+$ ]] || die "--service must be a numeric id (got: $SERVICE)"
    else
        [[ -n "$ORG" ]] || die "--service (preferred) or --org + --app is required"
        [[ -n "$APP" ]] || die "--app is required when using --org"
    fi

    [[ -f "$IMAGE" ]] || die "image file not found: $IMAGE"
    [[ -s "$IMAGE" ]] || die "image file is empty: $IMAGE"

    if [[ -n "$ENV_FILE" ]]; then
        [[ -f "$ENV_FILE" ]] || die "env-file not found: $ENV_FILE"
    fi

    URL="$(trim_slash "$URL")"
}

# ---------------------------------------------------------------------------
# API calls
# ---------------------------------------------------------------------------

# Build the base path for the target — service-keyed (preferred) or the
# legacy org/app-slug path.
target_base() {
    if [[ -n "$SERVICE" ]]; then
        printf '%s/%s/services/%s' "$URL" "$API_VERSION" "$SERVICE"
    else
        printf '%s/%s/organizations/%s/apps/%s' "$URL" "$API_VERSION" "$ORG" "$APP"
    fi
}

# Upload the gzipped tarball. The endpoint is ASYNCHRONOUS: it stages the
# tarball, hands it to a queued job on the worker (which does the skopeo push
# then chains the deploy), and returns 202 immediately with a deploy id. So a
# single upload call IS the whole deploy — there is no separate `deploys` call.
#
# Returns 0 on HTTP 2xx; sets DEPLOY_ID. (IMAGE_REF is not known until the
# worker computes the digest, so it's resolved from the logs / left empty.)
upload_image() {
    local endpoint
    endpoint="$(target_base)/images"
    local response_file http_code

    response_file="$(mktemp -t pomelo-upload.XXXXXX)"
    # Guard the expansion: a RETURN trap can fire in a caller's scope where
    # $response_file is no longer set (with `set -u` that would abort), so use
    # a defaulted expansion.
    trap 'rm -f "${response_file:-}"' RETURN

    info "uploading $IMAGE -> $endpoint"

    http_code="$(
        curl --silent --show-error \
             --write-out '%{http_code}' \
             --output "$response_file" \
             --progress-bar \
             --request POST \
             --header "Authorization: Bearer $TOKEN" \
             --header "Content-Type: application/octet-stream" \
             --header "Content-Encoding: gzip" \
             --data-binary "@$IMAGE" \
             "$endpoint"
    )"

    if [[ "$http_code" != 2* ]]; then
        log "upload failed (HTTP $http_code):"
        cat "$response_file" >&2 || true
        return 1
    fi

    # New async contract: the 202 response carries the deploy id the worker
    # created. The push + deploy happen server-side; we just follow the deploy.
    DEPLOY_ID="$(jq -r '.deploy_id // empty' < "$response_file")"
    # `image_ref` may be absent (async: not known until the worker digests the
    # archive). Keep whatever the server returned, for the emitted output.
    IMAGE_REF="$(jq -r '.image_ref // empty' < "$response_file")"

    [[ -n "$DEPLOY_ID" ]] || { log "no deploy_id in upload response"; cat "$response_file" >&2; return 1; }
    info "upload accepted; deploy started: $DEPLOY_ID"
}

# Per-connect ceiling (seconds) for a single curl — bounds BOTH a one-shot status
# probe and a single best-effort live-log connect. A hung/half-open socket trips
# this and we retry rather than hang. Kept below the total deadline.
POMELO_CONNECT_TIMEOUT="${POMELO_CONNECT_TIMEOUT:-120}"

# Total wall-clock budget for the whole wait. Must comfortably exceed the
# controller's rollout budget (~600s) so a genuinely slow-but-healthy rollout
# still reaches `ready` before we give up. Only exceeding THIS — while the status
# is still non-terminal — returns a timeout failure.
POMELO_POLL_TIMEOUT="${POMELO_POLL_TIMEOUT:-900}"

# Seconds between status polls. The status poll is cheap (a short SSE connect that
# reads only the connect-time snapshot frame), so a few seconds keeps CI feedback
# tight without hammering the controller.
POMELO_POLL_INTERVAL="${POMELO_POLL_INTERVAL:-3}"

# Delay between best-effort live-log reconnect attempts, so a flapping stream
# doesn't get hammered in a tight loop. Cosmetic path only — never affects the
# outcome.
POMELO_RECONNECT_DELAY="${POMELO_RECONNECT_DELAY:-2}"

# ---------------------------------------------------------------------------
# Status polling — the SOURCE OF TRUTH for the deploy outcome.
# ---------------------------------------------------------------------------
#
# WHY NOT A PLAIN JSON STATUS GET? The controller's JSON status endpoint
# (GET /v1/deploys/{ulid}) is JWT-only — it rejects the `pkd_…` deploy token the
# CLI holds. The only status channel a deploy token can read is the SSE logs
# endpoint. BUT: that endpoint emits, as the FIRST data frame on EVERY connect, a
# synthetic `status_changed` snapshot carrying the deploy's CURRENT status in
# `metadata.new_status` (with `metadata.snapshot:true`), flushed immediately and
# served with `X-Accel-Buffering: no`. See client-driver's DeployLogsController.
#
# So we treat a SHORT SSE connect as a status probe: connect, read the first
# status-bearing frame, close. That one frame is authoritative for the current
# status and does NOT depend on a long-lived stream surviving proxy/LB buffering
# or idle timeouts — which is exactly what was turning successful deploys red.
#
# probe_status prints the deploy's current status to stdout (empty on a failed
# probe) and returns 0 if it got a status, non-zero otherwise. It never decides
# the outcome by itself; the caller (wait_for_deploy) interprets the value.
probe_status() {
    local endpoint="$URL/$API_VERSION/deploys/$DEPLOY_ID/logs"
    local connect_max="$1"

    # A non-zero curl (we close early once we have the snapshot, tripping
    # SIGPIPE/28) is EXPECTED here, so don't let errexit abort us.
    local _errexit_was_set=0
    [[ $- == *e* ]] && _errexit_was_set=1
    set +e
    # Read the stream and emit the FIRST `new_status` we see, then stop. Closing
    # the awk early makes curl's write fail and exit — that's intended; we only
    # need the snapshot frame, not the whole stream.
    local status
    status="$(
        curl --silent --show-error -N \
             --max-time "$connect_max" \
             --header "Authorization: Bearer $TOKEN" \
             --header "Accept: text/event-stream" \
             "$endpoint" 2>/dev/null \
        | awk '
            match($0, /"new_status"[[:space:]]*:[[:space:]]*"[^"]+"/) {
                s = substr($0, RSTART, RLENGTH)
                sub(/^"new_status"[[:space:]]*:[[:space:]]*"/, "", s)
                sub(/"$/, "", s)
                print s
                exit 0
            }
        '
    )"
    [[ "$_errexit_was_set" -eq 1 ]] && set -e

    [[ -n "$status" ]] || return 1
    printf '%s\n' "$status"
}

# Fetch the controller's error message for a failed deploy, best-effort. Reads a
# longer slice of the stream (history replay carries the failing event, whose
# metadata.error holds the reason) and greps the last one out. Never fatal.
fetch_error_message() {
    local endpoint="$URL/$API_VERSION/deploys/$DEPLOY_ID/logs"
    local _errexit_was_set=0
    [[ $- == *e* ]] && _errexit_was_set=1
    set +e
    local err
    err="$(
        curl --silent --show-error -N \
             --max-time "$POMELO_CONNECT_TIMEOUT" \
             --header "Authorization: Bearer $TOKEN" \
             --header "Accept: text/event-stream" \
             "$endpoint" 2>/dev/null \
        | grep -o '"error"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | tail -n1 | sed 's/.*:[[:space:]]*"//; s/"$//'
    )"
    [[ "$_errexit_was_set" -eq 1 ]] && set -e
    printf '%s' "$err"
}

# ---------------------------------------------------------------------------
# Live log display — BEST-EFFORT ONLY. Never decides the exit code.
# ---------------------------------------------------------------------------
#
# Tails the SSE stream and prints each event for visibility, reconnecting if the
# stream drops. Runs in the BACKGROUND while wait_for_deploy() polls status in the
# foreground. If this stream is fully buffered, stalls, or never delivers a byte,
# it simply shows fewer logs — the outcome is still decided by the status poll.
# It exits when the parent signals completion (the LIVE_LOG_STOP file appears) or
# when it has shown a terminal status frame.
stream_live_logs() {
    local stop_file="$1"
    local endpoint="$URL/$API_VERSION/deploys/$DEPLOY_ID/logs"

    # Track the last status we showed across reconnects (in a temp file so it
    # survives each curl|awk subshell) to suppress replayed history on reconnect.
    local last_file
    last_file="$(mktemp -t pomelo-livelog-last.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -f '$last_file'" RETURN

    local _errexit_was_set=0
    [[ $- == *e* ]] && _errexit_was_set=1
    set +e
    local last_status=""
    while :; do
        [[ -f "$stop_file" ]] && break
        last_status="$(cat "$last_file" 2>/dev/null || true)"

        # Print each real (non-snapshot) event once, suppressing replayed history
        # up to the last status already shown, and record the newest status to the
        # last_file so a reconnect resumes cleanly. This is DISPLAY ONLY — its
        # exit never affects the deploy outcome (wait_for_deploy owns that).
        curl --silent --show-error -N \
             --max-time "$POMELO_CONNECT_TIMEOUT" \
             --header "Authorization: Bearer $TOKEN" \
             --header "Accept: text/event-stream" \
             "$endpoint" 2>/dev/null \
        | awk -v last="$last_status" -v lastfile="$last_file" '
            function status_of(line,   s) {
                if (match(line, /"new_status"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
                    s = substr(line, RSTART, RLENGTH)
                    sub(/^"new_status"[[:space:]]*:[[:space:]]*"/, "", s)
                    sub(/"$/, "", s)
                    return s
                }
                return ""
            }
            function is_snapshot(line) { return (line ~ /"snapshot"[[:space:]]*:[[:space:]]*true/) }
            BEGIN { seen_last = (last == "") ? 1 : 0 }
            /^data:/ {
                sub(/^data:[[:space:]]*/, "")
                cur = status_of($0)
                # Swallow the connect-time snapshot: it is a status probe, not a
                # log line, and would print a dup "current status" line on every
                # reconnect.
                if (is_snapshot($0)) next
                # Suppress replayed history up to the last status already shown.
                if (!seen_last) { if (cur != "" && cur == last) seen_last = 1; next }
                print; fflush()
                if (cur != "") { print cur > lastfile; fflush(lastfile) }
            }
        '

        # Stop reconnecting once the deploy is terminal — nothing more to show.
        last_status="$(cat "$last_file" 2>/dev/null || true)"
        case "$last_status" in
            ready|failed|available) break ;;
        esac
        [[ -f "$stop_file" ]] && break
        sleep "$POMELO_RECONNECT_DELAY"
    done
    [[ "$_errexit_was_set" -eq 1 ]] && set -e
}

# ---------------------------------------------------------------------------
# wait_for_deploy — the outcome driver. Polls status until terminal; the STATUS
# (not any log stream) decides the exit code.
#   0 on `ready`
#   1 on `failed`, on `available` (gated, awaiting promotion), or on timeout
#     (status still non-terminal after POMELO_POLL_TIMEOUT)
# ---------------------------------------------------------------------------
wait_for_deploy() {
    local logs_endpoint="$URL/$API_VERSION/deploys/$DEPLOY_ID/logs"
    info "waiting for deploy $DEPLOY_ID (polling status; logs shown best-effort)"
    info "wait budget: ${POMELO_POLL_TIMEOUT}s total, polling every ${POMELO_POLL_INTERVAL}s"

    # Start the best-effort live-log tail in the background. Its output is purely
    # for the operator; its exit is irrelevant to ours. Set POMELO_LIVE_LOGS=0 to
    # poll silently (e.g. in tests, or when the stream is known-unhealthy).
    local stop_file="" live_pid=""
    if [[ "${POMELO_LIVE_LOGS:-1}" != "0" ]]; then
        stop_file="$(mktemp -t pomelo-livelog-stop.XXXXXX)"
        rm -f "$stop_file"
        stream_live_logs "$stop_file" &
        live_pid=$!
    fi

    # Ensure we always stop the background tail, even on an early return.
    # shellcheck disable=SC2064
    trap "[[ -n \"$stop_file\" ]] && touch '$stop_file' 2>/dev/null; [[ -n \"$live_pid\" ]] && kill '$live_pid' 2>/dev/null; [[ -n \"$live_pid\" ]] && wait '$live_pid' 2>/dev/null; [[ -n \"$stop_file\" ]] && rm -f '$stop_file'; true" RETURN

    local start_ts now elapsed remaining
    start_ts="$(date +%s)"

    local status last_reported=""
    while :; do
        now="$(date +%s)"
        elapsed=$(( now - start_ts ))
        remaining=$(( POMELO_POLL_TIMEOUT - elapsed ))
        if [[ "$remaining" -le 0 ]]; then
            log "deploy status still non-terminal after ${POMELO_POLL_TIMEOUT}s"
            log "the deploy keeps running server-side; re-attach at $logs_endpoint"
            return 1
        fi

        # Bound each probe by the per-connect ceiling or the remaining budget.
        local connect_max="$POMELO_CONNECT_TIMEOUT"
        [[ "$remaining" -lt "$connect_max" ]] && connect_max="$remaining"

        status="$(probe_status "$connect_max")" || status=""

        if [[ -n "$status" && "$status" != "$last_reported" ]]; then
            info "deploy status: $status"
            last_reported="$status"
        fi

        case "$status" in
            ready)
                info "deploy reached status: ready"
                return 0
                ;;
            failed)
                log "deploy failed"
                local err
                err="$(fetch_error_message)"
                [[ -n "$err" ]] && log "controller error: $err"
                return 1
                ;;
            available)
                log "deploy reached status: available (gated build)"
                log "the image was pushed but is NOT live — it is awaiting promotion."
                log "promote it from the dashboard (or via the controller's promote"
                log "endpoint) to roll it out. Not treating this as a successful deploy."
                return 1
                ;;
            "")
                # The probe failed to read a status (stream never delivered the
                # snapshot, controller blip, torn socket). This is NOT a failure
                # of the deploy — just retry on the next interval. The outcome is
                # only ever decided by observing a terminal STATUS or the budget.
                :
                ;;
            *)
                # Non-terminal status (pending / pushing_to_ghcr / updating_k8s /
                # rolling_out): keep polling.
                :
                ;;
        esac

        sleep "$POMELO_POLL_INTERVAL"
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"
    require_cmd curl
    require_cmd jq

    # The upload endpoint is asynchronous: one POST to /images stages the
    # tarball, and the server chains push -> deploy. There is no longer a
    # separate /deploys call from the CLI.
    if [[ -n "$ENV_FILE" ]]; then
        log "warning: --env-file is ignored by the async upload flow. Manage"
        log "         deploy-time env via the controller's per-service secrets"
        log "         store (synced on provision), not the upload call."
    fi

    upload_image

    emit_output "image_ref" "$IMAGE_REF"
    emit_output "deploy_id" "$DEPLOY_ID"

    if [[ "$WAIT" == "false" ]]; then
        info "skipping wait (--no-wait); deploy is in progress"
        exit 0
    fi

    wait_for_deploy
    info "deploy ready"
    exit 0
}

# Only run main when executed directly, not when sourced by the test harness
# (tests source this file to exercise wait_for_deploy/probe_status against a
# mocked curl).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
