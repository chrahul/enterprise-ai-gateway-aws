# EKS Build Plan

This document is the authoritative deployment blueprint for building the Enterprise AI Gateway on Amazon EKS. It provides a phased, end-to-end guide that takes an engineer from an empty AWS account to a fully operational, production-grade AI Gateway serving requests through Amazon Bedrock.

The build plan is structured as eight sequential phases. Each phase must be completed and validated before the next begins. Skipping phases or performing them out of order is a common source of deployment failures — particularly phases 4 (IRSA) and 5 (Secrets), which are dependencies for phase 6 (LiteLLM deployment).

**Intended audience:** Cloud Engineers, Platform Engineers, DevOps Engineers, Solution Architects

**Repository manifests:** `kubernetes/` directory  
**Supporting design documents:**
- [95-irsa-and-iam-design.md](95-irsa-and-iam-design.md) — IAM and IRSA architecture
- [94-secrets-management-strategy.md](94-secrets-management-strategy.md) — Secrets architecture

---

## Phase 1 — AWS Foundations

Before any infrastructure is created, ensure the local environment and AWS account are correctly configured.

### 1.1 AWS Account and Region Selection

| Decision | Value | Rationale |
|---|---|---|
| **Primary region** | `us-east-1` | Amazon Bedrock has the broadest model availability in `us-east-1`. Choose the region where your target models are enabled. |
| **Account structure** | Separate accounts for dev / staging / prod | Enforces blast-radius containment and IAM boundary separation. See [94-secrets-management-strategy.md](94-secrets-management-strategy.md) — Environment Separation. |
| **VPC** | Dedicated VPC (do not use default VPC) | The default VPC is a shared, uncontrolled network. Create a dedicated VPC with private subnets for EKS nodes and public subnets for the ALB. |

**Verify Bedrock model access in your target region before proceeding:**
```bash
aws bedrock list-foundation-models \
  --region us-east-1 \
  --query "modelSummaries[?modelLifecycle.status=='ACTIVE'].[modelId]" \
  --output table
```

### 1.2 IAM Prerequisites

The engineer executing this build plan requires the following IAM permissions. These are elevated permissions required only for cluster creation — they should not be granted permanently to application roles.

| Permission Set | Purpose |
|---|---|
| `AdministratorAccess` or equivalent | EKS cluster creation, VPC/subnet tagging, IAM role creation |
| `eks:*` | Create and manage EKS clusters |
| `iam:CreateRole`, `iam:PutRolePolicy`, `iam:AttachRolePolicy` | Create IRSA roles |
| `secretsmanager:CreateSecret`, `secretsmanager:PutSecretValue` | Create initial secrets |

> **Note:** After the cluster is built, these elevated permissions should be removed from the deployment identity. Day-2 operations (deployments, scaling) should use a scoped role, not administrator access.

### 1.3 Required Local Tools

Install and verify each tool before proceeding:

```bash
# AWS CLI v2
aws --version
# Expected: aws-cli/2.x.x

# kubectl
kubectl version --client
# Expected: v1.31.x or later

# eksctl
eksctl version
# Expected: 0.190.x or later

# helm (required for AWS Load Balancer Controller)
helm version
# Expected: v3.x.x

# Verify AWS credentials are configured
aws sts get-caller-identity
```

**Installation references:**
- AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html
- kubectl: https://kubernetes.io/docs/tasks/tools/
- eksctl: https://eksctl.io/installation/
- helm: https://helm.sh/docs/intro/install/

---

## Phase 2 — EKS Cluster

### 2.1 Cluster Specification

| Parameter | Recommended Value | Notes |
|---|---|---|
| **Cluster name** | `ai-gateway-prod` | Use environment suffix: `ai-gateway-dev`, `ai-gateway-staging`, `ai-gateway-prod` |
| **Kubernetes version** | `1.31` | Use the latest EKS-supported stable version. Check `aws eks describe-addon-versions` for current supported versions. |
| **Region** | `us-east-1` | Match the region selected in Phase 1 |
| **Availability zones** | `us-east-1a`, `us-east-1b`, `us-east-1c` | Three AZs are required for production HA. Two is the minimum for non-production. |
| **VPC** | Dedicated, pre-created | Do not use the default VPC |

