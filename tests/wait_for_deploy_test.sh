#!/usr/bin/env bash
# Tests for the status-POLL wait logic in cli/pomelo-deploy.sh.
#
# THE FIX UNDER TEST: the deploy's STATUS — not a long-lived SSE log stream — is
# the source of truth for success/failure. We source the CLI (it no longer runs
# main when sourced) and replace `curl` with a mock that replays scripted SSE
# frames per connect. The controller emits a connect-time `status_changed`
# snapshot (metadata.new_status, metadata.snapshot:true) as the first frame on
# every connect, so a SHORT connect is an authoritative status probe. The mock
# lets us drive probe_status()/wait_for_deploy() without a real controller.
#
# The best-effort live-log tail (stream_live_logs) is DISABLED here
# (POMELO_LIVE_LOGS=0) so the single mock-curl connect counter is driven only by
# the status probes — making every scenario deterministic. A dedicated scenario
# re-enables it to prove a dropping live stream never changes the exit code.
#
# Scenarios covered:
#   1. probe_status parses metadata.new_status from a snapshot frame
#   2. probe_status returns non-zero when the connect yields no status
#   3. ready                 — poll observes `ready`                        -> 0
#   4. failed (with error)   — poll observes `failed`, surfaces the error   -> 1
#   5. available             — gated build lands on `available`             -> 1
#   6. ready-after-drops     — early probes tear/empty, later probe=ready   -> 0
#                              (THE BUG: stream drops must NOT fail a ready deploy)
#   7. non-terminal timeout  — status stays rolling_out past the budget     -> 1
#   8. live-stream-drops-ready — live log tail ON but tears after snapshot;
#                              status poll still concludes ready            -> 0

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../cli/pomelo-deploy.sh"

# shellcheck source=/dev/null
source "$CLI"

# The CLI sets `set -euo pipefail`; relax -e/pipefail here so intentionally
# non-zero wait_for_deploy() runs (failed/available/timeout) don't abort the
# harness when captured via $(...) or $?.
set +e +o pipefail

# Minimal globals the wait code reads.
# shellcheck disable=SC2034
URL="https://mock.controller"
# shellcheck disable=SC2034
API_VERSION="v1"
# shellcheck disable=SC2034
TOKEN="pkd_test"
# shellcheck disable=SC2034
DEPLOY_ID="dep_test"

WORK="$(mktemp -d -t pomelo-wait-test.XXXXXX)"
trap 'rm -rf "$WORK" 2>/dev/null' EXIT

: "${MOCK_DIR:=$WORK}"
CONNECT_FILE="$WORK/connect_count"

