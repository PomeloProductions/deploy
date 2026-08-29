#!/usr/bin/env bash
# Mocked-SSE tests for stream_logs() in cli/pomelo-deploy.sh.
#
# We source the CLI (which no longer auto-runs main when sourced) and replace
# `curl` with a mock that replays scripted SSE frames from fixture files, one
# fixture per connect attempt. This lets us exercise the reconnect/resume,
# terminal-status, and timeout logic without a real controller.
#
# Scenarios covered:
#   1. ready              — single connect ends on new_status: ready       -> 0
#   2. failed             — status_changed to failed (with metadata.error) -> 1
#   3. torn-then-ready    — connect #1 tears mid-rollout, connect #2 replays
#                           history then reaches ready                     -> 0
#   4. available          — gated build lands on `available`               -> 1
#   5. timeout            — never reaches terminal within POMELO_POLL_TIMEOUT -> 1

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../cli/pomelo-deploy.sh"

# shellcheck source=/dev/null
source "$CLI"

# The CLI sets `set -euo pipefail`; relax -e/pipefail here so that intentionally
# non-zero stream_logs() runs (failed/available/timeout) don't abort the harness
# when captured via $(...) or $?.
set +e +o pipefail

# Minimal globals stream_logs() reads. (Referenced indirectly via the function
# under test; declared here for the sourced code, hence shellcheck-exempt.)
# shellcheck disable=SC2034
URL="https://mock.controller"
# shellcheck disable=SC2034
API_VERSION="v1"
# shellcheck disable=SC2034
TOKEN="pkd_test"
# shellcheck disable=SC2034
DEPLOY_ID="dep_test"

WORK="$(mktemp -d -t pomelo-test.XXXXXX)"
trap 'rm -f "$WORK"/* 2>/dev/null; rmdir "$WORK" 2>/dev/null' EXIT

# Per-test connect counter + fixture dir, consumed by the mock curl.
: "${MOCK_DIR:=$WORK}"
CONNECT_FILE="$WORK/connect_count"

# Mock curl: ignores all args except that each invocation reads the next
# fixture ($MOCK_DIR/connect_N.sse) and cats it to stdout. A fixture whose
# first line is `__EXIT__ <code>` makes the mock exit with that code AFTER
# emitting the rest (simulating a torn connection / curl --max-time).
curl() {
    local n
    n="$(cat "$CONNECT_FILE" 2>/dev/null || echo 0)"
    n=$(( n + 1 ))
    printf '%s' "$n" > "$CONNECT_FILE"

    local fixture="$MOCK_DIR/connect_${n}.sse"
    if [[ ! -f "$fixture" ]]; then
        # No more scripted frames: behave like a connection that produced
        # nothing and closed (a torn/idle socket). Return non-zero like a
        # curl --max-time abort so the caller reconnects.
        return 28
    fi

    local first
    first="$(head -n1 "$fixture")"
    if [[ "$first" == __EXIT__* ]]; then
        local code="${first#__EXIT__ }"
        tail -n +2 "$fixture"
        return "$code"
    fi
    cat "$fixture"
    return 0
}

reset_mock() {
    : > "$CONNECT_FILE"
    rm -f "$MOCK_DIR"/connect_*.sse
}

PASS=0
FAIL=0
assert_rc() {
    local expected="$1" actual="$2" name="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf 'ok   - %s (rc=%s)\n' "$name" "$actual"
        PASS=$(( PASS + 1 ))
    else
        printf 'FAIL - %s (expected rc=%s, got rc=%s)\n' "$name" "$expected" "$actual"
        FAIL=$(( FAIL + 1 ))
    fi
}

# Keep waits fast in tests.
export POMELO_RECONNECT_DELAY=0
export POMELO_CONNECT_TIMEOUT=5

sse() { printf 'data: %s\n\n' "$1"; }