### 2.2 Node Group Strategy

LiteLLM is a CPU-bound proxy workload. It does not perform inference locally — it forwards requests to Bedrock and streams responses back. GPU instances are not required.

| Environment | Instance Type | Node Count | rationale |
|---|---|---|---|
| Development | `t3.medium` (2 vCPU, 4 GiB) | 2 nodes (1 per AZ) | Cost-minimised; sufficient for functional testing |
| Staging | `t3.large` (2 vCPU, 8 GiB) | 2 nodes (2 AZs) | Mirrors prod shape at reduced scale |
| Production | `m5.large` (2 vCPU, 8 GiB) | 3–6 nodes (3 AZs) | Burstable-free, predictable performance; cluster autoscaler scales within this range |

**Why `m5.large` for production over `t3.large`:**
`t3` instances use CPU credits that can be exhausted under sustained load. LiteLLM handling concurrent AI inference streams is not a burst workload — it maintains sustained CPU pressure during peak usage. `m5` provides consistent, unburst CPU performance.

### 2.3 Cluster Creation (eksctl)

Save the following as `cluster-config.yaml` (do not commit to the repository — it contains environment-specific values):

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ai-gateway-prod
  region: us-east-1
  version: "1.31"

availabilityZones:
  - us-east-1a
  - us-east-1b
  - us-east-1c

iam:
  withOIDC: true    # REQUIRED — enables IRSA (Phase 4)

managedNodeGroups:
  - name: ai-gateway-nodes
    instanceType: m5.large
    minSize: 3
    maxSize: 6
    desiredCapacity: 3
    volumeSize: 50
    privateNetworking: true    # Nodes in private subnets
    labels:
      role: worker
    tags:
      Environment: production
      Project: enterprise-ai-gateway
    iam:
      withAddonPolicies:
        awsLoadBalancerController: true
        cloudWatch: true

cloudWatch:
  clusterLogging:
    enableTypes:
      - api
      - audit
      - authenticator
      - controllerManager
      - scheduler
```

```bash
# Create the cluster (takes approximately 15–20 minutes)
eksctl create cluster -f cluster-config.yaml

# Verify cluster is active
aws eks describe-cluster \
  --name ai-gateway-prod \
  --region us-east-1 \
  --query "cluster.status"
# Expected: "ACTIVE"

# Update local kubeconfig
aws eks update-kubeconfig \
  --name ai-gateway-prod \
  --region us-east-1

# Verify connectivity
kubectl get nodes
```

### 2.4 High Availability Design

The cluster is designed for high availability across three dimensions:

| Dimension | Mechanism | Configuration |
|---|---|---|
| **Node failure** | Managed node group with autoscaling | `minSize: 3`, one node per AZ |
| **Pod failure** | Deployment `replicas: 2` with `maxUnavailable: 0` | See `kubernetes/deployment.yaml` |
| **AZ failure** | `topologySpreadConstraints` + `podAntiAffinity` | Pods spread across AZs and nodes |
| **Disruptions** | PodDisruptionBudget `minAvailable: 1` | See `kubernetes/pdb.yaml` |

---

## Phase 3 — EKS Add-ons

### 3.1 Core Add-ons

Install or verify the following core add-ons. Managed node groups created with `eksctl` typically install these automatically; verify they are running before proceeding.

```bash
# List installed add-ons
aws eks list-addons --cluster-name ai-gateway-prod --region us-east-1
```

| Add-on | Purpose | Minimum Version |
|---|---|---|
| `vpc-cni` | Pod networking with native VPC IPs | `v1.18.x` |
| `coredns` | In-cluster DNS resolution | `v1.11.x` |
| `kube-proxy` | Service networking and iptables rules | `v1.31.x` |

**Enable VPC CNI network policy support** (required for `kubernetes/networkpolicy.yaml` to take effect):

```bash
aws eks update-addon \
  --cluster-name ai-gateway-prod \
  --addon-name vpc-cni \
  --region us-east-1 \
  --configuration-values '{"enableNetworkPolicy": "true"}'

# Verify network policy is enabled
aws eks describe-addon \
  --cluster-name ai-gateway-prod \
  --addon-name vpc-cni \
  --region us-east-1 \
  --query "addon.configurationValues"
