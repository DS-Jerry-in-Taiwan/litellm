#!/bin/bash
# =============================================================================
# Terraform Destructive Guard Regression Tests
# =============================================================================
# Tests the is_destructive_plan() helper from terraform-accounts.sh
# to ensure correct classification of plan summaries.
#
# Test categories:
#   🟢 Positive: safe plans should NOT trigger destructive guard
#   🔴 Negative: true destroy plans MUST trigger destructive guard
#   📏 Range:   replacement patterns MUST trigger
#   🎯 Accuracy: same fixture → same result in both wrappers
#   🔲 Boundary: no-changes plan should not trigger
#
# Usage:
#   ./tests/scripts/test_terraform_destructive_guard.sh [--verbose]
#
# Exit codes:
#   0 = all tests passed
#   1 = one or more tests failed
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCOUNTS_SCRIPT="$SCRIPT_DIR/../../scripts/aws/terraform-accounts.sh"

# ANSI colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

# Counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Options
VERBOSE="${VERBOSE:-0}"
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

# ── Load helper under test ──────────────────────────────────────────────────────
if [[ ! -f "$ACCOUNTS_SCRIPT" ]]; then
    echo -e "${RED}ERROR: Cannot find terraform-accounts.sh at $ACCOUNTS_SCRIPT${NC}" >&2
    exit 1
fi

source "$ACCOUNTS_SCRIPT"

# ── Test helpers ──────────────────────────────────────────────────────────────
run_test() {
    local description="$1"
    local expected_result="$2"  # "destructive" or "safe"
    local plan_fixture="$3"

    ((TESTS_TOTAL++))

    # Run the helper
    local actual_result
    if is_destructive_plan "$plan_fixture"; then
        actual_result="destructive"
    else
        actual_result="safe"
    fi

    if [[ "$actual_result" == "$expected_result" ]]; then
        ((TESTS_PASSED++))
        echo -e "${GREEN}✓ PASS${NC} $description"
        [[ "$VERBOSE" == "1" ]] && echo -e "       Expected: $expected_result | Got: $actual_result"
    else
        ((TESTS_FAILED++))
        echo -e "${RED}✗ FAIL${NC} $description"
        echo -e "       Expected: $expected_result | Got: $actual_result"
        [[ "$VERBOSE" == "1" ]] && echo "       Fixture: $plan_fixture"
    fi
}

run_test_describe() {
    local description="$1"
    local expected_contains="$2"
    local plan_fixture="$3"

    ((TESTS_TOTAL++))

    local actual
    actual=$(describe_plan_destructiveness "$plan_fixture")

    if [[ "$actual" == *"$expected_contains"* ]]; then
        ((TESTS_PASSED++))
        echo -e "${GREEN}✓ PASS${NC} $description"
        [[ "$VERBOSE" == "1" ]] && echo -e "       Expected contains: $expected_contains | Got: $actual"
    else
        ((TESTS_FAILED++))
        echo -e "${RED}✗ FAIL${NC} $description"
        echo -e "       Expected contains: $expected_contains | Got: $actual"
    fi
}

run_test_count() {
    local description="$1"
    local expected_count="$2"
    local plan_fixture="$3"

    ((TESTS_TOTAL++))

    local actual
    actual=$(get_destroy_count "$plan_fixture")

    if [[ "$actual" == "$expected_count" ]]; then
        ((TESTS_PASSED++))
        echo -e "${GREEN}✓ PASS${NC} $description"
        [[ "$VERBOSE" == "1" ]] && echo -e "       Expected: $expected_count | Got: $actual"
    else
        ((TESTS_FAILED++))
        echo -e "${RED}✗ FAIL${NC} $description"
        echo -e "       Expected: $expected_count | Got: $actual"
    fi
}

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Terraform Destructive Guard Regression Tests${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 1: 🟢 POSITIVE TESTS — Safe plans should NOT trigger
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${BLUE}══ Category 1: Positive (safe plans — should NOT trigger) ══${NC}"

# Case 1a: 0 to destroy
run_test \
    "Plan with 0 to destroy is safe" \
    "safe" \
    'Plan: 5 to add, 2 to change, 0 to destroy.'

# Case 1b: Multi-line with 0 destroy
run_test \
    "Multi-line plan with 0 to destroy is safe" \
    "safe" \
    'Terraform will perform the following actions:

  # aws_api_gateway_method.example will be created
  + resource "aws_api_gateway_method" "example" { ... }

Plan: 5 to add, 2 to change, 0 to destroy.'

# Case 1c: Only add operations
run_test \
    "Plan with only adds is safe" \
    "safe" \
    'Plan: 10 to add, 0 to change, 0 to destroy.'

# Case 1d: Only change operations
run_test \
    "Plan with only changes is safe" \
    "safe" \
    'Plan: 0 to add, 5 to change, 0 to destroy.'

# Case 1e: Add and change
run_test \
    "Plan with adds and changes is safe" \
    "safe" \
    'Plan: 3 to add, 7 to change, 0 to destroy.'

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 2: 🔴 NEGATIVE TESTS — True destroy MUST trigger
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${BLUE}══ Category 2: Negative (true destroy — MUST trigger) ══════${NC}"

# Case 2a: 1 to destroy
run_test \
    "Plan with 1 to destroy is destructive" \
    "destructive" \
    'Plan: 0 to add, 0 to change, 1 to destroy.'

# Case 2b: 2 to destroy
run_test \
    "Plan with 2 to destroy is destructive" \
    "destructive" \
    'Plan: 0 to add, 1 to change, 2 to destroy.'

# Case 2c: 1 destroy with adds
run_test \
    "Plan with 1 destroy + adds is destructive" \
    "destructive" \
    'Plan: 1 to add, 0 to change, 1 to destroy.'

# Case 2d: Large destroy count
run_test \
    "Plan with 10 to destroy is destructive" \
    "destructive" \
    'Plan: 5 to add, 3 to change, 10 to destroy.'

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 3: 📏 RANGE TESTS — Replacement patterns MUST trigger
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${BLUE}══ Category 3: Range (replacement patterns — MUST trigger) ══${NC}"

# Case 3a: must be replaced
run_test \
    "Plan with 'must be replaced' is destructive" \
    "destructive" \
    '# aws_db_instance.example must be replaced
-/+ resource "aws_db_instance" "example" {
      # forces replacement
    }'

# Case 3b: -/+ marker
run_test \
    "Plan with '-/+' replacement marker is destructive" \
    "destructive" \
    '-/+ resource "aws_instance" "web" {
      ami: "ami-123" => "ami-456"
    }'

