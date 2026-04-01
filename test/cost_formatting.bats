#!/usr/bin/env bats
# Test cost formatting and display

load test_helper

# Helper to get cost from whichever var is populated
# (CLAUDE_COST for rate-limited, CLAUDE_COST_OK/WARN/CRIT for enterprise)
_get_any_cost() {
  local o="$1" c
  c=$(get_env_var "CLAUDE_COST" "$o")
  [ -n "$c" ] && { echo "$c"; return; }
  c=$(get_env_var "CLAUDE_COST_OK" "$o")
  [ -n "$c" ] && { echo "$c"; return; }
  c=$(get_env_var "CLAUDE_COST_WARN" "$o")
  [ -n "$c" ] && { echo "$c"; return; }
  get_env_var "CLAUDE_COST_CRIT" "$o"
}

@test "formats low cost with two decimals" {
  output=$(run_with_fixture "low_cost_session.json")
  cost=$(_get_any_cost "$output")

  # Should be formatted as $X.XX
  [[ "$cost" =~ ^\$[0-9]+\.[0-9]{2}$ ]]
}

@test "formats medium cost correctly" {
  output=$(run_with_fixture "medium_cost.json")
  cost=$(_get_any_cost "$output")

  # Should be formatted as $X.XX
  [[ "$cost" =~ ^\$[0-9]+\.[0-9]{2}$ ]]
}

@test "formats high cost correctly" {
  output=$(run_with_fixture "high_cost.json")
  cost=$(_get_any_cost "$output")

  # Should be formatted as $X.XX
  [[ "$cost" =~ ^\$[0-9]+\.[0-9]{2}$ ]]
}

@test "handles zero cost" {
  output=$(run_with_fixture "zero_cost.json")
  cost=$(get_env_var "CLAUDE_COST" "$output")

  # Zero should format as $0.00
  [ "$cost" = "\$0.00" ] || [ -z "$cost" ]
}

@test "handles null cost gracefully" {
  # Create a minimal fixture without cost field
  echo '{"session_id":"test","model":{"display_name":"Sonnet 4.5"}}' > "${TEST_TEMP_DIR}/no_cost.json"

  output=$(STARSHIP_CMD="${TEST_TEMP_DIR}/print-env" "${BIN_DIR}/starship-claude" < "${TEST_TEMP_DIR}/no_cost.json")

  # CLAUDE_COST should be empty
  cost=$(get_env_var "CLAUDE_COST" "$output")
  [ -z "$cost" ]
}
