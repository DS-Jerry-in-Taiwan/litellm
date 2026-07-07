# deploy/aws/company-existing/

Company Existing AWS Infrastructure — LiteLLM ECS Fargate 部署腳本。

## 設計目標

此目錄的目的是在公司既有 AWS 環境中部署 LiteLLM，**不自建**公司已擁有的資源：

- ✅ **不自建 VPC** — 使用既有 `datascienceResourceVPC`
- ✅ **不自建 Aurora** — 使用既有 `aurora-postgre01`
- ✅ **不重建 Subnets / Security Groups** — 使用既有網路層
- ✅ **只建立 LiteLLM runtime 資源** — ECS、ALB、IAM、Secrets Manager、CloudWatch

## 與官方 module 的差異

| 面向 | 官方 module (`deploy/aws/production/`) | 公司既有版 (`company-existing/`) |
|---|---|---|
| VPC | 自建 | 既有（data source） |
| Aurora | 自建 | 既有（data source） |
| ECS | 三服務（gateway/backend/ui） | 單服務（先期） |
| Secrets | Module managed | 自管（Secrets Manager） |

官方 module 設計僅供參考，不直接套用。

## 開發階段

| Phase | 目標 | 狀態 |
|---|---|---|
| 0 | Scaffold + data sources | ✅ 完成（骨架） |
| 1 | Secrets Manager + IAM + P0 safety | 🔜 待開發 |
| 2 | ECS + ALB + CloudWatch （MVP） | 🔜 待開發 |
| 3 | S3 config + migration task | 🔜 待開發 |
| 4 | CI/CD 整合 | 🔜 待開發 |
| 5 | Production hardening | 🔜 待開發 |

## P0 安全基線

此腳本從 Phase 0 開始即遵循以下安全原則：

- Secrets 僅透過 AWS Secrets Manager 注入 ECS
- IAM least privilege
- ALB/ECS health check 使用 `/health/liveliness`
- TLS / HTTP-only 明確 opt-in
- Destroy safety flags（default off）
- Immutable image tag（禁止 `latest`）

## 前置需求

1. AWS CLI 已設定且可存取公司帳號
2. 已取得既有 VPC、Subnet、Aurora 的 ID
3. ECS task 可連到既有 Aurora（需 SG 規則允許 5432）
