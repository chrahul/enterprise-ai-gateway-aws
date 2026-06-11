# LiteLLM Configuration Review

## Overview

This document reviews the production configuration for the LiteLLM proxy at `litellm/config.yaml`. It covers design decisions, the supported model catalogue, routing behaviour, operational controls, and the expansion path for adding new models or providers.

LiteLLM acts as an **OpenAI-compatible reverse proxy** in front of Amazon Bedrock. Calling applications (agents, dashboards, internal tools) send standard OpenAI-format requests to the gateway and are completely shielded from provider-specific SDKs, authentication mechanisms, and model ID formats.

---

## File Location and Deployment

| Artifact | Path |
|---|---|
| Source file | `litellm/config.yaml` |
| Container mount path | `/app/config.yaml` |
| Kubernetes ConfigMap | `kubernetes/configmap.yaml` (GAP-002 — to be created) |
| Pod reference | `LITELLM_CONFIG=/app/config.yaml` env var in `kubernetes/deployment.yaml` |

The config is injected into the pod via a ConfigMap volume mount. **After any change to this file**, the ConfigMap must be updated and a rolling restart must be triggered:

```bash
# Rebuild the ConfigMap from the updated file
kubectl create configmap litellm-config \
  --from-file=config.yaml=litellm/config.yaml \
  --namespace ai-gateway \
  --dry-run=client -o yaml | kubectl apply -f -

# Trigger rolling restart (zero-downtime due to RollingUpdate strategy)
kubectl rollout restart deployment/litellm -n ai-gateway

# Confirm rollout completes
kubectl rollout status deployment/litellm -n ai-gateway
```

---

## Supported Models

Two models are currently configured. Both route to Amazon Bedrock in `us-east-1` using IRSA authentication — no API keys are stored in the configuration or the cluster.

### Model Catalogue

| Alias | Bedrock Model ID | Capability Tier | Max Output Tokens | Request Timeout |
|---|---|---|---|---|
| `claude-sonnet` | `anthropic.claude-3-5-sonnet-20241022-v2:0` | Flagship | 4,096 | 120s |
| `claude-haiku` | `anthropic.claude-3-haiku-20240307-v1:0` | Fast / Economy | 2,048 | 60s |

### Why Two Models?

The gateway intentionally exposes two models at different capability and cost tiers. This allows teams to make cost-aware decisions at the application level:

- Use **`claude-sonnet`** for complex reasoning, code generation, structured data extraction, multi-step tool use, and document analysis where quality is paramount.
- Use **`claude-haiku`** for classification, summarisation, intent detection, high-volume processing pipelines, and any workload where sub-second latency or cost reduction is the primary constraint.

### Alias Design

Model names exposed to consumers (`claude-sonnet`, `claude-haiku`) are intentionally **provider-agnostic aliases**. This is a deliberate design decision documented in ADR-002 (`docs/98-architecture-decisions.md`).

When Anthropic releases an updated model (e.g. Claude 4), the gateway operator updates the single `litellm_params.model` value in this config file. Every consuming application continues to send `claude-sonnet` without modification.

---

## Routing Behaviour

### Strategy: `least-busy`

The router selects the deployment with the fewest active in-flight requests. With the current single-deployment-per-alias configuration, this has no observable effect; however it positions the gateway correctly for future multi-deployment scenarios (e.g. adding a cross-region Bedrock fallback or an OpenAI fallback).

### Retry Policy

| Setting | Value | Effect |
|---|---|---|
| `num_retries` | 3 | Up to 3 attempts per request |
| `retry_after` | 1s | Base delay between retries (exponential backoff applied) |
| `cooldown_time` | 60s | Failed deployment removed from rotation for 60 seconds |
| `allow_fallbacks` | false | Errors are surfaced to callers, not silently rerouted |

Retries apply **only to transient errors**: HTTP 429 (rate limit), 503 (service unavailable), and 500 (internal server error). Authentication errors (401, 403) are not retried because retrying will not resolve an auth failure.

`allow_fallbacks: false` is intentional for the initial deployment. Silently routing to an unexpected model can produce surprising behaviour for applications that are capacity- or cost-optimised for a specific model. Enable fallbacks only when cross-model substitution has been explicitly validated.

### Timeout Hierarchy

Timeouts are enforced at two levels:

```
global request_timeout (180s)         ← hard ceiling for any request
  └── per-model timeout (120s / 60s)  ← model-level ceiling
        └── stream_timeout (30s / 15s) ← first byte of streaming response
```

The global `request_timeout` in `litellm_settings` is the ultimate backstop. If a Bedrock request hangs (e.g. infrastructure issue), the proxy will terminate it and return a 504 to the caller rather than holding the connection indefinitely.

---

## Authentication and Security

### Master Key

All requests to the proxy must include the master key as a Bearer token:

```
Authorization: Bearer sk-your-master-key-here
```

The master key is **never stored in this config file**. It is read from the `LITELLM_MASTER_KEY` environment variable, which is injected from the `litellm-secrets` Kubernetes Secret at pod startup. The Secret itself is populated from AWS Secrets Manager at deploy time.

```
AWS Secrets Manager
  └── ai-gateway-{env}/litellm-secrets  (JSON object)
        └── LITELLM_MASTER_KEY
              └── K8s Secret: litellm-secrets
                    └── env var: LITELLM_MASTER_KEY
                          └── config.yaml: os.environ/LITELLM_MASTER_KEY
```

See `docs/94-secrets-management-strategy.md` for full details.

### AWS Authentication (Bedrock)

