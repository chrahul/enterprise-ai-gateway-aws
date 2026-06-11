# Deployment Inventory

## Purpose

This document is the definitive checklist of every resource required to deploy the Enterprise AI Gateway. It is intended to be used in three ways:

1. **Pre-deployment planning** — confirm all prerequisites exist before executing any phase of `docs/93-eks-build-plan.md`.
2. **During deployment** — check off resources as they are created to track progress.
3. **Post-deployment audit** — verify the deployed state matches the intended architecture.

**Related documents:**
- `docs/93-eks-build-plan.md` — Phase-by-phase deployment blueprint
- `docs/95-irsa-and-iam-design.md` — IAM and IRSA architecture
- `docs/94-secrets-management-strategy.md` — Secrets architecture
- `docs/92-repository-gap-analysis.md` — Current readiness score and open gaps

---

## Summary Counts

| Layer | Resource Count |
|---|---|
| AWS Resources | 19 |
| Kubernetes Resources | 9 |
| Bedrock Resources | 2 |
| Validation Artifacts | 6 |
| **Total** | **36** |

---

## AWS Resources

19 AWS resources are required across networking, compute, identity, secrets, and DNS layers.

| # | Resource | Type | Ownership | Notes |
|---|---|---|---|---|
| 1 | VPC | `AWS::EC2::VPC` | User Managed | Dedicated VPC — do not use default. CIDR `/16` recommended (e.g. `10.0.0.0/16`). |
| 2 | Private Subnet (AZ-a) | `AWS::EC2::Subnet` | User Managed | EKS nodes and pods. CIDR `/24` each (e.g. `10.0.1.0/24`). |
| 3 | Private Subnet (AZ-b) | `AWS::EC2::Subnet` | User Managed | EKS nodes and pods. |
| 4 | Private Subnet (AZ-c) | `AWS::EC2::Subnet` | User Managed | EKS nodes and pods. Three AZs required for production HA. |
| 5 | Public Subnet (AZ-a) | `AWS::EC2::Subnet` | User Managed | ALB placement. Tag: `kubernetes.io/role/elb=1`. |
| 6 | Public Subnet (AZ-b) | `AWS::EC2::Subnet` | User Managed | ALB placement. |
| 7 | Internet Gateway | `AWS::EC2::InternetGateway` | User Managed | Attached to VPC. Required for ALB outbound and NAT Gateway. |
| 8 | NAT Gateway | `AWS::EC2::NatGateway` | User Managed | One per AZ for production HA. EKS nodes in private subnets use NAT to reach Bedrock endpoints and pull container images. |
| 9 | EKS Cluster | `AWS::EKS::Cluster` | AWS Managed | Kubernetes `1.31`. Cluster name: `ai-gateway-prod`. OIDC issuer enabled. |
| 10 | EKS Node Group | `AWS::EKS::Nodegroup` | AWS Managed | `m5.large` (prod), `t3.medium` (dev). Min 2, desired 3, max 6. Nodes in private subnets. |
| 11 | EKS OIDC Provider | `AWS::IAM::OIDCProvider` | User Managed | Created from the cluster's OIDC issuer URL. Required for IRSA. One per cluster. |
| 12 | IAM Policy — Bedrock Access | `AWS::IAM::ManagedPolicy` | User Managed | Allows `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` on Claude Sonnet and Claude Haiku ARNs. See `docs/95-irsa-and-iam-design.md`. |
| 13 | IAM Policy — Secrets Manager | `AWS::IAM::ManagedPolicy` | User Managed | Allows `secretsmanager:GetSecretValue` on the `ai-gateway-*/litellm-secrets` path only. |
| 14 | IAM Role (IRSA) | `AWS::IAM::Role` | User Managed | Trust relationship scoped to `system:serviceaccount:ai-gateway:litellm-sa`. Attach policies #12 and #13. ARN populates `kubernetes/serviceaccount.yaml` annotation. |
| 15 | Secrets Manager Secret | `AWS::SecretsManager::Secret` | User Managed | Path: `ai-gateway-{env}/litellm-secrets`. JSON value containing `LITELLM_MASTER_KEY` and any optional API keys. See `litellm/secrets-example.yaml`. |
| 16 | AWS Load Balancer Controller | `AWS::IAM::Role` + Helm chart | AWS Managed (controller) / User Managed (IAM) | IAM role for the controller's ServiceAccount. Installed via Helm. Required for the ALB Ingress in `kubernetes/ingress.yaml` to provision. |
| 17 | ACM Certificate | `AWS::CertificateManager::Certificate` | User Managed | TLS certificate for the gateway domain. ARN populates `kubernetes/ingress.yaml` annotation `alb.ingress.kubernetes.io/certificate-arn`. DNS-validated. |
| 18 | Route 53 Record | `AWS::Route53::RecordSet` | User Managed | CNAME or A-alias pointing the gateway hostname to the ALB DNS name. Created after the ALB provisions. |
| 19 | Security Groups | `AWS::EC2::SecurityGroup` | AWS Managed / User Managed | Managed by EKS for node-to-node and node-to-control-plane communication. The ALB security group is created by the AWS Load Balancer Controller. |

