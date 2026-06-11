# Secrets Management Strategy

This document defines the secrets architecture for the Enterprise AI Gateway. It establishes the authoritative model for how sensitive credentials are stored, accessed, rotated, and audited across all environments.

Secrets management is not a peripheral concern — it is a foundational security control. Every decision about where and how credentials are stored directly determines the blast radius of a compromise. This document ensures that pattern is applied consistently and deliberately.

---

## Why Secrets Management Matters

### The Risks of Common Anti-Patterns

Most secrets incidents do not result from sophisticated attacks. They result from convenience-driven decisions made under time pressure: hardcoding a key to "just get it working," committing a `.env` file that was "only for testing," or reusing a credential "just for now." The following anti-patterns are explicitly prohibited in this architecture.

#### Hardcoded Credentials

Embedding credentials directly in application source code is the most dangerous practice in software development.

| Risk | Impact |
|---|---|
| **Version control exposure** | Every developer, CI/CD system, and code scanning tool that ever processes the repository has access to the credential — including historical commits after the secret is removed |
| **No rotation path** | Rotating a hardcoded credential requires a code change, a build, and a deployment. In an incident, this is too slow. |
| **No auditability** | There is no way to determine who accessed a hardcoded credential or when |
| **Accidental public exposure** | A single `git push` to a public fork, a GitHub Actions log, or a stack trace exposes the credential to the internet permanently |

Tools like `git-secrets`, `truffleHog`, and GitHub's secret scanning can detect hardcoded credentials, but detection is not prevention. The only reliable control is to never introduce them.

#### Kubernetes Secrets Only

Kubernetes Secrets are base64-encoded, not encrypted at rest by default. While EKS can be configured with envelope encryption via AWS KMS, relying solely on Kubernetes Secrets creates several risks:

| Risk | Impact |
|---|---|
| **Cluster compromise = credential exposure** | Any actor with `kubectl get secret` permission in the namespace can retrieve all secrets |
| **No centralised rotation** | Secrets stored only in Kubernetes must be manually updated in every namespace and cluster |
| **No cross-environment consistency** | The same logical secret (e.g. the LiteLLM master key) exists as separate objects in dev, staging, and prod clusters with no unified management plane |
| **Audit gaps** | Kubernetes audit logs capture API access but do not provide the same depth of secret access auditing as AWS Secrets Manager |

Kubernetes Secrets remain a valid mechanism for injecting secrets into pods, but they should be treated as an ephemeral delivery vehicle — not as the system of record.

#### Environment Variables in Source Control

`.env` files, `docker-compose.yml` files, CI/CD pipeline definitions, and Helm values files are frequent vectors for credential leakage. A `.env` file committed with `DB_PASSWORD=my-secret` and later added to `.gitignore` is still present in the git history and accessible via `git log -p`.

The principle is simple: **no credential — in any form — should ever appear in a file that is or could be committed to a version control system**.

---

## Recommended Architecture

The recommended architecture places AWS Secrets Manager as the single system of record for all credentials. Access is mediated by IRSA so no static AWS credentials are required. Credentials are retrieved at pod startup, not stored in environment variables or Kubernetes Secrets (except as a short-lived cache managed by the External Secrets Operator in future iterations).

