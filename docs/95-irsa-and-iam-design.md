# IRSA and IAM Architecture Design

This document defines the IAM identity and access model required for LiteLLM running on Amazon EKS. It covers the reasoning behind the IRSA pattern, the complete authentication flow from pod to AWS service, the minimum required permissions for each service, and concrete policy and trust-relationship examples.

This is a **design document only**. It does not provision or modify any AWS resources. All resource ARNs that appear are placeholders and must be replaced with environment-specific values before use.

---

## Why IRSA

### The Problem with Static Credentials

The naive approach to giving a Kubernetes pod access to AWS services is to supply `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` as environment variables or Kubernetes Secrets. This pattern is widely used in development environments but is categorically unacceptable in production for the following reasons:

| Problem | Impact |
|---|---|
| **Credentials are long-lived** | IAM access keys do not expire automatically. A leaked key remains valid until manually rotated or deactivated. |
| **Credentials are shared across replicas** | Every pod replica uses the same key. Revocation requires rotating the key for all pods simultaneously, creating an operational incident. |
| **No workload binding** | A static key can be used from anywhere — another pod, a developer laptop, an attacker's machine. There is no cryptographic guarantee that only the intended workload used it. |
| **Secrets sprawl** | Credentials stored in Kubernetes Secrets, CI/CD pipelines, and config files are difficult to audit and easy to inadvertently leak in logs or version control. |
| **Blast radius** | A compromised key has access to every permission attached to its IAM user until manually revoked — often after the damage is done. |

### The IRSA Solution

**IAM Roles for Service Accounts (IRSA)** replaces static credentials with short-lived, automatically rotated tokens that are cryptographically bound to a specific Kubernetes ServiceAccount in a specific namespace on a specific EKS cluster. Under IRSA:

- The pod receives a short-lived OIDC token (valid for 24 hours by default, configurable) projected into its filesystem.
- The AWS SDK exchanges this token for temporary credentials via `sts:AssumeRoleWithWebIdentity`.
- The resulting credentials are scoped to the IAM role's permissions only, and they expire automatically.
- No secret material appears in environment variables, Kubernetes Secrets, or version control.

IRSA satisfies the principle of **least privilege** and the principle of **workload identity** — only the specific pod running as the specific ServiceAccount in the specific namespace can assume the role.

---

## Authentication Flow

The following sequence describes how a LiteLLM pod authenticates to Amazon Bedrock (or any other AWS service) without static credentials.

```
┌──────────────────────────────────────────────────────────────────┐
│  Amazon EKS Node                                                 │
│                                                                  │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │  LiteLLM Pod                                              │   │
│  │                                                           │   │
│  │  1. AWS SDK reads OIDC token from:                        │   │
│  │     /var/run/secrets/eks.amazonaws.com/serviceaccount/    │   │
│  │     token                                                 │   │
│  │                                                           │   │
│  │  serviceAccountName: litellm-sa  ◄────────────────────┐  │   │
│  └──────────────────────┬────────────────────────────────┼──┘   │
│                         │                                │       │
└─────────────────────────┼────────────────────────────────┼───────┘
                          │                                │
┌─────────────────────────▼────────────────────────────────┼───────┐
│  Kubernetes Control Plane                                │       │
│                                                          │       │
│  ServiceAccount: litellm-sa (namespace: ai-gateway)      │       │
│  Annotation: eks.amazonaws.com/role-arn = <ROLE_ARN>  ───┘       │
│                                                                   │
│  EKS OIDC Provider: oidc.eks.REGION.amazonaws.com/id/OIDC_ID     │
└──────────────────────────┬────────────────────────────────────────┘
                           │ 2. SDK calls sts:AssumeRoleWithWebIdentity
                           │    with the projected OIDC token
┌──────────────────────────▼────────────────────────────────────────┐
│  AWS Security Token Service (STS)                                  │
│                                                                    │
│  3. STS validates the OIDC token signature against the EKS         │
│     OIDC provider's public key.                                    │
│                                                                    │
│  4. STS validates the trust relationship condition:                │
│     sub = system:serviceaccount:ai-gateway:litellm-sa              │
│                                                                    │
│  5. STS issues temporary credentials:                              │
│     AWS_ACCESS_KEY_ID      (short-lived)                           │
│     AWS_SECRET_ACCESS_KEY  (short-lived)                           │
│     AWS_SESSION_TOKEN      (short-lived)                           │
└──────────────────────────┬────────────────────────────────────────┘
                           │ 6. SDK uses temporary credentials
┌──────────────────────────▼────────────────────────────────────────┐
│  AWS Services                                                      │
│                                                                    │
│  ┌─────────────────────┐   ┌──────────────────────────────────┐   │
│  │  Amazon Bedrock      │   │  AWS Secrets Manager              │   │
│  │  bedrock-runtime.*   │   │  secretsmanager:GetSecretValue    │   │
│  │  REGION.amazonaws.com│   │                                  │   │
│  └─────────────────────┘   └──────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────┘
```

