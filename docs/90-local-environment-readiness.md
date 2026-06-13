# Local Environment Readiness Assessment

**Assessment date:** 2026-06-11  
**Machine:** Windows 11 AMD64  
**Repository:** enterprise-ai-gateway-aws  
**Target deployment:** Enterprise AI Gateway on Amazon EKS (`us-east-1`)

---

## Overall Readiness

| Metric | Result |
|---|---|
| **Overall Score** | **5 / 9 checks passing** |
| **Ready for deployment today?** | **NO** |
| **Blockers** | 4 (see below) |
| **Warnings** | 0 |

Deployment cannot begin until all 4 blockers are resolved. The AWS credentials issue alone prevents any interaction with the AWS account.

---

## Tool Checks

| # | Tool | Required | Status | Detected Version | Notes |
|---|---|---|---|---|---|
| 1 | AWS CLI | Yes | ✅ PASS | `2.30.2` | Current. Latest is `2.x`. No upgrade needed. |
| 2 | kubectl | Yes | ✅ PASS | `v1.34.1` | Current and compatible with EKS `1.31`. |
| 3 | eksctl | Yes | ❌ FAIL | Not found | Required for EKS cluster creation and OIDC setup. |
| 4 | Docker | Optional* | ✅ PASS | `29.4.3` | Not required for EKS deploy but useful for local image validation. |
| 5 | Git | Yes | ✅ PASS | `2.53.0` | Current. |
| 6 | Python | Yes | ✅ PASS | `3.14.5` | Current. Used for YAML validation scripts in this repo. |
| 7 | Helm | Yes | ❌ FAIL | Not found | Required for AWS Load Balancer Controller installation (deployment step 21). |

> *Docker is not required to deploy to EKS but is listed because the build plan references image operations.

---

## AWS Configuration Checks

| # | Check | Status | Result | Notes |
|---|---|---|---|---|
| 8 | AWS credentials configured | ❌ FAIL | `Unable to locate credentials` | `aws configure` has not been run, or no credential provider is active. |
| 9 | `aws sts get-caller-identity` | ❌ FAIL | Error — no credentials | Downstream of check #8. Will pass once credentials are configured. |
| — | AWS account ID | ❌ UNKNOWN | Not retrievable without credentials | — |
| — | AWS region configured | ❌ FAIL | Not set | `aws configure get region` returned empty. |

---

## Blockers (Must Fix Before Deployment)

### BLOCKER 1 — `eksctl` not installed

**Impact:** Cannot create the EKS cluster, configure OIDC provider, or manage node groups. Required for deployment steps 8–9 of the inventory.

**Fix:**
```powershell
# Option A: winget (recommended on Windows 11)
winget install eksctl

# Option B: Chocolatey
choco install eksctl

# Option C: Direct binary download
# Download from https://github.com/eksctl-io/eksctl/releases/latest
# Add to a directory on your PATH (e.g. C:\tools\)

# Verify after install:
eksctl version
# Expected: 0.190.x or later
```

---

### BLOCKER 2 — `helm` not installed

**Impact:** Cannot install the AWS Load Balancer Controller (deployment step 21). The ALB Ingress (`kubernetes/ingress.yaml`) will not provision until the controller is running.

**Fix:**
```powershell
# Option A: winget
winget install Helm.Helm

# Option B: Chocolatey
choco install kubernetes-helm

# Option C: Script installer
# https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3

# Verify after install:
helm version --short
# Expected: v3.x.x
```

---

### BLOCKER 3 — AWS credentials not configured

**Impact:** Every AWS CLI command fails. Cannot create any AWS resource, cannot validate account access, cannot enable Bedrock model access, cannot create the EKS cluster.

