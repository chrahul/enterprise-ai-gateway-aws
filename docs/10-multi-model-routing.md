# Multi-Model Routing

## Why Multi-Model Routing Matters

Enterprise AI workloads are heterogeneous. A single AI model does not optimally serve every use case, team, or cost target. Some tasks require maximum reasoning depth; others need maximum throughput at minimum cost. Multi-model routing allows the gateway to direct each request to the most appropriate model without requiring applications to know which model is in use.

Key drivers for multi-model routing:

- **Cost optimisation** — Cheaper models for simple tasks reduce token spend without degrading user experience.
- **Reliability** — If one provider or model is unavailable, traffic fails over to an alternative automatically.
- **Workload specialisation** — Different models have different strengths (coding, summarisation, instruction following, multilingual).
- **Compliance** — Sensitive workloads can be routed exclusively to Bedrock; non-sensitive workloads can optionally use external providers.

## How LiteLLM Implements Routing

LiteLLM exposes a single OpenAI-compatible endpoint (`/v1/chat/completions`). Each request specifies a `model` field. The gateway maps that alias to a backend provider and model.

```
                    ┌─────────────────────────────────────┐
                    │         AI Gateway (LiteLLM)        │
                    │                                     │
Client              │  model alias → provider mapping     │
  │                 │                                     │
  ├─ claude-sonnet  │──▶  bedrock/claude-3-5-sonnet  ─────┤──▶  Amazon Bedrock
  ├─ claude-haiku   │──▶  bedrock/claude-3-haiku     ─────┤──▶  Amazon Bedrock
  ├─ gpt-4o         │──▶  openai/gpt-4o              ─────┤──▶  OpenAI API
  └─ gpt-4o-mini    │──▶  openai/gpt-4o-mini         ─────┤──▶  OpenAI API
                    │                                     │
                    └─────────────────────────────────────┘
```

The calling application uses only the alias. The underlying model and provider are opaque to the caller.

## Current Model Catalogue

The following models are configured in `litellm/config.yaml`:

| Alias | Provider | Model ID | Use Case |
|---|---|---|---|
| `claude-sonnet` | Amazon Bedrock | `anthropic.claude-3-5-sonnet-20241022-v2:0` | Complex reasoning, long-form generation, code review |
| `claude-haiku` | Amazon Bedrock | `anthropic.claude-3-haiku-20240307-v1:0` | High-volume tasks, summarisation, classification |

OpenAI models can be added following the procedure in [09-openai-integration.md](09-openai-integration.md).

## Routing Strategy

The gateway uses **least-busy** routing when multiple instances of the same model are configured. This is set in `litellm/config.yaml`:

```yaml
router_settings:
  routing_strategy: least-busy
  num_retries: 3
  retry_after: 60
  allowed_fails: 3
  cooldown_time: 60
```

| Setting | Value | Effect |
|---|---|---|
| `routing_strategy` | `least-busy` | Routes to the backend with fewest in-flight requests |
| `num_retries` | 3 | Retries a failed request up to 3 times before returning an error |
| `retry_after` | 60 | Waits 60 seconds before retrying a request to a failed backend |
| `allowed_fails` | 3 | Marks a backend as unhealthy after 3 consecutive failures |
| `cooldown_time` | 60 | Keeps a failed backend in cooldown for 60 seconds |

## Failover Routing

When a model or provider is unavailable, LiteLLM can automatically fall back to an alternative. Failover is configured via the `fallbacks` field in `router_settings`:

```yaml
router_settings:
  routing_strategy: least-busy
  num_retries: 3
  fallbacks:
    - {"claude-sonnet": ["claude-haiku"]}
    - {"gpt-4o": ["claude-sonnet"]}
```

With this configuration:
- If `claude-sonnet` fails after 3 retries, the request is routed to `claude-haiku`
- If `gpt-4o` fails, the request falls back to `claude-sonnet` on Bedrock

Failover is transparent to the calling application. The response is returned from the fallback model without the client needing to retry.

## Cost-Aware Routing

For workloads where cost per token is the primary concern, route simple tasks to the cheapest capable model. The pattern is to define model tiers in the gateway and have the application select the appropriate tier:

| Tier | Model | Use When |
|---|---|---|
| Premium | `claude-sonnet` | Reasoning, code generation, complex instructions |
| Standard | `claude-haiku` | Summarisation, classification, Q&A, high-volume |
| Budget (future) | `amazon-titan-lite` | Simple keyword extraction, formatting tasks |

Claude Haiku costs approximately 20x less per token than Claude 3.5 Sonnet. Routing 80% of requests to Haiku while reserving Sonnet for complex tasks reduces token spend significantly at scale.

## Latency-Aware Routing

For latency-sensitive workloads, LiteLLM supports latency-based routing. This selects the backend with the lowest observed p50 latency:

```yaml
router_settings:
  routing_strategy: latency-based-routing
```

Latency-based routing is most useful when the same model is available in multiple regions and latency differs. For Bedrock in a single region, the routing strategy has minimal effect. It becomes relevant when adding cross-region failover.

## Adding a New Model

1. Identify the LiteLLM model string for the target provider (see `litellm --list-models` or the LiteLLM documentation).
2. Add an entry to `litellm/config.yaml` under `model_list`:
   ```yaml
   - model_name: my-new-alias
     litellm_params:
       model: bedrock/amazon.nova-pro-v1:0
       aws_region_name: us-east-1
   ```
3. Update `kubernetes/configmap.yaml` to reflect the new config (or re-run the ConfigMap from source).
4. If adding an OpenAI model, add the API key to Secrets Manager (see [09-openai-integration.md](09-openai-integration.md)).
5. Restart the LiteLLM pods: `kubectl rollout restart deployment/litellm -n ai-gateway`.
6. Validate: `curl -H "Authorization: Bearer $MASTER_KEY" http://localhost:4000/v1/models`.

## Enterprise AI Gateway Patterns

### Pattern 1 — Team-Specific Model Aliases

Assign different model aliases per team, each mapped to different cost tiers. Use LiteLLM's per-key budget controls to prevent one team from consuming the entire cluster's token budget.

### Pattern 2 — A/B Model Testing

Run two versions of the same alias pointing to different backend models. LiteLLM's `weight` parameter distributes traffic:

```yaml
model_list:
  - model_name: default
    litellm_params:
      model: bedrock/anthropic.claude-3-5-sonnet-20241022-v2:0
      aws_region_name: us-east-1
    model_info:
      weight: 9  # 90% of traffic

  - model_name: default
    litellm_params:
      model: bedrock/anthropic.claude-3-haiku-20240307-v1:0
      aws_region_name: us-east-1
    model_info:
      weight: 1  # 10% of traffic
```

### Pattern 3 — Regulatory Isolation

Some regulated workloads (PII, PHI, financial data) must not leave a given AWS account or region. Create a `bedrock-only` alias group that is restricted to Bedrock models. Instruct teams handling regulated data to use only those aliases. The gateway enforces the boundary.

## See Also

- [05-bedrock-integration.md](05-bedrock-integration.md) — Bedrock model configuration
- [09-openai-integration.md](09-openai-integration.md) — Adding OpenAI models
- [11-observability.md](11-observability.md) — Per-model traffic and token metrics
- [12-cost-governance.md](12-cost-governance.md) — Token economics and cost controls
