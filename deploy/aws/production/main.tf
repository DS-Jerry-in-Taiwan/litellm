# =============================================================================
# Production AWS Deployment — LiteLLM 官方 Terraform Module
# =============================================================================
# 使用 LiteLLM 官方 Terraform module（三組件架構）
# 詳見：https://github.com/BerriAI/litellm/tree/main/terraform/litellm/aws
# =============================================================================

terraform {
  required_version = ">= 1.9"
}

module "litellm" {
  source = "github.com/BerriAI/litellm//terraform/litellm/aws?ref=main"

  region = var.region
  azs    = var.azs
  tenant = var.tenant
  env    = var.env

  # ── 必填 ────────────────────────────────────────────────────────────────
  litellm_master_key = var.litellm_master_key

  # ── ALB ──────────────────────────────────────────────────────────────────
  # 試用階段 allow plain HTTP；上 production 請補 acm_certificate_arn
  allow_plaintext_alb = var.allow_plaintext_alb
  skip_final_snapshot = var.skip_final_snapshot
  s3_force_destroy    = var.s3_force_destroy

  # ── LiteLLM 設定（對應 config.yaml 內容）────────────────────────────────
  proxy_config = var.proxy_config

  # ── 可選：UI 管理員密碼 ─────────────────────────────────────────────────
  # ui_password = var.ui_password

  # ── 標籤 ─────────────────────────────────────────────────────────────────
  tags = var.tags
}
