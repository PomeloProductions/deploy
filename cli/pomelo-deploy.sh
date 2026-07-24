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
    0  deploy succeeded (or --no-wait was set and the deploy started)
    1  any failure (auth, upload, build, deploy timeout, etc.)
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

# Stream SSE logs until the deploy reaches a terminal status. The controller's
# wire format (see DeployLogsController) is:
#   data: {"event_type":"status_changed","message":"pending → ready",
#          "metadata":{"previous_status":"...","new_status":"ready"},...}\n\n
# and it sends a terminating `event: done\ndata: {}\n\n` once the deploy is
# terminal (ready / failed).
#
# We short-circuit on the status_changed event whose new_status is ready/failed
# (definitive), and treat a lone `event: done` as a clean end too. Returns 0 on
# ready, 1 on failed / torn connection.
stream_logs() {
    local endpoint="$URL/$API_VERSION/deploys/$DEPLOY_ID/logs"
    info "streaming logs from $endpoint"

    # `curl -N` disables buffering so SSE lines arrive as the server emits them.
    # We pipe through a small awk that pretty-prints each data event and
    # short-circuits when it sees a terminal new_status.
    set +e
    curl --silent --show-error -N \
         --header "Authorization: Bearer $TOKEN" \
         --header "Accept: text/event-stream" \
         "$endpoint" \
    | awk -v RS='\n' '
        /^data:/ {
            sub(/^data:[[:space:]]*/, "")
            print
            fflush()
            # Terminal status is carried in the status_changed metadata.
            # `"new_status":"ready"` / `"failed"` is definitive; match on the
            # substring (tolerant of surrounding whitespace variants).
            if ($0 ~ /"new_status"[[:space:]]*:[[:space:]]*"ready"/)  { print "__POMELO_STATUS__=ready";  exit 0 }
            if ($0 ~ /"new_status"[[:space:]]*:[[:space:]]*"failed"/) { print "__POMELO_STATUS__=failed"; exit 2 }
        }
    ' | tee /tmp/pomelo-stream.$$
    local rc=${PIPESTATUS[1]}
    set -e

    if grep -q '^__POMELO_STATUS__=failed' /tmp/pomelo-stream.$$ 2>/dev/null; then
        rm -f /tmp/pomelo-stream.$$
        return 1
    fi
    local sawReady=0
    grep -q '^__POMELO_STATUS__=ready' /tmp/pomelo-stream.$$ 2>/dev/null && sawReady=1
    rm -f /tmp/pomelo-stream.$$

    # If awk saw an explicit ready, we're done.
    if [[ "$sawReady" -eq 1 ]]; then
        return 0
    fi

    # Otherwise the stream ended on `event: done` (EOF, rc 0) without our awk
    # catching a terminal new_status. That's ambiguous — the server closed the
    # stream but we didn't positively observe `ready`. Treat as failure so CI
    # doesn't go green on a torn or truncated connection.
    log "log stream ended without a positive 'ready' status (exit $rc)"
    return 1
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
}

main "$@"