```

### 3.2 AWS Load Balancer Controller

The ALB Ingress in `kubernetes/ingress.yaml` requires the AWS Load Balancer Controller. Install it via Helm:

```bash
# Add the EKS Helm chart repository
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Create the IAM policy for the controller
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.0/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json

# Create the ServiceAccount with IRSA for the controller
eksctl create iamserviceaccount \
  --cluster ai-gateway-prod \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

# Install the controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName=ai-gateway-prod \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

# Verify the controller is running
kubectl get deployment -n kube-system aws-load-balancer-controller
```

### 3.3 Metrics Server

Required for the HorizontalPodAutoscaler in `kubernetes/hpa.yaml`:

```bash
# Install metrics-server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Verify metrics-server is running
kubectl get deployment metrics-server -n kube-system

# Verify metrics are available (wait 2–3 minutes after install)
kubectl top nodes
kubectl top pods -n ai-gateway
```

---

## Phase 4 — IAM / IRSA

This phase is covered in detail in [95-irsa-and-iam-design.md](95-irsa-and-iam-design.md). The steps below are a condensed deployment checklist.

### 4.1 Verify OIDC Provider

```bash
# Retrieve the OIDC issuer URL
aws eks describe-cluster \
  --name ai-gateway-prod \
  --region us-east-1 \
  --query "cluster.identity.oidc.issuer" \
  --output text

# Associate the OIDC provider with IAM (if not already done by eksctl)
eksctl utils associate-iam-oidc-provider \
  --cluster ai-gateway-prod \
  --region us-east-1 \
  --approve
```

### 4.2 Create the LiteLLM IRSA Role

```bash
# Create the IAM role using eksctl (handles trust policy automatically)
eksctl create iamserviceaccount \
  --cluster ai-gateway-prod \
  --namespace ai-gateway \
  --name litellm-sa \
  --attach-policy-arn arn:aws:iam::ACCOUNT_ID:policy/LiteLLMGatewayPolicy \
  --approve \
  --override-existing-serviceaccounts

# Verify the annotation was applied
kubectl get serviceaccount litellm-sa -n ai-gateway -o yaml | grep eks.amazonaws.com
```

The `LiteLLMGatewayPolicy` must be created first with the permissions defined in [95-irsa-and-iam-design.md — IAM Policy Example](95-irsa-and-iam-design.md#iam-policy-example):

```bash
# Save the policy JSON from 95-irsa-and-iam-design.md as litellm-policy.json
# Replace REGION, ACCOUNT_ID, and model ARNs with environment-specific values

aws iam create-policy \
  --policy-name LiteLLMGatewayPolicy \
  --policy-document file://litellm-policy.json
```

---

## Phase 5 — Secrets

This phase is covered in detail in [94-secrets-management-strategy.md](94-secrets-management-strategy.md). The steps below are a condensed deployment checklist.

### 5.1 Create Secrets in AWS Secrets Manager

```bash
# Create the LiteLLM secrets (replace values with real credentials)
aws secretsmanager create-secret \
  --name "ai-gateway-prod/litellm-secrets" \
  --region us-east-1 \
  --description "LiteLLM master key and AI provider credentials" \
  --secret-string '{
    "LITELLM_MASTER_KEY": "sk-your-master-key-here",
    "OPENAI_API_KEY": "sk-optional-openai-key",
    "ANTHROPIC_API_KEY": "sk-ant-optional-anthropic-key"
  }'

# Verify the secret was created
aws secretsmanager describe-secret \
  --secret-id "ai-gateway-prod/litellm-secrets" \
  --region us-east-1
```

### 5.2 Create the Kubernetes Secret for LiteLLM

In the current architecture, the master key is injected via a Kubernetes Secret referenced in the Deployment. Create it directly (do not add to source control):

```bash
# Retrieve the master key from Secrets Manager
MASTER_KEY=$(aws secretsmanager get-secret-value \
  --secret-id "ai-gateway-prod/litellm-secrets" \
  --region us-east-1 \
  --query "SecretString" \
  --output text | python3 -c "import sys,json; print(json.load(sys.stdin)['LITELLM_MASTER_KEY'])")

