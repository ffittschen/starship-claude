#!/usr/bin/env bats
# Tests for rate limit environment variable exports

bats_require_minimum_version 1.5.0
load test_helper

# =============================================================================
# Raw rate limit values
# =============================================================================

@test "rate: CLAUDE_RATE_5H_RAW is exported when rate_limits present" {
  output=$(run_with_fixture "rate_limits.json")
  assert_env_equals "CLAUDE_RATE_5H_RAW" "7" "$output"
}

@test "rate: CLAUDE_RATE_7D_RAW is exported when rate_limits present" {
  output=$(run_with_fixture "rate_limits.json")
  assert_env_equals "CLAUDE_RATE_7D_RAW" "42" "$output"
}

@test "rate: CLAUDE_RATE_5H_RESETS is exported when rate_limits present" {
  output=$(run_with_fixture "rate_limits.json")
  assert_env_equals "CLAUDE_RATE_5H_RESETS" "4102358400" "$output"
}

@test "rate: CLAUDE_RATE_7D_RESETS is exported when rate_limits present" {
  output=$(run_with_fixture "rate_limits.json")
  assert_env_equals "CLAUDE_RATE_7D_RESETS" "4133980800" "$output"
}

@test "rate: raw vars are empty when no rate_limits in payload" {
  output=$(run_with_fixture "active_session_with_context.json")
  assert_env_empty "CLAUDE_RATE_5H_RAW" "$output"
  assert_env_empty "CLAUDE_RATE_7D_RAW" "$output"
  assert_env_empty "CLAUDE_RATE_5H_RESETS" "$output"
  assert_env_empty "CLAUDE_RATE_7D_RESETS" "$output"
}

# =============================================================================
# Formatted rate limit values
# =============================================================================

@test "rate: CLAUDE_RATE_5H includes percentage and time remaining" {
  output=$(run_with_fixture "rate_limits.json")
  value=$(get_env_var "CLAUDE_RATE_5H" "$output")
  # resets_at is year 2099 so days format applies: "7% (Xd Yh)"
  [[ "$value" =~ ^7%\ \([0-9]+d\ [0-9]+h\)$ ]]
}

@test "rate: CLAUDE_RATE_7D includes percentage and time remaining" {
  output=$(run_with_fixture "rate_limits.json")
  value=$(get_env_var "CLAUDE_RATE_7D" "$output")
  [[ "$value" =~ ^42%\ \([0-9]+d\ [0-9]+h\)$ ]]
}

@test "rate: CLAUDE_RATE_5H is just percentage when no resets_at" {
  output=$(run_with_fixture "rate_limits_no_resets.json")
  assert_env_equals "CLAUDE_RATE_5H" "7%" "$output"
}

@test "rate: CLAUDE_RATE_7D is just percentage when no resets_at" {
  output=$(run_with_fixture "rate_limits_no_resets.json")
  assert_env_equals "CLAUDE_RATE_7D" "42%" "$output"
}

@test "rate: CLAUDE_RATE_5H is empty when no rate_limits data" {
  output=$(run_with_fixture "active_session_with_context.json")
  assert_env_empty "CLAUDE_RATE_5H" "$output"
}

@test "rate: CLAUDE_RATE_7D is empty when no rate_limits data" {
  output=$(run_with_fixture "active_session_with_context.json")
  assert_env_empty "CLAUDE_RATE_7D" "$output"
}
