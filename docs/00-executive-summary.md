# Executive Summary

This repository defines a reference architecture for an **Enterprise AI Gateway** — a centralized control plane that governs all AI model access within an organization.

The architecture is built on Amazon EKS, LiteLLM, and Amazon Bedrock, with integration support for OpenAI and Anthropic Claude. It is designed for organizations that are moving beyond individual AI integrations toward a managed, observable, and governed AI platform.

This document provides a 5-minute overview intended for technical leadership, enterprise architects, and platform strategy teams.

---

## The Problem

As generative AI adoption accelerates, most organizations begin by integrating AI providers directly into individual applications. This approach is fast to start but creates compounding risks at enterprise scale.

### Vendor Lock-In

Each application encodes direct dependencies on a specific provider — OpenAI, Anthropic, Google Gemini, or Amazon Bedrock. When provider capabilities, pricing, or availability change, engineering teams must update every application independently. There is no abstraction layer.

### Cost Visibility

AI inference costs are incurred per token, per model, per request. Without a central gateway, cost attribution is impossible. Finance and engineering leadership cannot answer basic questions: which applications are consuming the most tokens? Which models are most cost-effective? Where is spend growing?

### Governance Challenges

Without a control plane, there are no enforceable policies for which teams can access which models. There is no mechanism to restrict model usage, enforce prompt safety standards, or implement access controls aligned with enterprise security policy.

### Security Concerns

API keys and credentials for third-party AI providers are distributed across application codebases, environment variables, and CI/CD pipelines. There is no centralized rotation, no audit trail, and no single place to revoke access in a security incident.

### Operational Complexity

Each application manages its own retry logic, timeout handling, error classification, and observability instrumentation. There is no unified view of AI traffic health. Incidents are detected late and diagnosed slowly.

---

## The Architectural Shift

The pattern emerging in enterprise AI mirrors a well-established architectural evolution.

```
Monolith
    ↓
Microservices
    Application services decomposed by domain.
    ↓
API Gateway
    A centralized control plane for service-to-service and
    client-to-service communication. Governance, routing,
    and observability moved out of individual services.
    ↓
AI Gateway
    A centralized control plane for all AI model access.
    Applications do not call providers directly.
    Governance, routing, cost attribution, and observability
    are managed at the gateway layer.
```

The AI Gateway is not a new concept — it is the application of a proven enterprise pattern to a new domain.

**The principle is simple:**

> Applications should not call AI providers directly.
> `Application → AI Gateway → Models`

---

## Reference Architecture

The reference architecture is deployed on AWS and organized into four layers.

### Edge Layer

| Component | Role |
|-----------|------|
| **Amazon CloudFront** | Global content delivery, TLS termination, and edge caching. Reduces latency for geographically distributed consumers. |
| **AWS WAF** | Web Application Firewall. Enforces IP allowlisting, rate limiting, and DDoS protection before traffic reaches the application layer. |
| **Application Load Balancer** | Layer 7 HTTP routing into the EKS cluster. Provides health-check-based traffic management and cross-AZ load distribution. |

### Compute Layer

| Component | Role |
|-----------|------|
| **Amazon EKS** | Managed Kubernetes. Hosts all gateway workloads with production-grade scheduling, scaling, and isolation. |
| **LiteLLM** | Open-source AI proxy. Provides a unified OpenAI-compatible API surface across all providers. Handles model routing, fallback, and request normalization. Applications send one API format regardless of backend provider. |

### AI Providers

| Provider | Access Method |
|----------|--------------|
| **Amazon Bedrock** | IAM-authenticated via IRSA (IAM Roles for Service Accounts). No static credentials required. |
| **OpenAI / Anthropic Claude** | API keys stored in AWS Secrets Manager, injected at runtime. |

### Platform Services

| Component | Role |
|-----------|------|
| **AWS Secrets Manager** | Centralized credential storage for third-party API keys. Supports automatic rotation and audit logging. |
| **Amazon CloudWatch** | Receives structured logs and token-level metrics from LiteLLM. Provides dashboards, alarms, and cost attribution data. |

---

## Business Outcomes

Deploying an Enterprise AI Gateway delivers measurable outcomes across engineering, finance, and risk.

**Centralized Governance**
All AI traffic flows through a single control point. Model access policies are enforced at the gateway, not within individual applications. Changes to governance rules take effect immediately across the entire estate.

**Multi-Model Strategy**
The organization is not locked to a single AI provider. LiteLLM routes requests to the appropriate model based on capability, cost, and availability. Providers can be added, swapped, or deprecated without application code changes.

**Cost Control**
Every request is instrumented with token counts, model identifiers, and consumer attribution. Cost dashboards are derived from gateway telemetry. Engineering and finance leadership have a real-time view of AI spend by application, team, and model.

**Observability**
Latency, error rates, token throughput, and provider availability are monitored at the gateway layer. Incidents are detected centrally. Runbooks address gateway-level failures, not individual application failures.

**Enterprise Scalability**
The gateway scales horizontally via Kubernetes Horizontal Pod Autoscaler. New AI applications are onboarded by configuring a routing entry — not by distributing credentials or duplicating infrastructure.

---

## Who Should Read This Repository

This repository is structured for technical practitioners and technology leaders at different levels of engagement.

| Audience | Recommended Entry Point |
|----------|------------------------|
| **CTO / VP Engineering** | This document. [Roadmap](99-roadmap.md). |
| **Enterprise Architect / Cloud Architect** | [Architecture Overview](01-architecture.md). [Enterprise Architecture Review](07-enterprise-architecture-review.md). |
| **Platform Engineering Teams** | [EKS Setup](03-create-eks.md). [LiteLLM Installation](04-install-litellm.md). [Secrets Manager](08-secrets-manager.md). |
| **DevOps / SRE** | [Observability](11-observability.md). [Cost Governance](12-cost-governance.md). [Troubleshooting](91-troubleshooting.md). |
| **AI / ML Engineers** | [Bedrock Integration](05-bedrock-integration.md). [Multi-Model Routing](10-multi-model-routing.md). [RAG Architecture](13-rag-architecture.md). [Agentic AI](14-agentic-ai.md). |

For a guided reading path, see [Learning Path](00-learning-path.md).
