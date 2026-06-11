# Repository Gap Analysis

This document is a structured assessment of the enterprise-ai-gateway-aws repository. It scores the current state across six dimensions, identifies every remaining gap, classifies each gap by priority, and issues a definitive recommendation on what action to take next.

**Date:** 2026-06-11  
**Repository:** `github.com:chrahul/enterprise-ai-gateway-aws`  
**Branch:** `main`  
**Commit at assessment:** `96fdc61`

---

## Current Repository Score

| Dimension | Score | Assessment |
|---|---|---|
| **Documentation** | 95 / 100 | Exceptional. 23 docs covering architecture, ADRs, IRSA, secrets, build plan, roadmap, executive summary, learning path, and Kubernetes review. Only gaps: `docs/90-testing.md` and `docs/91-troubleshooting.md` are empty placeholder files. |
| **Architecture** | 95 / 100 | Complete and well-reasoned. Reference architecture, 6 ADRs, IRSA design, secrets strategy, and build plan together form a production-grade architecture corpus. Gap: no multi-region DR design. |
| **Kubernetes** | 88 / 100 | All 8 manifests are present and production-grade. Namespace, Deployment (pinned image), Service, Ingress, ServiceAccount, HPA, PDB, NetworkPolicy. All 12 cross-validation checks pass. Gap: image is pinned but not digest-pinned; no ConfigMap for LiteLLM config; `litellm/config.yaml` is empty. |
| **Security** | 82 / 100 | Strong posture on paper. IRSA design documented, no static credentials in manifests, `runAsNonRoot`, `capabilities.drop: ALL`, NetworkPolicy present. Gap: no `.gitignore` (no protection against accidental secret commits); placeholder ARNs not yet real; NetworkPolicy not enforced until VPC CNI network policy addon is enabled. |
| **Operations** | 55 / 100 | HPA, PDB, and topology spread are configured. Gap: no CI/CD pipeline (`.github/workflows/`); no `Makefile` for operator commands; `docs/90-testing.md` and `docs/91-troubleshooting.md` are empty; no runbook; no alerting configuration. |
| **Deployment Readiness** | 40 / 100 | All design artifacts exist. **Zero AWS resources have been created.** No EKS cluster, no IAM role, no Secrets Manager secret, no Bedrock model access, no ALB, no real domain. `litellm/config.yaml` is empty — the application cannot start without it. |

### **Overall Repository Score: 76 / 100**

The score is asymmetric: documentation and architecture are near-complete, while deployment readiness reflects the honest reality — nothing has been built in AWS yet.

---

## Top 10 Remaining Gaps

Ranked by impact on the ability to deploy and operate the gateway.

### GAP-001 — `litellm/config.yaml` Is Empty ⚠️ BLOCKER

**Impact:** Critical  
**Category:** Implementation

The LiteLLM proxy cannot start without a valid `config.yaml`. This file defines which models are available, how they are routed, what the master key is, and what callbacks (observability) are active. Without it, every pod that starts will either crash or serve zero models.

The deployment manifest references `/app/config.yaml` via the `LITELLM_CONFIG` environment variable. If this file is not mounted and populated, LiteLLM starts with no model definitions.

