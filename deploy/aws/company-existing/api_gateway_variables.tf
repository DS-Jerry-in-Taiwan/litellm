# =============================================================================
# API Gateway Variables — Public HTTPS Ingress for LiteLLM
# =============================================================================
# Phase 1 MVP: API Gateway HTTP API + VPC Link + Route Allowlist
# WAF is NOT implemented in this phase (deferred to optional hardening)
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# API Gateway Enable/Disable
# ─────────────────────────────────────────────────────────────────────────────

variable "enable_public_api_gateway" {
  description = "Enable public API Gateway HTTPS ingress via VPC Link to internal ALB. Set false to disable without destroying resources."
  type        = bool
  default     = true
}

# ─────────────────────────────────────────────────────────────────────────────
# API Gateway Stage
# ─────────────────────────────────────────────────────────────────────────────

variable "api_gateway_stage_name" {
  description = "API Gateway stage name (e.g. 'prod' or '$default'). Note: '$default' enables auto-deploy."
  type        = string
  default     = "$default"

  validation {
    condition     = contains(["$default", "prod", "staging", "dev"], var.api_gateway_stage_name)
    error_message = "api_gateway_stage_name must be one of: $default, prod, staging, dev."
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# API Gateway Throttling (Stage-level)
# ─────────────────────────────────────────────────────────────────────────────

variable "api_gateway_throttle_rate_limit" {
  description = "API Gateway stage throttling rate limit (requests per second). -1 = no limit."
  type        = number
  default     = 1000

  validation {
    condition     = var.api_gateway_throttle_rate_limit >= -1
    error_message = "api_gateway_throttle_rate_limit must be -1 (no limit) or >= 0."
  }
}

variable "api_gateway_throttle_burst_limit" {
  description = "API Gateway stage throttling burst limit (concurrent requests). -1 = no limit."
  type        = number
  default     = 100

  validation {
    condition     = var.api_gateway_throttle_burst_limit >= -1
    error_message = "api_gateway_throttle_burst_limit must be -1 (no limit) or >= 0."
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# API Gateway Route Throttling (Route-level, DEFERRED / INERT in MVP)
# ─────────────────────────────────────────────────────────────────────────────
# NOTE: Route-level throttling is NOT currently wired to any Terraform resource.
# The AWS provider does not support aws_apigatewayv2_route_settings for HTTP APIs.
# Stage-level throttling (api_gateway_throttle_rate_limit/burst_limit) applies
# to all routes. Route-level overrides require manual AWS Console/API configuration.
# These variables are defined for future provider support and are currently inert.
# ─────────────────────────────────────────────────────────────────────────────

variable "api_gateway_route_throttle_rate_limit" {
  description = "Per-route throttling rate limit (requests per second). DEFERRED: Currently inert — AWS provider does not support route_settings for HTTP APIs; stage-level throttling applies instead."
  type        = number
  default     = -1

  validation {
    condition     = var.api_gateway_route_throttle_rate_limit >= -1
    error_message = "api_gateway_route_throttle_rate_limit must be -1 (inherit) or >= 0."
  }
}

variable "api_gateway_route_throttle_burst_limit" {
  description = "Per-route throttling burst limit. DEFERRED: Currently inert — AWS provider does not support route_settings for HTTP APIs; stage-level throttling applies instead."
  type        = number
  default     = -1

  validation {
    condition     = var.api_gateway_route_throttle_burst_limit >= -1
    error_message = "api_gateway_route_throttle_burst_limit must be -1 (inherit) or >= 0."
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# API Gateway Timeout
# ─────────────────────────────────────────────────────────────────────────────

variable "api_gateway_timeout_ms" {
  description = "API Gateway integration timeout in milliseconds. LiteLLM OpenAI-compatible API should respond within this window."
  type        = number
  default     = 30000 # 30 seconds; adjust for expected LLM response time

  validation {
    condition     = var.api_gateway_timeout_ms >= 1000 && var.api_gateway_timeout_ms <= 300000
    error_message = "api_gateway_timeout_ms must be between 1000 (1s) and 300000 (300s)."
  }
}
