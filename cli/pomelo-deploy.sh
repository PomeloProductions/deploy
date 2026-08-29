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
    push then the deploy. The CLI follows that one deploy's SSE log stream to
    a terminal status. There is no separate deploy call.

OUTPUTS
    Prints `deploy_id=...` and `image_ref=...` to stdout (and to $GITHUB_OUTPUT
    when running inside a GitHub Actions step). NOTE: with the async flow the
    image_ref is computed server-side (the digest isn't known at upload time),
    so `image_ref` may be empty in the output.

EXIT
    0  deploy succeeded (reached `ready`), or --no-wait was set and it started
    1  any failure: auth/upload/build error, deploy `failed`, a gated
       `available` status awaiting promotion, or the wait exceeded
       POMELO_POLL_TIMEOUT before a terminal status

ENVIRONMENT (log-streaming wait tuning)
    POMELO_POLL_TIMEOUT     Total seconds to wait for a terminal status across
                            reconnects (default 900). A slow rollout that stays
                            healthy still reaches `ready` within this budget.
    POMELO_CONNECT_TIMEOUT  Per-connect curl --max-time in seconds (default 120,
                            kept below POMELO_POLL_TIMEOUT). A hung socket trips
                            this and we reconnect + resume (the controller
                            replays full history), instead of giving up.
    POMELO_RECONNECT_DELAY  Seconds to wait between reconnect attempts (default 2).
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

# How long (seconds) a single SSE connect may run before curl tears it down and
# we reconnect. Kept BELOW the total deadline so a hung/half-open socket becomes
# a reconnect, not a give-up. The controller replays full history on reconnect,
# so a fresh connect re-observes every status we may have missed.
POMELO_CONNECT_TIMEOUT="${POMELO_CONNECT_TIMEOUT:-120}"

# Total wall-clock budget for the whole wait, across reconnects. Must comfortably
# exceed the controller's rollout budget (~600s) so a genuinely slow-but-healthy
# rollout still reaches `ready` before we give up. Only exceeding THIS returns a
# timeout failure.
POMELO_POLL_TIMEOUT="${POMELO_POLL_TIMEOUT:-900}"

# Delay between reconnect attempts, so a truly-down controller doesn't get
# hammered in a tight loop.
POMELO_RECONNECT_DELAY="${POMELO_RECONNECT_DELAY:-2}"

# Stream SSE logs until the deploy reaches a terminal status. The controller's
# wire format (see DeployLogsController) is:
#   data: {"event_type":"status_changed","message":"pending → ready",
#          "metadata":{"previous_status":"...","new_status":"ready"},...}\n\n
# and it sends a terminating `event: done\ndata: {}\n\n` once the deploy is
# terminal (ready / failed / available).
#
# SNAPSHOT-ON-CONNECT: the controller now emits, as the FIRST data frame on
# every (re)connect, a synthetic `status_changed` carrying the deploy's CURRENT
# status and `metadata.snapshot:true`. So a client that attaches AFTER the
# deploy already finished learns the terminal status immediately — it no longer
# depends on catching the one-shot live transition or on the historical replay
# surviving proxy buffering. This is the server side of the fix for the
# "reports failure even when the deploy succeeded" bug: previously a late
# connect saw only `event: done` with no status and looped until timeout.
#
# The deploy advances pending → pushing_to_ghcr → updating_k8s → rolling_out →
# ready (or → failed; or → available for a gated build awaiting promotion).
#
# ROBUSTNESS: a single SSE connection is NOT authoritative for the deploy's
# outcome. A slow rollout can outlive a connection: the stream may tear (network
# blip, proxy idle-timeout, our own per-connect --max-time) or the server may
# close it with `event: done` before we caught a terminal new_status. On any
# such non-terminal end we RECONNECT and RESUME — the controller replays the
# full event history (and re-emits the snapshot) from the start, so we can't
# miss the terminal transition. We only ever return non-zero on a real
# `failed`/`available` status, or on blowing the total deadline.
#
# Returns: 0 on ready, 1 on failed / available / timeout.
stream_logs() {
    local endpoint="$URL/$API_VERSION/deploys/$DEPLOY_ID/logs"
    info "streaming logs from $endpoint"
    info "wait budget: ${POMELO_POLL_TIMEOUT}s total, ${POMELO_CONNECT_TIMEOUT}s per connect"

    local start_ts now elapsed remaining
    start_ts="$(date +%s)"

    # Track the last status we already printed so replayed history on reconnect
    # doesn't spam the log with duplicate transitions.
    local last_status=""
    local attempt=0

    local stream_file status_file
    stream_file="$(mktemp -t pomelo-stream.XXXXXX)"
    status_file="$(mktemp -t pomelo-status.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -f '$stream_file' '$status_file'" RETURN

    while :; do
        now="$(date +%s)"
        elapsed=$(( now - start_ts ))
        remaining=$(( POMELO_POLL_TIMEOUT - elapsed ))
        if [[ "$remaining" -le 0 ]]; then
            log "deploy did not reach a terminal status within ${POMELO_POLL_TIMEOUT}s"
            log "the deploy keeps running server-side; re-attach at $endpoint"
            return 1
        fi

        # Cap this connect at the smaller of the per-connect ceiling and whatever
        # remains of the total budget, so we never overshoot the deadline waiting
        # on one socket.
        local connect_max="$POMELO_CONNECT_TIMEOUT"
        [[ "$remaining" -lt "$connect_max" ]] && connect_max="$remaining"

        attempt=$(( attempt + 1 ))
        [[ "$attempt" -gt 1 ]] && info "reconnecting to log stream (attempt $attempt, ${remaining}s of budget left)"

        : > "$status_file"

        # `curl -N` disables buffering so SSE lines arrive as the server emits
        # them. --max-time bounds this single connect. We pipe through awk that
        # pretty-prints each new event and records a terminal new_status. awk
        # gets the last status we already printed so it can suppress replayed
        # lines up to and including it on a reconnect.
        #
        # A non-zero curl (torn stream / --max-time) is expected and handled, so
        # disable errexit around the pipe — saving the caller's setting so we
        # restore it exactly, rather than force it on.
        local _errexit_was_set=0
        [[ $- == *e* ]] && _errexit_was_set=1
        set +e
        curl --silent --show-error -N \
             --max-time "$connect_max" \
             --header "Authorization: Bearer $TOKEN" \
             --header "Accept: text/event-stream" \
             "$endpoint" \
        | awk -v RS='\n' -v last="$last_status" -v statusfile="$status_file" '
            function status_of(line,   s) {
                if (match(line, /"new_status"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
                    s = substr(line, RSTART, RLENGTH)
                    sub(/^"new_status"[[:space:]]*:[[:space:]]*"/, "", s)
                    sub(/"$/, "", s)
                    return s
                }
                return ""
            }
            function is_snapshot(line) {
                # The controller marks the connect-time status snapshot with
                # metadata.snapshot:true. It is authoritative for the CURRENT
                # status and always arrives first, so it must bypass the
                # replay-suppression gate below.
                return (line ~ /"snapshot"[[:space:]]*:[[:space:]]*true/)
            }
            function act_on(cur) {
                # Record the newest status so the parent can resume cleanly.
                print cur > statusfile
                fflush(statusfile)
                # Terminal statuses end this awk (and the connect) with a
                # DISTINCT non-zero code each. Crucially we do NOT use exit 0
                # for ready: a clean EOF with no data (torn/idle stream) also
                # yields awk exit 0, and that must NOT be read as success.
                if (cur == "ready")     { exit 10 }
                if (cur == "failed")    { exit 11 }
                if (cur == "available") { exit 12 }
            }
            BEGIN { seen_last = (last == "") ? 1 : 0 }
            /^data:/ {
                sub(/^data:[[:space:]]*/, "")
                cur = status_of($0)
                snap = is_snapshot($0)

                # The snapshot is the authoritative current status and always
                # comes first. Act on it immediately — even during suppression —
                # so an already-terminal deploy exits on the first frame instead
                # of looping until timeout. A non-terminal snapshot is swallowed
                # (not printed) to avoid a noisy "current status: rolling_out"
                # line on every reconnect; the real transitions still print.
                if (snap) {
                    if (cur != "" && (cur == "ready" || cur == "failed" || cur == "available")) {
                        print
                        fflush()
                        act_on(cur)
                    }
                    next
                }

                # Suppress replayed history: skip lines until we pass the last
                # status we had already printed on a previous connect.
                if (!seen_last) {
                    if (cur != "" && cur == last) { seen_last = 1 }
                    next
                }

                print
                fflush()

                if (cur != "") { act_on(cur) }
            }
        ' | tee "$stream_file"
        local awk_rc=${PIPESTATUS[1]}
        [[ "$_errexit_was_set" -eq 1 ]] && set -e

        # Adopt the newest status this connect observed, so a reconnect resumes
        # from the right point in the replayed history.
        if [[ -s "$status_file" ]]; then
            last_status="$(tail -n1 "$status_file")"
        fi

        case "$awk_rc" in
            10)
                info "deploy reached status: ready"
                return 0
                ;;
            11)
                log "deploy failed"
                # Surface the controller's error message if the failing event
                # carried one in metadata.error.
                local err
                err="$(grep -o '"error"[[:space:]]*:[[:space:]]*"[^"]*"' "$stream_file" | tail -n1 | sed 's/.*:[[:space:]]*"//; s/"$//')"
                [[ -n "$err" ]] && log "controller error: $err"
                return 1
                ;;
            12)
                log "deploy reached status: available (gated build)"
                log "the image was pushed but is NOT live — it is awaiting promotion."
                log "promote it from the dashboard (or via the controller's promote"
                log "endpoint) to roll it out. Not treating this as a successful deploy."
                return 1
                ;;
            *)
                # Non-terminal end: torn stream, curl --max-time hit, or a lone
                # `event: done` before we saw a terminal new_status. Reconnect
                # and resume rather than falsely reporting failure — the slow
                # rollout is very likely still progressing server-side.
                if [[ -n "$last_status" ]]; then
                    info "stream ended at status '$last_status' before terminal (curl rc via --max-time or torn/done); reconnecting"
                else
                    info "stream ended before any status (torn/done); reconnecting"
                fi
                sleep "$POMELO_RECONNECT_DELAY"
                ;;
        esac
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
        info "skipping log stream (--no-wait); deploy is in progress"
        exit 0
    fi

    stream_logs
    info "deploy ready"
    exit 0
}

# Only run main when executed directly, not when sourced by the test harness
# (tests source this file to exercise stream_logs against a mocked curl).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
