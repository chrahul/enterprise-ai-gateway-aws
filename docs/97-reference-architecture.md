# Reference Architecture

This document defines the target architecture for the Enterprise AI Gateway on AWS. It is the authoritative reference for how AI model access is structured, secured, governed, and observed across the enterprise.

The architecture is built around a single principle: **applications do not call AI models directly**. All AI inference requests flow through a centralized gateway that enforces governance, provides observability, and abstracts provider-specific details from consuming applications.

This document is intended for enterprise architects, cloud architects, platform engineers, AI engineers, and technology leaders evaluating or implementing this pattern.

---

## Architecture Objectives

The architecture is designed to satisfy the following objectives:

| Objective | Description |
|-----------|-------------|
| **Centralized AI access** | All AI inference requests from all applications flow through a single, governed control plane |
| **Multi-model support** | The gateway routes requests to multiple AI providers and models without requiring application changes |
| **Governance** | Model access policies, rate limits, and usage controls are applied centrally and consistently |
| **Security** | Credentials are never distributed to applications; access is controlled via IAM and encrypted secrets |
| **Observability** | All AI traffic is instrumented — latency, token consumption, error rates, and cost attribution are visible in real time |
| **Cost control** | Token usage is tracked per application, per model, and per team; cost attribution dashboards are derived from gateway telemetry |
| **Future extensibility** | The architecture accommodates new providers, advanced observability platforms, agentic patterns, and multi-region deployment without redesign |

---

## Logical Architecture

The architecture is organized into four layers: edge, compute, AI providers, and platform services.

```
┌─────────────────────────────────────────────────────────┐
│                      Consumers                          │
│         Web Applications  ·  APIs  ·  Services          │
└──────────────────────┬──────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────┐
│                    Edge Layer                           │
│                                                         │
│   Amazon CloudFront                                     │
│   ↓ Global CDN, TLS termination, edge caching          │
│                                                         │
│   AWS WAF                                               │
│   ↓ DDoS protection, IP filtering, rule enforcement    │
│                                                         │
│   Application Load Balancer                             │
│   ↓ HTTP/HTTPS routing, health checks, cross-AZ        │
│                                                         │
│   Amazon API Gateway                                    │
│   ↓ Rate limiting, authentication, throttling          │
└──────────────────────┬──────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────┐
│                   Compute Layer                         │
│                Amazon EKS Cluster                       │
│                                                         │
│   Namespace: ai-gateway                                 │
│   ┌─────────────────────────────────────┐               │
│   │  LiteLLM Proxy (Horizontally Scaled)│               │
│   │  - OpenAI-compatible API surface    │               │
│   │  - Multi-model routing engine       │               │
│   │  - Provider abstraction layer       │               │
│   │  - Token usage instrumentation      │               │
│   └─────────────────────────────────────┘               │
└──────────────────────┬──────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────┐
│                  AI Provider Layer                      │
│                                                         │
│   Amazon Bedrock          OpenAI          Anthropic     │
│   Claude · Titan          GPT-4o          Claude 3      │
│   Llama · Mistral         GPT-4           Sonnet/Opus   │
│                                                         │
└─────────────────────────────────────────────────────────┘

Supporting Services (operate alongside all layers):

   AWS Secrets Manager  ·  Amazon CloudWatch  ·  AWS IAM
```

---

## Request Flow

The following describes the complete lifecycle of an AI inference request through the architecture.

**Step 1 — Consumer sends request**
An application, service, or API sends an HTTP request to the gateway endpoint using the OpenAI-compatible API format. The application has no knowledge of which AI provider or model will fulfill the request.

**Step 2 — CloudFront processes request**
Amazon CloudFront receives the request at the nearest edge location. TLS is terminated at the edge. CloudFront forwards the request to the AWS WAF origin.

**Step 3 — WAF evaluates policies**
AWS WAF inspects the request against configured rule sets. Requests matching block rules (IP blocklists, rate violation thresholds, known attack patterns) are rejected at this layer before reaching application infrastructure.

**Step 4 — ALB routes traffic**
The Application Load Balancer receives the forwarded request and routes it to a healthy EKS pod based on configured listener rules. Cross-AZ load balancing ensures traffic is distributed across availability zones.