# --- Scenario 1: ready ------------------------------------------------------
reset_mock
{
    sse '{"event_type":"status_changed","metadata":{"new_status":"pushing_to_ghcr"}}'
    sse '{"event_type":"status_changed","metadata":{"new_status":"rolling_out"}}'
    sse '{"event_type":"status_changed","metadata":{"new_status":"ready"}}'
    printf 'event: done\ndata: {}\n\n'
} > "$MOCK_DIR/connect_1.sse"
POMELO_POLL_TIMEOUT=60 stream_logs >/dev/null 2>&1
assert_rc 0 $? "ready"

# --- Scenario 2: failed (with error) ---------------------------------------
reset_mock
{
    sse '{"event_type":"status_changed","metadata":{"new_status":"rolling_out"}}'
    sse '{"event_type":"status_changed","metadata":{"new_status":"failed","error":"image pull backoff"}}'
    printf 'event: done\ndata: {}\n\n'
} > "$MOCK_DIR/connect_1.sse"
out="$(POMELO_POLL_TIMEOUT=60 stream_logs 2>&1)"; rc=$?
assert_rc 1 "$rc" "failed"
if grep -q "image pull backoff" <<<"$out"; then
    printf 'ok   - failed surfaces metadata.error\n'; PASS=$(( PASS + 1 ))
else
    printf 'FAIL - failed did not surface metadata.error\n'; FAIL=$(( FAIL + 1 ))
fi

# --- Scenario 3: torn-then-ready (reconnect + resume) -----------------------
reset_mock
# Connect #1: progresses to rolling_out then tears (curl --max-time -> exit 28).
{
    printf '__EXIT__ 28\n'
    sse '{"event_type":"status_changed","metadata":{"new_status":"pushing_to_ghcr"}}'
    sse '{"event_type":"status_changed","metadata":{"new_status":"rolling_out"}}'
} > "$MOCK_DIR/connect_1.sse"
# Connect #2: controller replays full history, then reaches ready.
{
    sse '{"event_type":"status_changed","metadata":{"new_status":"pushing_to_ghcr"}}'
    sse '{"event_type":"status_changed","metadata":{"new_status":"rolling_out"}}'
    sse '{"event_type":"status_changed","metadata":{"new_status":"ready"}}'
    printf 'event: done\ndata: {}\n\n'
} > "$MOCK_DIR/connect_2.sse"
out="$(POMELO_POLL_TIMEOUT=60 stream_logs 2>&1)"; rc=$?
assert_rc 0 "$rc" "torn-then-ready"
# Resume should not double-print the replayed rolling_out transition.
dupes="$(grep -c '"new_status":"rolling_out"' <<<"$out")"
if [[ "$dupes" -le 1 ]]; then
    printf 'ok   - reconnect suppresses replayed history (rolling_out x%s)\n' "$dupes"; PASS=$(( PASS + 1 ))
else
    printf 'FAIL - replayed history not suppressed (rolling_out x%s)\n' "$dupes"; FAIL=$(( FAIL + 1 ))
fi

# --- Scenario 4: available (gated) ------------------------------------------
reset_mock
{
    sse '{"event_type":"status_changed","metadata":{"new_status":"pushing_to_ghcr"}}'
    sse '{"event_type":"status_changed","metadata":{"new_status":"available"}}'
    printf 'event: done\ndata: {}\n\n'
} > "$MOCK_DIR/connect_1.sse"
out="$(POMELO_POLL_TIMEOUT=60 stream_logs 2>&1)"; rc=$?
assert_rc 1 "$rc" "available"
if grep -qi "promote" <<<"$out"; then
    printf 'ok   - available prints promote guidance\n'; PASS=$(( PASS + 1 ))
else
    printf 'FAIL - available missing promote guidance\n'; FAIL=$(( FAIL + 1 ))
fi

