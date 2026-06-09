# Learning Path

This document is the recommended starting point for anyone exploring the Enterprise AI Gateway on AWS repository.

The repository covers a range of topics — from foundational architecture concepts through to advanced enterprise AI patterns. Depending on your role and goals, different reading orders will be more effective. The tracks below are designed to help you navigate the content efficiently.

---

## Track 1 — Architecture First (Recommended)

> **Start here if you are new to AI Gateways or evaluating the architecture.**

These chapters establish the conceptual foundation before any implementation begins. Understanding the architecture and design decisions first will make every subsequent chapter easier to follow. This track is recommended for architects, technical leads, and anyone evaluating whether this pattern fits their organization.

| Chapter | Document |
|---------|----------|
| 01 | [Architecture Overview](01-architecture.md) |
| 02 | [Prerequisites](02-prerequisites.md) |
| 06 | [API Gateway](06-api-gateway.md) |
| 07 | [Enterprise Architecture Review](07-enterprise-architecture-review.md) |

---

## Track 2 — Deployment Path

> **Start here if you are ready to implement and want a hands-on walkthrough.**

These chapters focus on the practical steps required to deploy the gateway. They cover cluster provisioning, LiteLLM installation, Bedrock integration, and secrets management. This track is recommended for engineers who have already reviewed the architecture and are ready to build.

| Chapter | Document |
|---------|----------|
| 03 | [Create EKS Cluster](03-create-eks.md) |
| 04 | [Install LiteLLM](04-install-litellm.md) |
| 05 | [Bedrock Integration](05-bedrock-integration.md) |
| 08 | [Secrets Manager](08-secrets-manager.md) |

---

## Track 3 — Enterprise Operations

> **Start here if you are responsible for running the gateway in production.**

These chapters address the operational concerns that matter at enterprise scale — routing traffic across multiple models, observing system behavior, and managing AI costs. This track is recommended for platform engineers and SREs taking ownership of a deployed gateway.

| Chapter | Document |
|---------|----------|
| 10 | [Multi-Model Routing](10-multi-model-routing.md) |
| 11 | [Observability](11-observability.md) |
| 12 | [Cost Governance](12-cost-governance.md) |

---

## Track 4 — Advanced AI

> **Start here if you are extending the gateway with advanced AI capabilities.**

These chapters build directly on the gateway foundation. RAG architecture and agentic AI patterns require a working, governed gateway as their foundation. This track is recommended for teams moving beyond basic model access toward intelligent, autonomous AI systems.

| Chapter | Document |
|---------|----------|
| 13 | [RAG Architecture](13-rag-architecture.md) |
| 14 | [Agentic AI](14-agentic-ai.md) |

---

## Validation and Troubleshooting

These chapters support any track. Use them to verify your deployment and resolve issues as they arise.

| Chapter | Document |
|---------|----------|
| 90 | [Testing](90-testing.md) |
| 91 | [Troubleshooting](91-troubleshooting.md) |

---

## Recommended Reading Order

For readers who prefer a linear path through the complete repository, the following order is recommended:

1. [01 — Architecture Overview](01-architecture.md)
2. [02 — Prerequisites](02-prerequisites.md)
3. [03 — Create EKS Cluster](03-create-eks.md)
4. [04 — Install LiteLLM](04-install-litellm.md)
5. [05 — Bedrock Integration](05-bedrock-integration.md)
6. [06 — API Gateway](06-api-gateway.md)
7. [07 — Enterprise Architecture Review](07-enterprise-architecture-review.md)
8. [08 — Secrets Manager](08-secrets-manager.md)
9. [09 — OpenAI Integration](09-openai-integration.md)
10. [10 — Multi-Model Routing](10-multi-model-routing.md)
11. [11 — Observability](11-observability.md)
12. [12 — Cost Governance](12-cost-governance.md)
13. [13 — RAG Architecture](13-rag-architecture.md)
14. [14 — Agentic AI](14-agentic-ai.md)
