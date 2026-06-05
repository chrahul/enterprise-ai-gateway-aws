# Enterprise Architecture Review

## 7.1 Introduction

In the previous chapters, we built the first working version of an Enterprise AI Gateway on AWS.

The request path now looks like this:

```text
User
 |
AWS API Gateway
 |
LiteLLM on Amazon EKS
 |
Amazon Bedrock
 |
Claude
```

At this point, it is tempting to continue adding services.

An architect should pause first and ask:

> What exactly have we built, why does each layer exist and what problems remain unsolved?

This chapter connects the technical steps from the previous chapters to the architectural decisions behind them.

It does not introduce a new AWS service.

Instead, it reviews the platform as a system.

## 7.2 Evolution of Enterprise Systems

Enterprise architecture has repeatedly evolved by introducing new control layers as systems became more distributed.

### Stage 1: Monolith

In a monolithic application, the user interface, business logic and data access are packaged together.

```text
User
 |
Monolith
 |
Database
```

This model is simple to understand and deploy when the application is small.

As the application grows, teams may struggle with:

- Large deployment units
- Tight coupling
- Slow release cycles
- Limited independent scaling

### Stage 2: Microservices

Microservices separate business capabilities into independently deployable services.

```text
User
 |
+-- User Service
+-- Order Service
+-- Billing Service
```

This improves team autonomy and independent scaling, but it introduces a new problem.

Clients must now discover, authenticate with and communicate with many services.

### Stage 3: API Gateway

The API Gateway pattern introduces a controlled front door.

```text
User
 |
API Gateway
 |
+-- User Service
+-- Order Service
+-- Billing Service
```

The gateway standardizes how clients access distributed services.

It provides a central place for capabilities such as:

- Authentication
- Authorization
- Throttling
- Routing
- Versioning
- Monitoring

### Stage 4: AI Gateway

The same architectural problem now appears with foundation models.

Without an AI Gateway:

```text
Application A --> OpenAI

Application B --> Anthropic

Application C --> Amazon Bedrock
```

Each application owns provider-specific code, credentials, policies and monitoring.

An AI Gateway introduces a standard model access layer.

```text
Applications
      |
  API Gateway
      |
  AI Gateway
      |
      +---- Amazon Bedrock
      +---- OpenAI
      +---- Anthropic
```

The progression is:

```text
Monolith
    |
    v
Microservices
    |
    v
API Gateway
    |
    v
AI Gateway
```

API Gateway standardized access to services.

AI Gateway standardizes access to intelligence.

## 7.3 Current Architecture Review

The platform currently contains five logical layers.

```text
User or Application
        |
        v
AWS API Gateway
        |
        v
LiteLLM Service
        |
        v
LiteLLM Pods on Amazon EKS
        |
        v
Amazon Bedrock
        |
        v
Claude
```

### User or Application

The consumer sends an AI request through a stable API endpoint.

The consumer should not need to understand:

- Where LiteLLM is running
- Which provider SDK is used
- How AWS authenticates with Bedrock
- Which model ultimately serves the request

This separation reduces coupling between applications and model providers.

### AWS API Gateway

API Gateway is the external entry point.

Its role is to provide a place to apply:

- Client authentication
- Authorization policies
- Request throttling
- API versioning
- Request and response monitoring

API Gateway creates the governance boundary between consumers and the internal AI platform.

These controls are capabilities, not automatic outcomes. They must be explicitly configured before the platform can rely on them.

### LiteLLM

LiteLLM is the AI Gateway.

It accepts a consistent request format and translates the request into the provider-specific operation required by Amazon Bedrock.

Its role can grow to include:

- Model aliases
- Provider routing
- Fallback models
- Retry policies
- Usage tracking
- Cost attribution

At this stage, the implementation uses LiteLLM primarily as a standardized interface to Bedrock.

### Amazon EKS

Amazon EKS is the runtime platform for LiteLLM.

Kubernetes manages the desired state of the LiteLLM workload and provides mechanisms for:

- Multiple replicas
- Pod replacement
- Rolling updates
- Horizontal scaling
- Service discovery

EKS provides these mechanisms, but production resilience still depends on correct configuration across replicas, health probes, autoscaling, disruption budgets and multiple Availability Zones.

### Amazon Bedrock

Amazon Bedrock provides managed access to foundation models through AWS.

It integrates model consumption with AWS capabilities such as:

- IAM
- CloudTrail
- AWS networking controls
- Centralized AWS billing

Bedrock removes the need to host the foundation model infrastructure ourselves.

### Claude

Claude is the foundation model that generates the response.

It is the intelligence provider in the current request path, while Bedrock is the managed service through which the platform invokes it.

## 7.4 Why Not Run LiteLLM on EC2?

LiteLLM can run on a single Amazon EC2 instance.

```text
User
 |
EC2
 |
LiteLLM
```

This can be appropriate for:

- Local experimentation
- Short-lived demonstrations
- Low-risk development environments
- Small workloads with limited availability requirements

The problem appears when the EC2 instance becomes the only gateway instance.

### Single Point of Failure

If the instance fails, LiteLLM becomes unavailable.

```text
EC2 Failure
    |
    v
AI Gateway Unavailable
```

With EKS, multiple LiteLLM pods can run behind a Kubernetes Service.

```text
Amazon EKS
    |
    +-- LiteLLM Pod 1
    +-- LiteLLM Pod 2
```

If one pod fails, Kubernetes can replace it and traffic can continue through another healthy pod.

### Scaling

An EC2 deployment usually requires the team to design instance scaling, traffic distribution and process management.

EKS provides a standard orchestration model for scaling pod replicas and distributing traffic through Kubernetes Services.

### Self-Healing

A process running on EC2 needs an external process manager or custom automation to detect failure and restart it.

Kubernetes continuously compares actual state with desired state. If a LiteLLM pod terminates, Kubernetes attempts to create a replacement.

### Upgrades

Updating a single EC2-hosted process can cause downtime.

Kubernetes Deployments support rolling updates, allowing new pods to become healthy before old pods are removed.

### Architectural Decision

The comparison is not:

```text
EC2 is bad
EKS is good
```

The real decision is:

| Requirement | EC2 | EKS |
| ----------- | --- | --- |
| Simple initial deployment | Strong | More complex |
| Operational overhead at small scale | Lower | Higher |
| Native workload orchestration | Manual or additional tooling | Built in |
| Multiple replicas | Requires design | Standard deployment pattern |
| Rolling updates | Requires design | Built in |
| Self-healing | Requires design | Built in |

EKS is justified when the organization needs a shared, scalable and resilient platform and is prepared to operate Kubernetes.

## 7.5 Why Not Call Amazon Bedrock Directly?

An application can call Amazon Bedrock directly.

```text
Application
     |
Amazon Bedrock
     |
Claude
```

For one application using one model, this is the shortest path.

The architecture becomes harder to manage when many applications and providers are introduced.

### Provider-Specific Integration

Without LiteLLM, each application must understand the provider's authentication, request format, model identifiers, errors and SDK.

With LiteLLM:

```text
Application
     |
OpenAI-Compatible API
     |
LiteLLM
     |
Amazon Bedrock
```

Applications integrate with one interface while LiteLLM handles provider-specific translation.

### Standardization

A shared gateway creates a consistent contract for all consuming teams.

This reduces:

- Duplicate integration code
- Inconsistent retry behavior
- Provider-specific logic in applications
- Migration effort when models change

### Vendor Independence

LiteLLM does not eliminate vendor dependence by itself.

It reduces application coupling by placing provider selection behind a gateway-controlled model alias.

For example:

```text
Application requests: enterprise-chat

LiteLLM routes to: Bedrock Claude
```

The platform team can later change the route without requiring every application to adopt a new provider SDK.

### Routing and Fallback

A direct Bedrock integration gives the application one provider path.

A multi-provider LiteLLM configuration can later support:

- Route selection by use case
- Fallback when a provider is unavailable
- Model selection by cost or latency
- Controlled model migrations

These capabilities are part of the roadmap and are not yet implemented in the current single-provider configuration.

## 7.6 Why Not Expose LiteLLM Directly?

LiteLLM can be exposed directly to consumers.

```text
User
 |
LiteLLM
```

This may be sufficient for a protected development environment.

For an enterprise platform, direct exposure mixes two different responsibilities:

```text
API Management

and

AI Model Routing
```

The architecture separates them.

```text
User
 |
AWS API Gateway
 |
LiteLLM
```

### Authentication and Authorization

API Gateway provides a managed point where the platform can verify caller identity and enforce access policies.

This allows the platform to distinguish between teams, applications and environments before a request reaches LiteLLM.

### Rate Limiting

AI requests consume tokens and create cost.

Throttling at the API boundary helps prevent one client from consuming all available capacity or creating an unexpected cost spike.

### Governance

A centralized API boundary gives the organization one place to define:

- Approved consumers
- Allowed routes
- API versions
- Request limits
- Deprecation policies

### Monitoring

API Gateway metrics can show:

- Request volume
- Error rates
- Integration latency
- Traffic patterns

LiteLLM and model-level telemetry are still required for token usage, model latency and provider cost. API Gateway monitoring does not replace AI-specific observability.

### Defense in Depth

API Gateway should be one layer in the security design.

A production architecture may also require:

- Private EKS networking
- Restricted security groups
- AWS WAF
- TLS
- Secrets management
- Workload identity
- Audit logging

Adding API Gateway alone does not make an exposed LiteLLM service secure.

## 7.7 What Problems Have We Solved?

The platform now has an architectural component assigned to each major problem introduced so far.

| Problem | Architectural Response |
| ------- | ---------------------- |
| Single host failure risk | Amazon EKS with multiple LiteLLM replicas |
| Provider-specific application integration | LiteLLM |
| Direct backend service exposure | AWS API Gateway |
| Hosting and operating a foundation model | Amazon Bedrock |
| Application coupling to a model name | LiteLLM model aliases |
| AWS-native model access control | Bedrock with IAM |

There is an important distinction between selecting a component and completing its production configuration.

For example:

```text
EKS enables high availability.

Multiple replicas, health checks and multi-AZ capacity implement it.
```

Similarly:

```text
API Gateway enables governance.

Authentication, authorization, throttling and logging implement it.
```

The current platform establishes the correct architectural boundaries. Later chapters will strengthen the controls inside those boundaries.

## 7.8 What Problems Still Exist?

The current platform is a strong foundation, but it is not a complete enterprise AI platform.

### Secret Management

Credentials and sensitive configuration need a centralized lifecycle.

The platform still needs:

- Secure storage
- Rotation
- Access auditing
- Separation between configuration and secrets

AWS Secrets Manager will address this area.

### Multi-Provider Support

The current request path uses only Amazon Bedrock.

The platform does not yet demonstrate:

- OpenAI integration
- Multiple provider routing
- Cross-provider fallback
- Provider selection policies

### Observability

Basic infrastructure metrics are not enough to operate an AI platform.

The platform still needs visibility into:

- Token consumption
- Model latency
- Provider errors
- Request traces
- Model usage by application or team
- Gateway and model health

### Cost Governance

The architecture can generate model costs, but it does not yet provide:

- Team-level budgets
- Per-model cost reporting
- Usage quotas
- Cost anomaly detection
- Cost-aware routing

### Retrieval-Augmented Generation

The platform can generate responses, but it cannot yet retrieve enterprise knowledge and ground model responses in approved data.

A RAG architecture will introduce document ingestion, retrieval and context assembly.

### Agentic AI

The platform currently handles request and response model invocation.

It does not yet provide agents that can:

- Select tools
- Execute multi-step workflows
- Maintain workflow state
- Apply approval boundaries

### Additional Production Controls

A production design may also require:

- AWS WAF
- CloudFront
- Private API integrations
- Persistent LiteLLM state
- Caching
- Disaster recovery
- Compliance controls

The exact requirements depend on the organization's risk, scale and regulatory environment.

## 7.9 Mapping to the AWS Reference Architecture

The target reference architecture contains more components than the current tutorial implementation.

The following mapping shows where we are today.

| Component | Status | Purpose |
| --------- | ------ | ------- |
| Amazon EKS | Implemented | Runs and orchestrates LiteLLM |
| LiteLLM | Implemented | Provides the AI Gateway interface |
| Amazon Bedrock | Implemented | Provides managed model access |
| Claude | Implemented | Generates model responses |
| AWS API Gateway | Implemented | Provides the managed API entry point |
| AWS Secrets Manager | Not yet implemented | Stores and rotates sensitive values |
| OpenAI | Not yet implemented | Adds a second model provider |
| Anthropic direct API | Not yet implemented | Adds another provider path outside Bedrock |
| Amazon RDS | Not yet implemented | Provides persistent relational state |
| Amazon ElastiCache | Not yet implemented | Provides caching and shared low-latency state |
| Amazon CloudWatch observability | Not yet implemented end to end | Centralizes metrics, logs and alarms |
| Amazon CloudFront | Not yet implemented | Adds edge distribution where required |
| AWS WAF | Not yet implemented | Adds web request filtering and protection |

Current scope:

```text
[x] Amazon EKS

[x] LiteLLM

[x] Amazon Bedrock

[x] Claude

[x] AWS API Gateway
```

Future scope:

```text
[ ] AWS Secrets Manager

[ ] OpenAI

[ ] Multi-model routing

[ ] Observability

[ ] Cost governance

[ ] Amazon RDS

[ ] Amazon ElastiCache

[ ] Amazon CloudFront

[ ] AWS WAF

[ ] RAG

[ ] Agents
```

This is not a list of services that every platform must deploy.

It is a capability roadmap. Each component should be added only when a clear architectural requirement justifies it.

## 7.10 Architecture Roadmap

The next chapters will evolve the platform in deliberate stages.

```text
Current Foundation
        |
        v
Secret Management
        |
        v
OpenAI Integration
        |
        v
Multi-Model Routing
        |
        v
Observability
        |
        v
Cost Governance
        |
        v
RAG Architecture
        |
        v
Agentic AI
```

Each stage answers a different enterprise question.

| Stage | Enterprise Question |
| ----- | ------------------- |
| Secrets Manager | How do we protect and rotate sensitive configuration? |
| OpenAI integration | How do we add another provider without changing every application? |
| Multi-model routing | How do we select and fail over between models? |
| Observability | How do we understand platform and model behavior? |
| Cost governance | How do we control and attribute AI spending? |
| RAG architecture | How do we ground responses in enterprise knowledge? |
| Agentic AI | How do we safely allow models to use tools and execute workflows? |

## 7.11 The Most Important Lesson

The architecture is not valuable because it can send a prompt to Claude.

A direct script can do that.

The value comes from creating controlled layers between enterprise applications and foundation models.

Those layers allow the platform to evolve independently:

- Applications depend on a stable API
- API Gateway manages consumer access
- LiteLLM manages model access
- EKS manages the gateway workload
- Bedrock manages foundation model consumption

The most important lesson is:

> The goal of an AI Platform is not to provide access to a model. The goal of an AI Platform is to provide governed, secure, observable, and scalable access to intelligence.

That principle will guide every capability added in the remaining chapters.

## 7.12 Summary

In this chapter, we reviewed:

- How enterprise systems evolved from monoliths to AI Gateways
- Why LiteLLM runs on Amazon EKS
- Why applications should not call model providers directly
- Why AWS API Gateway sits in front of LiteLLM
- Which problems the current architecture addresses
- Which enterprise capabilities are still missing
- How the current implementation maps to the larger roadmap

The current platform is not the end state.

It is the governed foundation on which the remaining enterprise AI capabilities will be built.
