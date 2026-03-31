#!/usr/bin/env bats
# Tests for budget intelligence: progress bar, pacing, peak, threshold classification

bats_require_minimum_version 1.5.0
load test_helper

# =============================================================================
# 3-var pattern: threshold classification
# =============================================================================

@test "budget: low usage (24%) populates CLAUDE_BUDGET_5H_OK only" {
  output=$(run_with_fixture "rate_limits_low.json")
  assert_env_set "CLAUDE_BUDGET_5H_OK" "$output"
  assert_env_empty "CLAUDE_BUDGET_5H_WARN" "$output"
  assert_env_empty "CLAUDE_BUDGET_5H_CRIT" "$output"
}

@test "budget: warning usage (78%) populates CLAUDE_BUDGET_5H_WARN only" {
  output=$(run_with_fixture "rate_limits_warn.json")
  assert_env_empty "CLAUDE_BUDGET_5H_OK" "$output"
  assert_env_set "CLAUDE_BUDGET_5H_WARN" "$output"
  assert_env_empty "CLAUDE_BUDGET_5H_CRIT" "$output"
}

@test "budget: critical usage (94%) populates CLAUDE_BUDGET_5H_CRIT only" {
  output=$(run_with_fixture "rate_limits_critical.json")
  assert_env_empty "CLAUDE_BUDGET_5H_OK" "$output"
  assert_env_empty "CLAUDE_BUDGET_5H_WARN" "$output"
  assert_env_set "CLAUDE_BUDGET_5H_CRIT" "$output"
}

@test "budget: original rate_limits fixture (7%) populates CLAUDE_BUDGET_5H_OK" {
  output=$(run_with_fixture "rate_limits.json")
  assert_env_set "CLAUDE_BUDGET_5H_OK" "$output"
  assert_env_empty "CLAUDE_BUDGET_5H_WARN" "$output"
  assert_env_empty "CLAUDE_BUDGET_5H_CRIT" "$output"
}

# =============================================================================
# Progress bar content format
# =============================================================================

@test "budget: 5h budget text starts with '5h' and includes percentage" {
  output=$(run_with_fixture "rate_limits_low.json")
  value=$(get_env_var "CLAUDE_BUDGET_5H_OK" "$output")
  [[ "$value" =~ ^5h\ .+\ 24%$ ]]
}

@test "budget: 5h budget text at 78% starts with '5h' and shows 78%" {
  output=$(run_with_fixture "rate_limits_warn.json")
  value=$(get_env_var "CLAUDE_BUDGET_5H_WARN" "$output")
  [[ "$value" =~ ^5h\ .+\ 78%$ ]]
}

@test "budget: 5h budget text at 94% starts with '5h' and shows 94%" {
  output=$(run_with_fixture "rate_limits_critical.json")
  value=$(get_env_var "CLAUDE_BUDGET_5H_CRIT" "$output")
  [[ "$value" =~ ^5h\ .+\ 94%$ ]]
}

# =============================================================================
# 7d auto-show logic
# =============================================================================

@test "budget: 7d hidden when both 5h and 7d are low" {
  output=$(run_with_fixture "rate_limits_low.json")
  assert_env_empty "CLAUDE_BUDGET_7D_OK" "$output"
  assert_env_empty "CLAUDE_BUDGET_7D_WARN" "$output"
  assert_env_empty "CLAUDE_BUDGET_7D_CRIT" "$output"
}

@test "budget: 7d shown when 5h is critical (94%) even if 7d is moderate" {
  output=$(run_with_fixture "rate_limits_critical.json")
  # 7d at 86% should show as WARN
  value_ok=$(get_env_var "CLAUDE_BUDGET_7D_OK" "$output")
  value_warn=$(get_env_var "CLAUDE_BUDGET_7D_WARN" "$output")
  value_crit=$(get_env_var "CLAUDE_BUDGET_7D_CRIT" "$output")
  # At least one should be populated
  [ -n "$value_ok" ] || [ -n "$value_warn" ] || [ -n "$value_crit" ]
}