---

## Kubernetes Resources

9 Kubernetes resources are defined in the `kubernetes/` directory. All resources are in the `ai-gateway` namespace.

| # | Resource | Kind | File | Ownership | Notes |
|---|---|---|---|---|---|
| 1 | `ai-gateway` | `Namespace` | `kubernetes/namespace.yaml` | Kubernetes Managed | Must be created first — all other resources depend on it. |
| 2 | `litellm-sa` | `ServiceAccount` | `kubernetes/serviceaccount.yaml` | Kubernetes Managed | Annotated with the IRSA IAM Role ARN (AWS resource #14). Replace placeholder ARN before applying. |
| 3 | `litellm-config` | `ConfigMap` | `kubernetes/configmap.yaml` | Kubernetes Managed | Embeds `litellm/config.yaml`. Mount target: `/app/config.yaml`. Regenerate via `kubectl create configmap --from-file` after any config change. |
| 4 | `litellm` | `Deployment` | `kubernetes/deployment.yaml` | Kubernetes Managed | 2 replicas, `ghcr.io/berriai/litellm:v1.88.1`. Mounts ConfigMap at `/app/config.yaml`. Master key from `litellm-secrets` Secret. |
| 5 | `litellm` | `Service` | `kubernetes/service.yaml` | Kubernetes Managed | ClusterIP, port 80 → 4000. Internal access only. ALB Ingress targets this Service. |
| 6 | `litellm` | `Ingress` | `kubernetes/ingress.yaml` | Kubernetes Managed | ALB, HTTPS 443, TLS 1.3. Depends on AWS Load Balancer Controller (AWS resource #16) and ACM Certificate (AWS resource #17). |
| 7 | `litellm` | `HorizontalPodAutoscaler` | `kubernetes/hpa.yaml` | Kubernetes Managed | Min 2 / max 10 replicas. CPU target 70%, Memory target 80%. |
| 8 | `litellm` | `PodDisruptionBudget` | `kubernetes/pdb.yaml` | Kubernetes Managed | `minAvailable: 1`. Ensures at least one pod remains during node drains and rolling updates. |
| 9 | (4 policies) | `NetworkPolicy` | `kubernetes/networkpolicy.yaml` | Kubernetes Managed | Default-deny, allow kube-system ingress, allow DNS egress (53), allow HTTPS egress to AWS (443). |

> **Note:** The `litellm-secrets` Kubernetes Secret is **not** stored in this repository. It is created imperatively at deploy time from the AWS Secrets Manager value. See `docs/94-secrets-management-strategy.md`.

---

## Bedrock Resources

2 Bedrock model access grants are required. Bedrock model access is opt-in — models are not available by default, even with a valid IAM policy.

| # | Resource | Model ID | Access Type | Notes |
|---|---|---|---|---|
| 1 | Claude 3.5 Sonnet Access | `anthropic.claude-3-5-sonnet-20241022-v2:0` | User Managed | Enable in the Bedrock console: **Model access → Anthropic → Claude 3.5 Sonnet v2**. Verify: `aws bedrock list-foundation-models --region us-east-1`. |
| 2 | Claude 3 Haiku Access | `anthropic.claude-3-haiku-20240307-v1:0` | User Managed | Enable in the Bedrock console: **Model access → Anthropic → Claude 3 Haiku**. Both models must be enabled in the same region as the EKS cluster. |

---

## Validation Artifacts

6 validation checks must pass before the deployment is considered production-ready.

| # | Check | Command | Expected Result |
|---|---|---|---|
| 1 | Pods healthy | `kubectl get pods -n ai-gateway` | All pods `Running`, `2/2` or `1/1` ready, 0 restarts |
| 2 | ConfigMap mounted | `kubectl exec -n ai-gateway deploy/litellm -- cat /app/config.yaml` | Outputs the LiteLLM config YAML |
| 3 | ALB provisioned | `kubectl get ingress -n ai-gateway` | `ADDRESS` column populated with an ALB DNS name (not empty) |
| 4 | TLS certificate valid | `curl -sv https://<gateway-domain>/health 2>&1 \| grep "SSL certificate verify ok"` | Certificate trusted, no TLS error |
| 5 | Bedrock reachable | `curl -X POST https://<gateway-domain>/v1/chat/completions -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" -d '{"model":"claude-haiku","messages":[{"role":"user","content":"ping"}],"max_tokens":5}'` | HTTP 200, response with `choices[0].message.content` |
| 6 | HPA active | `kubectl get hpa -n ai-gateway` | `TARGETS` shows CPU and Memory percentages (not `<unknown>`) |

---

## Resource Ownership Reference

| Ownership | Meaning |
|---|---|
| **AWS Managed** | AWS creates and manages the resource lifecycle (e.g. control plane nodes, managed node group instances). The user declares the desired state; AWS handles the underlying infrastructure. |
| **User Managed** | The user creates, configures, and is responsible for the resource. Errors or misconfigurations in these resources are the most common source of deployment failures. |
| **Kubernetes Managed** | The resource is declared as a manifest in the `kubernetes/` directory and applied via `kubectl`. The Kubernetes control plane manages the desired state. |

---

## Deployment Order

Resources must be created in this exact sequence. Dependencies are noted. Skipping steps or applying Kubernetes manifests before AWS resources are ready is the most common cause of deployment failures.

| Step | Resource | Layer | Dependency |
|---|---|---|---|
| 1 | VPC | AWS | None |
| 2 | Public Subnets (×2–3) | AWS | VPC |
| 3 | Private Subnets (×2–3) | AWS | VPC |
| 4 | Internet Gateway | AWS | VPC |
| 5 | NAT Gateway | AWS | Public Subnets, Elastic IP |
| 6 | Route Tables | AWS | Internet Gateway, NAT Gateway |
| 7 | Bedrock Model Access (Sonnet + Haiku) | AWS | AWS account |
| 8 | EKS Cluster | AWS | VPC, Private Subnets |
| 9 | EKS OIDC Provider | AWS | EKS Cluster (issuer URL required) |
| 10 | IAM Policy — Bedrock Access | AWS | Bedrock Model Access (#7) |
| 11 | IAM Policy — Secrets Manager | AWS | None |
| 12 | IAM Role (IRSA) | AWS | OIDC Provider (#9), IAM Policies (#10, #11) |
| 13 | EKS Node Group | AWS | EKS Cluster, Private Subnets |
| 14 | ACM Certificate | AWS | Domain registered in Route 53 |
| 15 | Secrets Manager Secret | AWS | None |
| 16 | Namespace `ai-gateway` | Kubernetes | EKS Cluster, Node Group (cluster must be schedulable) |
| 17 | ServiceAccount `litellm-sa` | Kubernetes | Namespace (#16), IRSA Role ARN (#12) |
| 18 | ConfigMap `litellm-config` | Kubernetes | Namespace (#16) |
| 19 | Secret `litellm-secrets` (imperative) | Kubernetes | Namespace (#16), Secrets Manager Secret (#15) |
| 20 | NetworkPolicy | Kubernetes | Namespace (#16) |
| 21 | AWS Load Balancer Controller | Kubernetes + AWS | EKS Cluster, IAM Role for controller |
| 22 | Deployment `litellm` | Kubernetes | ServiceAccount (#17), ConfigMap (#18), Secret (#19) |
| 23 | Service `litellm` | Kubernetes | Namespace (#16) |
| 24 | HPA `litellm` | Kubernetes | Deployment (#22), Metrics Server add-on |
| 25 | PDB `litellm` | Kubernetes | Deployment (#22) |
| 26 | Ingress `litellm` | Kubernetes | Service (#23), ALB Controller (#21), ACM Certificate (#14) |
| 27 | Route 53 Record | AWS | Ingress ALB DNS name (#26) |
| 28 | Security Groups (review) | AWS | All above |
| 29 | Run validation checks | — | All above |

---

## Open Gaps

The following gaps from `docs/92-repository-gap-analysis.md` affect this inventory:

| Gap ID | Resource Affected | Status | Action Required |
|---|---|---|---|
| GAP-003 | Steps 1–15 (all AWS resources) | Open | Follow `docs/93-eks-build-plan.md` to provision AWS infrastructure |
| GAP-004 | ServiceAccount `litellm-sa` | Open | Replace placeholder IRSA ARN in `kubernetes/serviceaccount.yaml` after AWS resource #12 is created |
| GAP-005 | Bedrock Model Access | Open | Enable Claude Sonnet and Claude Haiku in the Bedrock console for `us-east-1` |
| GAP-008 | CI/CD pipeline | Open | Automate ConfigMap update and rolling restart on `litellm/config.yaml` changes |
| GAP-010 | ACM Certificate and Route 53 | Open | Placeholder domain/ARN in `kubernetes/ingress.yaml` — update after AWS resource #14 is created |
