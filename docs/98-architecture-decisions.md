# Architecture Decision Records (ADR)

Architecture Decision Records document the significant technical decisions made during the design and implementation of the Enterprise AI Gateway. Each record captures the context, the decision, the alternatives that were considered, and the reasoning that led to the chosen approach.

ADRs serve as institutional memory. They answer the question: *why was this built this way?* Without them, the rationale behind architectural choices is lost as teams change, and future engineers are left to reverse-engineer intent from implementation.

Each ADR has a status: **Accepted** (in force), **Superseded** (replaced by a later decision), or **Proposed** (under review).

---

## ADR-001: Use Amazon EKS as the Orchestration Platform

**Status:** Accepted

### Context

The Enterprise AI Gateway requires a reliable, scalable platform to host the LiteLLM proxy and associated workloads. The platform must support production-grade scheduling, horizontal scaling, health management, and integration with AWS identity and networking primitives.

### Decision

Use **Amazon Elastic Kubernetes Service (EKS)** as the compute and orchestration platform.

### Alternatives Considered

| Alternative | Assessment |
|-------------|------------|
| **Amazon ECS** | AWS-native, simpler operational model. However, tightly coupled to AWS primitives — workloads are not portable to other environments. The Kubernetes ecosystem of tooling, operators, and integrations is not available. |
| **Amazon EC2 (unmanaged)** | Maximum control, but significant operational burden. Requires manual patching, scaling, health management, and network configuration. Not appropriate for a reference architecture intended to demonstrate enterprise practices. |
| **Self-managed Kubernetes on EC2** | Full control of Kubernetes configuration, but adds control plane management overhead with no corresponding benefit over EKS for this use case. |

### Decision Drivers

- **Portability** — Kubernetes workloads are portable. The gateway deployment manifests can be adapted for other Kubernetes distributions (GKE, AKS, on-premises) without fundamental redesign.
- **Kubernetes ecosystem** — Helm, Horizontal Pod Autoscaler, pod-level IAM via IRSA, and the broader CNCF tooling ecosystem are available out of the box.
- **Enterprise adoption** — Kubernetes is the de facto standard for enterprise container orchestration. Platform teams in enterprise organizations are already familiar with Kubernetes operational patterns.
- **AWS integration** — EKS provides native integration with IAM, VPC networking, ALB, and CloudWatch, reducing the integration burden for AWS-native deployments.

---

## ADR-002: Use LiteLLM as the AI Proxy Layer

**Status:** Accepted

### Context

The gateway requires a component that accepts AI inference requests and routes them to the appropriate upstream provider. This component must normalize the request format across providers and abstract provider-specific implementation details from consuming applications.

### Decision

Use **LiteLLM** as the proxy and model routing layer.

### Alternatives Considered

| Alternative | Assessment |
|-------------|------------|
| **Direct OpenAI SDK integration** | Simple for a single provider. Does not support multi-model routing. Every additional provider requires custom integration code. Applications become provider-aware. |
| **Direct Amazon Bedrock SDK integration** | Appropriate for AWS-only deployments. Does not provide an OpenAI-compatible API surface. Applications must use the Bedrock SDK format, preventing provider abstraction. |
| **Custom proxy implementation** | Maximum control, but high development and maintenance cost. LiteLLM is a mature open-source project with active development and broad provider support. Building an equivalent from scratch is not justified. |

### Decision Drivers

- **Provider abstraction** — LiteLLM exposes a single OpenAI-compatible API regardless of the backend provider. Applications send requests in one format and are never aware of which model fulfills the request.
- **Multi-model routing** — LiteLLM supports routing logic including round-robin, fallback, and least-latency strategies across multiple models and providers in a single configuration file.
- **Future extensibility** — New providers can be added by updating the LiteLLM configuration. No application code changes are required when adding, swapping, or deprecating a model.
- **Active ecosystem** — LiteLLM supports over 100 LLM providers and receives regular updates as the AI provider landscape evolves.

---

## ADR-003: Use Amazon Bedrock as the Primary AI Provider

**Status:** Accepted

### Context

The gateway must connect to one or more AI providers for model inference. The primary provider should align with the AWS infrastructure context of this architecture, minimize credential management overhead, and provide access to leading foundation models.

### Decision

Use **Amazon Bedrock** as the primary AI provider, with OpenAI and Anthropic Claude available as secondary providers through LiteLLM.

### Alternatives Considered

| Alternative | Assessment |
|-------------|------------|
| **Direct Anthropic API** | Requires API key management and outbound internet connectivity. Claude models are available through Bedrock, which removes the need for a separate Anthropic integration in AWS-centric deployments. |
| **Direct OpenAI API** | Requires API key management. OpenAI models are not available through Bedrock. Included as a secondary provider to demonstrate multi-model routing and non-AWS model access patterns. |
| **Open-source models on EKS** | Possible and addressed in the roadmap (Phase 4). Requires significant GPU infrastructure investment and model serving complexity not appropriate for a Phase 1 reference architecture. |

### Decision Drivers

- **AWS integration** — Bedrock operates within the AWS network boundary. Requests to Bedrock from EKS do not traverse the public internet, reducing latency and eliminating the need for outbound firewall rules.
- **Security** — Bedrock access is authenticated via IAM using IRSA (IAM Roles for Service Accounts). No static API keys are required, eliminating an entire class of credential management risk.
- **Governance** — Bedrock usage is subject to AWS CloudTrail, service control policies, and IAM permission boundaries — the same governance primitives that apply to the rest of the AWS estate.
- **Model breadth** — Bedrock provides access to multiple foundation model families (Claude, Titan, Llama, Mistral) through a single integration point.