### Step-by-Step Summary

| Step | Actor | Action |
|---|---|---|
| 1 | EKS | Projects a signed OIDC JWT into the pod filesystem at a well-known path |
| 2 | AWS SDK (in pod) | Calls `sts:AssumeRoleWithWebIdentity` with the JWT |
| 3 | AWS STS | Validates the JWT signature using the EKS OIDC provider's JWKS endpoint |
| 4 | AWS STS | Validates the `sub` claim matches the trust policy condition |
| 5 | AWS STS | Returns short-lived temporary credentials (valid 1 hour by default) |
| 6 | AWS SDK | Uses temporary credentials to sign API requests to Bedrock and Secrets Manager |

---

## Required IAM Permissions

### Amazon Bedrock — Minimum Permissions

The following permissions are the minimum required for LiteLLM to invoke foundation models via Amazon Bedrock.

| Permission | Purpose |
|---|---|
| `bedrock:InvokeModel` | Invoke a Bedrock foundation model for synchronous (non-streaming) completions |
| `bedrock:InvokeModelWithResponseStream` | Invoke a Bedrock foundation model with response streaming (required for LiteLLM streaming mode) |

**Optional — model discovery**

| Permission | Purpose |
|---|---|
| `bedrock:ListFoundationModels` | Enumerate available foundation models in the region (used by some LiteLLM health-check and model-routing features) |

**Scope guidance:**
- Restrict the `Resource` to specific model ARNs wherever possible. Using `"Resource": "*"` grants access to every Bedrock model in every region — acceptable as a starting point but should be tightened in production.
- The recommended approach is to enumerate only the model IDs your organisation has approved for use (e.g. `anthropic.claude-3-5-sonnet-*`, `amazon.titan-*`).

---

## Secrets Manager Permissions

LiteLLM reads the master key and any provider API keys from AWS Secrets Manager at startup. The required permission is:

| Permission | Purpose |
|---|---|
| `secretsmanager:GetSecretValue` | Read a specific named secret (e.g. `ai-gateway/litellm-secrets`) |

**No write permissions are required.** Do not grant `secretsmanager:CreateSecret`, `secretsmanager:PutSecretValue`, or `secretsmanager:DeleteSecret` to the LiteLLM role.

**Scope guidance:**
- Restrict the `Resource` to the exact secret ARN(s) used by LiteLLM. Using `"Resource": "*"` would allow the pod to read any secret in the account — a significant over-privilege.
- If using a path prefix (e.g. `ai-gateway/*`), use a condition key or explicit ARN prefix to limit scope.

---

## CloudWatch Permissions (Future)

If LiteLLM is configured to emit structured logs or custom metrics directly to Amazon CloudWatch (rather than relying on the node-level log collector), the following permissions may be required:

| Permission | Purpose |
|---|---|
| `logs:CreateLogGroup` | Create a log group if it does not exist |
| `logs:CreateLogStream` | Create a log stream within the group |
| `logs:PutLogEvents` | Write log entries to the stream |
| `cloudwatch:PutMetricData` | Emit custom metrics (token counts, latency, cost) to a custom namespace |

**Recommendation:** In the current architecture, logs are collected by the Fluent Bit DaemonSet (or Amazon CloudWatch Container Insights) running on each EKS node. The LiteLLM pod does not need direct CloudWatch permissions. Add these only if a direct-emission pattern is adopted in a future iteration.

---

## IAM Policy Example

