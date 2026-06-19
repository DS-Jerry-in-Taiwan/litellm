# LiteLLM 部署範本

## 概述

本目錄包含 LiteLLM Proxy 的部署範本，供本地 PoC、內網測試及 Production Kubernetes/Helm 部署使用。

**⚠️ 重要提醒**：這些檔案是**範本，不是 production-ready one-click deploy**。部署前請詳閱本文件所有安全注意事項。

---

## 目錄結構

```
deploy/litellm/
├── compose.yaml              # Docker Compose（LiteLLM + PostgreSQL + Redis + 可選 Prometheus）
├── .env.example              # 環境變數範本（複製為 .env）
├── config.yaml.example        # LiteLLM 設定檔範本
├── config.yaml                # LiteLLM 實際設定（從 example 複製，不進 Git）
├── prometheus.yml             # Prometheus 監控設定
├── smoke_test.sh              # 健康檢查腳本
├── helm/
│   └── values.yaml.example    # Kubernetes Helm values 範本
└── README.md                  # 本文件
```

---

## 快速開始 — 本機 PoC

### 前置條件

- Docker 與 Docker Compose（v2+）
- 至少一個 LLM provider API key（OpenAI / Azure OpenAI / Anthropic 等）

### 步驟 1：複製環境變數範本

```bash
cd deploy/litellm
cp .env.example .env
```

### 步驟 2：編輯 `.env`，替換 placeholder

```bash
# 必填：設定管理員金鑰（建議 ≥32 字元隨機字串）
#  openssl rand -hex 32
LITELLM_MASTER_KEY=sk-your-32-char-random-key

# 必填：DB 加密鹽（建議 ≥32 字元隨機字串）
LITELLM_SALT_KEY=your-32-char-random-salt

# 必填：PostgreSQL 密碼
POSTGRES_PASSWORD=your-postgres-password

# 必填：LLM Provider API Key
OPENAI_API_KEY=sk-your-openai-key

# Redis（可選密碼，若啟用請取消註解並填入）
# REDIS_PASSWORD=your-redis-password
```

### 步驟 3：複製設定檔

```bash
cp config.yaml.example config.yaml
```

### 步驟 4：啟動服務

```bash
docker compose up -d
```

### 步驟 5：驗證部署

```bash
# 健康檢查（基本）
./smoke_test.sh

# 含 Chat Completions 測試（需要真實 provider key）
RUN_CHAT_TEST=true ./smoke_test.sh

# 含 Virtual Key 建立測試（需要 master key）
RUN_KEY_TEST=true ./smoke_test.sh
```

---

## 使用方式

### OpenAI SDK 呼叫

```python
from openai import OpenAI

client = OpenAI(
    api_key="<virtual-key-or-master-key-for-admin-test>",  # 建議使用 virtual key
    base_url="http://localhost:4000/v1",                     # LiteLLM OpenAI-compatible endpoint
)

# ⚠️ 注意：active config.yaml 目前 model_list: []，請替換為已透過 Admin UI/API 建立的模型名稱
# gpt-4o-mini 只是示例，不代表 active config 已存在
response = client.chat.completions.create(
    model="gpt-4o-mini",  # 使用 config.yaml 中的 model_name
    messages=[{"role": "user", "content": "Hello"}],
)

print(response.choices[0].message.content)
```

### curl 呼叫

```bash
# ⚠️ 注意：active config.yaml 目前 model_list: []，請替換為已透過 Admin UI/API 建立的模型名稱
# gpt-4o-mini 只是示例，不代表 active config 已存在
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer <your-api-key>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o-mini",
    "messages": [{"role": "user", "content": "Say hi"}]
  }'
```

---

## 服務端點

| 端點 | 方法 | 用途 | 認證 |
|------|------|------|------|
| `/health` | GET | 健康檢查 | 無 |
| `/metrics` | GET | Prometheus metrics | 無 |
| `/v1/chat/completions` | POST | OpenAI-compatible API | Virtual key |
| `/key/generate` | POST | 建立 virtual key | Master key |
| `/keys` | GET | 列出所有 keys | Master key |
| `/spend/logs` | GET | 用量紀錄 | Master key |

---

## Docker Compose 服務一覽

| 服務 | Container Name | Image | Host Port | 用途 |
|------|---------------|-------|-----------|------|
| LiteLLM Proxy | `litellm-proxy` | `docker.litellm.ai/berriai/litellm:main-stable` | `4000` | OpenAI-compatible API proxy |
| PostgreSQL | `litellm-postgres` | `postgres:15-alpine` | `5433` | 資料庫（virtual keys、spend logs） |
| Redis | `litellm-redis` | `redis:alpine` | `6379` | Health check cache（多 pod 共用 health 結果） |
| Prometheus | `litellm-prometheus` | `prom/prometheus:latest` | `9091` | Metrics 收集（container internal `9090`） |

> **注意**：Redis container 無持久化 volume，重啟後 cache 資料遺失不影響核心功能。PostgreSQL 資料持久化於命名 volume `postgres_data`。

### Health Checks

