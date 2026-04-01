#!/usr/bin/env bats
# Integration tests for complete workflow

bats_require_minimum_version 1.5.0
load test_helper

@test "successfully processes complete session payload" {
  output=$(run_with_fixture "active_session_with_context.json")

  # All expected env vars should be set
  assert_env_set "CLAUDE_MODEL" "$output"
  # Without rate_limits, cost uses the 3-var pattern (CLAUDE_COST_OK/WARN/CRIT)
  local cost_ok cost_warn cost_crit
  cost_ok=$(get_env_var "CLAUDE_COST_OK" "$output")
  cost_warn=$(get_env_var "CLAUDE_COST_WARN" "$output")
  cost_crit=$(get_env_var "CLAUDE_COST_CRIT" "$output")
  [ -n "$cost_ok" ] || [ -n "$cost_warn" ] || [ -n "$cost_crit" ]
  assert_env_set "CLAUDE_CONTEXT" "$output"
  assert_env_set "CLAUDE_SESSION_ID" "$output"
  assert_env_set "STARSHIP_CONFIG" "$output"
  assert_env_set "STARSHIP_SHELL" "$output"
}

@test "handles minimal valid payload" {
  # Minimal payload with just model
  echo '{"model":{"display_name":"Sonnet 4.5"}}' > "${TEST_TEMP_DIR}/minimal.json"

  output=$(STARSHIP_CMD="${TEST_TEMP_DIR}/print-env" "${BIN_DIR}/starship-claude" < "${TEST_TEMP_DIR}/minimal.json")

  # Should at least set model
  assert_env_set "CLAUDE_MODEL" "$output"
}

@test "handles empty payload gracefully" {
  echo '{}' > "${TEST_TEMP_DIR}/empty.json"

  # Should not error
  run bash -c "STARSHIP_CMD=\"${TEST_TEMP_DIR}/print-env\" \"${BIN_DIR}/starship-claude\" < \"${TEST_TEMP_DIR}/empty.json\""
  [ "$status" -eq 0 ]
}

@test "handles malformed JSON gracefully" {
  echo 'not valid json' > "${TEST_TEMP_DIR}/malformed.json"

  # jq will fail with exit code 5 for parse errors
  run -5 bash -c "STARSHIP_CMD=\"${TEST_TEMP_DIR}/print-env\" \"${BIN_DIR}/starship-claude\" < \"${TEST_TEMP_DIR}/malformed.json\""
}

@test "respects STARSHIP_CMD environment variable" {
  # Create a custom command that outputs a marker
  echo '#!/bin/bash' > "${TEST_TEMP_DIR}/custom-cmd"
  echo 'echo "CUSTOM_COMMAND_RAN"' >> "${TEST_TEMP_DIR}/custom-cmd"
  chmod +x "${TEST_TEMP_DIR}/custom-cmd"

  output=$(STARSHIP_CMD="${TEST_TEMP_DIR}/custom-cmd" "${BIN_DIR}/starship-claude" < <(echo '{"model":{"display_name":"Sonnet"}}'))

  [[ "$output" == *"CUSTOM_COMMAND_RAN"* ]]
}

@test "uses default config path when --config not specified" {
  output=$(run_with_fixture "active_session_with_context.json")
  config=$(get_env_var "STARSHIP_CONFIG" "$output")

  [[ "$config" == *"/.claude/starship.toml" ]]
}

@test "accepts custom config path via --config option" {
  local fixture_path="${FIXTURES_DIR}/active_session_with_context.json"
  local custom_config="/tmp/my-custom-starship.toml"

  output=$(STARSHIP_CMD="${TEST_TEMP_DIR}/print-env" "${BIN_DIR}/starship-claude" --config "$custom_config" < "$fixture_path" 2>&1)

  config=$(get_env_var "STARSHIP_CONFIG" "$output")
  [ "$config" = "$custom_config" ]
}

@test "--config option requires an argument" {
  local fixture_path="${FIXTURES_DIR}/active_session_with_context.json"

  run bash -c "STARSHIP_CMD=\"${TEST_TEMP_DIR}/print-env\" \"${BIN_DIR}/starship-claude\" --config < \"$fixture_path\""

  [ "$status" -eq 1 ]
  [[ "$output" == *"--config requires a path argument"* ]]
}

@test "can combine --config and --no-progress options" {
  local fixture_path="${FIXTURES_DIR}/active_session_with_context.json"
  local custom_config="/tmp/test-config.toml"

  output=$(STARSHIP_CMD="${TEST_TEMP_DIR}/print-env" "${BIN_DIR}/starship-claude" --config "$custom_config" --no-progress < "$fixture_path" 2>&1)

  # Should use custom config
  config=$(get_env_var "STARSHIP_CONFIG" "$output")
  [ "$config" = "$custom_config" ]

  # Should not have progress bar
  ! echo "$output" | grep -q $'\033\]9;4;'
}

@test "different cost levels produce valid formatted output" {
  # These fixtures lack rate_limits, so cost uses CLAUDE_COST_OK/WARN/CRIT
  # Helper to get whichever cost var is set
  _get_cost() {
    local o="$1"
    local c
    c=$(get_env_var "CLAUDE_COST_OK" "$o")
    [ -n "$c" ] && { echo "$c"; return; }
    c=$(get_env_var "CLAUDE_COST_WARN" "$o")
    [ -n "$c" ] && { echo "$c"; return; }
    c=$(get_env_var "CLAUDE_COST_CRIT" "$o")
    [ -n "$c" ] && { echo "$c"; return; }
    # Fallback for rate-limited fixtures
    get_env_var "CLAUDE_COST" "$o"
  }

  # Test zero cost
  output=$(run_with_fixture "zero_cost.json")
  cost=$(_get_cost "$output")
  [[ -z "$cost" || "$cost" =~ ^\$[0-9]+\.[0-9]{2}$ ]]

  # Test medium cost
  output=$(run_with_fixture "medium_cost.json")
  cost=$(_get_cost "$output")
  [[ "$cost" =~ ^\$[0-9]+\.[0-9]{2}$ ]]

  # Test high cost
  output=$(run_with_fixture "high_cost.json")
  cost=$(_get_cost "$output")
  [[ "$cost" =~ ^\$[0-9]+\.[0-9]{2}$ ]]
}

@test "different context levels produce valid percentages" {
  # Test with context (left-padded to 3 chars)
  output=$(run_with_fixture "active_session_with_context.json")
  context=$(get_env_var "CLAUDE_CONTEXT" "$output")
  [[ "$context" =~ ^[\ 0-9][0-9]%$ ]]

  # Test 40% context
  output=$(run_with_fixture "context_40_percent.json")
  context=$(get_env_var "CLAUDE_CONTEXT" "$output")
  [ "$context" = "40%" ]

  # Test without context (null current_usage) - shows placeholder
  output=$(run_with_fixture "session_without_current_usage.json")
  context=$(get_env_var "CLAUDE_CONTEXT" "$output")
  [ "$context" = "~~%" ]
}
