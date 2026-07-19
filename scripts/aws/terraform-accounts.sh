#!/bin/bash
# =============================================================================
# LiteLLM AWS Terraform Account Allowlist
# =============================================================================
# Defines the approved AWS account IDs per environment.
# This script provides validation functions for terraform wrapper scripts.
#
# Usage:
#   source this script from terraform-plan.sh / terraform-apply.sh
#   then call: validate_account <env_name> <aws_profile>
#
# Account mapping:
#   office-mfa = 132815414471
#   dev        = 887678037646  (AWS managed dev account)
#
# NOTE: dev account (887678037646) is managed separately from this repo's
# Terraform state. The default/dev workspace targets this account.
#
# DO NOT add production accounts without explicit approval.
# DO NOT hardcode credentials or secrets in this file.
# =============================================================================

# Account allowlist — environment name to AWS account ID mapping
declare -A ACCOUNT_ALLOWLIST=(
    ["office-mfa"]="132815414471"
    ["dev"]="887678037646"
)

# Get the expected account ID for a given environment
# Usage: get_expected_account <env_name>
# Returns: account ID or empty string if unknown env
get_expected_account() {
    local env_name="$1"
    if [[ -v "ACCOUNT_ALLOWLIST[$env_name]" ]]; then
        echo "${ACCOUNT_ALLOWLIST[$env_name]}"
    else
        echo ""
    fi
}

# Get the actual AWS account ID for a given profile
# Usage: get_actual_account <aws_profile>
# Returns: account ID or "UNAVAILABLE" if sts call fails
# Note: On failure, emits a human-readable error type (e.g. ExpiredToken) to stderr
#       without exposing credentials, tokens, or secrets.
get_actual_account() {
    local aws_profile="$1"
    local sts_output

    # Capture both stdout and stderr from sts call.
    # On success: stdout is just the account ID.
    # On failure: stdout is error text starting with "An error occurred".
    sts_output=$(AWS_PROFILE="$aws_profile" aws sts get-caller-identity \
        --query 'Account' --output text 2>&1) || true

    # Success: output is a 12-digit AWS account ID (plain text, no "An error")
    if [[ "$sts_output" =~ ^[0-9]{12}$ ]]; then
        echo "$sts_output"
        return
    fi

    # Failure: extract the error TYPE from parentheses, e.g. "(ExpiredToken)"
    # Never expose the rest of the error body (which may contain token values).
    local error_type
    error_type=$(echo "$sts_output" \
        | grep -oE '\([A-Za-z0-9_]+\)' \
        | head -1 \
        | tr -d '()' \
        || echo "unknown")
    echo "UNAVAILABLE (${error_type})" >&2
    echo "UNAVAILABLE"
}

# Validate AWS account matches expected account for environment
# Usage: validate_account <env_name> <aws_profile>
# Returns: 0 if valid, 1 if invalid
validate_account() {
    local env_name="$1"
    local aws_profile="$2"
    local expected_account actual_account

    expected_account=$(get_expected_account "$env_name")
    if [[ -z "$expected_account" ]]; then
        echo "ERROR: Unknown environment '$env_name'. Allowed environments: ${!ACCOUNT_ALLOWLIST[*]}" >&2
        return 1
    fi

    actual_account=$(get_actual_account "$aws_profile")
    if [[ "$actual_account" == "UNAVAILABLE" ]]; then
        echo "ERROR: Cannot verify AWS identity for profile '$aws_profile'." >&2
        echo "       Ensure AWS credentials are configured and MFA session is valid." >&2
        echo "       (aws sts get-caller-identity failed — see error above for class/type)" >&2
        return 1
    fi

    if [[ "$expected_account" != "$actual_account" ]]; then
        echo "ERROR: AWS account mismatch for environment '$env_name'" >&2
        echo "       Expected: $expected_account" >&2
        echo "       Actual:   $actual_account" >&2
        echo "       Profile:  $aws_profile" >&2
        echo "" >&2
        echo "This indicates wrong AWS profile or credentials. Aborting to prevent cross-account operations." >&2
        return 1
    fi

    echo "OK: AWS account $actual_account matches expected account for '$env_name'"
    return 0
}

# Check if workspace exists without creating it
# Usage: workspace_exists <terraform_dir> <workspace_name>
# Returns: 0 if exists, 1 if does not exist
# Note: terraform workspace list output includes '*' prefix for current workspace
workspace_exists() {
    local tf_dir="$1"
    local workspace="$2"
    terraform -chdir="$tf_dir" workspace list 2>/dev/null | grep -qE "^[[:space:]]*\*?[[:space:]]*$workspace$"
}