# Case 3c: must be replaced inline
run_test \
    "Plan with inline 'must be replaced' is destructive" \
    "destructive" \
    '  # aws_s3_bucket.example must be replaced ( Forces new resource )
  ~ resource "aws_s3_bucket" "example" { }'

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 4: 🎯 ACCURACY TESTS — Wrapper consistency
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${BLUE}══ Category 4: Accuracy (consistent classification) ══════════${NC}"

# Same fixture should produce same result from both helpers
run_test \
    "Safe fixture is_destructive_plan returns false" \
    "safe" \
    'Plan: 5 to add, 2 to change, 0 to destroy.'

run_test_describe \
    "Safe fixture describe says SAFE" \
    "SAFE" \
    'Plan: 5 to add, 2 to change, 0 to destroy.'

run_test_describe \
    "Destroy fixture describe says DESTRUCTIVE" \
    "DESTRUCTIVE" \
    'Plan: 0 to add, 0 to change, 3 to destroy.'

run_test_count \
    "Destroy fixture get_destroy_count returns 3" \
    "3" \
    'Plan: 0 to add, 0 to change, 3 to destroy.'

run_test_count \
    "Safe fixture get_destroy_count returns 0" \
    "0" \
    'Plan: 5 to add, 2 to change, 0 to destroy.'

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 5: 🔲 BOUNDARY TESTS — Edge cases
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${BLUE}══ Category 5: Boundary (edge cases) ══════════════════════════${NC}"

# Case 5a: No changes
run_test \
    "No changes plan is safe" \
    "safe" \
    'No changes. Infrastructure is up-to-date.'

# Case 5b: Empty input
run_test \
    "Empty input is safe" \
    "safe" \
    ''

# Case 5c: Plan with whitespace variations
run_test \
    "Plan with 0 destroy (trailing spaces) is safe" \
    "safe" \
    'Plan: 5 to add, 2 to change, 0 to destroy.  '

# Case 5d: Mixed add/change/destroy with 0
run_test \
    "Complex plan with 0 destroy is safe" \
    "safe" \
    'Plan: 20 to add, 15 to change, 0 to destroy.
  # aws_resource.example will be created
  + resource "aws_resource" "example" { }'

# Case 5e: Only replacement marker, no Plan: line
run_test \
    "Replacement marker without Plan: line is destructive" \
    "destructive" \
    '-/+ resource "aws_lambda_function" "handler" {
      runtime: "python3.8" => "python3.11"
    }'

# Case 5f: Capitalization variations
run_test \
    "PLAN: (uppercase) with 0 destroy is safe" \
    "safe" \
    'PLAN: 5 to add, 2 to change, 0 to destroy.'

run_test \
    "PLAN: (uppercase) with 1 destroy is destructive" \
    "destructive" \
    'PLAN: 0 to add, 0 to change, 1 to destroy.'

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 6: 🔍 FALSE POSITIVE REGRESSION TESTS
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${BLUE}══ Category 6: False Positive Regression ══════════════════════${NC}"

# This was the bug: "Plan: ... 0 to destroy." matched "Plan:.*destroy"
run_test \
    "0 to destroy does NOT match false positive (THE BUG FIX)" \
    "safe" \
    'Plan: 5 to add, 2 to change, 0 to destroy.'

run_test \
    "0 to destroy mixed with replacement text is safe" \
    "safe" \
    'Plan: 0 to add, 0 to change, 0 to destroy.
Note: Some resources shown may be skipped due to "destroy" in provider config.'

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Test Summary${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Total:  $TESTS_TOTAL"
echo -e "  ${GREEN}Passed:${NC} $TESTS_PASSED"
echo -e "  ${RED}Failed:${NC} $TESTS_FAILED"
echo ""

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    echo -e "${RED}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}  TESTS FAILED — See failures above${NC}"
    echo -e "${RED}═══════════════════════════════════════════════════════════════════${NC}"
    exit 1
else
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ALL TESTS PASSED${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
    exit 0
fi