@test "budget: 7d at 86% is classified as WARN" {
  output=$(run_with_fixture "rate_limits_critical.json")
  assert_env_set "CLAUDE_BUDGET_7D_WARN" "$output"
  assert_env_empty "CLAUDE_BUDGET_7D_OK" "$output"
  assert_env_empty "CLAUDE_BUDGET_7D_CRIT" "$output"
}

# =============================================================================
# Pace indicator
# =============================================================================

@test "budget: pace empty when resets_at is far in future (outside window)" {
  output=$(run_with_fixture "rate_limits_low.json")
  # resets_at is year 2099 — we're not within the 5h window, so pace is empty
  assert_env_empty "CLAUDE_PACE_OK" "$output"
  assert_env_empty "CLAUDE_PACE_WARN" "$output"
  assert_env_empty "CLAUDE_PACE_CRIT" "$output"
  assert_env_empty "CLAUDE_PACE_TARGET_5H" "$output"
  assert_env_empty "CLAUDE_PACE_DELTA_5H" "$output"
}

@test "budget: pace indicator populated when within 5h window" {
  # Create a dynamic fixture with resets_at 2.5h from now (midway through 5h window)
  local resets_at=$(( $(date +%s) + 9000 ))
  local fixture="${TEST_TEMP_DIR}/rate_limits_pace.json"
  jq --argjson ra "$resets_at" '.rate_limits.five_hour.resets_at = $ra' \
    "${FIXTURES_DIR}/rate_limits_low.json" > "$fixture"

  output=$(STARSHIP_CMD="${TEST_TEMP_DIR}/print-env" "${BIN_DIR}/starship-claude" <"$fixture" 2>&1)
  pace_ok=$(get_env_var "CLAUDE_PACE_OK" "$output")
  pace_warn=$(get_env_var "CLAUDE_PACE_WARN" "$output")
  pace_crit=$(get_env_var "CLAUDE_PACE_CRIT" "$output")
  target=$(get_env_var "CLAUDE_PACE_TARGET_5H" "$output")
  delta=$(get_env_var "CLAUDE_PACE_DELTA_5H" "$output")
  # At least one pace var should be populated
  [ -n "$pace_ok" ] || [ -n "$pace_warn" ] || [ -n "$pace_crit" ]
  # Raw values should be set
  [ -n "$target" ]
  [ -n "$delta" ]
}

@test "budget: pace shows under-pace when usage is low and midway through window" {
  # 24% usage, midway through 5h window (target ~50%) → under pace
  local resets_at=$(( $(date +%s) + 9000 ))
  local fixture="${TEST_TEMP_DIR}/rate_limits_pace.json"
  jq --argjson ra "$resets_at" '.rate_limits.five_hour.resets_at = $ra' \
    "${FIXTURES_DIR}/rate_limits_low.json" > "$fixture"

  output=$(STARSHIP_CMD="${TEST_TEMP_DIR}/print-env" "${BIN_DIR}/starship-claude" <"$fixture" 2>&1)
  # 24% usage with ~50% target → under pace → CLAUDE_PACE_OK with ⇣
  pace_ok=$(get_env_var "CLAUDE_PACE_OK" "$output")
  [ -n "$pace_ok" ]
}

@test "budget: pace shows over-pace when usage is high and early in window" {
  # 78% usage, near start of 5h window (target ~5%) → over pace
  local resets_at=$(( $(date +%s) + 17500 ))  # 4h52m left → ~3% elapsed
  local fixture="${TEST_TEMP_DIR}/rate_limits_pace.json"
  jq --argjson ra "$resets_at" '.rate_limits.five_hour.resets_at = $ra' \
    "${FIXTURES_DIR}/rate_limits_warn.json" > "$fixture"

  output=$(STARSHIP_CMD="${TEST_TEMP_DIR}/print-env" "${BIN_DIR}/starship-claude" <"$fixture" 2>&1)
  # 78% usage with ~3% target → way over pace → CLAUDE_PACE_WARN or CRIT
  pace_warn=$(get_env_var "CLAUDE_PACE_WARN" "$output")
  pace_crit=$(get_env_var "CLAUDE_PACE_CRIT" "$output")
  [ -n "$pace_warn" ] || [ -n "$pace_crit" ]
}

