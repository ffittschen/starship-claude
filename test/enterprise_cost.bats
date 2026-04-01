#!/usr/bin/env bats
# Tests for enterprise/API cost tracking: threshold coloring, ledger, delta, discount

bats_require_minimum_version 1.5.0
load test_helper

# =============================================================================
# Cost threshold classification (3-var pattern)
# =============================================================================

@test "enterprise: low cost ($2.50) populates CLAUDE_COST_OK only" {
  output=$(run_with_fixture "enterprise_low_cost.json")
  assert_env_set "CLAUDE_COST_OK" "$output"
  assert_env_empty "CLAUDE_COST_WARN" "$output"
  assert_env_empty "CLAUDE_COST_CRIT" "$output"
}

@test "enterprise: high cost ($25.00) populates CLAUDE_COST_CRIT only" {
  output=$(run_with_fixture "enterprise_high_cost.json")
  assert_env_empty "CLAUDE_COST_OK" "$output"
  assert_env_empty "CLAUDE_COST_WARN" "$output"
  assert_env_set "CLAUDE_COST_CRIT" "$output"
}

@test "enterprise: CLAUDE_COST_OK shows formatted cost" {
  output=$(run_with_fixture "enterprise_low_cost.json")
  assert_env_equals "CLAUDE_COST_OK" '$2.50' "$output"
}

@test "enterprise: CLAUDE_COST_CRIT shows formatted cost" {
  output=$(run_with_fixture "enterprise_high_cost.json")
  assert_env_equals "CLAUDE_COST_CRIT" '$25.00' "$output"
}

@test "enterprise: CLAUDE_COST is unset for enterprise users" {
  output=$(run_with_fixture "enterprise_low_cost.json")
  assert_env_empty "CLAUDE_COST" "$output"
}

@test "enterprise: CLAUDE_COST_RAW is still exported" {
  output=$(run_with_fixture "enterprise_low_cost.json")
  assert_env_equals "CLAUDE_COST_RAW" "2.5" "$output"
}

# =============================================================================
# Rate-limited path unchanged
# =============================================================================

@test "enterprise: rate-limited users keep CLAUDE_COST, no CLAUDE_COST_OK/WARN/CRIT" {
  output=$(run_with_fixture "rate_limits.json")
  assert_env_set "CLAUDE_COST" "$output"
  assert_env_empty "CLAUDE_COST_OK" "$output"
  assert_env_empty "CLAUDE_COST_WARN" "$output"
  assert_env_empty "CLAUDE_COST_CRIT" "$output"
}

# =============================================================================
# Budget vars unset for enterprise users
# =============================================================================

@test "enterprise: budget 5h vars unset without rate_limits" {
  output=$(run_with_fixture "enterprise_low_cost.json")
  assert_env_empty "CLAUDE_BUDGET_5H_OK" "$output"
  assert_env_empty "CLAUDE_BUDGET_5H_WARN" "$output"
  assert_env_empty "CLAUDE_BUDGET_5H_CRIT" "$output"
}

@test "enterprise: peak vars unset without rate_limits" {
  output=$(run_with_fixture "enterprise_low_cost.json")
  assert_env_empty "CLAUDE_PEAK_ON" "$output"
  assert_env_empty "CLAUDE_PEAK_OFF" "$output"
}

# =============================================================================
# Enterprise discount
# =============================================================================

@test "enterprise: discount halves displayed cost" {
  export CLAUDE_ENTERPRISE_DISCOUNT=50
  output=$(run_with_fixture "enterprise_high_cost.json")
  unset CLAUDE_ENTERPRISE_DISCOUNT
  # $25.00 * 0.5 = $12.50 → should be WARN (>= $5, < $20)
  assert_env_empty "CLAUDE_COST_OK" "$output"
  assert_env_set "CLAUDE_COST_WARN" "$output"
  assert_env_empty "CLAUDE_COST_CRIT" "$output"
  assert_env_equals "CLAUDE_COST_WARN" '$12.50' "$output"
}

@test "enterprise: zero discount is no-op" {
  export CLAUDE_ENTERPRISE_DISCOUNT=0
  output=$(run_with_fixture "enterprise_low_cost.json")
  unset CLAUDE_ENTERPRISE_DISCOUNT
  assert_env_equals "CLAUDE_COST_OK" '$2.50' "$output"
}

# =============================================================================
# Custom thresholds
# =============================================================================

@test "enterprise: custom warn threshold changes classification" {
  export CLAUDE_COST_WARN_USD=2 CLAUDE_COST_CRIT_USD=10
  output=$(run_with_fixture "enterprise_low_cost.json")
  unset CLAUDE_COST_WARN_USD CLAUDE_COST_CRIT_USD
  # $2.50 >= $2 warn threshold → WARN
  assert_env_set "CLAUDE_COST_WARN" "$output"
  assert_env_empty "CLAUDE_COST_OK" "$output"
}

# =============================================================================
# Ledger: daily and monthly totals
# =============================================================================

@test "enterprise: CLAUDE_COST_TODAY shows today's total from ledger" {
  # Create a mock state file with ledger entries
  local state_dir="${TEST_TEMP_DIR}/state"
  mkdir -p "$state_dir"
  local today
  today="$(date +%Y-%m-%d)"
  local month
  month="$(date +%Y-%m)"
  cat > "$state_dir/budget-state.json" << STATEEOF
{"v":1,"snapshots":{},"ledger":{"other-session":{"cost":5.0,"day":"$today","month":"$month"}}}
STATEEOF

  export CLAUDE_BUDGET_STATE_DIR="$state_dir"
  output=$(run_with_fixture "enterprise_low_cost.json")
  unset CLAUDE_BUDGET_STATE_DIR
  value=$(get_env_var "CLAUDE_COST_TODAY" "$output")
  # Today total = $5.00 (other session) + $2.50 (current) = $7.50
  [[ "$value" =~ ^\$7\.50\ today$ ]]
}