No AWS credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) appear anywhere in this configuration. The LiteLLM pod authenticates to Bedrock via **IRSA (IAM Roles for Service Accounts)**. The pod's Kubernetes ServiceAccount is annotated with an IAM Role ARN, and the EKS Pod Identity webhook injects short-lived AWS credentials into the pod's environment automatically.

See `docs/95-irsa-and-iam-design.md` for the trust relationship, IAM policy, and IRSA setup procedure.

### Parameter Sanitisation

`drop_params: true` in `litellm_settings` causes LiteLLM to silently discard request parameters that are not supported by the target provider, rather than returning a 400 error. This is important for cross-provider compatibility: if an application sends `logprobs=true` (an OpenAI-specific parameter), the proxy will strip it before forwarding to Bedrock rather than failing the request.

---

## Observability Hooks

The `litellm_settings` block includes `success_callback` and `failure_callback` arrays, both currently empty. These are the integration points for the observability stack.

| Callback | Trigger | Recommended Integration |
|---|---|---|
| `success_callback` | Every successful request | Langfuse (prompt tracing), Prometheus metrics |
| `failure_callback` | Every failed request | Datadog, PagerDuty (via webhook) |

### Enabling Langfuse (Example)

When the Langfuse instance is provisioned (see `docs/11-observability.md`):

1. Add Langfuse credentials to AWS Secrets Manager and the `litellm-secrets` Kubernetes Secret.
2. Update `litellm_settings` in this file:

```yaml
litellm_settings:
  success_callback: ["langfuse"]
  LANGFUSE_PUBLIC_KEY: os.environ/LANGFUSE_PUBLIC_KEY
  LANGFUSE_SECRET_KEY: os.environ/LANGFUSE_SECRET_KEY
```

3. Rebuild the ConfigMap and restart the deployment (commands above).

No application code changes are required — LiteLLM will begin emitting traces automatically.

---

## Spend Tracking

`disable_spend_logs: true` is set because the per-request spend tracking feature requires a PostgreSQL database (configured via `database_url`). The database is not yet provisioned as part of the initial deployment.

When RDS PostgreSQL is available:

1. Store the connection string in AWS Secrets Manager.
2. Set `database_url: os.environ/DATABASE_URL` in `general_settings`.
3. Set `disable_spend_logs: false`.
4. Set `store_model_in_db: true` to enable the LiteLLM Admin UI for model management.

This enables per-API-key, per-team, and per-model token usage budgets enforced at the proxy layer.

---

## Expanding the Model Catalogue

The following process applies when adding a new model. All steps are required:

### Step 1 — Verify Bedrock model access

```bash
aws bedrock list-foundation-models --region us-east-1 --query \
  "modelSummaries[?modelId=='<model-id>'].{id:modelId,status:modelLifecycle.status}"
```

The model must show `status: ACTIVE`. If access is not granted, request it via the Bedrock console under **Model access**.

### Step 2 — Update the IAM policy

If the new model belongs to a family not already covered by the IAM policy (e.g. adding Amazon Titan after only Claude was permitted), update the `bedrock:InvokeModel` action resource list in the IAM policy attached to the IRSA role. See `docs/95-irsa-and-iam-design.md`.

### Step 3 — Add the model to config.yaml

```yaml
- model_name: your-alias
  litellm_params:
    model: bedrock/<bedrock-model-id>
    aws_region_name: us-east-1
    max_tokens: 4096
    timeout: 120
    stream_timeout: 30
```

Choose a short, descriptive, provider-agnostic alias for `model_name`. Callers will use this alias; the underlying Bedrock model ID is an implementation detail.

### Step 4 — Deploy

```bash
kubectl create configmap litellm-config \
  --from-file=config.yaml=litellm/config.yaml \
  --namespace ai-gateway \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment/litellm -n ai-gateway
kubectl rollout status deployment/litellm -n ai-gateway
```

### Step 5 — Validate

```bash
# Confirm the new model appears in the model list
curl -s -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  http://<gateway-url>/v1/models | jq '.data[].id'

# Send a test completion
curl -s -X POST http://<gateway-url>/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "your-alias",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 10
  }' | jq '.choices[0].message.content'
```

---

## Configuration Gaps Addressed by This File

This configuration directly closes **GAP-001** identified in `docs/92-repository-gap-analysis.md`:

| Gap ID | Description | Status |
|---|---|---|
| GAP-001 | `litellm/config.yaml` was empty — LiteLLM could not start | **Closed** |
| GAP-006 | `litellm/secrets-example.yaml` was empty | **Closed** (this session) |

The following related gaps remain open:

| Gap ID | Description | Next Action |
|---|---|---|
| GAP-002 | No `kubernetes/configmap.yaml` to mount config into pod | Create `kubernetes/configmap.yaml` |
| GAP-003 | No AWS infrastructure (EKS cluster, VPC, IAM roles) | Follow `docs/93-eks-build-plan.md` |
| GAP-004 | IRSA role ARN is a placeholder in `kubernetes/serviceaccount.yaml` | Populate after EKS cluster is created |

---

## Related Documents

| Document | Content |
|---|---|
| `docs/92-repository-gap-analysis.md` | Full gap analysis — overall score 76/100 |
| `docs/93-eks-build-plan.md` | 8-phase EKS deployment blueprint |
| `docs/94-secrets-management-strategy.md` | Secrets storage and rotation strategy |
| `docs/95-irsa-and-iam-design.md` | IRSA design, IAM policy, trust relationship |
| `docs/04-install-litellm.md` | LiteLLM installation walkthrough |
| `docs/05-bedrock-integration.md` | Bedrock-specific configuration guidance |
| `docs/11-observability.md` | Observability stack — Langfuse, Prometheus, Grafana |