# Create the Kubernetes Secret
kubectl create secret generic litellm-secrets \
  --namespace ai-gateway \
  --from-literal=master-key="$MASTER_KEY"

# Verify (value will be base64-encoded — do not log the decoded value)
kubectl get secret litellm-secrets -n ai-gateway
```

---

## Phase 6 — Deploy LiteLLM

### 6.1 Apply the Namespace First

```bash
kubectl apply -f kubernetes/namespace.yaml
kubectl get namespace ai-gateway
```

### 6.2 Apply Remaining Manifests

```bash
# Apply all manifests in dependency order
kubectl apply -f kubernetes/serviceaccount.yaml
kubectl apply -f kubernetes/deployment.yaml
kubectl apply -f kubernetes/service.yaml
kubectl apply -f kubernetes/ingress.yaml
kubectl apply -f kubernetes/networkpolicy.yaml
kubectl apply -f kubernetes/hpa.yaml
kubectl apply -f kubernetes/pdb.yaml

# Or apply all at once (Kubernetes handles ordering)
kubectl apply -f kubernetes/
```

### 6.3 Verify Deployment

```bash
# Watch pods come up
kubectl rollout status deployment/litellm -n ai-gateway

# Check pod status
kubectl get pods -n ai-gateway -o wide

# Check pod logs
kubectl logs -l app=litellm -n ai-gateway --tail=50

# Verify HPA is active
kubectl get hpa -n ai-gateway

# Verify PDB is active
kubectl get pdb -n ai-gateway
```

### 6.4 Update serviceaccount.yaml with IRSA ARN

Before deploying, update `kubernetes/serviceaccount.yaml` with the IAM role ARN created in Phase 4:

```bash
# Retrieve the role ARN created by eksctl
aws iam get-role \
  --role-name eksctl-ai-gateway-prod-addon-iamserviceaccount-ai-gateway-litellm-sa-Role \
  --query "Role.Arn" \
  --output text
```

Replace the `ACCOUNT_ID` and `ROLE_NAME` placeholders in `kubernetes/serviceaccount.yaml` with the actual ARN, then re-apply.

---

## Phase 7 — Bedrock Integration

### 7.1 Enable Model Access in Bedrock Console

Model access in Amazon Bedrock is **not enabled by default**. You must explicitly request access for each model family.

1. Navigate to the [AWS Bedrock console](https://console.aws.amazon.com/bedrock)
2. Select **Model access** from the left navigation
3. Click **Manage model access**
4. Enable access for:
   - Anthropic Claude (recommended: Claude 3.5 Sonnet, Claude 3 Haiku)
   - Amazon Titan (Text Express, Titan Embeddings)
   - Any other models defined in `litellm/config.yaml`
5. Submit the access request and wait for approval (Claude models may take minutes to hours)

**Verify access:**
```bash
# From your local machine (with appropriate IAM permissions)
aws bedrock list-foundation-models \
  --region us-east-1 \
  --query "modelSummaries[?modelLifecycle.status=='ACTIVE'].[modelId,providerName]" \
  --output table
```

### 7.2 Validate IRSA-to-Bedrock Access from the Pod

```bash
# Exec into a running LiteLLM pod
kubectl exec -it -n ai-gateway \
  $(kubectl get pod -n ai-gateway -l app=litellm -o jsonpath='{.items[0].metadata.name}') \
  -- /bin/bash

# Inside the pod — verify the OIDC token is projected
cat /var/run/secrets/eks.amazonaws.com/serviceaccount/token | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool

# Verify the IAM identity the pod assumes
aws sts get-caller-identity
# Expected: ARN of the litellm-irsa-prod role

# Verify Bedrock access
aws bedrock list-foundation-models --region us-east-1
```

### 7.3 Validate LiteLLM Config

```bash
# Review the LiteLLM config mounted in the pod
kubectl exec -it -n ai-gateway \
  $(kubectl get pod -n ai-gateway -l app=litellm -o jsonpath='{.items[0].metadata.name}') \
  -- cat /app/config.yaml
```

---

## Phase 8 — Validation

Run the complete validation checklist before declaring the deployment complete. Each item must pass before the environment is considered production-ready.

### 8.1 Infrastructure Validation Checklist

```bash
# ── Pods ────────────────────────────────────────────────────────────
kubectl get pods -n ai-gateway
# Expected: 2/2 pods in Running state, Ready 1/1

