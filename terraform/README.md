# Terraform Design Document

**Status:** Design Only — No resources will be created until this document is approved.  
**Date:** 2026-06-13  
**Target Environment:** `lab`  
**AWS Region:** `us-east-1`  
**Domain:** `gateway.unametechnology.com`  
**Architecture:** 2 × t3.medium, 2 Availability Zones

---

## Overview

This document defines the complete Terraform structure for the Enterprise AI Gateway infrastructure. It covers folder layout, module decomposition, variable strategy, state management, remote backend, and naming standards.

**Scope of this document:** Design only. No Terraform files will be written until this design is reviewed and approved.

**Infrastructure to be provisioned:**

| Layer | Resources |
|---|---|
| Networking | VPC, 2 private subnets, 2 public subnets, IGW, NAT Gateway, route tables |
| Compute | EKS cluster (Kubernetes 1.31), managed node group (2 × t3.medium across 2 AZs) |
| Identity | IAM policy (Bedrock + Secrets Manager), IRSA role, OIDC provider association |
| Secrets | AWS Secrets Manager secret for LiteLLM credentials |
| TLS | ACM certificate for `gateway.unametechnology.com` (DNS-validated) |
| DNS | Route 53 record pointing `gateway.unametechnology.com` to the ALB |
| Add-ons | AWS Load Balancer Controller (Helm), Metrics Server (Helm) |

---

## 1. Folder Structure