@test "enterprise: CLAUDE_COST_MONTH shows monthly total" {
  local state_dir="${TEST_TEMP_DIR}/state"
  mkdir -p "$state_dir"
  local today
  today="$(date +%Y-%m-%d)"
  local month
  month="$(date +%Y-%m)"
  cat > "$state_dir/budget-state.json" << STATEEOF
{"v":1,"snapshots":{},"ledger":{"old-session":{"cost":100.0,"day":"${month}-01","month":"$month"}}}
STATEEOF

  export CLAUDE_BUDGET_STATE_DIR="$state_dir"
  output=$(run_with_fixture "enterprise_low_cost.json")
  unset CLAUDE_BUDGET_STATE_DIR
  value=$(get_env_var "CLAUDE_COST_MONTH" "$output")
  # Month total = $100.00 (old) + $2.50 (current) = $102.50
  [[ "$value" =~ ^\$102\.50 ]]
}

@test "enterprise: yesterday fallback when no sessions today" {
  local state_dir="${TEST_TEMP_DIR}/state"
  mkdir -p "$state_dir"
  local yesterday
  yesterday="$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d 2>/dev/null)"
  [ -z "$yesterday" ] && skip "Cannot compute yesterday date"
  local month="${yesterday:0:7}"
  # Create ledger with only yesterday's entry (different session)
  # Current session has cost but it's the ONLY session today
  cat > "$state_dir/budget-state.json" << STATEEOF
{"v":1,"snapshots":{},"ledger":{"yesterday-session":{"cost":8.50,"day":"$yesterday","month":"$month"}}}
STATEEOF

  # Use a fixture with very low cost — the script will write today's entry too,
  # so today_total will be > 0. We need to test with a state where today's date
  # is different from the fixture session. Since the script always writes today's
  # entry, the yesterday fallback only triggers if today_total is 0.
  # This means we can't easily test it with run_with_fixture because it always
  # adds today's entry. Skip this edge case for now.
  skip "Yesterday fallback requires no sessions today, but statusline always writes current"
}

# =============================================================================
# Per-prompt cost delta
# =============================================================================

@test "enterprise: CLAUDE_COST_DELTA computed from snapshot" {
  local state_dir="${TEST_TEMP_DIR}/state"
  mkdir -p "$state_dir"
  local today
  today="$(date +%Y-%m-%d)"
  local month
  month="$(date +%Y-%m)"
  # Snapshot with previous cost of $1.00 for this session
  cat > "$state_dir/budget-state.json" << STATEEOF
{"v":1,"snapshots":{"aaaa1111-aaaa-1111-aaaa-111111111111":{"cost_usd":1.0,"ts":$(date +%s)}},"ledger":{}}
STATEEOF

  export CLAUDE_BUDGET_STATE_DIR="$state_dir"
  output=$(run_with_fixture "enterprise_low_cost.json")
  unset CLAUDE_BUDGET_STATE_DIR
  value=$(get_env_var "CLAUDE_COST_DELTA" "$output")
  # Delta = $2.50 - $1.00 = $1.50
  [[ "$value" == '(+$1.50)' ]]
}

@test "enterprise: no delta when no snapshot exists" {
  local state_dir="${TEST_TEMP_DIR}/state"
  mkdir -p "$state_dir"
  echo '{"v":1,"snapshots":{},"ledger":{}}' > "$state_dir/budget-state.json"

  export CLAUDE_BUDGET_STATE_DIR="$state_dir"
  output=$(run_with_fixture "enterprise_low_cost.json")
  unset CLAUDE_BUDGET_STATE_DIR
  assert_env_empty "CLAUDE_COST_DELTA" "$output"
}

@test "enterprise: no delta when cost hasn't changed" {
  local state_dir="${TEST_TEMP_DIR}/state"
  mkdir -p "$state_dir"
  # Snapshot with same cost as fixture ($2.50)
  cat > "$state_dir/budget-state.json" << STATEEOF
{"v":1,"snapshots":{"aaaa1111-aaaa-1111-aaaa-111111111111":{"cost_usd":2.5,"ts":$(date +%s)}},"ledger":{}}
STATEEOF

  export CLAUDE_BUDGET_STATE_DIR="$state_dir"
  output=$(run_with_fixture "enterprise_low_cost.json")
  unset CLAUDE_BUDGET_STATE_DIR
  assert_env_empty "CLAUDE_COST_DELTA" "$output"
}

# =============================================================================
# State file management
# =============================================================================

@test "enterprise: state file is created when it doesn't exist" {
  local state_dir="${TEST_TEMP_DIR}/new-state"
  [ ! -d "$state_dir" ]  # Confirm doesn't exist

  export CLAUDE_BUDGET_STATE_DIR="$state_dir"
  output=$(run_with_fixture "enterprise_low_cost.json")
  unset CLAUDE_BUDGET_STATE_DIR

  [ -f "$state_dir/budget-state.json" ]
}

@test "enterprise: ledger entry written to state file" {
  local state_dir="${TEST_TEMP_DIR}/state"
  mkdir -p "$state_dir"
  echo '{}' > "$state_dir/budget-state.json"

  export CLAUDE_BUDGET_STATE_DIR="$state_dir"
  output=$(run_with_fixture "enterprise_low_cost.json")
  unset CLAUDE_BUDGET_STATE_DIR

  # Check the ledger has the session entry
  local session_cost
  session_cost="$(jq -r '.ledger["aaaa1111-aaaa-1111-aaaa-111111111111"].cost' "$state_dir/budget-state.json")"
  [ "$session_cost" = "2.5" ]
}