**Required content (minimum):**
```yaml
model_list:
  - model_name: claude-3-haiku
    litellm_params:
      model: bedrock/anthropic.claude-3-haiku-20240307-v1:0
      aws_region_name: us-east-1
  - model_name: claude-3-5-sonnet
    litellm_params:
      model: bedrock/anthropic.claude-3-5-sonnet-20241022-v2:0
      aws_region_name: us-east-1

litellm_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  drop_params: true

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

**Fix:** Write `litellm/config.yaml` with at least the Bedrock model definitions and create a Kubernetes ConfigMap to mount it into the pod.

---

### GAP-002 — No Kubernetes ConfigMap for LiteLLM Config ⚠️ BLOCKER

**Impact:** Critical  
**Category:** Kubernetes

The Deployment mounts `LITELLM_CONFIG=/app/config.yaml` but there is no `kubernetes/configmap.yaml` that mounts the config file into the pod. The config cannot reach the pod without this resource.

**Fix:** Create `kubernetes/configmap.yaml` from `litellm/config.yaml` and add a `volumeMount` + `volume` referencing it in the Deployment.

---

### GAP-003 — No AWS Infrastructure Exists ⚠️ BLOCKER

**Impact:** Critical  
**Category:** Deployment

There is no EKS cluster, no IAM role, no Secrets Manager secret, no ALB, no OIDC provider, and no Bedrock model access in any AWS account. The repository describes a deployment that does not exist.

This is by design — the repository has been built in planning/design mode. It is the primary reason deployment readiness scores 40/100 rather than 80+.

**Fix:** Execute Phase 2 of [docs/93-eks-build-plan.md](93-eks-build-plan.md).

---

### GAP-004 — IRSA Role ARN Is a Placeholder ⚠️ BLOCKER

**Impact:** Critical  
**Category:** Security / Deployment

`kubernetes/serviceaccount.yaml` contains:
```yaml
eks.amazonaws.com/role-arn: "arn:aws:iam::ACCOUNT_ID:role/ROLE_NAME"
```

Until the IRSA role exists in AWS and this value is replaced, every LiteLLM pod will use the node's instance role (or no role) when calling AWS APIs. Bedrock calls will return `AccessDenied`.

**Fix:** Create the IAM role (Phase 4 of the build plan), retrieve the ARN, update `serviceaccount.yaml`.

---

### GAP-005 — No Bedrock Model Access Enabled ⚠️ BLOCKER

**Impact:** Critical  
**Category:** Deployment

Amazon Bedrock requires explicit model access requests per AWS account. Even with correct IAM permissions, `InvokeModel` returns `AccessDeniedException` until access is granted in the console.

**Fix:** Navigate to the Bedrock console → Model access → Enable Claude 3 Haiku, Claude 3.5 Sonnet, Amazon Titan. Validate with `aws bedrock list-foundation-models`.

---

### GAP-006 — `litellm/secrets-example.yaml` Is Empty

**Impact:** High  
**Category:** Developer Experience

This file was presumably intended as a reference for the secrets structure used by LiteLLM. It is empty. Engineers setting up the project for the first time have no reference for what secret keys to create.

**Fix:** Populate with a non-sensitive example showing the expected JSON structure with placeholder values. Do not add real credentials.

---

### GAP-007 — No `.gitignore`

**Impact:** High  
**Category:** Security

There is no `.gitignore` file. This means `.env` files, `kubeconfig` files, AWS credential files, and Terraform state files could be accidentally committed. The secrets management strategy document explicitly prohibits secrets in Git, but there is no technical enforcement.

**Fix:** Create `.gitignore` with entries for `.env`, `*.tfstate`, `kubeconfig`, `cluster-config.yaml`, `litellm-policy.json`, `aws-credentials`, and other sensitive files.

---

### GAP-008 — No CI/CD Pipeline

**Impact:** High  
**Category:** Operations

There are no GitHub Actions workflows (no `.github/` directory). Without a pipeline:
- There is no automated YAML validation on pull requests
- There is no protection against committing broken manifests
- Image tag upgrades require manual `kubectl apply` — no automated deploy

**Fix:** Create `.github/workflows/validate.yml` (YAML lint + `kubectl dry-run --validate`) as a minimum. A deployment workflow can be added when the cluster exists.

---

### GAP-009 — `docs/90-testing.md` and `docs/91-troubleshooting.md` Are Empty

**Impact:** Medium  
**Category:** Operations

Two files that appear in the documentation index are completely empty. An operator encountering an issue has no troubleshooting guidance. A QA engineer has no test procedures.

**Fix:** Populate with the validation commands from [docs/93-eks-build-plan.md](93-eks-build-plan.md) Phase 8 (testing) and common failure modes (pod crash loops, IRSA auth failures, NetworkPolicy blocking traffic, ALB not provisioning).

---

### GAP-010 — No ACM Certificate or Domain

**Impact:** Medium  
**Category:** Deployment

`kubernetes/ingress.yaml` contains:
```yaml
alb.ingress.kubernetes.io/certificate-arn: "arn:aws:acm:us-east-1:ACCOUNT_ID:certificate/CERTIFICATE_ID"
host: ai-gateway.PLACEHOLDER_DOMAIN.com
```

Until an ACM certificate is provisioned and a domain is registered or delegated, the ALB will not provision on port 443. The ingress will either fail or fall back to HTTP.

**Fix:** Provision an ACM certificate (or use ACM with automatic DNS validation), update the ARN and host in `ingress.yaml`.

---

## Must Have Before First Deployment

These are hard blockers. The gateway will not function without resolving each item.

| # | Item | File to Change | Effort |
|---|---|---|---|
| 1 | Write `litellm/config.yaml` with Bedrock model definitions | `litellm/config.yaml` | 30 min |
| 2 | Create `kubernetes/configmap.yaml` to mount the config | New file | 20 min |
| 3 | Update Deployment to mount the ConfigMap volume | `kubernetes/deployment.yaml` | 15 min |
| 4 | Create EKS cluster (`ai-gateway-prod`) | AWS — follow [93-eks-build-plan.md](93-eks-build-plan.md) Phase 2 | 30 min |
| 5 | Create IAM role + IRSA (Phase 4 of build plan) | AWS + `kubernetes/serviceaccount.yaml` | 30 min |
| 6 | Enable Bedrock model access in AWS console | AWS console | 15 min |
| 7 | Create `ai-gateway-prod/litellm-secrets` in Secrets Manager | AWS | 15 min |
| 8 | Create `litellm-secrets` Kubernetes Secret | `kubectl create secret` | 5 min |
| 9 | Provision ACM certificate and update `ingress.yaml` | AWS + `kubernetes/ingress.yaml` | 20 min |
| 10 | Create `.gitignore` | New file | 10 min |

**Total estimated effort to unblock deployment: ~3 hours**

---

## Should Have Before Production

These items are not hard blockers for a first deployment, but their absence creates operational or security risk in a production environment.

| Priority | Item | Rationale |
|---|---|---|
| High | GitHub Actions CI pipeline for YAML validation | Prevents broken manifests reaching the cluster |
| High | Populate `docs/90-testing.md` with test procedures | Required for QA sign-off |
| High | Populate `docs/91-troubleshooting.md` with runbook | Required for on-call engineers |
| High | Populate `litellm/secrets-example.yaml` | Required for new engineers to understand secret structure |
| Medium | Enable VPC CNI network policy enforcement | NetworkPolicy manifests are present but unenfored until this addon is enabled |
| Medium | Add `startupProbe` to Deployment | Prevents readiness probe failures on slow first boot |
| Medium | Implement automated Secrets Manager rotation Lambda | Eliminates manual rotation + pod restart workflow |
| Medium | Enable CloudWatch Container Insights | Provides node and pod-level metrics beyond what Metrics Server exposes |
| Low | Add image digest pinning alongside version tag | Eliminates residual risk of tag mutation (even with pinned version) |
| Low | Create Helm chart wrapping the Kubernetes manifests | Simplifies multi-environment deployment; enables `helm diff` for change review |

---

## Nice To Have

Future enhancements that increase platform maturity but are not required for a functioning production gateway.

| Item | Value |
|---|---|
| External Secrets Operator | Eliminates manual Kubernetes Secret sync; enables zero-downtime secret rotation |
| Terraform IaC for AWS resources | Makes EKS cluster, IAM roles, and Secrets Manager resources version-controlled and repeatable |
| Langfuse observability backend | Provides LLM-specific trace visibility (prompt, completion, tokens, cost per request) beyond what CloudWatch offers |
| Multi-region active-passive failover | Increases availability SLA from ~99.9% (single region) to ~99.99% |
| OpenTelemetry Collector sidecar | Enables vendor-neutral trace export to any OTLP-compatible backend |
| LiteLLM spend tracking database (PostgreSQL/RDS) | Enables per-key, per-team, per-model cost attribution and budget enforcement |
| Amazon API Gateway in front of ALB | Adds request throttling, usage plans, and API key management at the edge |
| Sealed Secrets for GitOps workflows | Enables safe storage of encrypted secrets in Git for Argo CD / Flux deployments |
| Bedrock Guardrails integration | Adds content filtering, PII detection, and topic denial at the model invocation layer |
| VPC endpoints for Bedrock and Secrets Manager | Eliminates internet egress for AWS API calls; reduces attack surface and data transfer costs |

---

## Recommended Next Step

### **A. Build AWS Infrastructure**

**Rationale:**

The repository has achieved its documentation and design objectives. The architecture is sound, the Kubernetes manifests are production-grade, the security model is well-defined, and the deployment blueprint is complete. The gap analysis confirms the user's prediction: the remaining blockers are not design gaps — they are execution gaps.

Specifically, items GAP-001 through GAP-005 (the five most critical gaps) fall into two categories:

1. **One implementation task** (GAP-001, GAP-002): Write `litellm/config.yaml` and create a Kubernetes ConfigMap. This is a 45-minute task that can be done in parallel with or immediately before cluster creation.

2. **Four AWS provisioning tasks** (GAP-003, GAP-004, GAP-005, and the ACM certificate): These require an AWS account with Bedrock access. No amount of additional repository work removes these blockers.

**The repository is stronger than most public AI Gateway reference implementations.** Continuing to add documentation at this point is a form of analysis paralysis. The real information — what works, what needs tuning, what was missed — can only come from running the system.

**Recommended execution order for Step 16:**

1. Write `litellm/config.yaml` (30 minutes — can be done now, without AWS access)
2. Create `kubernetes/configmap.yaml` (20 minutes — can be done now)
3. Create `.gitignore` (10 minutes — can be done now)
4. Commit the above three items
5. Execute [docs/93-eks-build-plan.md](93-eks-build-plan.md) Phases 1–3 (EKS cluster + add-ons)
6. Execute Phase 4 (IRSA role)
7. Execute Phase 5 (Secrets Manager)
8. Execute Phase 6–8 (Deploy, validate, test)

**Items B (Improve Repository), C (Add Missing Kubernetes Components), and D (Implement LiteLLM Configuration)** are all valid — but C and D are pre-conditions that should be completed in the first hour of Step 16, not as a separate step that delays infrastructure work.

---

## Score Summary

| Dimension | Score |
|---|---|
| Documentation | 95 / 100 |
| Architecture | 95 / 100 |
| Kubernetes | 88 / 100 |
| Security | 82 / 100 |
| Operations | 55 / 100 |
| Deployment Readiness | 40 / 100 |
| **Overall** | **76 / 100** |

The gap between documentation (95) and deployment readiness (40) is the defining characteristic of this repository's current state. It is not a weakness — it reflects a deliberate design-first approach. The design is complete. The gap closes only by building.