| 服務 | Health Check 指令 | 間隔 | 起始等待 |
|------|-------------------|------|----------|
| LiteLLM Proxy | `curl -f http://localhost:4000/health` | 30s | 60s |
| PostgreSQL | `pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}` | 10s | 30s |
| Redis | `redis-cli ping`（預期回傳 `PONG`） | 10s | 10s |
| Prometheus | 無內建 healthcheck（依賴 container 狀態） | — | — |

`litellm` service 的 `depends_on` 使用 `condition: service_healthy` 確保 Postgres 與 Redis 皆就緒後才啟動。

---

## Production 安全注意事項

> ⚠️ **這些範本預設不含 production 等級的安全設定，部署正式環境前請逐一確認以下項目**：

### 1. TLS / HTTPS

- **禁止**將 `:4000` HTTP port裸露至網際網路。
- 所有對外流量必須經過 TLS reverse proxy（Nginx、Traefik、Cloudflare 等）或 Kubernetes Ingress TLS 終止。
- 建議使用 cert-manager + Let's Encrypt 自動化 TLS 憑證管理。

### 2. Master Key 管理

- `LITELLM_MASTER_KEY` 必須是強隨機字串（建議 ≥32 字元）。
- **嚴禁**將 master key 提供給客戶端或一般應用。
- 建議定期輪換 master key，並使用 secret manager（AWS Secrets Manager、HashiCorp Vault、K8s Secret）管理。

### 3. Virtual Keys

- 所有外部客戶端**必須**使用 virtual key，**禁止**直接使用 master key。
- Virtual key 可绑定模型白名單、 RPM 限制、budget 上限。
- 建立方式：`POST /key/generate`（需 master key）。

### 4. Secrets 不進 Git

- `.env` 檔案**絕對不可** commit 至 Git repository。
- 建議使用 `.gitignore` 排除 `.env`。
- 生產環境使用 K8s Secret 或 Vault 管理 secrets。

### 5. Admin UI / Dashboard 認證

- LiteLLM UI / Admin dashboard 的路由可能因 image 版本而異（常見路由包括 `/`、`/ui`、`/admin`），具體應查閱該版本官方文件或實際存取 root 路徑確認。
- Admin UI 預設無額外認證，**嚴禁**直接暴露至網際網路。
- 建議設定 `UI_USERNAME`/`UI_PASSWORD` 環境變數，或啟用 LDAP/SSO（企業版）。
- Ingress / NetworkPolicy 層級限制 Admin UI 存取來源（僅限內網或特定 VPN 網段）。

### 6. PostgreSQL 備份

- 確認 managed Postgres 或手動備份策略。
- LiteLLM 資料庫包含 virtual keys、spend logs、team 設定，屬於關鍵資料。
- 建議設定 Point-in-Time Recovery（PITR）。

### 7. Redis（多 pod 必備）

- 多副本部署**必須**啟用 Redis shared health check，避免每個 pod 重複打 provider health check，導致 RPM/Rate limit 消耗倍增。
- 本 PoC 配置已包含 Redis service（`redis:alpine`），compose.yaml 中 `litellm.depends_on` 設有 `condition: service_healthy`。
- LiteLLM config.yaml 中的 `redis_host`/`redis_port`/`redis_password` 已取消註解，對應 compose.yaml 的 `REDIS_HOST`/`REDIS_PORT`/`REDIS_PASSWORD` 環境變數。
- Redis 密碼建議啟用，並透過 K8s Secret 管理（PoC 階段可選，`.env` 中已保留 `# REDIS_PASSWORD` 欄位）。
- ❗ **主機 port 6379** 在啟動前需確認未被其他 process 佔用（`ss -tlnp | grep 6379`）。

### 8. 網路存取控制

- 使用 Kubernetes NetworkPolicy 限制 LiteLLM proxy 只允許來自必要 namespace 的流量。
- 建議劃分管理網段與應用網段。

### 9. 資源限制

- 設定合理的 CPU/Memory requests 與 limits。
- 生產環境建議 `resources.limits.memory ≥ 2Gi`。

### 10. 日誌與監控

- 啟用 Prometheus callback，並確認 `/metrics` 可被 Prometheus scrape。
- 避免在日誌中記錄完整 prompt/response 或 API keys。
- 建議整合集中式日誌系統（ELK、Loki、Datadog 等）。

### 11. Prometheus 端點暴露

- Prometheus container 內部監聽 `9090` port，但 `compose.yaml` 已將 host port 映射為 `9091`（`9091:9090`），降低與主機上既有 Prometheus 實例的 port 衝突風險。
- `9091` host port **仍不應**直接對外公開，應限制為內網可存取或透過安全的 observability gateway（如 Grafana Cloud、Own your metrics 策略）暴露。
- 建議使用 NetworkPolicy 或 firewall 規則確保 Prometheus 只接受來自授權 scrape targets 的流量。

---

## QA 驗證清單

### 部署前

- [ ] `.env` 已建立，所有 placeholder 已替換
- [ ] `LITELLM_MASTER_KEY` 確認為強隨機（≥32 字元）
- [ ] `config.yaml` 中無寫死的 API key 或密碼
- [ ] PostgreSQL 備份策略已確認
- [ ] 確認使用哪個 LLM provider 與模型