**Step 5 — API Gateway enforces controls**
Amazon API Gateway applies rate limiting, throttling, and authentication checks. Requests exceeding configured thresholds are rejected with appropriate HTTP status codes.

**Step 6 — LiteLLM receives request**
The LiteLLM proxy pod receives the normalized request. LiteLLM evaluates the configured routing policy to determine the target provider and model based on the requested model alias, current availability, and routing strategy (round-robin, fallback, or least-latency).

**Step 7 — Credentials retrieved**
LiteLLM retrieves provider credentials from AWS Secrets Manager at runtime using its IRSA-assigned IAM role. For Amazon Bedrock, authentication is handled directly via IAM — no credentials are retrieved.

**Step 8 — Request forwarded to provider**
LiteLLM translates the request into the provider-specific format and forwards it to the selected AI provider. For Bedrock, the request travels within the AWS network boundary. For external providers (OpenAI, Anthropic), the request traverses TLS-encrypted outbound connections.

**Step 9 — Response returned**
The provider returns the inference response to LiteLLM. LiteLLM normalizes the response to the OpenAI format, emits token usage metrics and structured logs to CloudWatch, and returns the response to the consuming application through the same network path.

---

## Security Architecture

Security is applied at every layer of the architecture. No single control is relied upon exclusively.

### Identity and Access Management

- **IRSA (IAM Roles for Service Accounts)** — The LiteLLM pod is assigned a Kubernetes service account bound to an IAM role via IRSA. This role grants least-privilege access to Amazon Bedrock and AWS Secrets Manager. No static AWS credentials are used.
- **IAM policies** — Bedrock model access is controlled by IAM resource policies. Access to specific model families can be granted or revoked per role.
- **Kubernetes RBAC** — Pod-level access within the EKS cluster is governed by Kubernetes RBAC. The LiteLLM service account has no unnecessary cluster-wide permissions.

### Secrets Management

- All third-party API keys (OpenAI, Anthropic) are stored in AWS Secrets Manager, encrypted at rest using AWS KMS.
- Secrets are accessed at pod startup via the AWS Secrets Manager CSI driver or at runtime via the AWS SDK. Secrets are never stored in environment variables committed to source control or baked into container images.
- Secret access is logged to AWS CloudTrail, providing a complete audit trail of credential retrieval.

### Transport Security

- All external traffic is TLS-encrypted. CloudFront terminates TLS at the edge using ACM-managed certificates.
- Internal traffic within the VPC uses private load balancer targets. The EKS API server is accessible only within the VPC network boundary.
- Outbound connections to external AI providers (OpenAI, Anthropic) use HTTPS with certificate validation enforced by LiteLLM.

### Edge Protection

- **AWS WAF** enforces IP allowlisting, geographic restrictions, rate-based rules, and managed rule groups (AWS Managed Rules for known threat patterns).
- **CloudFront** provides DDoS protection via AWS Shield Standard, absorbing volumetric attack traffic at the edge before it reaches the application layer.

---

## Observability Architecture

Observability is not optional in this architecture. Every AI request is instrumented, and the resulting telemetry supports operational monitoring, incident response, and cost governance.

### Logs

LiteLLM emits structured JSON logs for every request, including:
- Timestamp and request identifier
- Consumer identifier (API key or service identity)
- Requested model alias and resolved provider/model
- Request and response token counts
- Latency (time to first token, total response time)
- HTTP status code and error classification

Logs are forwarded to Amazon CloudWatch Logs via the Fluent Bit DaemonSet deployed on each EKS node.

### Metrics

LiteLLM emits custom CloudWatch metrics including:
- `litellm.requests.total` — total request count by model and status
- `litellm.tokens.input` — input token consumption by model and consumer
- `litellm.tokens.output` — output token consumption by model and consumer
- `litellm.latency.p50/p95/p99` — request latency percentiles by model

EKS Container Insights provides cluster-level infrastructure metrics (CPU utilization, memory utilization, network throughput, pod count).

### Monitoring and Alerting