# Mock curl: ignores all args except that each invocation reads the next fixture
# ($MOCK_DIR/connect_N.sse) and cats it to stdout. A fixture whose first line is
# `__EXIT__ <code>` emits the rest then exits with that code (a torn connection /
# curl --max-time). No fixture => return 28 (torn/idle socket, nothing emitted).
curl() {
    local n
    n="$(cat "$CONNECT_FILE" 2>/dev/null || echo 0)"
    n=$(( n + 1 ))
    printf '%s' "$n" > "$CONNECT_FILE"

    local fixture="$MOCK_DIR/connect_${n}.sse"
    if [[ ! -f "$fixture" ]]; then
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
assert_eq() {
    local expected="$1" actual="$2" name="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf 'ok   - %s (=%s)\n' "$name" "$actual"
        PASS=$(( PASS + 1 ))
    else
        printf 'FAIL - %s (expected "%s", got "%s")\n' "$name" "$expected" "$actual"
        FAIL=$(( FAIL + 1 ))
    fi
}

# Keep waits fast. Live logs OFF for determinism (one curl consumer); the
# dedicated live-stream scenario re-enables it locally.
export POMELO_RECONNECT_DELAY=0
export POMELO_POLL_INTERVAL=0
export POMELO_CONNECT_TIMEOUT=5
export POMELO_LIVE_LOGS=0

# A connect-time status snapshot frame (what the controller emits first on every
# connect): status_changed, metadata.new_status, metadata.snapshot:true.
snap() { printf 'data: {"event_type":"status_changed","message":"current status: %s","metadata":{"new_status":"%s","snapshot":true}}\n\n' "$1" "$1"; }

# --- Scenario 1: probe_status parses a snapshot ----------------------------
reset_mock
snap rolling_out > "$MOCK_DIR/connect_1.sse"
got="$(probe_status 5)"; rc=$?
assert_eq "rolling_out" "$got" "probe_status parses metadata.new_status"
assert_rc 0 "$rc" "probe_status returns 0 on a parsed status"

# --- Scenario 2: probe_status on an empty/torn connect ---------------------
reset_mock
# No fixture -> mock returns 28 with no output.
got="$(probe_status 5)"; rc=$?
assert_eq "" "$got" "probe_status yields empty on a torn connect"
assert_rc 1 "$rc" "probe_status returns non-zero when no status read"

# --- Scenario 3: ready ------------------------------------------------------
reset_mock
snap pushing_to_ghcr > "$MOCK_DIR/connect_1.sse"
snap rolling_out     > "$MOCK_DIR/connect_2.sse"
snap ready           > "$MOCK_DIR/connect_3.sse"
POMELO_POLL_TIMEOUT=60 wait_for_deploy >/dev/null 2>&1
assert_rc 0 $? "ready"

# --- Scenario 4: failed (with error) ---------------------------------------
reset_mock
# A failed snapshot for the poll; fetch_error_message re-reads the stream and
# greps metadata.error, so include a failed event carrying one.
{
    printf 'data: {"event_type":"status_changed","message":"current status: failed","metadata":{"new_status":"failed","snapshot":true}}\n\n'
    printf 'data: {"event_type":"status_changed","metadata":{"new_status":"failed","error":"image pull backoff"}}\n\n'
    printf 'event: done\ndata: {}\n\n'
} > "$MOCK_DIR/connect_1.sse"
# connect_2 is consumed by fetch_error_message after the poll sees `failed`.
{
    printf 'data: {"event_type":"status_changed","metadata":{"new_status":"failed","error":"image pull backoff"}}\n\n'
    printf 'event: done\ndata: {}\n\n'
} > "$MOCK_DIR/connect_2.sse"
out="$(POMELO_POLL_TIMEOUT=60 wait_for_deploy 2>&1)"; rc=$?
assert_rc 1 "$rc" "failed"
if grep -q "image pull backoff" <<<"$out"; then
    printf 'ok   - failed surfaces metadata.error\n'; PASS=$(( PASS + 1 ))
else
    printf 'FAIL - failed did not surface metadata.error\n'; FAIL=$(( FAIL + 1 ))
fi

# --- Scenario 5: available (gated) -----------------------------------------
reset_mock
snap available > "$MOCK_DIR/connect_1.sse"
out="$(POMELO_POLL_TIMEOUT=60 wait_for_deploy 2>&1)"; rc=$?
assert_rc 1 "$rc" "available"
if grep -qi "promote" <<<"$out"; then
    printf 'ok   - available prints promote guidance\n'; PASS=$(( PASS + 1 ))
else
    printf 'FAIL - available missing promote guidance\n'; FAIL=$(( FAIL + 1 ))
fi

# --- Scenario 6: ready after early stream drops (THE BUG) -------------------
# The first two probes tear with NO data (the exact failure that used to run out
# the clock and go red); the third probe reads `ready`. Must exit 0.
reset_mock
printf '__EXIT__ 28\n' > "$MOCK_DIR/connect_1.sse"   # torn, no status
printf '__EXIT__ 28\n' > "$MOCK_DIR/connect_2.sse"   # torn, no status
snap ready            > "$MOCK_DIR/connect_3.sse"    # status finally readable
POMELO_POLL_TIMEOUT=60 wait_for_deploy >/dev/null 2>&1
assert_rc 0 $? "ready-after-stream-drops"

# --- Scenario 7: non-terminal past the budget -> timeout -------------------
reset_mock
# Every probe reports a non-terminal status; never terminal within the budget.
# Use a generator: any connect number yields rolling_out by pre-seeding several.
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do snap rolling_out > "$MOCK_DIR/connect_${i}.sse"; done
POMELO_POLL_TIMEOUT=2 POMELO_CONNECT_TIMEOUT=1 wait_for_deploy >/dev/null 2>&1
assert_rc 1 $? "non-terminal-timeout"

# --- Scenario 8: live-log tail ON but drops; status poll still ready -------
# Re-enable the best-effort live tail. The mock tears every connect right after
# the snapshot (exit 28), simulating a stream that never stays up. The status
# poll must STILL conclude ready -> exit 0, proving the exit code is decoupled
# from the live stream's health. (Here every connect — probe or tail — yields a
# ready snapshot then tears, so interleaving is irrelevant to the outcome.)
reset_mock
# Override the mock for this scenario: always emit a ready snapshot then tear.
_orig_curl_decl="$(declare -f curl)"
curl() {
    printf 'data: {"event_type":"status_changed","metadata":{"new_status":"ready","snapshot":true}}\n\n'
    return 28
}
POMELO_LIVE_LOGS=1 POMELO_POLL_TIMEOUT=60 wait_for_deploy >/dev/null 2>&1
assert_rc 0 $? "live-stream-drops-but-status-ready"
# Restore the fixture-based mock (not strictly needed; last scenario).
eval "$_orig_curl_decl"

echo "-----"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
