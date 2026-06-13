# Secrets Manager

> **This topic has been covered by two dedicated reference documents.**

The secrets management strategy and AWS Secrets Manager integration for this project have been documented in detail across two documents:

- **[94-secrets-management-strategy.md](94-secrets-management-strategy.md)** — Anti-patterns to avoid, the Secrets Manager strategy, secret hierarchy, rotation roadmap, and the operational workflow for keeping the Kubernetes Secret in sync with Secrets Manager.

- **[95-irsa-and-iam-design.md](95-irsa-and-iam-design.md)** — IRSA authentication flow, the IAM policy that grants LiteLLM pods permission to read from Secrets Manager, the trust relationship, and the deployment checklist for wiring IRSA to the EKS cluster.

## Quick Reference

| Secret | Location | Who reads it |
|---|---|---|
| `LITELLM_MASTER_KEY` | AWS Secrets Manager `ai-gateway-prod/litellm-secrets` | LiteLLM pods via IRSA |
| `OPENAI_API_KEY` | AWS Secrets Manager `ai-gateway-prod/litellm-secrets` | LiteLLM pods via IRSA |
| Langfuse keys | AWS Secrets Manager `ai-gateway-prod/litellm-secrets` | LiteLLM pods via IRSA |

See [litellm/secrets-example.yaml](../litellm/secrets-example.yaml) for the expected secret structure with placeholder values.