# ── Pod health endpoint ──────────────────────────────────────────────
kubectl port-forward svc/litellm -n ai-gateway 8080:80
curl -s http://localhost:8080/health
# Expected: {"status":"healthy"} or similar

# ── ALB created ─────────────────────────────────────────────────────
kubectl get ingress -n ai-gateway
# Expected: ADDRESS column shows an ALB DNS name
# (ALB creation can take 2–5 minutes after ingress apply)

# ── ALB target group healthy ─────────────────────────────────────────
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --query "TargetGroups[?contains(TargetGroupName,'ai-gateway')].TargetGroupArn" \
    --output text) \
  --query "TargetHealthDescriptions[*].[Target.Id,TargetHealth.State]" \
  --output table
# Expected: All targets in "healthy" state

# ── HTTPS endpoint ────────────────────────────────────────────────────
ALB_DNS=$(kubectl get ingress -n ai-gateway -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
curl -s https://${ALB_DNS}/health
# Expected: 200 OK (requires DNS CNAME or /etc/hosts entry for custom domain)

# ── HPA active ────────────────────────────────────────────────────────
kubectl describe hpa litellm-hpa -n ai-gateway
# Expected: Current replicas >= minReplicas, no "unable to get metrics" warnings

# ── Logs visible ─────────────────────────────────────────────────────
kubectl logs -l app=litellm -n ai-gateway --tail=20
# Expected: Structured log output, no ERROR or FATAL entries at startup
```

### 8.2 Functional Validation

```bash
# ── Test a completion via the LiteLLM API ────────────────────────────
# (Substitute your LITELLM_MASTER_KEY and ALB endpoint)

curl -X POST https://${ALB_DNS}/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d '{
    "model": "bedrock/anthropic.claude-3-haiku-20240307-v1:0",
    "messages": [{"role": "user", "content": "Say hello in one sentence."}],
    "max_tokens": 50
  }'
# Expected: 200 OK with a completion response from Claude via Bedrock
```

### 8.3 Observability Validation

```bash
# ── CloudWatch logs ───────────────────────────────────────────────────
aws logs describe-log-groups \
  --log-group-name-prefix "/aws/containerinsights/ai-gateway-prod" \
  --region us-east-1
# Expected: Log groups present for application and system logs

# ── CloudTrail — verify Bedrock calls are being logged ───────────────
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=InvokeModel \
  --region us-east-1 \
  --max-results 5
