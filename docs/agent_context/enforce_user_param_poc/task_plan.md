# PoC Plan: enforce_user_param = false

**Tracking ID**: 20260724-008  
**Scope**: PR B (`chore/config-enforce-user-param-poc`)  
**Base**: `origin/dev` (commit `70f2f4e`)

---

## Why `false`

Lambda/API Gateway PoC — the API Gateway may not forward the `user` parameter in all authentication modes. Setting `false` allows the PoC to proceed without blocking requests that arrive without a `user` field.

## Scope

Dev/PoC only. **Not for production use.**

---

## Safeguards (what still works)

- API Gateway-level rate limiting still applies.
- LiteLLM Redis cache and RPM tracking still function for authenticated requests.
- Authenticated API key enforcement remains active.

---

## Lost Protections

- **Per-user RPM/budget tracking** requires the `user` param — disabled for requests without `user`.
- **Anonymous abuse detection** via `user` parameter is disabled.
- **Any request without `user`** bypasses per-user rate limits.

---

## Production Re-enable Trigger

Set back to `true` when **any** of:

1. Lambda/API Gateway PoC is complete AND API Gateway is confirmed to forward `user` in all auth flows, **OR**
2. API Gateway is configured to enforce `user` parameter in all authentication flows, **OR**
3. A per-API-key RPM/budget mechanism is implemented that does not require the `user` param.

---

## Safe Rollback / Re-enable Procedure

```bash
# 1. Re-enable enforce_user_param
#    Edit config.yaml: set `enforce_user_param: true`
#    Remove the NOTE comment line (keep only the key: value)

# 2. Restart LiteLLM to reload config
docker compose restart litellm

# 3. Verify config reloaded (no errors)
docker compose logs litellm --tail 20 | grep -i 'reload\|config\|enforce'

# 4. Confirm enforcement is active: POST without "user" should return 400
curl -X POST http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "agent-architect-primary", "messages": [{"role":"user","content":"hi"}]}'
# Expected: HTTP 400 (enforce_user_param blocks the request)

# 5. Confirm normal user-bearing requests still work
curl -X POST http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "agent-architect-primary", "messages": [{"role":"user","content":"hi"}], "user": "test-user"}'
# Expected: HTTP 200 (user param present — passes enforcement)
```

---

## Docker Compose Restart / Reload Verification

After any config change, restart to confirm clean reload:

```bash
docker compose restart litellm
docker compose logs litellm --tail 20 | grep -i 'error\|warn\|config\|reload'
```

**Expected**: No error/warning lines. Log shows config was re-read successfully.

**Safe rollback** (before next restart):
```bash
git checkout origin/dev -- config.yaml
docker compose restart litellm
```
