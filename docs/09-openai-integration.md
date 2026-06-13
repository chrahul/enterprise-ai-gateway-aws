# OpenAI Integration

## Why OpenAI Support Exists

This gateway is built on Amazon Bedrock as its primary AI provider. Bedrock delivers all the enterprise requirements: AWS-native identity via IRSA, data residency within a single AWS account, no data used for model training, and unified billing through AWS Cost Explorer.

OpenAI support is present for two practical reasons:

1. **Model availability gap.** Bedrock's catalogue does not include every model. GPT-4o, GPT-4 Turbo, and future OpenAI-exclusive models may be required for specific workloads.
2. **Migration and portability.** Teams migrating from a direct OpenAI integration can continue using the same API contract while routing shifts to Bedrock over time. The gateway abstracts the provider from the caller.

## Provider Abstraction via LiteLLM

LiteLLM normalises all AI providers behind a single OpenAI-compatible API surface. The calling application sends a standard `/v1/chat/completions` request. LiteLLM translates it to the appropriate provider format — Bedrock's `InvokeModel` or OpenAI's native API — without any change to the client.

```
Client Application
       │
       ▼  POST /v1/chat/completions
  AI Gateway (LiteLLM)
       ├─── model: "claude-sonnet"  ──▶  Amazon Bedrock (IRSA auth)
       ├─── model: "claude-haiku"   ──▶  Amazon Bedrock (IRSA auth)
       └─── model: "gpt-4o"        ──▶  OpenAI API (API key auth)
```

The caller never interacts with Bedrock or OpenAI directly. The gateway enforces authentication, rate limiting, and routing at the edge.

## Configuration

To add OpenAI as a provider, append the following to `litellm/config.yaml` under `model_list`:

```yaml
model_list:
  # --- Bedrock models (already configured) ---
  - model_name: claude-sonnet
    litellm_params:
      model: bedrock/anthropic.claude-3-5-sonnet-20241022-v2:0
      aws_region_name: us-east-1

  - model_name: claude-haiku
    litellm_params:
      model: bedrock/anthropic.claude-3-haiku-20240307-v1:0
      aws_region_name: us-east-1

  # --- OpenAI models (optional, add when needed) ---
  - model_name: gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: os.environ/OPENAI_API_KEY

  - model_name: gpt-4o-mini
    litellm_params:
      model: openai/gpt-4o-mini
      api_key: os.environ/OPENAI_API_KEY
```

The `api_key` field references an environment variable, not a literal key. Add `OPENAI_API_KEY` to the Kubernetes Secret alongside the existing `LITELLM_MASTER_KEY`:

```bash
# Retrieve current secret, add OPENAI_API_KEY, re-create
aws secretsmanager get-secret-value \
  --secret-id ai-gateway-prod/litellm-secrets \
  --query SecretString \
  --output text | \
  jq '. + {"OPENAI_API_KEY": "sk-..."}' | \
  aws secretsmanager put-secret-value \
    --secret-id ai-gateway-prod/litellm-secrets \
    --secret-string file:///dev/stdin
```

Then restart the LiteLLM pods to pick up the new environment variable:

```bash
kubectl rollout restart deployment/litellm -n ai-gateway
```

## Enterprise Considerations

### Cost and Billing

| Provider | Billing | Visibility |
|---|---|---|
| Amazon Bedrock | AWS account | AWS Cost Explorer, per-model breakdowns |
| OpenAI | OpenAI account (separate invoice) | OpenAI dashboard; not in AWS Cost Explorer |

Bedrock costs appear in the same AWS bill as all other infrastructure. OpenAI costs require a separate account and dashboard. For unified cost governance, prefer Bedrock models when equivalent capability is available.

### Data Residency

Amazon Bedrock processes requests within the AWS region specified (`us-east-1`). Data does not leave the AWS account. OpenAI processes requests on OpenAI's infrastructure, which may not satisfy all data residency requirements (GDPR, FedRAMP, sector-specific regulations). Review your organisation's data classification policy before sending regulated data to OpenAI.

### Data Used for Training

By default, OpenAI does not use API traffic for training when accessed via the API (not the consumer product). Bedrock does not use prompts or completions for model training. Both providers should be validated against the most current version of their data processing agreements before use in regulated workloads.

## Vendor Lock-in Avoidance

The AI Gateway pattern prevents vendor lock-in at the application layer. Because every application calls `/v1/chat/completions` against the gateway using a model alias (`claude-sonnet`, `gpt-4o`), switching the underlying model requires a configuration change in `litellm/config.yaml` — not a code change in each application.

For example, to route `gpt-4o` to a Bedrock-hosted alternative in the future:

```yaml
# Before: routes to OpenAI
- model_name: gpt-4o
  litellm_params:
    model: openai/gpt-4o
    api_key: os.environ/OPENAI_API_KEY

# After: routes to Bedrock (zero application code change)
- model_name: gpt-4o
  litellm_params:
    model: bedrock/us.amazon.nova-pro-v1:0
    aws_region_name: us-east-1
```

This is the core value proposition of the AI Gateway — provider portability without application coupling.

## See Also

- [05-bedrock-integration.md](05-bedrock-integration.md) — Primary provider configuration
- [10-multi-model-routing.md](10-multi-model-routing.md) — Routing strategies across providers
- [12-cost-governance.md](12-cost-governance.md) — Cost tracking per provider
- [litellm/secrets-example.yaml](../litellm/secrets-example.yaml) — Secret structure reference
