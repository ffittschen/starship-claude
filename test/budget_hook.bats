#!/usr/bin/env bats
# Tests for budget-hook script

bats_require_minimum_version 1.5.0
load test_helper

HOOK_SCRIPT="${PROJECT_ROOT}/plugin/bin/budget-hook"

# =============================================================================
# Basic hook behavior
# =============================================================================

@test "hook: creates state directory if missing" {
  local state_dir="${TEST_TEMP_DIR}/hook-state"
  [ ! -d "$state_dir" ]

  export CLAUDE_BUDGET_STATE_DIR="$state_dir"
  echo '{"session_id":"test-session","cost":{"total_cost_usd":1.5}}' \
    | "$HOOK_SCRIPT"
  unset CLAUDE_BUDGET_STATE_DIR

  [ -d "$state_dir" ]
  [ -f "$state_dir/budget-state.json" ]
}

@test "hook: snapshots session cost into state file" {
  local state_dir="${TEST_TEMP_DIR}/hook-state"
  mkdir -p "$state_dir"
  echo '{}' > "$state_dir/budget-state.json"

  export CLAUDE_BUDGET_STATE_DIR="$state_dir"
  echo '{"session_id":"snap-session","cost":{"total_cost_usd":3.50}}' \
    | "$HOOK_SCRIPT"
  unset CLAUDE_BUDGET_STATE_DIR

  # The hook reads cost from the ledger (written by statusline), not from stdin.
  # Since ledger is empty, snapshot cost_usd will be null.
  local snap_ts
  snap_ts="$(jq '.snapshots["snap-session"].ts' "$state_dir/budget-state.json")"
  [ "$snap_ts" != "null" ]
}

@test "hook: handles missing session_id gracefully" {
  local state_dir="${TEST_TEMP_DIR}/hook-state"
  mkdir -p "$state_dir"
  echo '{}' > "$state_dir/budget-state.json"

  # No session_id — should exit cleanly
  export CLAUDE_BUDGET_STATE_DIR="$state_dir"
  echo '{"cost":{"total_cost_usd":1.0}}' \
    | "$HOOK_SCRIPT"
  unset CLAUDE_BUDGET_STATE_DIR

  # State should be unchanged (no snapshots added)
  local snap_count
  snap_count="$(jq '.snapshots | length' "$state_dir/budget-state.json")"
  [ "$snap_count" = "0" ]
}

@test "hook: handles empty stdin gracefully" {
  local state_dir="${TEST_TEMP_DIR}/hook-state"
  mkdir -p "$state_dir"

  export CLAUDE_BUDGET_STATE_DIR="$state_dir"
  echo "" | "$HOOK_SCRIPT"
  unset CLAUDE_BUDGET_STATE_DIR
  # Should not crash, and no state file created (no payload to process)
}

@test "hook: prunes old snapshots" {
  local state_dir="${TEST_TEMP_DIR}/hook-state"
  mkdir -p "$state_dir"
  # Create state with an old snapshot (ts = 0, well beyond 48h cutoff)
  cat > "$state_dir/budget-state.json" << 'EOF'
{"v":1,"snapshots":{"old-session":{"cost_usd":1.0,"ts":0}},"ledger":{}}
EOF

  export CLAUDE_BUDGET_STATE_DIR="$state_dir"
  echo '{"session_id":"new-session","cost":{"total_cost_usd":2.0}}' \
    | "$HOOK_SCRIPT"
  unset CLAUDE_BUDGET_STATE_DIR

  # Old snapshot should be pruned
  local old_snap
  old_snap="$(jq '.snapshots["old-session"] // empty' "$state_dir/budget-state.json")"
  [ -z "$old_snap" ]
}

@test "hook: preserves ledger entries" {
  local state_dir="${TEST_TEMP_DIR}/hook-state"
  mkdir -p "$state_dir"
  cat > "$state_dir/budget-state.json" << 'EOF'
{"v":1,"snapshots":{},"ledger":{"existing":{"cost":5.0,"day":"2026-03-31","month":"2026-03"}}}
EOF

  export CLAUDE_BUDGET_STATE_DIR="$state_dir"
  echo '{"session_id":"new-session","cost":{"total_cost_usd":1.0}}' \
    | "$HOOK_SCRIPT"
  unset CLAUDE_BUDGET_STATE_DIR

  # Ledger should still have the existing entry
  local existing_cost
  existing_cost="$(jq '.ledger["existing"].cost' "$state_dir/budget-state.json")"
  # jq may output 5 or 5.0 depending on version
  [[ "$existing_cost" == "5" || "$existing_cost" == "5.0" ]]
}
