# Exposing the Enterprise AI Gateway Through AWS API Gateway

## 6.1 Introduction

At the end of the previous chapter, we successfully deployed LiteLLM on Amazon EKS and connected it to Amazon Bedrock.

Our architecture currently looks like this:

```text
User
 |
LiteLLM
 |
Amazon Bedrock
 |
Claude
```

The AI Gateway is operational and capable of processing requests.

However, this architecture is not yet enterprise-ready.

The purpose of this chapter is to introduce AWS API Gateway and explain why enterprises rarely expose backend services directly to consumers.

By the end of this chapter, our architecture will evolve into:

```text
User
 |
AWS API Gateway
 |
LiteLLM
 |
Amazon Bedrock
 |
Claude
```

This seemingly small change dramatically improves governance, security, scalability and operational control.

## 6.2 The Problem: Why Not Expose LiteLLM Directly?

Many engineers ask:

```text
If LiteLLM is already working, why introduce API Gateway?
```

This is a valid question.

Let us examine what happens when LiteLLM is exposed directly.

```text
Users
   |
   v
LiteLLM
   |
   v
Amazon Bedrock
```

Initially, this seems simple.

However, as usage grows, several enterprise challenges emerge.

### Problem 1: No Central Authentication

Without API Gateway, any client capable of reaching LiteLLM can attempt to invoke the service.

Questions arise:

- Who is calling the service?
- Is the caller authenticated?
- Which team owns the request?
- Which application generated the traffic?

Without a centralized entry point, answering these questions becomes difficult.

### Problem 2: No Rate Limiting

Imagine an internal application accidentally enters an infinite loop.

```text
Application
     |
     +--> 10,000 AI Requests
```

Without rate limiting:

- Token consumption increases rapidly
- Bedrock costs increase
- Other users experience degraded performance

A single application can consume the entire platform.

### Problem 3: No Central Governance

Suppose five different teams consume the AI platform.

```text
HR Team
Finance Team
Operations Team
Legal Team
Engineering Team
```

Without API Gateway:

- No centralized policy enforcement
- No request tracking
- No usage visibility
- No consistent security controls

Every team interacts with the platform differently.

### Problem 4: No API Lifecycle Management

Enterprise APIs evolve.

Version 1:

```text
/chat
```

Version 2:

```text
/v2/chat
```

Without API Gateway, versioning becomes difficult.

Applications break when backend implementations change.

### Problem 5: No Enterprise Observability

A CTO may ask:

```text
Which team consumed 5 million tokens last month?
```

Without a centralized API layer, answering this question becomes difficult.

API Gateway provides a natural control point for:

- Usage metrics
- Request counts
- Traffic analysis
- Error monitoring

## 6.3 The Architectural Principle

This chapter introduces one of the most important principles in modern distributed systems.

During the microservices revolution, organizations learned:

```text
Never expose internal services directly.
```

Instead:

```text
Client
   |
API Gateway
   |
Microservices
```

The same principle applies to AI systems.

Instead of:

```text
Applications
      |
      v
LiteLLM
```

We introduce:

```text
Applications
      |
      v
API Gateway
      |
      v
LiteLLM
```

The API Gateway becomes the enterprise control plane.

## 6.4 API Gateway Responsibilities

AWS API Gateway is much more than a URL router.

It acts as a policy enforcement layer.

### Authentication

Verifies who is calling the platform.

Examples:

- IAM
- Cognito
- JWT Tokens
- API Keys

Without authentication:

Anyone with network access can attempt to use the AI platform.

### Authorization

Determines what callers are allowed to do.

Examples:

- HR application can access HR endpoints
- Finance application can access Finance endpoints

Without authorization:

Every user potentially has access to everything.

### Throttling

Controls request volume.

Examples:

```text
100 Requests / Minute
1000 Requests / Hour
```

Without throttling:

A single client can overwhelm the platform.

### Monitoring

Captures:

- Request counts
- Error rates
- Latency
- Usage patterns

Without monitoring:

Platform operations become reactive rather than proactive.

### Versioning

Supports controlled API evolution.

Example:

```text
/v1/chat
/v2/chat
```

Without versioning:

Every change risks breaking consumers.

## 6.5 Why API Gateway Makes This an Enterprise Architecture

This is the key takeaway of the chapter.

Before API Gateway:

```text
User
 |
LiteLLM
 |
Bedrock
```

This is a working AI deployment.

After API Gateway:

```text
User
 |
API Gateway
 |
LiteLLM
 |
Bedrock
```

This becomes an enterprise platform.

Why?

Because enterprises care about:

- Governance
- Security
- Compliance
- Auditability
- Cost Control
- Usage Tracking
- Lifecycle Management

API Gateway provides the control point required to enforce these capabilities.

## 6.6 Target Architecture

After completing this chapter, our architecture becomes:

```text
User
 |
AWS API Gateway
 |
LiteLLM Service
 |
LiteLLM Pods
 |
Amazon Bedrock
 |
Claude
```

Responsibilities:

| Component      | Responsibility                   |
| -------------- | -------------------------------- |
| API Gateway    | Entry point and governance layer |
| LiteLLM        | AI routing layer                 |
| Amazon Bedrock | Managed model access             |
| Claude         | Foundation model                 |

## 6.7 Create the AWS API Gateway

For this lab we will use:

```text
HTTP API
```

Reason:

- Simpler configuration
- Lower cost
- Sufficient for our architecture

Steps:

1. Open AWS Console
2. Navigate to API Gateway
3. Create API
4. Select HTTP API
5. Name:

```text
enterprise-ai-gateway
```

6. Continue to integration configuration

## 6.8 Configure Integration

The integration target will be:

```text
LiteLLM Service running on Amazon EKS
```

Important:

API Gateway does not run AI workloads.

API Gateway only forwards requests.

The processing path remains:

```text
API Gateway
      |
      v
LiteLLM
      |
      v
Bedrock
```

## 6.9 Create Route

Create a route:

```text
POST /chat
```

Flow:

```text
POST /chat
       |
       v
API Gateway
       |
       v
LiteLLM
```

## 6.10 Test End-to-End Connectivity

Invoke:

```text
POST /chat
```

Request:

```json
{
  "model": "claude",
  "messages": [
    {
      "role": "user",
      "content": "Explain Kubernetes"
    }
  ]
}
```

Request Flow:

```text
Client
 |
API Gateway
 |
LiteLLM
 |
Bedrock
 |
Claude
```

Response returns through the same path.

## 6.11 Common Issues

### 403 Forbidden

Possible Causes:

- Missing authentication
- Authorization failure
- Incorrect API Gateway permissions

### 502 Bad Gateway

Possible Causes:

- LiteLLM unavailable
- Incorrect integration target
- Backend timeout

### Timeout Errors

Possible Causes:

- EKS networking issue
- Bedrock latency
- Incorrect backend configuration

## 6.12 Summary

At the end of this chapter we have achieved:

```text
[x] Amazon EKS

[x] LiteLLM

[x] Amazon Bedrock

[x] Claude

[x] AWS API Gateway
```

Current Architecture:

```text
User
 |
AWS API Gateway
 |
LiteLLM
 |
Amazon Bedrock
 |
Claude
```

Most importantly, we have transformed a working AI deployment into an enterprise-grade AI platform by introducing a centralized governance and control layer.

API Gateway exists because without it, backend AI services are directly exposed, making governance, security, observability and lifecycle management significantly more difficult.