### 部署後（Smoke Test）

- [ ] `GET /health` 回傳 HTTP 200
- [ ] `/health` response body 中 `db_connection` 為 `connected`（或 `not_configured` 如無 DB）
- [ ] Prometheus `/metrics` 可被 scrape（如已啟用 prometheus service）
- [ ] `POST /v1/chat/completions` 可正常回應（如有 provider key）
- [ ] `POST /key/generate` 可建立 virtual key（需 master key）
- [ ] Virtual key 可用於 `/v1/chat/completions` 認證

### Redis 驗證

- [ ] `docker compose exec redis redis-cli ping` 回傳 `PONG`
- [ ] LiteLLM logs 無 Redis connection errors
- [ ] Host port 6379 未被其他 process 佔用（`ss -tlnp | grep 6379`）
- [ ] （可選）若設定 `REDIS_PASSWORD`，`redis-cli -a <password> ping` 應回傳 `PONG`

### 安全性（建議 QA 核查）

- [ ] 對外 port 只有 TLS reverse proxy，`:4000` 未直接暴露
- [ ] Master key 未提供給客戶端應用
- [ ] 所有 API keys / DB passwords 未寫入 Git
- [ ] Admin UI 已有基本認證或網段限制
- [ ] 已設定 `store_completion: false` 或已確認資料保留政策（如隱私敏感）

---

## 測試：單一 key 按 user 限制 RPM

### 架構說明

本測試驗證在同一個 shared virtual key 下，LiteLLM 能依 `user` 參數独立执行 RPM 限制。

**流程：**
1. 建立一個 `budget`，設定 `rpm_limit`（每 user 每分鐘最多 N 個請求）
2. 建立兩個 customer：`user_a` 和 `user_b`，皆绑定同一 budget
3. 產生一個 shared virtual key（未绑定特定 user）
4. 以 `user=user_a` 呼叫 API `rpm_limit + 1` 次，預期第 N+1 次被 rate-limited
5. 以 `user=user_b` 呼叫 1 次，預期成功（user_a 的限流不影響 user_b）
6. 不帶 `user` 參數呼叫，預期被拒絕（`enforce_user_param: true`）

```
Client → Virtual Key → LiteLLM Proxy
                      ├── user=user_a → [RPM counter: user_a] → Provider
                      ├── user=user_b → [RPM counter: user_b] → Provider
                      └── (no user)   → REJECT (enforce_user_param)
```

### 前置條件

- LiteLLM stack 運行中（`docker compose up -d`）
- Admin key（`LITELLM_MASTER_KEY`）已設定
- **`TEST_MODEL` 必須已存在** — 因為 `config.yaml` 中 `model_list: []`，模型需透過 Admin UI 或 `/model/new` API 先建立

### 指令範例

```bash
cd deploy/litellm

# ⚠️ 請替換為您已透過 Admin UI/API 建立的模型名稱，不代表 active config 已存在
export TEST_MODEL="your-existing-model-name"
export LITELLM_API_KEY="sk-..."        # master key 或 admin key
export LITELLM_BASE_URL="http://localhost:4000"
export USER_RPM_LIMIT=2                 # 每 user 每分鐘最多 2 個請求
export RUN_PROVIDER_CALLS=true         # 設 false 可跳過實際 API 呼叫
export RUN_BOUNDARY_TEST=false         # 設 true 可測試 rate window 恢復（需等待約 70 秒）

./test_user_rpm.sh
```

**邊界測試說明：**
- `RUN_BOUNDARY_TEST=true` 會在完成步驟 7 後等待 70 秒（`RATE_WINDOW_WAIT_SECONDS`，可自訂），然後以 `user_a` 再打一筆，預期成功（rate window 已重置）。

**不使用 jq 的環境：**
```bash
apt install jq || true   # 安裝失敗仍可執行（會有 warning）
```

### 共享 virtual key 安全警告

> ⚠️ **Shared virtual key 绑定了 budget RPM limit，但依 user 計數**。如果有多個消費者共享同一 key，每個消費者的 `user` 值必須唯一且穩定。若攻擊者偽造他人 `user` 值，可能規避 RPM 限制。建議：
> - Virtual key 僅交給信任的內部服務
> - `user` 值由後端系統固定指派，而非由客戶端自行帶入
> - 重要情境改用 per-customer virtual key 而非 shared key

---

## 參考資料

- LiteLLM 官方部署文件：<https://docs.litellm.ai/docs/proxy/deploy>
- LiteLLM Docker quick start：<https://docs.litellm.ai/docs/proxy/docker_quick_start>
- LiteLLM production best practices：<https://docs.litellm.ai/docs/proxy/prod>
- LiteLLM config settings：<https://docs.litellm.ai/docs/proxy/config_settings>
- LiteLLM virtual keys：<https://docs.litellm.ai/docs/proxy/virtual_keys>
- LiteLLM Helm Chart：<https://github.com/BerriAI/litellm-helm>
- LiteLLM security FAQ：<https://docs.litellm.ai/docs/proxy/security_encryption_faq>