# --- Scenario 6: snapshot-on-connect, already ready -------------------------
# Reproduces the live bug: the client connects AFTER the deploy finished. The
# controller's first frame is a status snapshot (metadata.snapshot:true) with
# new_status: ready, followed by history + done. The CLI must exit 0 on the
# snapshot without looping.
reset_mock
{
    sse '{"event_type":"status_changed","message":"current status: ready","metadata":{"new_status":"ready","snapshot":true}}'
    sse '{"event_type":"status_changed","metadata":{"new_status":"pushing_to_ghcr"}}'
    sse '{"event_type":"status_changed","metadata":{"new_status":"ready"}}'
    printf 'event: done\ndata: {}\n\n'
} > "$MOCK_DIR/connect_1.sse"
POMELO_POLL_TIMEOUT=60 stream_logs >/dev/null 2>&1
assert_rc 0 $? "snapshot-ready-on-connect"

# --- Scenario 7: snapshot-on-connect, already failed ------------------------
reset_mock
{
    sse '{"event_type":"status_changed","message":"current status: failed","metadata":{"new_status":"failed","snapshot":true}}'
    printf 'event: done\ndata: {}\n\n'
} > "$MOCK_DIR/connect_1.sse"
POMELO_POLL_TIMEOUT=60 stream_logs >/dev/null 2>&1
assert_rc 1 $? "snapshot-failed-on-connect"

# --- Scenario 8: non-terminal snapshot then live rollout to ready -----------
# A snapshot with a non-terminal status (rolling_out) must NOT be printed as a
# duplicate line and must NOT terminate; the live transition to ready ends it.
reset_mock
{
    sse '{"event_type":"status_changed","message":"current status: rolling_out","metadata":{"new_status":"rolling_out","snapshot":true}}'
    sse '{"event_type":"status_changed","metadata":{"new_status":"rolling_out"}}'
    sse '{"event_type":"status_changed","metadata":{"new_status":"ready"}}'
    printf 'event: done\ndata: {}\n\n'
} > "$MOCK_DIR/connect_1.sse"
out="$(POMELO_POLL_TIMEOUT=60 stream_logs 2>&1)"; rc=$?
assert_rc 0 "$rc" "non-terminal-snapshot-then-ready"
# The snapshot line ("current status: rolling_out") must not be echoed.
if grep -q 'current status: rolling_out' <<<"$out"; then
    printf 'FAIL - non-terminal snapshot leaked to output\n'; FAIL=$(( FAIL + 1 ))
else
    printf 'ok   - non-terminal snapshot is swallowed\n'; PASS=$(( PASS + 1 ))
fi

# --- Scenario 9: torn mid-rollout, reconnect snapshot is terminal -----------
# Connect #1 progresses then tears. Connect #2's snapshot reports ready (the
# deploy finished during the gap). The CLI must exit 0 on the reconnect
# snapshot even though last_status was rolling_out (suppression must not eat it).
reset_mock
{
    printf '__EXIT__ 28\n'
    sse '{"event_type":"status_changed","message":"current status: rolling_out","metadata":{"new_status":"rolling_out","snapshot":true}}'
    sse '{"event_type":"status_changed","metadata":{"new_status":"rolling_out"}}'
} > "$MOCK_DIR/connect_1.sse"
{
    sse '{"event_type":"status_changed","message":"current status: ready","metadata":{"new_status":"ready","snapshot":true}}'
    sse '{"event_type":"status_changed","metadata":{"new_status":"rolling_out"}}'
    sse '{"event_type":"status_changed","metadata":{"new_status":"ready"}}'
    printf 'event: done\ndata: {}\n\n'
} > "$MOCK_DIR/connect_2.sse"
POMELO_POLL_TIMEOUT=60 stream_logs >/dev/null 2>&1
assert_rc 0 $? "reconnect-snapshot-terminal"

# --- Scenario 5: timeout ----------------------------------------------------
reset_mock
# Every connect returns 28 with no fixture (mock default) -> never terminal.
POMELO_POLL_TIMEOUT=2 POMELO_CONNECT_TIMEOUT=1 stream_logs >/dev/null 2>&1
assert_rc 1 $? "timeout"

echo "-----"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