The following is a least-privilege inline or managed policy for the LiteLLM IRSA role. Replace placeholders before use.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BedrockInvokeModels",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": [
        "arn:aws:bedrock:REGION::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0",
        "arn:aws:bedrock:REGION::foundation-model/anthropic.claude-3-haiku-20240307-v1:0",
        "arn:aws:bedrock:REGION::foundation-model/amazon.titan-text-express-v1",
        "arn:aws:bedrock:REGION::foundation-model/amazon.titan-embed-text-v2:0"
      ]
    },
    {
      "Sid": "BedrockListModels",
      "Effect": "Allow",
      "Action": [
        "bedrock:ListFoundationModels"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SecretsManagerReadLiteLLMSecrets",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": [
        "arn:aws:secretsmanager:REGION:ACCOUNT_ID:secret:ai-gateway/litellm-secrets-*"
      ]
    }
  ]
}
```

**Notes:**
- Replace `REGION`, `ACCOUNT_ID`, and model IDs with environment-specific values.
- The trailing `-*` wildcard in the Secrets Manager ARN accommodates the random 6-character suffix that AWS appends to secret ARNs.
- Add or remove model ARNs as new models are approved or deprecated. Use the `bedrock:ListFoundationModels` response to obtain correct ARN formats.
- Do not add `s3:*`, `ec2:*`, or any other service permissions to this role. The principle of least privilege requires that each role grants only what is needed for its specific workload.

---

## IRSA Trust Relationship

The IAM role assumed by LiteLLM pods must have a trust policy that permits only the correct EKS OIDC provider to assume it, and only for the specific Kubernetes ServiceAccount in the specific namespace.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EKSIRSATrustLiteLLM",
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/oidc.eks.REGION.amazonaws.com/id/OIDC_ID"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.REGION.amazonaws.com/id/OIDC_ID:sub": "system:serviceaccount:ai-gateway:litellm-sa",
          "oidc.eks.REGION.amazonaws.com/id/OIDC_ID:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

**Understanding the trust conditions:**

| Field | Value | Purpose |
|---|---|---|
| `Principal.Federated` | EKS OIDC provider ARN | Only this specific EKS cluster's OIDC provider can present tokens for this role |
| `Condition sub` | `system:serviceaccount:ai-gateway:litellm-sa` | Only the `litellm-sa` ServiceAccount in the `ai-gateway` namespace can assume this role |
| `Condition aud` | `sts.amazonaws.com` | The token audience must match the STS service — prevents token reuse against other services |

**Why the `sub` condition is critical:**
Without the `sub` condition, any ServiceAccount in any namespace on the EKS cluster could assume the role. The `sub` condition is the primary guard that binds the role assumption to the exact workload identity.

**How to retrieve your OIDC ID:**
```bash
aws eks describe-cluster \
  --name YOUR_CLUSTER_NAME \
  --region REGION \
  --query "cluster.identity.oidc.issuer" \
  --output text
# Returns: https://oidc.eks.REGION.amazonaws.com/id/OIDC_ID
# The OIDC_ID is the last path segment of the URL.
```

**Creating the OIDC provider (if not already present):**
```bash
eksctl utils associate-iam-oidc-provider \
  --cluster YOUR_CLUSTER_NAME \
  --region REGION \
  --approve
```

---

## Kubernetes ServiceAccount Configuration

Once the IAM role is created, annotate the Kubernetes ServiceAccount to bind it to the role:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: litellm-sa
  namespace: ai-gateway
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::ACCOUNT_ID:role/ROLE_NAME"
```

The `kubernetes/serviceaccount.yaml` manifest in this repository includes this annotation with a placeholder ARN. Replace `ACCOUNT_ID` and `ROLE_NAME` with the values from your environment before deploying.

---

## Deployment Checklist

The following steps must be completed in order before LiteLLM pods can authenticate to AWS services.

| Step | Command / Action | Status |
|---|---|---|
| 1 | Verify EKS OIDC provider exists | `aws eks describe-cluster --query "cluster.identity.oidc.issuer"` |
| 2 | Associate OIDC provider with IAM (if not present) | `eksctl utils associate-iam-oidc-provider` |
| 3 | Create IAM role with trust policy | AWS Console or `aws iam create-role` |
| 4 | Attach inline or managed policy to role | AWS Console or `aws iam put-role-policy` |
| 5 | Update `serviceaccount.yaml` with role ARN | Edit `kubernetes/serviceaccount.yaml` |
| 6 | Apply manifests | `kubectl apply -f kubernetes/` |
| 7 | Verify token projection | `kubectl exec -it <pod> -- cat /var/run/secrets/eks.amazonaws.com/serviceaccount/token` |
| 8 | Verify credentials resolved | `kubectl exec -it <pod> -- aws sts get-caller-identity` |
| 9 | Verify Bedrock access | `kubectl exec -it <pod> -- aws bedrock list-foundation-models --region REGION` |

---

## Security Considerations

### Token Lifetime

By default, the projected OIDC token is valid for 24 hours and is rotated automatically by EKS before expiry. For higher-security environments, reduce the token expiration:

```yaml
# In serviceaccount.yaml:
annotations:
  eks.amazonaws.com/token-expiration: "3600"  # 1 hour
```

