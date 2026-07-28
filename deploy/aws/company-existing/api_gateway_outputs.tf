# =============================================================================
# API Gateway Outputs — Public HTTPS Ingress for LiteLLM
# =============================================================================
# Phase 1 MVP outputs for the public API Gateway HTTP API.
# WAF is NOT implemented; no WAF-related outputs.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# API Gateway Endpoint URL
# ─────────────────────────────────────────────────────────────────────────────

output "api_gateway_endpoint_url" {
  description = "Public HTTPS endpoint URL for LiteLLM API Gateway. Use this URL in Lambda/service clients. Note: $default stage does not include stage in path."
  value       = var.enable_public_api_gateway ? "${aws_apigatewayv2_api.litellm[0].api_endpoint}${var.api_gateway_stage_name != "$default" ? "/${var.api_gateway_stage_name}" : ""}" : null
}

output "api_gateway_endpoint_base" {
  description = "API Gateway base endpoint (without stage path). Use for constructing full URLs."
  value       = var.enable_public_api_gateway ? aws_apigatewayv2_api.litellm[0].api_endpoint : null
}

# ─────────────────────────────────────────────────────────────────────────────
# API Gateway API ID
# ─────────────────────────────────────────────────────────────────────────────

output "api_gateway_api_id" {
  description = "API Gateway API ID (e.g., 'abc123xyz'). Needed for custom domain or CLI management."
  value       = var.enable_public_api_gateway ? aws_apigatewayv2_api.litellm[0].id : null
}

output "api_gateway_stage_name" {
  description = "API Gateway stage name in use."
  value       = var.enable_public_api_gateway ? aws_apigatewayv2_stage.litellm[0].name : null
}

output "api_gateway_stage_arn" {
  description = "API Gateway stage ARN. Use this for WAF association (when WAF is added in a future phase)."
  value       = var.enable_public_api_gateway ? aws_apigatewayv2_stage.litellm[0].arn : null
}

# ─────────────────────────────────────────────────────────────────────────────
# VPC Link Info
# ─────────────────────────────────────────────────────────────────────────────

output "api_gateway_vpc_link_id" {
  description = "VPC Link ID used by API Gateway to reach the internal ALB."
  value       = var.enable_public_api_gateway ? aws_apigatewayv2_vpc_link.litellm[0].id : null
}

output "api_gateway_integration_id" {
  description = "API Gateway integration ID for the LiteLLM backend."
  value       = var.enable_public_api_gateway ? aws_apigatewayv2_integration.litellm[0].id : null
}

# ─────────────────────────────────────────────────────────────────────────────
# Route Information
# ─────────────────────────────────────────────────────────────────────────────

output "api_gateway_public_routes" {
  description = "List of public routes exposed via API Gateway. Admin endpoints NOT included."
  value = var.enable_public_api_gateway ? {
    allowed      = ["POST /v1/chat/completions"]
    allowed_cors = "OPTIONS handled automatically by API Gateway CORS configuration"
    blocked      = ["POST /key/generate", "GET /ui", "GET /metrics", "GET /key/*", "GET /model/*", "GET /credentials/*"]
  } : null
}

output "api_gateway_chat_completions_url" {
  description = "Full URL for POST /v1/chat/completions endpoint. Note: $default stage does not include stage in path."
  value       = var.enable_public_api_gateway ? "${aws_apigatewayv2_api.litellm[0].api_endpoint}${var.api_gateway_stage_name != "$default" ? "/${var.api_gateway_stage_name}" : ""}/v1/chat/completions" : null
}

# ─────────────────────────────────────────────────────────────────────────────
# Throttling Configuration
# ─────────────────────────────────────────────────────────────────────────────

output "api_gateway_throttle_config" {
  description = "Current throttling configuration applied to the API Gateway."
  value = var.enable_public_api_gateway ? {
    stage_rate_limit  = var.api_gateway_throttle_rate_limit
    stage_burst_limit = var.api_gateway_throttle_burst_limit
    route_rate_limit  = var.api_gateway_route_throttle_rate_limit
    route_burst_limit = var.api_gateway_route_throttle_burst_limit
    timeout_ms        = var.api_gateway_timeout_ms
  } : null
}

# ─────────────────────────────────────────────────────────────────────────────
# WAF Status
# ─────────────────────────────────────────────────────────────────────────────

output "waf_enabled" {
  description = "WAF protection status. Currently false (WAF is deferred to optional hardening phase)."
  value       = false
}

# ─────────────────────────────────────────────────────────────────────────────
# Architecture Summary
# ─────────────────────────────────────────────────────────────────────────────

output "architecture_summary" {
  description = "Summary of public API Gateway architecture."
  value = var.enable_public_api_gateway ? {
    public_ingress = "API Gateway HTTP API (public HTTPS)"
    vpc_link       = "VPC Link to internal ALB (${aws_lb.main.dns_name})"
    backend        = "ECS LiteLLM via internal ALB :80 -> container :${var.container_port}"
    allowed_routes = ["POST /v1/chat/completions", "OPTIONS (automatic CORS preflight)"]
    blocked_routes = ["GET /ui", "GET /metrics", "POST /key/generate", "GET /key/*", "GET /model/*", "GET /credentials/*"]
    waf_status     = "NOT IMPLEMENTED (deferred to optional hardening)"
    internal_alb   = "Unchanged: internal=true, not exposed publicly"
    ecs_exposure   = "Unchanged: port ${var.container_port} not exposed to 0.0.0.0/0"
    } : {
    public_ingress = "DISABLED (enable_public_api_gateway=false)"
    vpc_link       = "Not created"
    backend        = "No change to existing architecture"
    allowed_routes = []
    blocked_routes = []
    waf_status     = "NOT IMPLEMENTED"
    internal_alb   = "Unchanged"
    ecs_exposure   = "Unchanged"
  }
}