# Expected: Recent InvokeModel events from the litellm-irsa-prod role
```

---

## Estimated Cost

The following estimates are for reference only. Actual costs depend on traffic volume, token consumption at the AI provider level, and regional pricing. All estimates are for `us-east-1` at 2026 pricing.

> **Important:** Amazon Bedrock usage costs (per-token charges) are not included below. These are highly workload-dependent and are tracked separately.

### Development Environment

| Resource | Specification | Estimated Monthly Cost |
|---|---|---|
| EKS cluster (control plane) | 1 cluster | ~$73 |
| EC2 nodes | 2× `t3.medium` | ~$60 |
| ALB | 1 ALB, low traffic | ~$18 |
| CloudWatch Logs | Moderate volume | ~$5 |
| Secrets Manager | 2 secrets | ~$1 |
| **Total (excl. Bedrock)** | | **~$157/month** |

### Staging / Test Environment

| Resource | Specification | Estimated Monthly Cost |
|---|---|---|
| EKS cluster (control plane) | 1 cluster | ~$73 |
| EC2 nodes | 2× `t3.large` | ~$120 |
| ALB | 1 ALB, moderate traffic | ~$25 |
| CloudWatch Logs | Moderate volume | ~$15 |
| Secrets Manager | 3 secrets | ~$2 |
| **Total (excl. Bedrock)** | | **~$235/month** |

### Production Environment

| Resource | Specification | Estimated Monthly Cost |
|---|---|---|
| EKS cluster (control plane) | 1 cluster | ~$73 |
| EC2 nodes | 3–6× `m5.large` (autoscaling) | ~$330–$660 |
| ALB | 1 ALB, production traffic | ~$50–$150 |
| CloudWatch Logs | High volume | ~$50 |
| Secrets Manager | 4 secrets + rotation Lambda | ~$5 |
| Data transfer | Bedrock response egress | ~$20–$100 |
| **Total (excl. Bedrock)** | | **~$530–$1,040/month** |

**Cost optimisation levers:**
- Use Savings Plans or Reserved Instances for `m5.large` nodes (up to 40% discount)
- Enable CloudWatch Log retention policies (30 days for dev, 90 days for staging, 365 days for prod)
- Set HPA `minReplicas: 2` and scale down during off-hours in non-production environments
- Use Spot Instances for the dev node group (not recommended for staging/prod)

---

## Success Criteria

A deployment is considered **complete and production-ready** when all of the following criteria are measurably satisfied:

### Infrastructure

| Criterion | How to Verify | Pass Condition |
|---|---|---|
| All pods running | `kubectl get pods -n ai-gateway` | 2/2 pods `Running`, `Ready 1/1` |
| No pod restarts | `kubectl get pods -n ai-gateway` | `RESTARTS` column = 0 |
| ALB provisioned | `kubectl get ingress -n ai-gateway` | `ADDRESS` column populated |
| ALB targets healthy | AWS Console → EC2 → Target Groups | All targets in `healthy` state |
| HTTPS responding | `curl https://<endpoint>/health` | HTTP 200 with valid JSON body |
| HPA active | `kubectl get hpa -n ai-gateway` | `TARGETS` shows current metrics |
| PDB enforced | `kubectl get pdb -n ai-gateway` | `ALLOWED DISRUPTIONS` ≥ 1 |
| Network policies applied | `kubectl get networkpolicy -n ai-gateway` | 4 policies listed |

### Security

| Criterion | How to Verify | Pass Condition |
|---|---|---|
| IRSA active | `aws sts get-caller-identity` from pod | Returns litellm-irsa role ARN |
| No static AWS keys | `kubectl get deployment -n ai-gateway -o yaml` | No `AWS_ACCESS_KEY_ID` env var |
| Secrets in Secrets Manager | `aws secretsmanager list-secrets` | `ai-gateway-prod/litellm-secrets` present |
| Non-root container | `kubectl exec -- id` | `uid=1000` (non-root) |
| `allowPrivilegeEscalation: false` | `kubectl get pod -o yaml` | Confirmed in securityContext |

### Functional

| Criterion | How to Verify | Pass Condition |
|---|---|---|
| Bedrock reachable | `curl POST /chat/completions` | 200 response with completion text |
| Response streaming | `curl POST /chat/completions` with `"stream": true` | Server-sent events received |
| Master key authentication | `curl /health` without Authorization header | 401 Unauthorized |
| `/health` endpoint | `curl /health` | 200 OK |

### Observability

| Criterion | How to Verify | Pass Condition |
|---|---|---|
| Logs in CloudWatch | AWS Console → CloudWatch → Log groups | Container logs visible |
| Bedrock calls in CloudTrail | CloudTrail → Event history | `InvokeModel` events present |
| Secrets access in CloudTrail | CloudTrail → Event history | `GetSecretValue` events present |

---

## Quick Reference — Phase Summary

| Phase | Deliverable | Est. Duration |
|---|---|---|
| 1 — AWS Foundations | AWS account, tools, IAM prerequisites configured | 1–2 hours |
| 2 — EKS Cluster | EKS cluster active, nodes running, kubeconfig updated | 20–30 minutes |
| 3 — EKS Add-ons | ALB Controller, Metrics Server, VPC CNI network policy enabled | 30–45 minutes |
| 4 — IAM / IRSA | OIDC provider, IRSA role, IAM policy created | 30–45 minutes |
| 5 — Secrets | Secrets Manager entries created, Kubernetes Secret created | 15–20 minutes |
| 6 — Deploy LiteLLM | All 8 Kubernetes manifests applied, pods running | 10–15 minutes |
| 7 — Bedrock Integration | Model access enabled, pod-to-Bedrock validated | 15–30 minutes |
| 8 — Validation | All success criteria verified | 30–45 minutes |
| **Total** | | **~3–5 hours** |