```
terraform/
├── README.md                  ← This file
│
├── environments/
│   └── lab/
│       ├── main.tf            ← Root module: calls all child modules
│       ├── variables.tf       ← Environment-level input declarations
│       ├── terraform.tfvars   ← Lab-specific values (NOT committed — in .gitignore)
│       ├── outputs.tf         ← Outputs: cluster name, ALB DNS, role ARNs
│       ├── providers.tf       ← AWS + Kubernetes + Helm provider pins
│       └── backend.tf         ← S3 remote backend configuration
│
└── modules/
    ├── networking/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── eks/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── iam/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── secrets/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── acm/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── dns/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    │
    └── addons/
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

### Rationale for `environments/lab/` vs flat root

Using an `environments/` tree allows the same modules to be reused for future `staging` and `prod` environments by adding `environments/staging/` and `environments/prod/` directories. Each environment has its own state file and its own `terraform.tfvars`. Modules are environment-agnostic — they receive all environment-specific values as input variables.

---

## 2. Module Structure

Each module owns a single infrastructure concern. Modules communicate through outputs — no module reads another module's state directly.

### Module: `networking`

**Owns:** VPC, subnets, Internet Gateway, NAT Gateway, route tables, subnet tags for ALB discovery.

**Key inputs:**
```hcl
variable "vpc_cidr"           { type = string }   # "10.0.0.0/16"
variable "availability_zones" { type = list(string) }  # ["us-east-1a", "us-east-1b"]
variable "private_subnet_cidrs" { type = list(string) } # ["10.0.1.0/24", "10.0.2.0/24"]
variable "public_subnet_cidrs"  { type = list(string) } # ["10.0.101.0/24", "10.0.102.0/24"]
variable "environment"        { type = string }   # "lab"
variable "project"            { type = string }   # "enterprise-ai-gateway"
```

**Key outputs:**
```hcl
output "vpc_id"              { value = aws_vpc.main.id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "public_subnet_ids"  { value = aws_subnet.public[*].id }
```

---

### Module: `eks`

**Owns:** EKS cluster, managed node group, OIDC issuer URL extraction, cluster add-on configuration (VPC CNI with network policy enforcement).

**Key inputs:**
```hcl
variable "cluster_name"        { type = string }          # "ai-gateway-lab"
variable "kubernetes_version"  { type = string }          # "1.31"
variable "vpc_id"              { type = string }          # from networking module
variable "private_subnet_ids"  { type = list(string) }   # from networking module
variable "node_instance_type"  { type = string }          # "t3.medium"
variable "node_min_size"       { type = number }          # 2
variable "node_max_size"       { type = number }          # 4
variable "node_desired_size"   { type = number }          # 2
variable "environment"         { type = string }
variable "project"             { type = string }
```

**Key outputs:**
```hcl
output "cluster_name"         { value = aws_eks_cluster.main.name }
output "cluster_endpoint"     { value = aws_eks_cluster.main.endpoint }
output "cluster_ca_cert"      { value = aws_eks_cluster.main.certificate_authority[0].data }
output "oidc_issuer_url"      { value = aws_eks_cluster.main.identity[0].oidc[0].issuer }
output "oidc_provider_arn"    { value = aws_iam_openid_connect_provider.eks.arn }
```

> **Note:** The OIDC provider (`aws_iam_openid_connect_provider`) lives in the `eks` module because it is a direct property of the cluster identity. The `iam` module consumes the OIDC provider ARN as an input.

---

### Module: `iam`

**Owns:** LiteLLM IAM policy (Bedrock + Secrets Manager), IRSA role, trust relationship scoped to `system:serviceaccount:ai-gateway:litellm-sa`.

**Key inputs:**
```hcl
variable "oidc_provider_arn"  { type = string }  # from eks module
variable "oidc_issuer_url"    { type = string }  # from eks module
variable "namespace"          { type = string }  # "ai-gateway"
variable "service_account"    { type = string }  # "litellm-sa"
variable "aws_region"         { type = string }  # "us-east-1"
variable "account_id"         { type = string }  # from data.aws_caller_identity
variable "secret_arn"         { type = string }  # from secrets module
variable "environment"        { type = string }
variable "project"            { type = string }
```

**Key outputs:**
```hcl
output "irsa_role_arn"        { value = aws_iam_role.litellm_irsa.arn }
output "irsa_role_name"       { value = aws_iam_role.litellm_irsa.name }
output "bedrock_policy_arn"   { value = aws_iam_policy.litellm_bedrock.arn }
```

**IAM policy scope (least-privilege design):**
- `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` scoped to Claude Sonnet and Claude Haiku model ARNs only — not `*`
- `secretsmanager:GetSecretValue` scoped to the specific secret ARN from the `secrets` module — not `*`

---

### Module: `secrets`

**Owns:** AWS Secrets Manager secret resource (structure only — the actual secret value is set out-of-band and never in Terraform state).

**Key inputs:**
```hcl
variable "secret_name"        { type = string }   # "ai-gateway-lab/litellm-secrets"
variable "description"        { type = string }
variable "environment"        { type = string }
variable "project"            { type = string }
```

**Key outputs:**
```hcl
output "secret_arn"           { value = aws_secretsmanager_secret.litellm.arn }
output "secret_name"          { value = aws_secretsmanager_secret.litellm.name }
```

**Design decision — secret values never in Terraform:**  
The Terraform `secrets` module creates the Secrets Manager secret *resource* (name, description, KMS key, tags, rotation config) but does not set `secret_string`. The actual credential values (`LITELLM_MASTER_KEY`, etc.) are injected via `aws secretsmanager put-secret-value` as a separate operational step, outside Terraform. This prevents secrets from appearing in Terraform state, plan output, or version control.

---

### Module: `acm`

**Owns:** ACM certificate request, Route 53 DNS validation records.

**Key inputs:**
```hcl
variable "domain_name"        { type = string }   # "gateway.unametechnology.com"
variable "hosted_zone_id"     { type = string }   # Route 53 hosted zone for unametechnology.com
variable "environment"        { type = string }
variable "project"            { type = string }
```

**Key outputs:**
```hcl
output "certificate_arn"      { value = aws_acm_certificate.gateway.arn }
output "certificate_status"   { value = aws_acm_certificate.gateway.status }
```

**Design decision — validation method:**  
DNS validation is used (not email) because:
1. It can be automated entirely within Terraform using `aws_route53_record` for the CNAME
2. It auto-renews without human intervention
3. Email validation requires manual action in an inbox

The ACM module creates the certificate and the Route 53 CNAME validation record in a single apply. It uses `aws_acm_certificate_validation` to wait until the certificate reaches `ISSUED` status before the apply completes.

---

### Module: `dns`

**Owns:** Route 53 A-alias record pointing `gateway.unametechnology.com` to the ALB DNS name.

**Key inputs:**
```hcl
variable "hosted_zone_id"     { type = string }
variable "domain_name"        { type = string }   # "gateway.unametechnology.com"
variable "alb_dns_name"       { type = string }   # from ALB — provided post-EKS deploy
variable "alb_zone_id"        { type = string }   # ALB canonical zone ID
variable "environment"        { type = string }
```

**Key outputs:**
```hcl
output "gateway_fqdn"         { value = aws_route53_record.gateway.fqdn }
```

**Design decision — ALB DNS name source:**  
The ALB is provisioned by the Kubernetes AWS Load Balancer Controller, not by Terraform. Its DNS name is only known after the Kubernetes Ingress is applied. The `dns` module therefore accepts `alb_dns_name` as an input variable. For the lab environment, this value is obtained after Step 7.6 of [deployment-checklist.md](deployment-checklist.md) and passed to Terraform as a tfvars value or via a `terraform apply -var` flag.

---

### Module: `addons`

**Owns:** Helm releases for the AWS Load Balancer Controller and the Kubernetes Metrics Server. Both are deployed via the Terraform Helm provider.

**Key inputs:**
```hcl
variable "cluster_name"                    { type = string }
variable "alb_controller_role_arn"         { type = string }  # IRSA role for ALB controller
variable "alb_controller_chart_version"    { type = string }  # e.g. "1.8.0"
variable "metrics_server_chart_version"    { type = string }  # e.g. "3.12.0"
variable "environment"                     { type = string }
```

**Key outputs:**
```hcl
output "alb_controller_status"   { value = helm_release.alb_controller.status }
output "metrics_server_status"   { value = helm_release.metrics_server.status }
```

---

## 3. Variables Strategy

### Three-tier variable resolution

Variables are resolved in this precedence order (highest to lowest):

```
1. CLI override:       terraform apply -var="node_desired_size=3"
2. tfvars file:        environments/lab/terraform.tfvars
3. Variable defaults:  modules/*/variables.tf (default block)
```

### Variable categories

| Category | Where defined | Example |
|---|---|---|
| **Required — no default** | `variables.tf` (no default block) | `account_id`, `hosted_zone_id` |
| **Environment-specific** | `terraform.tfvars` | `environment = "lab"`, `node_instance_type = "t3.medium"` |
| **Tunable with safe defaults** | `variables.tf` default block | `node_min_size = 2`, `kubernetes_version = "1.31"` |
| **Sensitive** | Never in tfvars — passed via env var `TF_VAR_*` or CI/CD secret | `(none — all secrets are out-of-band)` |

### `terraform.tfvars` for lab environment

This file is in `.gitignore` and must not be committed. It contains:

```hcl
# environments/lab/terraform.tfvars
# DO NOT COMMIT — gitignored

aws_region          = "us-east-1"
environment         = "lab"
project             = "enterprise-ai-gateway"
account_id          = "ACCOUNT_ID"

# Networking
vpc_cidr                = "10.0.0.0/16"
availability_zones      = ["us-east-1a", "us-east-1b"]
private_subnet_cidrs    = ["10.0.1.0/24", "10.0.2.0/24"]
public_subnet_cidrs     = ["10.0.101.0/24", "10.0.102.0/24"]

# EKS
cluster_name            = "ai-gateway-lab"
kubernetes_version      = "1.31"
node_instance_type      = "t3.medium"
node_min_size           = 2
node_max_size           = 4
node_desired_size       = 2

# TLS and DNS
domain_name             = "gateway.unametechnology.com"
hosted_zone_id          = "ZXXXXXXXXXX"

# Versions
alb_controller_chart_version   = "1.8.0"
metrics_server_chart_version   = "3.12.0"
```

### Variable type constraints

All variables use explicit `type` and `description` blocks:

```hcl
variable "node_instance_type" {
  type        = string
  description = "EC2 instance type for EKS worker nodes. Use t3.medium for lab, m5.large for production."
  default     = "t3.medium"

  validation {
    condition     = contains(["t3.medium", "t3.large", "m5.large", "m5.xlarge"], var.node_instance_type)
    error_message = "node_instance_type must be one of: t3.medium, t3.large, m5.large, m5.xlarge."
  }
}
```

Validation blocks are added for any variable where an invalid value would result in a silent, hard-to-diagnose deployment failure.

---

## 4. State Management Strategy

### One state file per environment

Each environment has its own isolated Terraform state. This is the most critical state design decision — shared state across environments creates blast radius where a failed `lab` plan can lock the `prod` state.

```
S3 bucket: tf-state-enterprise-ai-gateway-ACCOUNT_ID/

  lab/     → terraform/environments/lab/terraform.tfstate
  staging/ → terraform/environments/staging/terraform.tfstate   (future)
  prod/    → terraform/environments/prod/terraform.tfstate       (future)
```

### State file locking

DynamoDB is used for state locking. This prevents concurrent `terraform apply` runs from corrupting state. One DynamoDB table serves all environments (the lock key includes the environment path).

```
DynamoDB table: tf-state-lock-enterprise-ai-gateway
  Partition key: LockID (String)
```

### What is and is not in Terraform state

| Resource | In state? | Rationale |
|---|---|---|
| VPC, subnets, IGW, NAT | Yes | Infrastructure lifecycle managed by Terraform |
| EKS cluster, node group | Yes | Infrastructure lifecycle managed by Terraform |
| IAM roles and policies | Yes | Infrastructure lifecycle managed by Terraform |
| Secrets Manager secret (structure) | Yes | Name, ARN, KMS key, tags |
| Secrets Manager secret *value* | **No** | Set out-of-band via CLI; never in state |
| ACM certificate | Yes | Lifecycle managed by Terraform |
| Route 53 records | Yes | DNS records created and managed by Terraform |
| Kubernetes Namespace | **No** | Applied via `kubectl apply -f kubernetes/namespace.yaml` |
| Kubernetes Deployment, Service, Ingress | **No** | Applied via `kubectl apply -f kubernetes/` |
| Kubernetes Secrets | **No** | Applied via `kubectl create secret` — never in Terraform |
| Helm releases (ALB controller, Metrics Server) | Yes | Terraform Helm provider manages these |

**Design decision — Kubernetes manifests stay in kubectl, not Terraform:**  
The Kubernetes manifests in `kubernetes/` are authoritative and version-controlled. Wrapping them in Terraform's `kubernetes_manifest` resource or Helm charts would require duplicating them or losing the single-source-of-truth property. The clear boundary is: Terraform owns AWS infrastructure, `kubectl` owns Kubernetes application resources.

---

## 5. Remote Backend Recommendation

### Backend: S3 + DynamoDB

The recommended backend for this architecture is the native Terraform S3 backend. It is the standard choice for AWS-hosted Terraform workloads and requires no additional tooling.

```hcl
# terraform/environments/lab/backend.tf

terraform {
  backend "s3" {
    bucket         = "tf-state-enterprise-ai-gateway-ACCOUNT_ID"
    key            = "lab/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    kms_key_id     = "alias/tf-state-key"         # CMK for state encryption
    dynamodb_table = "tf-state-lock-enterprise-ai-gateway"
  }
}
```

### Backend bootstrap procedure

The S3 bucket and DynamoDB table must exist before `terraform init` can run. They are created once manually (or via a minimal bootstrap script) and are never managed by the main Terraform configuration:

```bash
# 1. Create the state bucket with versioning and server-side encryption
aws s3api create-bucket \
  --bucket tf-state-enterprise-ai-gateway-ACCOUNT_ID \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket tf-state-enterprise-ai-gateway-ACCOUNT_ID \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket tf-state-enterprise-ai-gateway-ACCOUNT_ID \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'

aws s3api put-public-access-block \
  --bucket tf-state-enterprise-ai-gateway-ACCOUNT_ID \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# 2. Create the DynamoDB lock table
aws dynamodb create-table \
  --table-name tf-state-lock-enterprise-ai-gateway \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### S3 bucket security properties

| Property | Setting | Reason |
|---|---|---|
| Versioning | Enabled | Allows rollback to a previous state if state corruption occurs |
| Server-side encryption | SSE-KMS (CMK) | State contains ARNs, role names, and resource IDs — treat as sensitive |
| Public access block | All four blocks enabled | State must never be publicly accessible |
| Bucket policy | Deny non-HTTPS access (`aws:SecureTransport: false`) | Enforce TLS for all state reads and writes |
| Object-level logging | Enabled to CloudTrail | Audits who read or wrote the state file |

### Why not Terraform Cloud or other backends

| Option | Assessment for this project |
|---|---|
| **S3 + DynamoDB** | Recommended. Native AWS, no external service dependency, satisfies enterprise data residency requirements. |
| Terraform Cloud | Requires an external SaaS dependency. Acceptable if the organisation already uses it. State leaves the AWS account. |
| HashiCorp Vault | Over-engineered for a single-team lab environment. Consider for multi-team or regulated production. |
| Local state | Unsuitable for team use. Not acceptable for any environment beyond local development. |

---

## 6. Naming Standards

All resources follow a consistent naming pattern that encodes the project, environment, and resource function. This enables filtering in the AWS console, Cost Explorer, and CloudTrail without relying solely on tags.

### Name pattern

```
{project}-{environment}-{resource-function}
```

| Component | Value |
|---|---|
| `{project}` | `ai-gateway` |
| `{environment}` | `lab` (also: `staging`, `prod`) |
| `{resource-function}` | Describes the resource's role (see table below) |

### Resource naming table

| Resource | Name | Example (lab) |
|---|---|---|
| VPC | `{project}-{env}-vpc` | `ai-gateway-lab-vpc` |
| Private subnet | `{project}-{env}-private-{az}` | `ai-gateway-lab-private-a` |
| Public subnet | `{project}-{env}-public-{az}` | `ai-gateway-lab-public-a` |
| Internet Gateway | `{project}-{env}-igw` | `ai-gateway-lab-igw` |
| NAT Gateway | `{project}-{env}-nat-{az}` | `ai-gateway-lab-nat-a` |
| Private route table | `{project}-{env}-rt-private` | `ai-gateway-lab-rt-private` |
| Public route table | `{project}-{env}-rt-public` | `ai-gateway-lab-rt-public` |
| EKS cluster | `{project}-{env}` | `ai-gateway-lab` |
| Node group | `{project}-{env}-nodes` | `ai-gateway-lab-nodes` |
| IAM policy (Bedrock) | `{project}-{env}-bedrock-policy` | `ai-gateway-lab-bedrock-policy` |
| IAM policy (Secrets) | `{project}-{env}-secrets-policy` | `ai-gateway-lab-secrets-policy` |
| IAM role (IRSA) | `{project}-{env}-litellm-irsa` | `ai-gateway-lab-litellm-irsa` |
| Secrets Manager secret | `{project}-{env}/litellm-secrets` | `ai-gateway-lab/litellm-secrets` |
| ACM certificate | `{domain}` (ACM uses domain, not name) | `gateway.unametechnology.com` |
| Route 53 record | `{domain}` | `gateway.unametechnology.com` |
| Terraform state bucket | `tf-state-{project}-{account_id}` | `tf-state-enterprise-ai-gateway-123456789012` |
| DynamoDB lock table | `tf-state-lock-{project}` | `tf-state-lock-enterprise-ai-gateway` |

### Tagging standard

Every AWS resource receives these tags. Tags are applied via a `default_tags` block on the AWS provider so they are inherited by all resources automatically:

```hcl
# In environments/lab/providers.tf
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "enterprise-ai-gateway"
      Environment = var.environment        # "lab"
      ManagedBy   = "terraform"
      Repository  = "github.com/chrahul/enterprise-ai-gateway-aws"
      Owner       = "platform-team"
    }
  }
}
```

Using `default_tags` means these five tags are automatically applied to every AWS resource created in the provider session. Individual resources can add additional tags but cannot remove the default tags.

### Kubernetes resource naming

Kubernetes resources in `kubernetes/` already follow their own conventions (established in the manifests). Terraform does not manage Kubernetes application resources, so no change to Kubernetes naming is needed.

---

## 7. Provider Versions

All providers are pinned to explicit version constraints. Using `~>` (pessimistic constraint) allows patch updates but prevents major version surprises.

```hcl
# terraform/environments/lab/providers.tf

terraform {
  required_version = ">= 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"     # Used to extract OIDC thumbprint for IRSA
    }
  }
}
```

---

## 8. Module Dependency Graph

The modules must be initialised in this dependency order. Terraform resolves this automatically via output references, but it is documented here for clarity.

```
networking
    │
    └──▶ eks (needs vpc_id, private_subnet_ids, public_subnet_ids)
              │
              ├──▶ iam (needs oidc_provider_arn, oidc_issuer_url)
              │         │
              │         └── depends on: secrets (needs secret_arn for IAM policy)
              │
              ├──▶ addons (needs cluster_name, cluster endpoint, CA cert)
              │
              └──▶ dns (needs ALB DNS name — available only after Kubernetes Ingress is applied)

acm (independent — no dependency on eks or networking)
    │
    └── uses: hosted_zone_id (provided as input, not from another module)
```

`acm` can be applied in parallel with `networking` and `eks` since it only requires the Route 53 hosted zone ID. The `dns` module is applied last, after the ALB DNS name is known.

---

## 9. Apply Sequence

```
Phase A (parallel)
  terraform apply -target=module.networking
  terraform apply -target=module.acm
  terraform apply -target=module.secrets

Phase B (after A completes)
  terraform apply -target=module.eks

Phase C (after B completes)
  terraform apply -target=module.iam
  terraform apply -target=module.addons

Phase D (after Kubernetes manifests applied and ALB provisioned)
  terraform apply -target=module.dns
```

In practice, `terraform apply` (without `-target`) handles dependency resolution automatically. The `-target` sequence is provided for engineers who prefer to apply incrementally and validate each phase.

---

## 10. Files Excluded from Version Control

The following files must be in `.gitignore`. The repository `.gitignore` already covers most of these:

```gitignore
# Terraform — already in .gitignore
**/.terraform/
*.tfstate
*.tfstate.backup
*.tfvars
crash.log
override.tf
override.tf.json

# Lab-specific sensitive files (verify these are covered)
terraform/environments/lab/terraform.tfvars
litellm-policy.json
cluster-config.yaml
```

---

## Next Steps

This document defines the design. Execution begins only after approval.

| Step | Action | Owner |
|---|---|---|
| 1 | Review and approve this design document | Architect / Tech Lead |
| 2 | Bootstrap the S3 state bucket and DynamoDB lock table | Platform Engineer |
| 3 | Write `terraform/modules/networking/` | Platform Engineer |
| 4 | Write `terraform/modules/eks/` | Platform Engineer |
| 5 | Write `terraform/modules/iam/` | Platform Engineer |
| 6 | Write `terraform/modules/secrets/` | Platform Engineer |
| 7 | Write `terraform/modules/acm/` | Platform Engineer |
| 8 | Write `terraform/modules/addons/` | Platform Engineer |
| 9 | Write `terraform/environments/lab/` root module | Platform Engineer |
| 10 | Run `terraform init && terraform validate && terraform plan` | Platform Engineer |
| 11 | Review plan output, confirm no unintended changes | Architect / Tech Lead |
| 12 | Run `terraform apply` in phases (see Section 9) | Platform Engineer |
| 13 | Apply Kubernetes manifests from `kubernetes/` | Platform Engineer |
| 14 | Run deployment validation checklist from [deployment-checklist.md](deployment-checklist.md) | Platform Engineer |

---

## See Also

- [docs/deployment-checklist.md](../docs/deployment-checklist.md) — Step-by-step deployment execution guide
- [docs/93-eks-build-plan.md](../docs/93-eks-build-plan.md) — Narrative EKS build plan (non-Terraform)
- [docs/95-irsa-and-iam-design.md](../docs/95-irsa-and-iam-design.md) — IAM policy and IRSA trust relationship design
- [docs/94-secrets-management-strategy.md](../docs/94-secrets-management-strategy.md) — Secrets strategy
- [docs/98-architecture-decisions.md](../docs/98-architecture-decisions.md) — Architecture Decision Records
