# =============================================================================
# API Gateway — Public HTTPS Ingress for LiteLLM (MVP)
# =============================================================================
# Phase 1 MVP Architecture:
#
#   Non-VPC Lambda / External Service
#     -> API Gateway HTTP API (public HTTPS)
#     -> VPC Link (apigatewayv2)
#     -> Existing Internal ALB :80 (aws_lb_listener.http)
#     -> ECS LiteLLM :4000
#
# Route Allowlist: POST /v1/chat/completions ONLY
# Admin APIs (/ui, /key/*, /model/*, /credentials/*, /metrics) NOT exposed
#
# WAF: NOT IMPLEMENTED in this phase
#   WAF is deferred to optional hardening (Phase 5).
#   Do NOT add aws_wafv2_* resources in this file.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# API Gateway HTTP API
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_apigatewayv2_api" "litellm" {
  count         = var.enable_public_api_gateway ? 1 : 0
  name          = "${local.name_prefix}-public-api"
  protocol_type = "HTTP"

  # CORS: MVP-only setting for Lambda/service callers.
  # allow_origins=["*"] and allow_headers=["*"] is intentionally broad for
  # non-browser clients (Lambda, backend services). RESTRICT or disable CORS
  # during Phase 5 hardening if browser-based clients are introduced.
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["*"]
    max_age       = 86400
  }

  tags = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# API Gateway VPC Link
# ─────────────────────────────────────────────────────────────────────────────
# VPC Link enables API Gateway to connect to internal ALB without exposing
# ECS/ALB to the public internet.
#
# Security group: The VPC Link ENIs use the ECS security group (or existing
# ECS SG). The ALB allows inbound from VPC CIDR, so traffic from VPC Link
# ENIs will be accepted.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_apigatewayv2_vpc_link" "litellm" {
  count = var.enable_public_api_gateway ? 1 : 0
  name  = "${local.name_prefix}-vpc-link"
  security_group_ids = [
    var.existing_ecs_security_group_id != "" ? var.existing_ecs_security_group_id : aws_security_group.ecs[0].id
  ]
  subnet_ids = var.existing_private_app_subnet_ids

  tags = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# API Gateway Integration (HTTP Proxy via VPC Link)
# ─────────────────────────────────────────────────────────────────────────────
# Integration forwards requests to the existing internal ALB HTTP listener.
# The integration uses the VPC Link to reach the ALB inside the VPC.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_apigatewayv2_integration" "litellm" {
  count                = var.enable_public_api_gateway ? 1 : 0
  api_id               = aws_apigatewayv2_api.litellm[0].id
  integration_type     = "HTTP_PROXY"
  integration_uri      = aws_lb_listener.http.arn
  connection_type      = "VPC_LINK"
  connection_id        = aws_apigatewayv2_vpc_link.litellm[0].id
  timeout_milliseconds = var.api_gateway_timeout_ms

  # REQUIRED for HTTP_PROXY integration_type. AWS will reject apply with:
  #   BadRequestException: HttpMethod parameter method must be specified
  #   for integrationType HTTPPROXY
  # "ANY" forwards all HTTP methods to the backend via VPC Link.
  integration_method = "ANY"

  # Passthrough means the request body is sent as-is to the backend.
  passthrough_behavior = "WHEN_NO_MATCH"
}

# ─────────────────────────────────────────────────────────────────────────────
# API Gateway Stage
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_apigatewayv2_stage" "litellm" {
  count       = var.enable_public_api_gateway ? 1 : 0
  api_id      = aws_apigatewayv2_api.litellm[0].id
  name        = var.api_gateway_stage_name
  auto_deploy = true

  # Stage-level throttling. Use -1 for no limit.
  default_route_settings {
    throttling_rate_limit    = var.api_gateway_throttle_rate_limit
    throttling_burst_limit   = var.api_gateway_throttle_burst_limit
    detailed_metrics_enabled = true
  }

  tags = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# API Gateway Route: POST /v1/chat/completions
# ─────────────────────────────────────────────────────────────────────────────
# Route allowlist: ONLY POST /v1/chat/completions is exposed publicly.
# Admin endpoints (/ui, /key/*, /model/*, /credentials/*, /metrics) are NOT
# added as routes and will return 404 if called.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_apigatewayv2_route" "chat_completions" {
  count     = var.enable_public_api_gateway ? 1 : 0
  api_id    = aws_apigatewayv2_api.litellm[0].id
  route_key = "POST /v1/chat/completions"
  target    = "integrations/${aws_apigatewayv2_integration.litellm[0].id}"
}

# ─────────────────────────────────────────────────────────────────────────────
# NOTE: WAF NOT IMPLEMENTED
# ─────────────────────────────────────────────────────────────────────────────
# This phase deliberately excludes AWS WAF (aws_wafv2_web_acl, etc.).
#
# Rationale:
#   1. MVP protection is route allowlist + API Gateway throttling + LiteLLM key.
#   2. The caller (non-VPC Lambda) has floating egress IP, making WAF IP allowlist
#      ineffective as a primary control.
#   3. WAF adds per-request cost and management overhead.
#
# To add WAF in a future phase (optional hardening):
#   1. Create api_gateway_waf.tf with aws_wafv2_web_acl (scope = REGIONAL).
#   2. Add AWS managed rules: AWSManagedRulesCommonRuleSet,
#      AWSManagedRulesKnownBadInputsRuleSet, AWSManagedRulesAmazonIpReputationList.
#   3. Add rate-based rule for brute-force protection.
#   4. Associate Web ACL with aws_apigatewayv2_stage.litellm[0].arn.
#
# Until WAF is explicitly added, this API Gateway has NO WAF protection.
# ─────────────────────────────────────────────────────────────────────────────
