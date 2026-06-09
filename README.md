# Enterprise AI Gateway on AWS

Enterprise AI Gateway is a reference architecture that demonstrates how to build a centralized AI control plane on AWS using Amazon EKS, LiteLLM, Amazon Bedrock, and supporting AWS services.

The goal is simple:

**Applications should not call LLM providers directly.**

Instead:

```
Application → AI Gateway → Models
```

This approach enables:

- Multi-model access
- Governance
- Cost visibility
- Security controls
- Observability
- Vendor abstraction
- Enterprise scalability

---

## Why This Repository Exists

Over the last decade, enterprises learned that applications should not call microservices directly.

API Gateways emerged as the control plane for microservices.

Today, a similar pattern is emerging in Generative AI.

Many organizations are integrating directly with:

- OpenAI
- Anthropic Claude
- Google Gemini
- Amazon Bedrock
- Open-source models

Initially this works.

As adoption grows, organizations face new challenges:

- Which model should be used?
- How do we track AI costs?
- How do we enforce governance?
- How do we avoid vendor lock-in?
- How do we observe AI traffic?

This repository demonstrates an Enterprise AI Gateway architecture that addresses these challenges.

---

## Architecture Overview

```
User
↓
API Gateway
↓
LiteLLM
↓
Amazon Bedrock / OpenAI / Anthropic / Gemini
```

Supporting Services:

- Amazon EKS
- AWS Secrets Manager
- Amazon CloudWatch
- Application Load Balancer
- AWS WAF
- Amazon CloudFront

---

## Repository Structure

```
docs/
  01-architecture.md
  02-prerequisites.md
  03-create-eks.md
  04-install-litellm.md
  05-bedrock-integration.md
  06-api-gateway.md
  07-enterprise-architecture-review.md
  08-secrets-manager.md
  09-openai-integration.md
  10-multi-model-routing.md
  11-observability.md
  12-cost-governance.md
  13-rag-architecture.md
  14-agentic-ai.md
  90-testing.md
  91-troubleshooting.md

kubernetes/
  deployment.yaml
  service.yaml
  namespace.yaml
  ingress.yaml

litellm/
  config.yaml
  secrets-example.yaml
```

---

## Learning Path

New to AI Gateways? Read in this order:

1. [Architecture](docs/01-architecture.md)
2. [Prerequisites](docs/02-prerequisites.md)
3. [EKS Setup](docs/03-create-eks.md)
4. [LiteLLM Installation](docs/04-install-litellm.md)
5. [Bedrock Integration](docs/05-bedrock-integration.md)
6. [API Gateway](docs/06-api-gateway.md)
7. [Secrets Manager](docs/08-secrets-manager.md)
8. [Multi-Model Routing](docs/10-multi-model-routing.md)
9. [Observability](docs/11-observability.md)
10. [Cost Governance](docs/12-cost-governance.md)
11. [RAG Architecture](docs/13-rag-architecture.md)
12. [Agentic AI](docs/14-agentic-ai.md)

---

## Key Technologies

| Category | Technology |
|----------|-----------|
| Compute | Amazon EKS |
| AI Gateway | LiteLLM |
| AI Models | Amazon Bedrock, OpenAI, Anthropic Claude |
| Secrets | AWS Secrets Manager |
| Observability | Amazon CloudWatch |
| Networking | Application Load Balancer, AWS WAF |
| Orchestration | Kubernetes |

---

## Roadmap

| Phase | Focus |
|-------|-------|
| Phase 1 | Architecture Foundation |
| Phase 2 | Enterprise Operations |
| Phase 3 | Security and Governance |
| Phase 4 | Multi-Model AI Platform |

---

## Status

| Item | Status |
|------|--------|
| Documentation | Complete |
| Deployment | In Progress |
| Production Readiness | Educational Reference Architecture |

---

## License

MIT License
