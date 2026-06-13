# Observability

## Why Observability Matters for AI Gateways

AI gateways carry traffic that is qualitatively different from traditional API traffic. A single request may consume tens of thousands of tokens, cost several cents, and interact with an external LLM provider. Standard HTTP metrics (request count, latency, error rate) are necessary but not sufficient. Token usage, per-model error rates, cost per request, and prompt/completion patterns are all operationally critical.

This document describes the observability stack for the enterprise AI gateway on Amazon EKS.

## Observability Architecture

```
LiteLLM Pods
     │
     ├─── stdout/stderr ──────────────────▶  CloudWatch Logs (Container Insights)
     │
     ├─── /metrics (Prometheus format) ──▶  CloudWatch Container Insights (custom metrics)
     │
     └─── Langfuse callbacks (future) ───▶  Langfuse (AI-specific observability)
```

## Amazon CloudWatch

### Container Insights

CloudWatch Container Insights is the primary observability platform for the EKS cluster. It provides:

- **Node-level metrics** — CPU utilisation, memory pressure, disk I/O, network throughput per node
- **Pod-level metrics** — CPU requests vs limits, memory usage, restart counts, OOMKill events
- **Namespace-level aggregations** — Total resource consumption for the `ai-gateway` namespace

Enable Container Insights when creating the EKS cluster:

```bash
aws eks update-cluster-config \
  --name ai-gateway-prod \
  --region us-east-1 \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}'
```

Install the CloudWatch agent as a DaemonSet:

```bash
ClusterName=ai-gateway-prod
RegionName=us-east-1
FluentBitHttpPort='2020'
FluentBitReadFromHead='Off'

curl https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/quickstart/cwagent-fluent-bit-quickstart.yaml | \
  sed "s/{{cluster_name}}/${ClusterName}/;s/{{region_name}}/${RegionName}/;s/{{http_server_toggle}}/${FluentBitHttpPort}/;s/{{read_from_head}}/${FluentBitReadFromHead}/" | \
  kubectl apply -f -
```

### CloudWatch Log Groups

LiteLLM logs to stdout in structured JSON format. Container Insights captures these logs into CloudWatch:

| Log Group | Contents |
|---|---|
| `/aws/containerinsights/ai-gateway-prod/application` | LiteLLM application logs (requests, errors, model calls) |
| `/aws/containerinsights/ai-gateway-prod/host` | Node-level logs |
| `/aws/containerinsights/ai-gateway-prod/dataplane` | Kubernetes dataplane logs |

Log retention should be set to match your compliance requirements (default: 30 days). Set via:

```bash
aws logs put-retention-policy \
  --log-group-name /aws/containerinsights/ai-gateway-prod/application \
  --retention-in-days 90
```

## Key Metrics

### Infrastructure Metrics

| Metric | Source | Alert Threshold |
|---|---|---|
| Pod CPU utilisation | Container Insights | > 80% for 5 min |
| Pod memory utilisation | Container Insights | > 85% for 5 min |
| Pod restart count | Container Insights | > 3 restarts in 10 min |
| Replica count | HPA | < 2 (below minReplicas) |

### Application Metrics (LiteLLM)

LiteLLM exposes a `/metrics` endpoint with Prometheus-format metrics. These can be scraped by a CloudWatch agent or Prometheus-compatible collector.

| Metric | Description |
|---|---|
| `litellm_requests_total` | Total requests handled, labelled by model and status |
| `litellm_request_duration_seconds` | Request latency histogram (p50, p95, p99) |
| `litellm_tokens_total` | Total tokens processed, labelled by model and direction (input/output) |
| `litellm_errors_total` | Error count labelled by error type and model |
| `litellm_spend_total` | Estimated spend, labelled by model |

### SLO Targets

| SLO | Target | Measurement |
|---|---|---|
| Availability | 99.9% | Successful responses / total requests |
| Latency p95 | < 10 s | Request duration from gateway receipt to response |
| Error rate | < 1% | 5xx responses / total requests |

## Structured Logging

LiteLLM emits structured JSON logs by default. Each log entry includes:

```json
{
  "timestamp": "2026-06-13T10:23:45Z",
  "level": "INFO",
  "model": "claude-sonnet",
  "provider": "bedrock",
  "request_id": "req_abc123",
  "status": 200,
  "input_tokens": 512,
  "output_tokens": 1024,
  "latency_ms": 3241,
  "user": "team-platform",
  "key_alias": "platform-team-key"
}
```

CloudWatch Logs Insights can be used to query these structured fields:

```sql
-- Find all requests that exceeded 10 seconds
fields @timestamp, model, latency_ms, user
| filter latency_ms > 10000
| sort @timestamp desc
| limit 50
```

```sql
-- Token consumption by model in the last 24 hours
stats sum(input_tokens) as total_input, sum(output_tokens) as total_output by model
| sort total_output desc
```

## AI-Specific Observability (Future: Langfuse)

The current `litellm/config.yaml` has the Langfuse callback stubbed and disabled:

```yaml
litellm_settings:
  callbacks: []   # future: ["langfuse"]
```

Langfuse is an open-source LLM observability platform that provides:

- **Trace-level visibility** — Full prompt, completion, and metadata per request
- **Token cost tracking** — Actual cost per trace and per session
- **Quality evaluation** — Human and automated scoring of outputs
- **Session analysis** — Multi-turn conversation traces

To enable Langfuse, add the keys to Secrets Manager and update `litellm/config.yaml`:

```yaml
litellm_settings:
  callbacks: ["langfuse"]
  langfuse_public_key: os.environ/LANGFUSE_PUBLIC_KEY
  langfuse_secret_key: os.environ/LANGFUSE_SECRET_KEY
  langfuse_host: https://cloud.langfuse.com
```

Self-hosted Langfuse can be deployed on the same EKS cluster in a separate namespace.

## OpenTelemetry (Future)

LiteLLM supports OpenTelemetry tracing. This enables distributed traces that span from the calling application through the gateway to the AI provider:

```yaml
litellm_settings:
  callbacks: ["otel"]
  otel_exporter: "otlp"
  otel_endpoint: "http://otel-collector.observability.svc.cluster.local:4317"
```

OpenTelemetry traces can be exported to AWS X-Ray, Jaeger, or any OTLP-compatible backend. This is recommended for production deployments to enable full end-to-end request tracing.

## CloudWatch Alarms

Create alarms for key operational thresholds:

```bash
# High error rate alarm
aws cloudwatch put-metric-alarm \
  --alarm-name ai-gateway-high-error-rate \
  --metric-name 5xxErrorCount \
  --namespace AWS/ApplicationELB \
  --statistic Sum \
  --period 300 \
  --threshold 10 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2 \
  --alarm-actions arn:aws:sns:us-east-1:ACCOUNT_ID:ai-gateway-alerts
```

## See Also

- [12-cost-governance.md](12-cost-governance.md) — Token cost tracking and chargeback
- [91-troubleshooting.md](91-troubleshooting.md) — Operational runbook for common failures
- [docs/89-litellm-configuration-review.md](89-litellm-configuration-review.md) — LiteLLM configuration including callback stubs
