# Diagram: Enterprise AI Gateway — Reference Architecture

This diagram shows the complete production architecture for the Enterprise AI Gateway on AWS.

The architecture is organized into four layers: edge, compute, AI providers, and platform services. Each layer has a distinct responsibility. Traffic flows from users through the edge security layer, into the EKS compute layer where LiteLLM handles routing, and out to AI providers. Supporting services operate alongside the request path.

```mermaid
graph TD
    User([End User /\nApplication])

    subgraph Edge Layer
        CF[Amazon CloudFront\nGlobal CDN / TLS Termination]
        WAF[AWS WAF\nDDoS Protection / IP Filtering]
        ALB[Application Load Balancer\nHTTP Routing / Health Checks]
        APIGW[Amazon API Gateway\nRate Limiting / Auth / Throttling]
    end

    subgraph Compute Layer — Amazon EKS
        NS[Namespace: ai-gateway]
        LITELLM[LiteLLM Proxy\nModel Router / OpenAI-compatible API]
        HPA[Horizontal Pod Autoscaler]
        LITELLM --- HPA
    end

    subgraph AI Providers
        BEDROCK[Amazon Bedrock\nClaude / Titan / Llama]
        OPENAI[OpenAI\nGPT-4o / GPT-4]
        CLAUDE[Anthropic Claude\nClaude 3 Opus / Sonnet]
    end

    subgraph Platform Services
        SM[AWS Secrets Manager\nAPI Keys / Credentials]
        CW[Amazon CloudWatch\nLogs / Metrics / Alarms]
        IAM[AWS IAM\nIRSA / Pod Identity]
    end

    User --> CF
    CF --> WAF
    WAF --> ALB
    ALB --> APIGW
    APIGW --> NS
    NS --> LITELLM

    LITELLM -->|Bedrock SDK / IAM Auth| BEDROCK
    LITELLM -->|HTTPS / API Key| OPENAI
    LITELLM -->|HTTPS / API Key| CLAUDE

    LITELLM -.->|Secret Retrieval| SM
    LITELLM -.->|Emit Logs & Metrics| CW
    SM -.->|Credential Injection| LITELLM
    IAM -.->|IRSA / Pod Role| LITELLM

    style User fill:#E3F2FD,stroke:#1565C0
    style CF fill:#FFF9C4,stroke:#F9A825
    style WAF fill:#FFCCBC,stroke:#BF360C
    style ALB fill:#FFF9C4,stroke:#F9A825
    style APIGW fill:#FFF9C4,stroke:#F9A825
    style NS fill:#E8F5E9,stroke:#2E7D32
    style LITELLM fill:#4CAF50,stroke:#1B5E20,color:#fff
    style HPA fill:#C8E6C9,stroke:#2E7D32
    style BEDROCK fill:#FFB74D,stroke:#E65100
    style OPENAI fill:#FFB74D,stroke:#E65100
    style CLAUDE fill:#FFB74D,stroke:#E65100
    style SM fill:#CE93D8,stroke:#6A1B9A
    style CW fill:#CE93D8,stroke:#6A1B9A
    style IAM fill:#CE93D8,stroke:#6A1B9A
```

## Architecture Layer Summary

| Layer | Components | Responsibility |
|-------|-----------|----------------|
| Edge | CloudFront, WAF, ALB, API Gateway | TLS termination, DDoS protection, rate limiting, routing |
| Compute | Amazon EKS, LiteLLM, HPA | Model routing, API normalization, horizontal scaling |
| AI Providers | Amazon Bedrock, OpenAI, Anthropic | LLM inference |
| Platform | Secrets Manager, CloudWatch, IAM | Credentials, observability, identity |

## Request Flow

```
User Request
    → CloudFront (TLS, global edge caching)
    → AWS WAF (threat filtering, IP rules)
    → Application Load Balancer (HTTP routing)
    → API Gateway (rate limiting, auth enforcement)
    → LiteLLM on EKS (model routing, request normalization)
    → AI Provider (inference)
    ← Response returned through the same path
```

## Key Design Decisions

- **LiteLLM** provides an OpenAI-compatible API surface — applications do not need provider-specific SDKs
- **IRSA (IAM Roles for Service Accounts)** gives the LiteLLM pod direct IAM-authenticated access to Amazon Bedrock without storing AWS credentials
- **AWS Secrets Manager** stores third-party API keys (OpenAI, Anthropic) and injects them at runtime
- **CloudWatch** receives structured logs and token-level metrics from LiteLLM for cost and observability dashboards
- **HPA** scales LiteLLM pods based on request load, ensuring the gateway does not become a bottleneck

## Related Documentation

- [Architecture Overview](../docs/01-architecture.md)
- [EKS Setup](../docs/03-create-eks.md)
- [LiteLLM Installation](../docs/04-install-litellm.md)
- [Bedrock Integration](../docs/05-bedrock-integration.md)
- [API Gateway](../docs/06-api-gateway.md)
- [Secrets Manager](../docs/08-secrets-manager.md)
- [Observability](../docs/11-observability.md)