---

## ADR-004: Use the AI Gateway Pattern

**Status:** Accepted

### Context

As generative AI adoption grows across an organization, applications begin integrating directly with AI providers. Each application manages its own credentials, implements its own retry logic, and is coupled to a specific provider API. This creates a distributed, ungoverned, and unobservable AI integration surface.

### Decision

Enforce the **AI Gateway pattern**: all AI inference requests from applications must flow through the centralized gateway.

```
Application → AI Gateway → AI Provider
```

Not:

```
Application → AI Provider (direct)
```

### Decision Drivers

- **Single control point** — Governance policies, rate limits, and access controls are applied once at the gateway and take effect across all consuming applications immediately.
- **Credential isolation** — Applications never hold AI provider credentials. Credential management, rotation, and revocation are handled at the gateway layer.
- **Cost attribution** — All token consumption is instrumented at the gateway. Cost dashboards are derived from gateway telemetry, not from individual application instrumentation.
- **Vendor abstraction** — Applications are decoupled from provider-specific APIs. The organization can switch providers, add new models, or change routing logic without modifying application code.
- **Observability** — All AI traffic is observable at a single layer. Latency, error rates, and token throughput are monitored centrally.

### Consequences

Applications must be configured to call the gateway endpoint rather than provider endpoints directly. This is enforced through network policy and is a deliberate constraint of the architecture.

---

## ADR-005: Use AWS Secrets Manager for Credential Management

**Status:** Accepted

### Context

The gateway requires credentials to authenticate with third-party AI providers (OpenAI, Anthropic). These credentials must not be stored in application configuration files, environment variable manifests committed to source control, or container images.

### Decision

Store all AI provider credentials in **AWS Secrets Manager** and inject them into the LiteLLM pod at runtime via Kubernetes secret synchronization.

### Alternatives Considered

| Alternative | Assessment |
|-------------|------------|
| **Kubernetes Secrets (unencrypted)** | Base64-encoded by default, not encrypted at rest unless EKS envelope encryption is enabled. Does not provide rotation, audit logging, or centralized visibility. |
| **Environment variables in deployment manifests** | Credentials visible in source control or Kubernetes API. No rotation support. Fails basic security requirements. |
| **HashiCorp Vault** | Strong credential management capability, but introduces additional infrastructure and operational complexity not justified when AWS Secrets Manager is available natively. |

### Decision Drivers

- **Encryption at rest** — Secrets Manager encrypts all secrets using AWS KMS by default.
- **Audit logging** — All secret access is logged to AWS CloudTrail, providing a complete audit trail of when credentials were accessed and by which identity.
- **Rotation support** — Secrets Manager supports automatic rotation policies, reducing the operational burden of manual credential rotation.
- **IAM integration** — Access to secrets is controlled by IAM policies, consistent with the rest of the AWS security model. The LiteLLM pod accesses secrets using its IRSA role, not a static service account key.

---

## ADR-006: Use Amazon CloudWatch for Observability

**Status:** Accepted

### Context

The gateway must emit logs and metrics to support operational monitoring, incident response, and cost attribution. The observability platform must be accessible to platform teams operating within the AWS environment.

### Decision

Use **Amazon CloudWatch** as the primary observability platform, receiving structured logs and token-level metrics from LiteLLM.

### Alternatives Considered

| Alternative | Assessment |
|-------------|------------|
| **Prometheus + Grafana** | Industry-standard Kubernetes observability stack. Strong dashboarding capability. Adds infrastructure components (Prometheus server, Grafana, persistence) that are not justified for a Phase 1 reference architecture. Appropriate for Phase 4 (see roadmap). |
| **Datadog / New Relic** | Commercial platforms with strong AI observability features. Appropriate for organizations with existing licensing. Introduces external dependencies not aligned with an AWS-native reference architecture. |
| **ELK Stack** | Powerful log aggregation and search. Significant operational overhead. Not appropriate as a default choice for Phase 1. |

### Decision Drivers

- **AWS-native** — CloudWatch requires no additional infrastructure. Log groups, metric filters, alarms, and dashboards are available immediately.
- **EKS integration** — CloudWatch Container Insights provides cluster-level metrics (CPU, memory, network) alongside application logs with no additional configuration.
- **Cost attribution** — LiteLLM emits token counts per request. CloudWatch Metric Math can aggregate these into per-model, per-application cost dashboards.
- **Operational simplicity** — Platform teams already operating in AWS are familiar with CloudWatch. It does not require a separate observability platform to learn and operate.

---

## Future ADRs

The following decisions are anticipated as the project evolves through later roadmap phases. ADRs will be added as decisions are made.

| ID | Topic | Phase |
|----|-------|-------|
| ADR-007 | Authentication mechanism for gateway consumers (API keys vs JWT vs mTLS) | Phase 3 |
| ADR-008 | Multi-tenancy isolation strategy (namespace vs cluster vs configuration) | Phase 3 |
| ADR-009 | LLM observability platform (Langfuse vs OpenTelemetry vs custom) | Phase 4 |
| ADR-010 | Prompt versioning and management strategy | Phase 4 |
| ADR-011 | Agent orchestration framework selection | Phase 5 |
| ADR-012 | MCP server deployment and governance model | Phase 5 |