**Fix (choose one based on your organisation's identity model):**

```powershell
# Option A: Static credentials (development / personal account only)
# WARNING: Do NOT use static credentials in CI/CD or shared environments.
aws configure
# Enter: AWS Access Key ID
# Enter: AWS Secret Access Key
# Enter: Default region (us-east-1)
# Enter: Default output format (json)

# Verify:
aws sts get-caller-identity
```

```powershell
# Option B: SSO / IAM Identity Center (recommended for enterprise accounts)
aws configure sso
# Follow the prompts to configure your SSO start URL, account, and role.

# After configuring, authenticate before each session:
aws sso login --profile <profile-name>

# Verify:
aws sts get-caller-identity --profile <profile-name>
```

```powershell
# Option C: Environment variables (useful in CI/CD or temporary sessions)
$env:AWS_ACCESS_KEY_ID     = "AKIA..."
$env:AWS_SECRET_ACCESS_KEY = "..."
$env:AWS_SESSION_TOKEN     = "..."   # If using temporary credentials
$env:AWS_DEFAULT_REGION    = "us-east-1"

# Verify:
aws sts get-caller-identity
```

> **Security note:** The IAM identity used for deployment requires elevated permissions for initial cluster creation. After the cluster is built, switch to a scoped deployment role. See `docs/93-eks-build-plan.md` Phase 1.2 for the full permissions list.

---

### BLOCKER 4 — AWS default region not set

**Impact:** AWS CLI commands that require a region will fail or prompt interactively. Bedrock, EKS, and Secrets Manager calls all require an explicit region.

**Fix:**
```powershell
# Option A: Set in AWS CLI config
aws configure set region us-east-1

# Option B: Environment variable (session-scoped)
$env:AWS_DEFAULT_REGION = "us-east-1"

# Verify:
aws configure get region
# Expected: us-east-1
```

---

## Installation Recommendations

### Install order

Install tools in this order to avoid dependency issues:

1. **eksctl** (Blocker 1) — standalone binary, no dependencies
2. **Helm** (Blocker 2) — standalone binary, no dependencies
3. **Configure AWS credentials** (Blocker 3)
4. **Set AWS region** (Blocker 4) — do this as part of `aws configure`

### Verify the full stack after installation

Run this script after fixing all blockers to confirm readiness:

```powershell
Write-Host "--- Tool Versions ---"
aws --version
kubectl version --client --short
eksctl version
helm version --short
docker --version
git --version
python --version

Write-Host ""
Write-Host "--- AWS Identity ---"
aws sts get-caller-identity

Write-Host ""
Write-Host "--- AWS Region ---"
aws configure get region

Write-Host ""
Write-Host "--- Bedrock Model Access ---"
aws bedrock list-foundation-models `
  --region us-east-1 `
  --query "modelSummaries[?contains(modelId, 'claude')].[modelId,modelLifecycle.status]" `
  --output table
```

All outputs should be non-empty and error-free before beginning deployment.

---

## Tools That Are Already Installed

No action required for these tools:

| Tool | Version | Notes |
|---|---|---|
| AWS CLI | `2.30.2` | Current — no upgrade needed |
| kubectl | `v1.34.1` | Fully compatible with EKS `1.31` |
| Docker | `29.4.3` | Current |
| Git | `2.53.0` | Current |
| Python | `3.14.5` | Current — used for YAML validation in this repo |

---

## Post-Fix Readiness Checklist

Once all blockers are resolved, verify these items before beginning Phase 1 of `docs/93-eks-build-plan.md`:

- [ ] `eksctl version` returns `0.190.x` or later
- [ ] `helm version` returns `v3.x.x` or later
- [ ] `aws sts get-caller-identity` returns a valid account ID and ARN
- [ ] `aws configure get region` returns `us-east-1`
- [ ] Bedrock model access is enabled for Claude 3.5 Sonnet and Claude 3 Haiku
- [ ] IAM identity has the permissions listed in `docs/93-eks-build-plan.md` Phase 1.2
- [ ] VPC CIDR plan is documented (do not use the default VPC)
- [ ] Domain name for the gateway is registered and accessible in Route 53

---

## Related Documents

| Document | Content |
|---|---|
| `docs/91-deployment-inventory.md` | All 36 resources required for deployment |
| `docs/93-eks-build-plan.md` | 8-phase deployment blueprint with exact commands |
| `docs/94-secrets-management-strategy.md` | How to configure AWS credentials and secrets securely |
| `docs/95-irsa-and-iam-design.md` | Required IAM permissions for EKS and Bedrock |