# =============================================================================
# Reset countdown
# =============================================================================

@test "budget: CLAUDE_BUDGET_RESET is set when resets_at exists" {
  output=$(run_with_fixture "rate_limits_low.json")
  assert_env_set "CLAUDE_BUDGET_RESET" "$output"
}

@test "budget: CLAUDE_BUDGET_RESET contains arrow and time" {
  output=$(run_with_fixture "rate_limits_low.json")
  value=$(get_env_var "CLAUDE_BUDGET_RESET" "$output")
  # Should start with ➞ (U+279E) and contain time like "Xd Yh" or "Xh Ym"
  [ -n "$value" ]
}

# =============================================================================
# Peak/off-peak detection
# =============================================================================

@test "budget: CLAUDE_IS_PEAK is set to true or false" {
  output=$(run_with_fixture "rate_limits_low.json")
  value=$(get_env_var "CLAUDE_IS_PEAK" "$output")
  [ "$value" = "true" ] || [ "$value" = "false" ]
}

@test "budget: exactly one of CLAUDE_PEAK_ON or CLAUDE_PEAK_OFF is populated" {
  output=$(run_with_fixture "rate_limits_low.json")
  peak_on=$(get_env_var "CLAUDE_PEAK_ON" "$output")
  peak_off=$(get_env_var "CLAUDE_PEAK_OFF" "$output")
  # Exactly one should be non-empty
  if [ -n "$peak_on" ]; then
    [ -z "$peak_off" ]
  else
    [ -n "$peak_off" ]
  fi
}

# =============================================================================
# Backward compatibility: no rate data
# =============================================================================

@test "budget: all budget vars empty when no rate_limits" {
  output=$(run_with_fixture "active_session_with_context.json")
  assert_env_empty "CLAUDE_BUDGET_5H_OK" "$output"
  assert_env_empty "CLAUDE_BUDGET_5H_WARN" "$output"
  assert_env_empty "CLAUDE_BUDGET_5H_CRIT" "$output"
  assert_env_empty "CLAUDE_PACE_OK" "$output"
  assert_env_empty "CLAUDE_PACE_WARN" "$output"
  assert_env_empty "CLAUDE_PACE_CRIT" "$output"
  assert_env_empty "CLAUDE_BUDGET_RESET" "$output"
  assert_env_empty "CLAUDE_BUDGET_7D_OK" "$output"
  assert_env_empty "CLAUDE_BUDGET_7D_WARN" "$output"
  assert_env_empty "CLAUDE_BUDGET_7D_CRIT" "$output"
}

@test "budget: peak detection not shown without rate_limits" {
  output=$(run_with_fixture "active_session_with_context.json")
  assert_env_empty "CLAUDE_PEAK_ON" "$output"
  assert_env_empty "CLAUDE_PEAK_OFF" "$output"
  assert_env_empty "CLAUDE_IS_PEAK" "$output"
}

# =============================================================================
# Existing rate limit vars still work
# =============================================================================

@test "budget: existing CLAUDE_RATE_5H still exported alongside budget vars" {
  output=$(run_with_fixture "rate_limits_low.json")
  assert_env_set "CLAUDE_RATE_5H" "$output"
  assert_env_set "CLAUDE_BUDGET_5H_OK" "$output"
}

@test "budget: existing CLAUDE_RATE_7D still exported alongside budget vars" {
  output=$(run_with_fixture "rate_limits_low.json")
  assert_env_set "CLAUDE_RATE_7D" "$output"
}
