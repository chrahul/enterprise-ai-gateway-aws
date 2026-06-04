# Amazon Bedrock Integration

## 5.1 Introduction

### What Are We Building?

In the previous chapter, we deployed LiteLLM on Amazon EKS.

Current:

```text
LiteLLM
```

Target:

```text
LiteLLM
    |
Amazon Bedrock
    |
Claude
```

This chapter connects LiteLLM to Amazon Bedrock and invokes Claude through the AI Gateway.

No API Gateway.

No OpenAI.

No multi-provider routing.

The only objective is:

```text
User
 |
LiteLLM
 |
Bedrock
 |
Claude
```

## 5.2 What is Amazon Bedrock?

### The Problem

Without Bedrock, applications often connect directly to external model providers.

```text
Application
     |
 Direct OpenAI
```

This creates challenges:

- API key management
- Security concerns
- Compliance concerns
- Limited governance

Direct provider integration may work for a single prototype, but it becomes harder to manage when many teams, applications and environments need AI access.

### The Solution

Amazon Bedrock provides:

- Managed model access
- IAM integration
- CloudTrail auditing
- AWS-native security

Bedrock gives enterprises a managed way to consume foundation models without hosting the models themselves.

### Why Bedrock Exists

> Amazon Bedrock exists because without it, enterprises lack a governed and secure way to consume foundation models.

## 5.3 Bedrock Architecture

The architecture for this chapter is intentionally simple.

```text
Application
      |
   LiteLLM
      |
   Bedrock
      |
   Claude
```

| Component | Responsibility         |
| --------- | ---------------------- |
| LiteLLM   | Gateway                |
| Bedrock   | Managed model platform |
| Claude    | Foundation model       |

LiteLLM receives the request from the user or application.

Bedrock provides governed access to the model.

Claude generates the AI response.

## 5.4 Verify Bedrock Access

Before configuring LiteLLM, verify that Claude access is enabled in Amazon Bedrock.

Open the AWS Console:

```text
Amazon Bedrock
     |
Model Access
```

Verify that Claude is enabled.

If Claude is not enabled, request access before continuing.

Common error:

```text
AccessDeniedException
```

This usually means model access has not been granted in Amazon Bedrock.

IAM permissions alone are not enough. Bedrock model access must also be approved.

## 5.5 Create IAM Permissions

LiteLLM running on EKS must be allowed to call Amazon Bedrock.

The required action is:

```text
bedrock:InvokeModel
```

Example permission:

```json
{
  "Effect": "Allow",
  "Action": [
    "bedrock:InvokeModel"
  ],
  "Resource": "*"
}
```

For a lab, this permission is enough to understand the integration path.

For production, restrict access to the specific Bedrock models and AWS regions required by the platform.

## 5.6 Configure LiteLLM

Update:

```text
litellm/config.yaml
```

Add a Claude model mapping:

```yaml
model_list:
  - model_name: claude
    litellm_params:
      model: bedrock/anthropic.claude-3-5-sonnet
```

Field explanation:

| Field          | Purpose                                      |
| -------------- | -------------------------------------------- |
| model_list     | List of models exposed by LiteLLM            |
| model_name     | Name clients use when calling LiteLLM        |
| litellm_params | Provider-specific LiteLLM configuration      |
| model          | Actual provider and model behind the gateway |

The client calls:

```text
claude
```

LiteLLM maps that name to:

```text
bedrock/anthropic.claude-3-5-sonnet
```

This is the core gateway pattern.

Applications do not need to know the full Bedrock model identifier. They only need to know the gateway model name.

## 5.7 Apply Configuration

After updating the LiteLLM configuration, apply the Kubernetes resources again:

```bash
kubectl apply -f kubernetes/namespace.yaml
kubectl apply -f kubernetes/deployment.yaml
kubectl apply -f kubernetes/service.yaml
```

Restart the LiteLLM deployment:

```bash
kubectl rollout restart deployment litellm -n ai-gateway
```

Verify rollout status:

```bash
kubectl rollout status deployment litellm -n ai-gateway
```

This ensures the running LiteLLM pods pick up the updated configuration.

## 5.8 Verify LiteLLM Logs

Check LiteLLM logs:

```bash
kubectl logs deployment/litellm -n ai-gateway
```

Success usually means:

```text
LiteLLM starts without configuration errors.
The configured model name is loaded.
The service continues running.
```

Failure usually means:

```text
The model mapping is invalid.
AWS credentials are missing.
IAM permissions are insufficient.
Bedrock model access is not enabled.
```

Logs are the first place to check when LiteLLM starts but requests fail.

## 5.9 Test Claude

Port-forward the LiteLLM service:

```bash
kubectl port-forward svc/litellm 4000:4000 -n ai-gateway
```

Send a request to LiteLLM:

```bash
curl http://localhost:4000/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude",
    "messages": [
      {
        "role": "user",
        "content": "Explain Kubernetes"
      }
    ]
  }'
```

The request goes to LiteLLM first.

LiteLLM then routes the request to Claude through Amazon Bedrock.

## 5.10 Expected Response

Example response:

```json
{
  "choices": [
    {
      "message": {
        "content": "Kubernetes is..."
      }
    }
  ]
}
```

This response came from:

```text
curl
 |
LiteLLM
 |
Bedrock
 |
Claude
```

This is the first major milestone of the tutorial.

The platform is no longer only running infrastructure. It is now returning an AI response through the gateway.

## 5.11 Troubleshooting

### Model Access Not Enabled

Error:

```text
AccessDeniedException
```

Cause:

Claude access is not enabled in Amazon Bedrock Model Access.

Fix:

Enable Claude in the Amazon Bedrock console before retrying.

### IAM Permission Missing

Error:

```text
Unauthorized
```

Cause:

The identity used by LiteLLM does not have permission to invoke Bedrock.

Fix:

Grant the required `bedrock:InvokeModel` permission.

### Wrong Region

Error:

```text
Model Not Found
```

Cause:

The selected model is not available in the configured AWS region.

Fix:

Use a Bedrock-supported region where Claude is available.

### LiteLLM Config Error

Error:

```text
Model Mapping Error
```

Cause:

The LiteLLM model configuration is incorrect.

Fix:

Review `litellm/config.yaml` and confirm the model name and provider identifier are correct.

## 5.12 Summary

Completed:

```text
[x] EKS

[x] LiteLLM

[x] Bedrock

[x] Claude

[x] First AI Response
```

Not Yet Completed:

```text
[ ] API Gateway

[ ] OpenAI

[ ] Multi-Provider Routing

[ ] Fallbacks

[ ] Observability
```

Current Architecture:

```text
User
 |
LiteLLM
 |
Bedrock
 |
Claude
```

This chapter is the first major milestone of the entire project.

After Chapter 5, this repository stops being only a Kubernetes project and becomes a real GenAI platform.
