# Cost Governance

## Why AI Cost Management Is Different

Traditional API costs are predictable: a fixed number of requests at a known price per request. AI costs are probabilistic and per-token. A single user prompt can generate 50 tokens or 50,000 tokens depending on what they ask. Without governance, a single team or application can consume a disproportionate share of the total token budget without anyone noticing until the monthly bill arrives.

The AI Gateway is the natural enforcement point for cost governance because every AI request passes through it.

## Token Economics

### Amazon Bedrock Pricing (us-east-1)

Prices are per 1,000 tokens (1K tokens ≈ 750 words). Verify current pricing in the [Bedrock pricing page](https://aws.amazon.com/bedrock/pricing/).

| Model | Input (per 1K tokens) | Output (per 1K tokens) |
|---|---|---|
| Claude 3.5 Sonnet (`claude-sonnet`) | $0.003 | $0.015 |
| Claude 3 Haiku (`claude-haiku`) | $0.00025 | $0.00125 |

Key insight: Claude 3 Haiku is **12x cheaper on input** and **12x cheaper on output** than Claude 3.5 Sonnet. Routing classification, summarisation, and simple Q&A workloads to Haiku dramatically reduces spend without significant quality degradation for those tasks.

### Monthly Cost Examples

| Scenario | Volume | Model | Estimated Monthly Cost |
|---|---|---|---|
| Internal chatbot, 10K sessions/day, avg 2K tokens/session | 600M tokens | Claude Haiku | ~$150 |
| Code review assistant, 1K PRs/day, avg 10K tokens/PR | 300M tokens | Claude Sonnet | ~$4,500 |
| Document summarisation, 5K docs/day, avg 5K tokens/doc | 750M tokens | Claude Haiku | ~$190 |

These estimates assume a 1:3 input-to-output token ratio.

## Chargeback Model

### API Key Per Team or Application

LiteLLM supports per-key budget controls. Each team or application receives a unique API key with:

- A monthly token budget
- A monthly spend budget (in USD)
- Rate limits (requests per minute)

```bash
# Create a key for the platform team with a $200/month spend limit
curl -X POST http://litellm-gateway/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "max_budget": 200,
    "budget_duration": "1mo",
    "key_alias": "platform-team",
    "team_id": "platform",
    "metadata": {"team": "platform", "owner": "platform-team@company.com"},
    "rpm_limit": 100,
    "tpm_limit": 1000000
  }'
```

> **Note:** Per-key budget controls require LiteLLM to be configured with a database backend (PostgreSQL). This is a future enhancement. See [99-roadmap.md](99-roadmap.md).

### Key Naming Convention

| Key Alias Pattern | Example | Scope |
|---|---|---|
| `{team}-key` | `platform-key` | All applications owned by a team |
| `{team}-{app}-key` | `platform-catalog-key` | A specific application |
| `{team}-{env}-key` | `platform-prod-key` | Environment-scoped key |

All keys are stored in AWS Secrets Manager under `ai-gateway-prod/api-keys/`. They are rotated quarterly.

## Cost Visibility

### Per-Model Spend in AWS Cost Explorer

Enable Bedrock cost allocation tags to break down spend by model:

```bash
aws bedrock put-model-invocation-logging-configuration \
  --logging-config '{
    "cloudWatchConfig": {
      "logGroupName": "/aws/bedrock/invocations",
      "roleArn": "arn:aws:iam::ACCOUNT_ID:role/bedrock-logging"
    },
    "s3Config": {
      "bucketName": "ai-gateway-bedrock-logs",
      "keyPrefix": "invocations"
    },
    "textDataDeliveryEnabled": false,
    "imageDataDeliveryEnabled": false
  }'
```

Cost Explorer dimensions available after enabling cost allocation tags:

| Dimension | Description |
|---|---|
| `aws:bedrock:modelId` | Which model was invoked |
| Resource tag on the EKS cluster | Which cluster generated the cost |

### Gateway-Level Spend Tracking (LiteLLM)

LiteLLM tracks spend per key and per model in its internal database (when a DB is configured). The `/spend/logs` and `/spend/keys` endpoints return:

```bash
# Get spend by API key
curl http://litellm-gateway/spend/keys \
  -H "Authorization: Bearer $MASTER_KEY"

# Get spend by model
curl http://litellm-gateway/spend/models \
  -H "Authorization: Bearer $MASTER_KEY"
```

Without a database backend, spend data is in-memory only and lost on pod restart. Persistent spend tracking requires a PostgreSQL sidecar — see [99-roadmap.md](99-roadmap.md).

## Budget Controls

### Soft Limits (Alerting)

Set CloudWatch alarms to alert when spend approaches the budget threshold:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name bedrock-spend-80pct-threshold \
  --metric-name EstimatedCharges \
  --namespace AWS/Billing \
  --statistic Maximum \
  --period 86400 \
  --threshold 800 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 1 \
  --alarm-actions arn:aws:sns:us-east-1:ACCOUNT_ID:billing-alerts
```

### Hard Limits (AWS Budgets)

Create an AWS Budget to cap monthly Bedrock spend:

```bash
aws budgets create-budget \
  --account-id ACCOUNT_ID \
  --budget '{
    "BudgetName": "bedrock-monthly-limit",
    "BudgetLimit": {"Amount": "1000", "Unit": "USD"},
    "TimeUnit": "MONTHLY",
    "BudgetType": "COST",
    "CostFilters": {
      "Service": ["Amazon Bedrock"]
    }
  }' \
  --notifications-with-subscribers '[
    {
      "Notification": {
        "NotificationType": "ACTUAL",
        "ComparisonOperator": "GREATER_THAN",
        "Threshold": 80,
        "ThresholdType": "PERCENTAGE"
      },
      "Subscribers": [
        {"SubscriptionType": "EMAIL", "Address": "platform-team@company.com"}
      ]
    }
  ]'
```

## Governance Policies

| Policy | Enforcement |
|---|---|
| No direct Bedrock API access from applications | IAM — only the LiteLLM IRSA role has `bedrock:InvokeModel` |
| All AI traffic through the gateway | Network — applications call gateway DNS, not Bedrock endpoints |
| Every application has a named API key | Operational process — keys are created per team before access is granted |
| Monthly spend review | Monthly meeting — Cost Explorer report reviewed by platform team |
| Key rotation every 90 days | Operational process — Secrets Manager reminder |

## Cost Optimisation Checklist

- [ ] Route classification and summarisation workloads to Claude Haiku instead of Claude Sonnet
- [ ] Set `max_tokens` in client applications to prevent unbounded output lengths
- [ ] Enable Bedrock invocation logging to get per-request token counts
- [ ] Enable `drop_params: true` in LiteLLM (already configured) to strip unsupported parameters that cause retries
- [ ] Set per-key `tpm_limit` to prevent a single application from monopolising capacity
- [ ] Review spend by model weekly using CloudWatch Logs Insights on the Bedrock invocation log group

## See Also

- [10-multi-model-routing.md](10-multi-model-routing.md) — Routing to lower-cost models
- [11-observability.md](11-observability.md) — Token usage metrics
- [99-roadmap.md](99-roadmap.md) — PostgreSQL backend for persistent spend tracking
