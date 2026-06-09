# Diagram: AI Integration With a Gateway

This diagram illustrates the correct enterprise pattern — all applications route AI requests through a centralized AI Gateway.

The gateway is the single control point for model access, governance, cost attribution, and observability. Applications are decoupled from providers and are not aware of which model fulfills their request.

```mermaid
graph TD
    subgraph Applications
        A1[Web Application]
        A2[Mobile Backend]
        A3[Internal Tool]
        A4[Data Pipeline]
        A5[Analytics Service]
    end

    GW[AI Gateway\nLiteLLM on EKS]

    subgraph AI Providers
        P1[Amazon Bedrock]
        P2[OpenAI]
        P3[Anthropic Claude]
        P4[Google Gemini]
    end

    subgraph Platform Services
        SM[AWS Secrets Manager]
        CW[Amazon CloudWatch]
    end

    A1 -->|Unified API| GW
    A2 -->|Unified API| GW
    A3 -->|Unified API| GW
    A4 -->|Unified API| GW
    A5 -->|Unified API| GW

    GW -->|Model Routing| P1
    GW -->|Model Routing| P2
    GW -->|Model Routing| P3
    GW -->|Model Routing| P4

    GW -.->|Credentials| SM
    GW -.->|Metrics & Logs| CW

    style GW fill:#4CAF50,stroke:#2E7D32,color:#fff
    style A1 fill:#90CAF9,stroke:#1565C0
    style A2 fill:#90CAF9,stroke:#1565C0
    style A3 fill:#90CAF9,stroke:#1565C0
    style A4 fill:#90CAF9,stroke:#1565C0
    style A5 fill:#90CAF9,stroke:#1565C0
    style P1 fill:#FFB74D,stroke:#E65100
    style P2 fill:#FFB74D,stroke:#E65100
    style P3 fill:#FFB74D,stroke:#E65100
    style P4 fill:#FFB74D,stroke:#E65100
    style SM fill:#CE93D8,stroke:#6A1B9A
    style CW fill:#CE93D8,stroke:#6A1B9A
```

## Benefits of This Pattern

| Capability | How the Gateway Provides It |
|------------|----------------------------|
| Unified API | Applications use a single OpenAI-compatible endpoint |
| Credential management | Secrets stored centrally in AWS Secrets Manager |
| Cost attribution | Token usage tracked per application, per model |
| Governance | Model access controlled by routing policy |
| Observability | All traffic flows through a single observable layer |
| Vendor abstraction | Swap providers without changing application code |
| Rate limiting | Enforced at the gateway, not per application |

## Next

See [03-enterprise-ai-gateway-architecture.md](03-enterprise-ai-gateway-architecture.md) for the full production architecture.