```
┌──────────────────────────────────────────────────────────────────────┐
│  Secret Creation / Rotation                                          │
│                                                                      │
│  Platform / Security Team  ──►  AWS Secrets Manager                 │
│                                  (System of Record)                  │
└──────────────────────────────────────┬───────────────────────────────┘
                                       │
                                       │ secretsmanager:GetSecretValue
                                       │ (via IRSA — no static AWS keys)
┌──────────────────────────────────────▼───────────────────────────────┐
│  Amazon EKS                                                          │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  LiteLLM Pod                                                │    │
│  │                                                             │    │
│  │  ServiceAccount: litellm-sa                                 │    │
│  │    ↓ IRSA token (auto-projected)                            │    │
│  │  AWS SDK calls sts:AssumeRoleWithWebIdentity                │    │
│  │    ↓ temporary credentials                                  │    │
│  │  secretsmanager:GetSecretValue("ai-gateway/litellm-secrets")│    │
│  │    ↓ secret JSON payload                                    │    │
│  │  LiteLLM reads LITELLM_MASTER_KEY, provider API keys        │    │
│  │    ↓                                                        │    │
│  │  Application processes requests                             │    │
│  └─────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

### Design Principles of This Architecture

1. **AWS Secrets Manager is the single system of record** — all secrets originate and are managed here
2. **IRSA eliminates static AWS credentials** — the pod authenticates to AWS using a projected OIDC token; no `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` is ever stored
3. **Secrets are retrieved at runtime** — the application reads credentials when it starts, not when the image is built
4. **No credential material appears in manifests or source code** — Kubernetes manifests, Helm values, and Dockerfiles contain no secrets

---

## Secrets To Be Managed

The following table enumerates all secrets that must be managed by the AI Gateway platform, their purpose, their storage path in AWS Secrets Manager, and whether they are required or optional.

| Secret | Purpose | Secrets Manager Path | Required |
|---|---|---|---|
| `LITELLM_MASTER_KEY` | Authenticates administrative API calls to the LiteLLM proxy | `ai-gateway/litellm-secrets` | **Required** |
| `OPENAI_API_KEY` | Authenticates calls to the OpenAI API (GPT models) | `ai-gateway/litellm-secrets` | Optional |
| `ANTHROPIC_API_KEY` | Authenticates calls to the Anthropic Claude API | `ai-gateway/litellm-secrets` | Optional |
| `COHERE_API_KEY` | Authenticates calls to the Cohere API | `ai-gateway/provider-credentials` | Optional |
| `HUGGINGFACE_API_KEY` | Authenticates calls to HuggingFace Inference endpoints | `ai-gateway/provider-credentials` | Optional |
| `LANGFUSE_SECRET_KEY` | Authenticates LiteLLM to the Langfuse observability backend | `ai-gateway/observability-secrets` | Future |
| `LANGFUSE_PUBLIC_KEY` | Public key for Langfuse project identification | `ai-gateway/observability-secrets` | Future |
| Database credentials | Connection string for LiteLLM's usage/spend tracking database | `ai-gateway/database-credentials` | Future |

### Secret Grouping Strategy

Secrets are grouped by function rather than stored as individual entries. This reduces the number of `GetSecretValue` calls at startup and simplifies rotation (rotating one secret JSON object rotates all related credentials atomically).

```
ai-gateway/
├── litellm-secrets          # Core LiteLLM credentials (master key)
├── provider-credentials     # Third-party AI provider API keys
├── observability-secrets    # Langfuse, DataDog, etc. (future)
└── database-credentials     # PostgreSQL/RDS connection details (future)
```

Each secret stores a JSON object:

```json
// ai-gateway/litellm-secrets
{
  "LITELLM_MASTER_KEY": "sk-...",
  "OPENAI_API_KEY": "sk-...",
  "ANTHROPIC_API_KEY": "sk-ant-..."
}
```

---

## Access Pattern

### Runtime Secret Retrieval

The preferred pattern is runtime retrieval — secrets are fetched by the application at startup via the AWS SDK. This ensures the application always uses the current version of a secret without requiring a pod restart after rotation (when combined with periodic refresh logic).

```
Step 1: EKS projects OIDC token into pod filesystem
        /var/run/secrets/eks.amazonaws.com/serviceaccount/token

Step 2: AWS SDK (boto3 / AWS SDK for Python) reads the token
        and calls sts:AssumeRoleWithWebIdentity

Step 3: STS returns short-lived temporary credentials

Step 4: SDK calls secretsmanager:GetSecretValue
        with SecretId = "ai-gateway/litellm-secrets"

Step 5: SDK returns JSON payload, application parses it
        and injects values into LiteLLM configuration

Step 6: LiteLLM starts; credentials are in memory only
        — never written to disk or environment variables
```

### LiteLLM Configuration Integration

LiteLLM supports reading credentials from environment variables. The recommended integration pattern is to use the AWS SDK to fetch secrets from Secrets Manager at container startup (via an init script or entrypoint wrapper) and export them as environment variables scoped to the process:

```bash
#!/bin/bash
# entrypoint.sh — fetch secrets and start LiteLLM
# This script is illustrative only; implement with appropriate error handling.

SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "ai-gateway/litellm-secrets" \
  --region "${AWS_REGION}" \
  --query SecretString \
  --output text)

export LITELLM_MASTER_KEY=$(echo "$SECRET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['LITELLM_MASTER_KEY'])")
export OPENAI_API_KEY=$(echo "$SECRET_JSON"     | python3 -c "import sys,json; print(json.load(sys.stdin).get('OPENAI_API_KEY',''))")

