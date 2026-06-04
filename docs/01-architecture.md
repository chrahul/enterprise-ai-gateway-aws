# Enterprise AI Gateway on AWS

## Overview

This project demonstrates how to build a production-grade Enterprise AI Gateway on AWS using Amazon EKS, LiteLLM, Amazon Bedrock and API Gateway.

Instead of allowing applications to connect directly to multiple Large Language Model (LLM) providers, a centralized AI Gateway is introduced to provide governance, security, observability and cost control.

The architecture follows the same design principles that transformed enterprise applications during the microservices revolution.

Applications interact with a single endpoint while the AI Gateway manages routing, authentication, failover and model selection behind the scenes.

## The Problem

In the old world, each application integrates directly with the model provider it needs.

```text
Application A --> OpenAI

Application B --> Anthropic

Application C --> Bedrock
```

At first, this looks simple. Each team chooses the model it wants, writes the integration, stores credentials and starts calling the provider directly.

But as usage grows across an enterprise, this pattern becomes difficult to govern. Every application now owns its own AI integration, security model, cost tracking approach and provider-specific logic.

### Challenges

- Vendor lock-in
- No centralized governance
- No visibility into AI costs
- Duplicate integrations
- Inconsistent security controls
- Difficult model switching
- No standard observability

## The AI Gateway Pattern

An AI Gateway introduces a centralized layer between applications and model providers.

```text
Applications
      |
      v
 AI Gateway
      |
      +---- OpenAI
      +---- Anthropic
      +---- Bedrock
      +---- Gemini
```

Applications call one standard endpoint. The AI Gateway handles provider routing, authentication, model selection, policy enforcement, logging, failover and usage tracking behind the scenes.

The AI Gateway becomes the control plane for enterprise AI consumption.

## API Gateway vs AI Gateway

| Microservices Era      | AI Era          |
| ---------------------- | --------------- |
| API Gateway            | LiteLLM Gateway |
| Login Service          | GPT             |
| Search Service         | Claude          |
| Billing Service        | Nova            |
| Recommendation Service | Gemini          |

API Gateway standardized access to services.

AI Gateway standardizes access to intelligence.

## Target Architecture

```text
User
 |
API Gateway
 |
LiteLLM
 |
Amazon Bedrock
 |
Claude
```

In this tutorial, the user sends a request to a public API endpoint.

API Gateway provides the front door for the system. It exposes a managed API endpoint and gives us a place to apply centralized access, throttling and request controls.

LiteLLM acts as the AI Gateway. It receives OpenAI-compatible requests from applications and routes them to the configured model provider.

Amazon Bedrock provides managed access to foundation models on AWS.

Claude is the foundation model invoked through Amazon Bedrock.

## Why Each Component Exists

### Amazon EKS

Exists because:

> Without it, running, scaling and updating AI services becomes operationally difficult.

Amazon EKS gives us a managed Kubernetes platform for running LiteLLM as a containerized service. It helps separate application deployment from infrastructure operations.

### LiteLLM

Exists because:

> Without it, every application must integrate with every model provider separately.

LiteLLM provides a unified interface for model access. Applications can send requests to one gateway while LiteLLM handles provider-specific API differences behind the scenes.

### Amazon Bedrock

Exists because:

> Without it, enterprises lose a managed and governed way to consume foundation models.

Amazon Bedrock gives AWS customers access to foundation models without managing model infrastructure directly. It also fits naturally into AWS identity, networking and governance patterns.

### API Gateway

Exists because:

> Without it, applications directly expose backend services and lose centralized control.

API Gateway gives the architecture a controlled external entry point. It helps standardize how clients reach the AI Gateway.

## What We Will Build

```text
User
 |
API Gateway
 |
LiteLLM on EKS
 |
Amazon Bedrock Claude
```

By the end of this tutorial, we will build a working Enterprise AI Gateway pattern on AWS.

The implementation will demonstrate how applications can call a single endpoint while the gateway routes requests to Claude through Amazon Bedrock.

Capabilities:

- Deploy LiteLLM on EKS
- Integrate with Amazon Bedrock
- Expose through API Gateway
- Invoke Claude through a unified endpoint
- Demonstrate enterprise AI gateway principles