CloudWatch dashboards aggregate gateway telemetry into operational views:
- **Traffic dashboard** — requests per minute, error rate, latency by model
- **Cost dashboard** — token consumption and estimated cost by model, application, and team
- **Health dashboard** — pod availability, HPA scaling events, provider error rates

CloudWatch Alarms trigger on:
- Error rate exceeding threshold (e.g., >5% 5xx responses over 5 minutes)
- Latency exceeding SLA threshold
- Provider availability degradation
- Unusual token consumption spikes

---

## Future Evolution

The architecture is designed to evolve without requiring a fundamental redesign. The following extensions are planned across future roadmap phases.

### Advanced Observability (Phase 4)

**Langfuse** — LLM-specific observability platform providing trace-level visibility into prompt inputs, model outputs, latency breakdowns, and evaluation scores. LiteLLM has native Langfuse integration via callback configuration.

**OpenTelemetry** — Standardized telemetry collection replacing or augmenting CloudWatch. OpenTelemetry traces provide distributed tracing across the full request path from consumer to provider, enabling root cause analysis of latency issues.

### Agentic Platform (Phase 5)

**Model Context Protocol (MCP)** — MCP provides a standardized interface for exposing tools and resources to AI agents. The gateway will be extended to support MCP server endpoints, allowing agents to access enterprise data sources and APIs through the same governed control plane.

**Agent Orchestration** — Multi-step agentic workflows require the gateway to manage session context, tool call routing, and human-in-the-loop interruption points. The architecture extends to support long-lived agent sessions alongside stateless inference requests.

### Multi-Region Deployment

The architecture is deployable in multiple AWS regions with Route 53 latency-based routing directing consumers to the nearest gateway instance. Regional deployments share a common configuration baseline with region-specific model availability adjustments.

Global CloudFront distributions provide consistent edge behavior across regions. Secrets Manager replication supports cross-region credential availability.

---

## Architecture Principles

The following principles govern all design and implementation decisions in this architecture. They are not guidelines — they are constraints. Deviations require explicit justification documented in an Architecture Decision Record.

1. **Applications never call AI models directly.**
All inference requests flow through the gateway. There are no approved exceptions. Direct provider integrations create governance blind spots, credential exposure risks, and cost attribution gaps that the gateway exists to eliminate.

2. **Credentials never reside in application code or configuration files.**
API keys, tokens, and secrets are stored in AWS Secrets Manager and injected at runtime. No credential material appears in source control, container images, or Kubernetes manifests.

3. **Observability is mandatory, not optional.**
Every AI request is logged and metered. Operational decisions — scaling, cost attribution, incident response — are made from gateway telemetry. Systems that cannot be observed cannot be operated reliably.

4. **The gateway is the single control point for AI governance.**
Rate limits, model access policies, consumer attribution, and cost controls are applied at the gateway layer. Governance logic is not distributed across individual applications.

5. **Multi-model support is a design requirement, not an afterthought.**
The architecture assumes multiple providers and models from the outset. Provider lock-in is an organizational risk. The abstraction layer exists specifically to preserve optionality.

6. **Security is applied in depth.**
No single security control is relied upon exclusively. Edge (WAF), transport (TLS), identity (IAM/IRSA), and secrets (Secrets Manager) controls operate independently. The failure of any single control does not compromise the security posture of the system.

7. **The architecture scales horizontally.**
Gateway capacity scales through pod replication governed by the Horizontal Pod Autoscaler. No component in the critical path is a fixed-size single instance.

8. **Configuration changes do not require application code changes.**
Adding a new model, changing a routing policy, or swapping a provider is a gateway configuration change. Consumer applications are unaffected.

9. **Architecture decisions are documented.**
Significant design choices are recorded in Architecture Decision Records (see [98-architecture-decisions.md](98-architecture-decisions.md)). Future engineers must be able to understand why the system was built the way it was, not just how it works.

10. **The architecture evolves through phases, not rewrites.**
Each roadmap phase builds on the previous one. The gateway remains the central control point through all phases. Agentic capabilities, advanced observability, and multi-region deployments extend the architecture without replacing its foundation.