exec litellm --config /app/config.yaml
```

**Note:** In the current architecture, LiteLLM reads `LITELLM_MASTER_KEY` from a Kubernetes Secret referenced by `secretKeyRef` in the Deployment manifest. This is a pragmatic starting point. The External Secrets Operator (documented in the Future Evolution section) should be adopted to automate synchronisation from Secrets Manager to the Kubernetes Secret, eliminating the manual step.

---

## Rotation Strategy

### Manual Rotation (Current State)

In the initial deployment, secrets are rotated manually by a platform engineer:

1. Generate a new credential value (e.g. a new master key or API key)
2. Update the secret value in AWS Secrets Manager:
   ```bash
   aws secretsmanager put-secret-value \
     --secret-id "ai-gateway/litellm-secrets" \
     --secret-string '{"LITELLM_MASTER_KEY":"sk-new-value","OPENAI_API_KEY":"sk-..."}'
   ```
3. Trigger a rolling restart of the LiteLLM deployment to pick up the new value:
   ```bash
   kubectl rollout restart deployment/litellm -n ai-gateway
   ```
4. Verify the new pods start successfully and the old pods terminate cleanly
5. Record the rotation in the platform change log

**Limitation:** Manual rotation requires a pod restart, which introduces a brief increase in pod churn during the rolling update. With `maxUnavailable: 0` in the rolling update strategy, this is safe but should be scheduled during low-traffic windows.

### Automated Rotation (Target State)

AWS Secrets Manager supports automatic rotation via Lambda functions. For API keys managed by third-party providers (OpenAI, Anthropic), automated rotation is not directly available because those providers do not expose a rotation API. However, for internally generated secrets such as the `LITELLM_MASTER_KEY`, a Lambda-based rotation function can:

1. Generate a new master key
2. Update the LiteLLM database (if spend tracking is enabled) with the new key
3. Update the secret value in Secrets Manager
4. Trigger a rolling restart of the LiteLLM deployment via the Kubernetes API

Automated rotation should target a **30-day rotation cycle** for the master key and **90-day cycle** for third-party API keys (rotated manually at provider renewal).

### Future: External Secrets Operator

The [External Secrets Operator (ESO)](https://external-secrets.io/) is a Kubernetes operator that synchronises secrets from external secret stores (including AWS Secrets Manager) into Kubernetes Secrets automatically. When ESO is adopted:

1. The `ExternalSecret` custom resource defines which Secrets Manager path maps to which Kubernetes Secret
2. ESO polls Secrets Manager on a configurable interval (e.g. every 60 seconds)
3. When a secret is rotated in Secrets Manager, the Kubernetes Secret is updated automatically within the polling interval
4. LiteLLM pods can be configured to watch for Secret changes and reload without a restart (via volume-mounted secrets)

This eliminates the manual pod restart step from the rotation workflow and decouples secret rotation from deployment operations.

---

## Environment Separation

All secrets must be maintained independently for each environment. Using the same credentials across environments defeats the purpose of environment isolation and means a development compromise can directly impact production.

### Naming Convention

```
ai-gateway-{environment}/litellm-secrets
ai-gateway-{environment}/provider-credentials
ai-gateway-{environment}/observability-secrets
```

| Environment | Secrets Manager Path | AWS Account | EKS Cluster |
|---|---|---|---|
| Development | `ai-gateway-dev/litellm-secrets` | Dev account | `eks-dev` |
| Staging | `ai-gateway-staging/litellm-secrets` | Staging account | `eks-staging` |
| Production | `ai-gateway-prod/litellm-secrets` | Production account | `eks-prod` |

### Cross-Environment Rules

| Rule | Rationale |
|---|---|
| Dev credentials must **never** be used in production | A compromised dev key must not enable production access |
| Prod credentials must **never** appear in dev configurations | Reduces exposure surface; engineers should not have routine access to production secrets |
| IRSA roles must be scoped to their environment's AWS account | An EKS cluster in the dev account must not be able to assume an IRSA role in the production account |
| Separate IAM roles per environment | `litellm-irsa-dev`, `litellm-irsa-staging`, `litellm-irsa-prod` — each scoped to its own secrets path |

### IRSA Role Scoping Per Environment

The IAM policy for each environment's IRSA role must reference only that environment's secrets:

```json
// Production IRSA policy — Secrets Manager statement
{
  "Sid": "SecretsManagerProd",
  "Effect": "Allow",
  "Action": ["secretsmanager:GetSecretValue"],
  "Resource": [
    "arn:aws:secretsmanager:REGION:PROD_ACCOUNT_ID:secret:ai-gateway-prod/*"
  ]
}
```

The `ai-gateway-dev` and `ai-gateway-staging` paths are absent from the production policy. The inverse is true for dev and staging policies.

---

## Security Principles

The following principles govern all secrets management decisions in the Enterprise AI Gateway.

### No Secrets in GitHub

No credential — in any form — may appear in any file committed to the GitHub repository. This includes:

- Source code (`.py`, `.js`, `.go`, etc.)
- Kubernetes manifests (`.yaml`)
- Helm values files (`values.yaml`, `values-prod.yaml`)
- Dockerfiles and entrypoint scripts
- CI/CD pipeline definitions (`.github/workflows/*.yml`)
- Documentation (`.md`) — do not use real secrets as examples
- Test fixtures and mock data

**Enforcement controls:**
- GitHub secret scanning (enabled at the repository level)
- `git-secrets` pre-commit hook for local enforcement
- CI/CD step that runs `truffleHog` or `gitleaks` on every pull request

### No Static AWS Keys

The IAM identity model is built entirely on IRSA. No IAM user access keys (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`) are created, stored, or rotated for application use. If a static key is found in any configuration file or environment variable, it must be immediately revoked and the incident reviewed.

### Least Privilege

The IRSA role for LiteLLM grants `secretsmanager:GetSecretValue` only on the specific secret ARNs required. It does not grant:

- `secretsmanager:ListSecrets` — not needed; the path is known at configuration time
- `secretsmanager:DescribeSecret` — not needed for runtime operation
- `secretsmanager:CreateSecret` / `PutSecretValue` / `DeleteSecret` — the application must not be able to modify its own credentials

### Auditability

AWS Secrets Manager integrates with AWS CloudTrail. Every `GetSecretValue` call is logged with:

- The IAM principal that made the call (the IRSA role ARN + pod identity)
- The secret ARN that was accessed
- The timestamp
- The source IP address (the EKS node's VPC IP)

These logs provide a complete audit trail for compliance reporting and incident investigation. Ensure CloudTrail is enabled in all AWS accounts that host Secrets Manager secrets, and that trail logs are stored in an S3 bucket with object-lock enabled (immutable audit log).

### Principle of Separation of Duties

- **Platform team** creates and rotates secrets in Secrets Manager
- **Application (LiteLLM pod)** reads secrets at runtime via IRSA — read-only
- **Developers** access secrets in dev environments only, never in production
- **CI/CD pipelines** deploy Kubernetes manifests — they do not require access to secret values

---

## Future Evolution

### External Secrets Operator (ESO)

ESO is the recommended next step after the initial deployment. It provides:

- **Automatic sync** from Secrets Manager to Kubernetes Secrets on a configurable interval
- **No manual pod restarts** after secret rotation — the Kubernetes Secret is updated, and pods can be configured to reload
- **Declarative configuration** via `ExternalSecret` and `SecretStore` CRDs
- **Multi-backend support** — the same operator supports AWS Secrets Manager, HashiCorp Vault, Azure Key Vault, and others, enabling future cloud portability

Example `ExternalSecret` resource:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: litellm-secrets
  namespace: ai-gateway
spec:
  refreshInterval: 60s
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: litellm-secrets          # Creates/updates this Kubernetes Secret
    creationPolicy: Owner
  data:
    - secretKey: master-key        # Key in the Kubernetes Secret
      remoteRef:
        key: ai-gateway-prod/litellm-secrets
        property: LITELLM_MASTER_KEY
```

### Sealed Secrets

[Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) by Bitnami provides a mechanism to commit encrypted secrets to version control safely. A `SealedSecret` is a Kubernetes custom resource that contains a secret encrypted with the cluster's public key — it can only be decrypted by the Sealed Secrets controller running in that specific cluster.

**When to use:** Sealed Secrets is most valuable when GitOps workflows (Argo CD, Flux) require secrets to be managed declaratively in Git alongside other manifests. In the current architecture, AWS Secrets Manager is preferred because it provides rotation, auditing, and cross-team governance that Sealed Secrets does not.

**Complementary pattern:** Sealed Secrets and ESO can coexist — use ESO for runtime credentials that benefit from automated rotation, and Sealed Secrets for cluster-bootstrap credentials (e.g. the ESO `ClusterSecretStore` credentials used to authenticate ESO itself to Secrets Manager).

### HashiCorp Vault Integration

HashiCorp Vault is the industry-standard secrets management platform for multi-cloud and on-premises environments. If the organisation operates a Vault cluster (common in large enterprises with hybrid cloud deployments), LiteLLM secrets can be managed in Vault rather than AWS Secrets Manager.

The ESO `ClusterSecretStore` supports Vault as a backend, requiring no changes to the LiteLLM application or Kubernetes manifests — only the ESO configuration changes.

**When to prefer Vault over Secrets Manager:**
- The organisation already operates a Vault cluster
- Secrets must be shared across AWS and non-AWS workloads
- Dynamic secrets (auto-generated, short-lived database credentials) are required
- Fine-grained policy control beyond IAM is needed

---

## Summary

| Principle | Current Implementation | Future Target |
|---|---|---|
| Credential storage | AWS Secrets Manager | AWS Secrets Manager (no change) |
| Pod credential access | IRSA + manual `secretKeyRef` in Deployment | IRSA + External Secrets Operator auto-sync |
| Secret rotation | Manual + pod restart | Automated via Secrets Manager rotation Lambda |
| No secrets in Git | Enforced via policy + GitHub secret scanning | Enforced + automated pre-commit hooks in CI |
| Environment separation | Separate Secrets Manager paths per environment | Separate AWS accounts per environment |
| Audit trail | AWS CloudTrail + Secrets Manager logs | CloudTrail + centralised SIEM integration |

The transition from the current state to the future target is incremental. Each step can be adopted independently without disrupting the running gateway.