Shorter lifetimes reduce the window of opportunity if a token is intercepted, at the cost of more frequent STS calls.

### Role Session Duration

The temporary credentials issued by STS are valid for 1 hour by default. The maximum is 12 hours. Do not extend this unnecessarily — shorter sessions reduce blast radius if credentials are leaked.

### Resource Scoping

The policy example above scopes Bedrock permissions to specific model ARNs. This is strongly preferred over `"Resource": "*"`. The list of approved model ARNs should be treated as a governance artifact and reviewed during architecture reviews.

### Separate Roles Per Environment

Create separate IAM roles for development, staging, and production environments. Do not reuse the same role across environments — this ensures that a compromise in a lower environment cannot escalate to production.

| Environment | Role Name (example) |
|---|---|
| Development | `litellm-irsa-dev` |
| Staging | `litellm-irsa-staging` |
| Production | `litellm-irsa-prod` |

---

## Future Expansion

As the Enterprise AI Gateway evolves, the IAM and identity model will need to accommodate new components. The following table documents anticipated future requirements.

### Langfuse (Observability Platform)

If Langfuse is deployed as an on-cluster observability backend, its pods will require:

| Permission | Purpose |
|---|---|
| `secretsmanager:GetSecretValue` | Read Langfuse database credentials and API keys |
| `s3:PutObject`, `s3:GetObject` | Store and retrieve trace data from S3 (if S3 backend is configured) |

Langfuse should run under a **separate IAM role** (`langfuse-irsa`) with its own trust policy scoped to the `langfuse` ServiceAccount. It must not share the `litellm-irsa` role.

### OpenTelemetry Collector

If an OpenTelemetry Collector sidecar or DaemonSet is deployed to forward traces and metrics to AWS X-Ray, CloudWatch, or an external backend, it will require:

| Permission | Purpose |
|---|---|
| `xray:PutTraceSegments` | Send trace segments to AWS X-Ray |
| `xray:PutTelemetryRecords` | Send telemetry metadata to X-Ray |
| `logs:PutLogEvents` | Forward structured logs to CloudWatch Logs |
| `cloudwatch:PutMetricData` | Emit custom metrics to CloudWatch (token counts, latency) |

The OTel Collector should run under its own ServiceAccount and IRSA role (`otel-collector-irsa`), separate from the LiteLLM role.

### Agent Platforms

Future agentic AI patterns (LangChain agents, AutoGen, Amazon Bedrock Agents) may require additional permissions depending on the tools they invoke:

| Component | Additional Permissions Required |
|---|---|
| Bedrock Agents | `bedrock:InvokeAgent`, `bedrock:InvokeInlineAgent` |
| Knowledge Base (RAG) | `bedrock:Retrieve`, `bedrock:RetrieveAndGenerate` |
| S3 document store | `s3:GetObject` on the knowledge base bucket |
| DynamoDB memory store | `dynamodb:GetItem`, `dynamodb:PutItem`, `dynamodb:Query` |

Each agent workload should run under a dedicated ServiceAccount and IRSA role scoped to its specific tool permissions. Sharing a single broad role across multiple agent types defeats the purpose of least-privilege workload identity.

### Multi-Region Deployment

In a multi-region active-active deployment, each regional EKS cluster will have its own OIDC provider. IAM roles must be created in each region (or a single cross-region role must be configured), and the trust policy must enumerate all regional OIDC provider ARNs. Evaluate AWS IAM Identity Center or AWS Organizations-level SCPs to enforce consistent permission boundaries across all regional roles.

---

## Summary

| Component | IAM Mechanism | Role Name (example) | Key Permissions |
|---|---|---|---|
| LiteLLM proxy | IRSA | `litellm-irsa-prod` | `bedrock:InvokeModel`, `bedrock:InvokeModelWithResponseStream`, `secretsmanager:GetSecretValue` |
| Langfuse (future) | IRSA | `langfuse-irsa-prod` | `secretsmanager:GetSecretValue`, `s3:PutObject/GetObject` |
| OTel Collector (future) | IRSA | `otel-collector-irsa-prod` | `xray:PutTraceSegments`, `logs:PutLogEvents`, `cloudwatch:PutMetricData` |
| Agent Platform (future) | IRSA | `bedrock-agents-irsa-prod` | `bedrock:InvokeAgent`, `bedrock:Retrieve`, tool-specific permissions |

The guiding principle across all components is: **one role per workload identity, scoped to the minimum permissions required for that workload's specific function**.
