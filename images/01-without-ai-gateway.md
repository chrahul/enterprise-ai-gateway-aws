# Diagram: AI Integration Without a Gateway

This diagram illustrates the anti-pattern — applications calling AI providers directly.

Each application manages its own credentials, handles its own retry logic, implements its own cost tracking, and is tightly coupled to a specific provider. This approach does not scale in an enterprise environment.

```mermaid
graph TD
    subgraph Applications
        A1[Web Application]
        A2[Mobile Backend]
        A3[Internal Tool]
        A4[Data Pipeline]
        A5[Analytics Service]
    end

    subgraph AI Providers
        P1[Amazon Bedrock]
        P2[OpenAI]
        P3[Anthropic Claude]
        P4[Google Gemini]
    end

    A1 -->|Direct API Call| P1
    A1 -->|Direct API Call| P2
    A2 -->|Direct API Call| P2
    A2 -->|Direct API Call| P3
    A3 -->|Direct API Call| P1
    A3 -->|Direct API Call| P3
    A4 -->|Direct API Call| P4
    A5 -->|Direct API Call| P1
    A5 -->|Direct API Call| P2

    style A1 fill:#ff9999,stroke:#cc0000
    style A2 fill:#ff9999,stroke:#cc0000
    style A3 fill:#ff9999,stroke:#cc0000
    style A4 fill:#ff9999,stroke:#cc0000
    style A5 fill:#ff9999,stroke:#cc0000
    style P1 fill:#ffcc99,stroke:#cc6600
    style P2 fill:#ffcc99,stroke:#cc6600
    style P3 fill:#ffcc99,stroke:#cc6600
    style P4 fill:#ffcc99,stroke:#cc6600
```

## Problems With This Pattern

| Problem | Impact |
|---------|--------|
| Credentials scattered across all applications | Security risk — no central rotation or audit |
| No unified cost tracking | AI spend is invisible until the bill arrives |
| No governance | Any application can call any model with no controls |
| Tight vendor coupling | Switching providers requires changes in every application |
| No observability | No unified view of AI traffic, latency, or errors |
| Duplicated retry and error handling | Inconsistent behavior across the estate |
| No rate limiting | A single rogue application can exhaust quotas |

## Next

See [02-with-ai-gateway.md](02-with-ai-gateway.md) for the corrected architecture.