# Validate workspace exists (fail if not found)
# Usage: validate_workspace <terraform_dir> <workspace_name> <env_name>
# Returns: 0 if valid, 1 if invalid
validate_workspace() {
    local tf_dir="$1"
    local workspace="$2"
    local env_name="$3"

    if ! workspace_exists "$tf_dir" "$workspace"; then
        echo "ERROR: Workspace '$workspace' does not exist for environment '$env_name'." >&2
        echo "" >&2
        echo "Available workspaces:" >&2
        terraform -chdir="$tf_dir" workspace list 2>/dev/null | sed 's/^/  /' >&2
        echo "" >&2
        echo "To create this workspace, a Human/Releaser must explicitly approve:" >&2
        echo "  terraform -chdir=\"$tf_dir\" workspace new $workspace" >&2
        echo "" >&2
        echo "Automatic 'terraform workspace new' is DISABLED to prevent typo workspace creation." >&2
        return 1
    fi

    echo "OK: Workspace '$workspace' exists for environment '$env_name'"
    return 0
}

# Display context information
# Usage: display_context <env_name> <aws_profile> <terraform_dir> <workspace> <tfvars_path>
display_context() {
    local env_name="$1"
    local aws_profile="$2"
    local tf_dir="$3"
    local workspace="$4"
    local tfvars_path="$5"

    echo ""
    echo "=== Terraform Context ==="
    echo "  Environment:     $env_name"
    echo "  AWS Profile:     $aws_profile"
    echo "  AWS Account:     $(get_actual_account "$aws_profile")"
    echo "  Workspace:       $workspace"
    echo "  TF_DIR:          $tf_dir"
    echo "  TFVARS:          $tfvars_path"
    echo "========================="
    echo ""
}

# =============================================================================
# Terraform Plan Destructive Guard Helpers
# =============================================================================

# Check if a plan contains destructive operations.
# Parses plan summary text (typically first 30 lines of `terraform show` output).
#
# Destructive = true when ANY of:
#   1. "Plan:" line shows N to destroy where N > 0
#   2. Resource marked "must be replaced"
#   3. Resource change line contains "-/+" replacement marker
#
# Usage:
#   is_destructive_plan <plan_text>
#
# Returns:
#   0 (success)  = plan IS destructive
#   1 (failure)   = plan is safe (no destroy/replace)
#
# Examples:
#   is_destructive_plan "$(terraform show -no-color tfplan)"   # safe wrapper usage
#   echo "$text" | is_destructive_plan                          # pipe usage
is_destructive_plan() {
    local plan_text
    # Accept input from argument OR stdin (pipe support)
    if [[ -n "${1:-}" ]]; then
        plan_text="$1"
    else
        plan_text=$(cat)
    fi

    # ----------------------------------------------------------------
    # Check 1: Numeric destroy count from "Plan:" summary line
    # Only destructive if the count is GREATER THAN 0.
    # Matches: "Plan: 5 to add, 2 to change, 0 to destroy."
    # Does NOT match: "Plan: 5 to add, 2 to change, 0 to destroy." as destructive
    # ----------------------------------------------------------------
    local destroy_count
    destroy_count=$(echo "$plan_text" \
        | grep -iE "^Plan:" \
        | grep -oE "[0-9]+ to destroy" \
        | grep -oE "^[0-9]+" \
        || echo "0")

    if [[ "$destroy_count" -gt 0 ]]; then
        return 0
    fi

    # ----------------------------------------------------------------
    # Check 2: Replacement markers in resource lines
    # Matches: "~ resource "aws_instance" "example"  (in-place update)
    #          -/+ resource "aws_instance" "example" (force replacement)
    # "must be replaced" is explicit replacement intent
    # ----------------------------------------------------------------
    if echo "$plan_text" | grep -qiE "(must be replaced|-/\+)"; then
        return 0
    fi

    # Safe: no destroy/replace detected
    return 1
}

# Get the numeric destroy count from a plan.
# Usage: get_destroy_count <plan_text>
# Returns: integer (0 if no destroy, >0 if destructive)
get_destroy_count() {
    local plan_text="${1:-}"
    if [[ -z "$plan_text" ]]; then
        plan_text=$(cat)
    fi
    echo "$plan_text" \
        | grep -iE "^Plan:" \
        | grep -oE "[0-9]+ to destroy" \
        | grep -oE "^[0-9]+" \
        || echo "0"
}

# Describe the destructive status of a plan (human-readable).
# Usage: describe_plan_destructiveness <plan_text>
# Echoes: "SAFE" or "DESTRUCTIVE (N to destroy)" or "DESTRUCTIVE (replacement)"
describe_plan_destructiveness() {
    local plan_text="${1:-}"
    if [[ -z "$plan_text" ]]; then
        plan_text=$(cat)
    fi

    local destroy_count
    destroy_count=$(get_destroy_count "$plan_text")

    if [[ "$destroy_count" -gt 0 ]]; then
        echo "DESTRUCTIVE ($destroy_count to destroy)"
    elif echo "$plan_text" | grep -qiE "(must be replaced|-/\+)"; then
        echo "DESTRUCTIVE (replacement)"
    else
        echo "SAFE"
    fi
}
