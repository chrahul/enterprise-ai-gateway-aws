# Deployment Execution Checklist

**Purpose:** Step-by-step execution guide that converts the EKS build plan and deployment inventory into atomic, verifiable commands. Each step has a single objective, the command to execute, a validation command, and the expected output.

**Source documents:**
- [93-eks-build-plan.md](93-eks-build-plan.md) — Phase-by-phase blueprint
- [91-deployment-inventory.md](91-deployment-inventory.md) — 36-resource inventory and deployment order

**Scope:** This document prepares all execution steps. It does **not** create any AWS resources. No command in this document must be run before the engineer has reviewed and confirmed the environment-specific values (account ID, VPC CIDR, domain name, etc.).

**Before you begin:** Substitute these values throughout the document:

| Placeholder | Your Value | Description |
|---|---|---|
| `ACCOUNT_ID` | e.g. `123456789012` | 12-digit AWS account ID |
| `VPC_ID` | e.g. `vpc-0abc1234` | VPC created in Step 1 |
| `PRIVATE_SUBNET_A` | e.g. `subnet-0aaa1111` | Private subnet in AZ us-east-1a |
| `PRIVATE_SUBNET_B` | e.g. `subnet-0bbb2222` | Private subnet in AZ us-east-1b |
| `PRIVATE_SUBNET_C` | e.g. `subnet-0ccc3333` | Private subnet in AZ us-east-1c |
| `PUBLIC_SUBNET_A` | e.g. `subnet-0ddd4444` | Public subnet in AZ us-east-1a |
| `PUBLIC_SUBNET_B` | e.g. `subnet-0eee5555` | Public subnet in AZ us-east-1b |
| `GATEWAY_DOMAIN` | e.g. `ai-gateway.example.com` | Fully qualified domain for the gateway |
| `MASTER_KEY` | e.g. `sk-prod-...` | LiteLLM master key (generate securely) |

---

## Phase 1 — AWS Foundations

### Step 1.1 — Verify AWS CLI Identity

**Objective:** Confirm the AWS CLI is authenticated with an identity that has sufficient permissions to create VPCs, EKS clusters, and IAM roles.

**Command:**
```bash
aws sts get-caller-identity
```

**Validation command:**
```bash
aws sts get-caller-identity --query '[Account, Arn, UserId]' --output table
```

**Expected output:**
```
------------------------------------------------------------------------------------------
|                                   GetCallerIdentity                                   |
+----------------+------------------+------------------------------------------------------+
|  ACCOUNT_ID    |  UserId          |  Arn                                                 |
+----------------+------------------+------------------------------------------------------+
|  123456789012  |  AIDAXXXXX       |  arn:aws:iam::123456789012:user/deploy-engineer       |
+----------------+------------------+------------------------------------------------------+
```

The account ID must match your target environment. The ARN must belong to an identity with `AdministratorAccess` or an equivalent policy. Do not proceed if the account ID is unexpected.

---

### Step 1.2 — Verify Required Local Tools

**Objective:** Confirm all required CLI tools are installed with supported versions before any infrastructure commands are run.

**Command:**
```bash
aws --version
kubectl version --client --short
eksctl version
helm version --short
```

**Validation command:**
```bash
echo "aws:     $(aws --version 2>&1)" && \
echo "kubectl: $(kubectl version --client --short 2>&1)" && \
echo "eksctl:  $(eksctl version 2>&1)" && \
echo "helm:    $(helm version --short 2>&1)"
```

**Expected output:**
```
aws:     aws-cli/2.x.x Python/3.x.x ...
kubectl: Client Version: v1.31.x
eksctl:  0.190.x
helm:    v3.x.x+g...
```

All four tools must return a version string. If any command is not found, install it before proceeding. See [90-local-environment-readiness.md](90-local-environment-readiness.md) for installation links.

---

### Step 1.3 — Verify Bedrock Model Availability in us-east-1

**Objective:** Confirm that Claude 3.5 Sonnet and Claude 3 Haiku are accessible in the target region before building any infrastructure.

**Command:**
```bash
aws bedrock list-foundation-models \
  --region us-east-1 \
  --query "modelSummaries[?modelLifecycle.status=='ACTIVE'].[modelId]" \
  --output text | grep -E "claude-3-5-sonnet|claude-3-haiku"
```

**Validation command:**
```bash
aws bedrock list-foundation-models \
  --region us-east-1 \
  --query "modelSummaries[?contains(modelId, 'claude-3')].{id:modelId, status:modelLifecycle.status}" \
  --output table
```

**Expected output:**
```
-----------------------------------------------------------------------
|                        ListFoundationModels                         |
+-----------------------------------------------+---------------------+
|  id                                           |  status             |
+-----------------------------------------------+---------------------+
|  anthropic.claude-3-5-sonnet-20241022-v2:0    |  ACTIVE             |
|  anthropic.claude-3-haiku-20240307-v1:0       |  ACTIVE             |
+-----------------------------------------------+---------------------+
```

If either model is missing, navigate to the Bedrock console → Model access → enable the model before proceeding. Approval is typically instant for us-east-1.

---

## Phase 2 — Networking

> **Note:** Steps 2.1–2.6 create networking resources. If you already have a suitable VPC, skip to Step 2.7 (subnet tagging).

### Step 2.1 — Create Dedicated VPC

**Objective:** Create a new, dedicated VPC for the AI Gateway. Do not use the default VPC.

**Command:**
```bash
aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --region us-east-1 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=ai-gateway-vpc},{Key=Project,Value=enterprise-ai-gateway}]'
```

**Validation command:**
```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=ai-gateway-vpc" \
  --query "Vpcs[0].{VpcId:VpcId, State:State, CIDR:CidrBlock}" \
  --output table
```

**Expected output:**
```
--------------------------------------------
|               DescribeVpcs               |
+--------+------------------+--------------+
|  CIDR  |  State           |  VpcId       |
+--------+------------------+--------------+
|  10.0.0.0/16 |  available |  vpc-0abc... |
+--------+------------------+--------------+
```

Record the `VpcId` value as `VPC_ID` for subsequent steps.

---

### Step 2.2 — Create Private Subnets

**Objective:** Create three private subnets (one per availability zone) for EKS nodes and pods.

**Command:**
```bash
# AZ-a
aws ec2 create-subnet \
  --vpc-id VPC_ID \
  --cidr-block 10.0.1.0/24 \
  --availability-zone us-east-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=ai-gateway-private-a},{Key=kubernetes.io/role/internal-elb,Value=1}]'

# AZ-b
aws ec2 create-subnet \
  --vpc-id VPC_ID \
  --cidr-block 10.0.2.0/24 \
  --availability-zone us-east-1b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=ai-gateway-private-b},{Key=kubernetes.io/role/internal-elb,Value=1}]'

# AZ-c
aws ec2 create-subnet \
  --vpc-id VPC_ID \
  --cidr-block 10.0.3.0/24 \
  --availability-zone us-east-1c \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=ai-gateway-private-c},{Key=kubernetes.io/role/internal-elb,Value=1}]'
```

**Validation command:**
```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=VPC_ID" "Name=tag:Name,Values=ai-gateway-private-*" \
  --query "Subnets[].{Name:Tags[?Key=='Name']|[0].Value, SubnetId:SubnetId, AZ:AvailabilityZone, CIDR:CidrBlock}" \
  --output table
```

**Expected output:**
```
Three rows, one per AZ, each with a SubnetId and CIDR 10.0.[1-3].0/24.
State must be available.
```

Record the three SubnetId values as `PRIVATE_SUBNET_A`, `PRIVATE_SUBNET_B`, `PRIVATE_SUBNET_C`.

---

### Step 2.3 — Create Public Subnets

**Objective:** Create two public subnets for ALB placement. Tag them so the AWS Load Balancer Controller can discover them.

**Command:**
```bash
# AZ-a
aws ec2 create-subnet \
  --vpc-id VPC_ID \
  --cidr-block 10.0.101.0/24 \
  --availability-zone us-east-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=ai-gateway-public-a},{Key=kubernetes.io/role/elb,Value=1}]'

# AZ-b
aws ec2 create-subnet \
  --vpc-id VPC_ID \
  --cidr-block 10.0.102.0/24 \
  --availability-zone us-east-1b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=ai-gateway-public-b},{Key=kubernetes.io/role/elb,Value=1}]'
```

**Validation command:**
```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=VPC_ID" "Name=tag:Name,Values=ai-gateway-public-*" \
  --query "Subnets[].{Name:Tags[?Key=='Name']|[0].Value, SubnetId:SubnetId, AZ:AvailabilityZone}" \
  --output table
```

**Expected output:**
```
Two rows: ai-gateway-public-a and ai-gateway-public-b, each with a SubnetId.
```

Record the two SubnetId values as `PUBLIC_SUBNET_A`, `PUBLIC_SUBNET_B`.

---

### Step 2.4 — Create and Attach Internet Gateway

**Objective:** Create an Internet Gateway and attach it to the VPC so that public subnets can route outbound traffic and the ALB can receive inbound traffic.

**Command:**
```bash
aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=ai-gateway-igw}]'

# Attach (replace IGW_ID with the InternetGatewayId returned above)
aws ec2 attach-internet-gateway \
  --internet-gateway-id IGW_ID \
  --vpc-id VPC_ID
```

**Validation command:**
```bash
aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=VPC_ID" \
  --query "InternetGateways[0].{Id:InternetGatewayId, State:Attachments[0].State}" \
  --output table
```

**Expected output:**
```
State: available  (attachment state = attached)
```

---

### Step 2.5 — Create NAT Gateway

**Objective:** Create a NAT Gateway in the public subnet so that EKS nodes in private subnets can make outbound calls to Bedrock endpoints and pull container images.

**Command:**
```bash
# Allocate an Elastic IP for the NAT Gateway
aws ec2 allocate-address --domain vpc

# Create the NAT Gateway in the first public subnet
# Replace EIP_ALLOC_ID with the AllocationId returned above
aws ec2 create-nat-gateway \
  --subnet-id PUBLIC_SUBNET_A \
  --allocation-id EIP_ALLOC_ID \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=ai-gateway-nat}]'
```

**Validation command:**
```bash
aws ec2 describe-nat-gateways \
  --filter "Name=tag:Name,Values=ai-gateway-nat" \
  --query "NatGateways[0].{Id:NatGatewayId, State:State, SubnetId:SubnetId}" \
  --output table
```

**Expected output:**
```
State: available   (takes 1–2 minutes to reach this state)
```

---

### Step 2.6 — Create Route Tables

**Objective:** Route private subnet traffic through the NAT Gateway, and public subnet traffic through the Internet Gateway.

**Command:**
```bash
# Public route table
aws ec2 create-route-table --vpc-id VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=ai-gateway-public-rt}]'

aws ec2 create-route --route-table-id PUBLIC_RT_ID \
  --destination-cidr-block 0.0.0.0/0 --gateway-id IGW_ID

aws ec2 associate-route-table --route-table-id PUBLIC_RT_ID --subnet-id PUBLIC_SUBNET_A
aws ec2 associate-route-table --route-table-id PUBLIC_RT_ID --subnet-id PUBLIC_SUBNET_B

# Private route table
aws ec2 create-route-table --vpc-id VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=ai-gateway-private-rt}]'

aws ec2 create-route --route-table-id PRIVATE_RT_ID \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id NAT_GW_ID

aws ec2 associate-route-table --route-table-id PRIVATE_RT_ID --subnet-id PRIVATE_SUBNET_A
aws ec2 associate-route-table --route-table-id PRIVATE_RT_ID --subnet-id PRIVATE_SUBNET_B
aws ec2 associate-route-table --route-table-id PRIVATE_RT_ID --subnet-id PRIVATE_SUBNET_C
```

**Validation command:**
```bash
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=VPC_ID" \
  --query "RouteTables[].{Name:Tags[?Key=='Name']|[0].Value, Routes:Routes[?State=='active'].DestinationCidrBlock}" \
  --output table
```

**Expected output:**
```
Public route table: has route 0.0.0.0/0 → igw-xxx
Private route table: has route 0.0.0.0/0 → nat-xxx
```

---

## Phase 3 — EKS Cluster

### Step 3.1 — Create Cluster Config File

**Objective:** Prepare the eksctl cluster configuration file. This file is environment-specific and must not be committed to the repository.

**Command:**
```bash
cat > cluster-config.yaml << 'EOF'
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

vpc:
  id: "VPC_ID"
  subnets:
    private:
      us-east-1a: { id: "PRIVATE_SUBNET_A" }
      us-east-1b: { id: "PRIVATE_SUBNET_B" }
      us-east-1c: { id: "PRIVATE_SUBNET_C" }
    public:
      us-east-1a: { id: "PUBLIC_SUBNET_A" }
      us-east-1b: { id: "PUBLIC_SUBNET_B" }

iam:
  withOIDC: true

managedNodeGroups:
  - name: ai-gateway-nodes
    instanceType: m5.large
    minSize: 3
    maxSize: 6
    desiredCapacity: 3
    volumeSize: 50
    privateNetworking: true
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
EOF
```

**Validation command:**
```bash
# Confirm the file was written and contains the correct cluster name
grep -E "name:|region:|version:" cluster-config.yaml
```

**Expected output:**
```
  name: ai-gateway-prod
  region: us-east-1
  version: "1.31"
```

> **Security note:** `cluster-config.yaml` is in `.gitignore` and must not be committed. It contains your VPC and subnet IDs.

---

### Step 3.2 — Create the EKS Cluster

**Objective:** Provision the EKS cluster with OIDC enabled (required for IRSA in Phase 5). This takes 15–20 minutes.

**Command:**
```bash
eksctl create cluster -f cluster-config.yaml
```

**Validation command:**
```bash
aws eks describe-cluster \
  --name ai-gateway-prod \
  --region us-east-1 \
  --query "cluster.{Status:status, K8sVersion:version, Endpoint:endpoint}" \
  --output table
```

**Expected output:**
```
----------------------------------------------------------------------
|                          DescribeCluster                           |
+-------------------+-------+---------------------------------------+
|  Endpoint         |  K8sVersion  |  Status                        |
+-------------------+-------+---------------------------------------+
|  https://xxx.eks  |  1.31  |  ACTIVE                              |
+-------------------+-------+---------------------------------------+
```

`Status` must be `ACTIVE`. If it shows `CREATING`, wait and re-run the validation command.

---

### Step 3.3 — Update kubeconfig

**Objective:** Configure `kubectl` to communicate with the new cluster.

**Command:**
```bash
aws eks update-kubeconfig \
  --name ai-gateway-prod \
  --region us-east-1
```

**Validation command:**
```bash
kubectl get nodes -o wide
```

**Expected output:**
```
Three nodes, all in STATUS Ready, running Kubernetes v1.31.x.
NODE_NAME   STATUS   ROLES    AGE   VERSION   INTERNAL-IP   ...
ip-10-0-1-x   Ready   <none>   Xm   v1.31.x   10.0.1.x   ...
ip-10-0-2-x   Ready   <none>   Xm   v1.31.x   10.0.2.x   ...
ip-10-0-3-x   Ready   <none>   Xm   v1.31.x   10.0.3.x   ...
```

All nodes must be `Ready`. Internal IPs must fall within the private subnet CIDRs (`10.0.1–3.x`).

---

### Step 3.4 — Enable VPC CNI Network Policy Enforcement

**Objective:** Activate network policy enforcement in the VPC CNI add-on so that `kubernetes/networkpolicy.yaml` documents are enforced rather than just loaded.

**Command:**
```bash
aws eks update-addon \
  --cluster-name ai-gateway-prod \
  --addon-name vpc-cni \
  --region us-east-1 \
  --configuration-values '{"enableNetworkPolicy": "true"}'
```

**Validation command:**
```bash
aws eks describe-addon \
  --cluster-name ai-gateway-prod \
  --addon-name vpc-cni \
  --region us-east-1 \
  --query "addon.{Status:status, Config:configurationValues}" \
  --output table
```

**Expected output:**
```
Status: ACTIVE
Config: {"enableNetworkPolicy": "true"}
```

---

### Step 3.5 — Install AWS Load Balancer Controller

**Objective:** Install the AWS Load Balancer Controller, which is required for `kubernetes/ingress.yaml` to provision an Application Load Balancer.

**Command:**
```bash
# Step A: Download the IAM policy document
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.0/docs/install/iam_policy.json

# Step B: Create the IAM policy
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json

# Step C: Create the IRSA service account for the controller
eksctl create iamserviceaccount \
  --cluster ai-gateway-prod \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

# Step D: Install the controller via Helm
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName=ai-gateway-prod \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

**Validation command:**
```bash
kubectl get deployment aws-load-balancer-controller -n kube-system \
  -o jsonpath='{.status.readyReplicas}'
```

**Expected output:**
```
2
```

Two replicas of the controller must be ready. If the value is `0` or empty, check the controller logs: `kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50`.

---

### Step 3.6 — Install Metrics Server

**Objective:** Install the Kubernetes Metrics Server, required for the HorizontalPodAutoscaler in `kubernetes/hpa.yaml`.

**Command:**
```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

**Validation command:**
```bash
kubectl get deployment metrics-server -n kube-system \
  -o jsonpath='{.status.readyReplicas}' && echo ""
kubectl top nodes 2>&1 | head -5
```

**Expected output:**
```
1
NAME          CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
ip-10-0-1-x   45m          2%     1024Mi          13%
...
```

Wait 2–3 minutes after installation before running `kubectl top nodes`. The metrics server needs time to scrape its first metrics cycle.

---

## Phase 4 — ACM Certificate

### Step 4.1 — Request ACM Certificate

**Objective:** Provision a TLS certificate for the gateway domain. The certificate ARN will be placed in `kubernetes/ingress.yaml`.

**Command:**
```bash
aws acm request-certificate \
  --domain-name GATEWAY_DOMAIN \
  --validation-method DNS \
  --region us-east-1 \
  --tags Key=Name,Value=ai-gateway-cert Key=Project,Value=enterprise-ai-gateway
```

**Validation command:**
```bash
aws acm list-certificates \
  --region us-east-1 \
  --query "CertificateSummaryList[?DomainName=='GATEWAY_DOMAIN'].{ARN:CertificateArn, Status:Status}" \
  --output table
```

**Expected output:**
```
Status: PENDING_VALIDATION  (initially)
Status: ISSUED              (after DNS validation is complete)
```

Record the `CertificateArn` value as `CERT_ARN`.

---

### Step 4.2 — Complete DNS Validation

**Objective:** Add the CNAME record required by ACM to validate ownership of the domain.

**Command:**
```bash
# Retrieve the CNAME record to add to your DNS provider
aws acm describe-certificate \
  --certificate-arn CERT_ARN \
  --region us-east-1 \
  --query "Certificate.DomainValidationOptions[0].ResourceRecord"
```

**Validation command:**
```bash
aws acm describe-certificate \
  --certificate-arn CERT_ARN \
  --region us-east-1 \
  --query "Certificate.Status" \
  --output text
```

**Expected output:**
```
ISSUED
```

Add the CNAME record returned in the Command step to your DNS provider (Route 53, Cloudflare, or other). ACM validates automatically once the record propagates (typically 1–5 minutes with Route 53).

---

### Step 4.3 — Update Ingress with Certificate ARN

**Objective:** Replace the placeholder ACM ARN and domain in `kubernetes/ingress.yaml` with the real values.

**Command:**
```bash
# Review the current placeholder values
grep -E "certificate-arn|host:" kubernetes/ingress.yaml
```

**Update `kubernetes/ingress.yaml`** — replace these two lines:
```yaml
# Before
alb.ingress.kubernetes.io/certificate-arn: "arn:aws:acm:us-east-1:ACCOUNT_ID:certificate/CERTIFICATE_ID"
...
  - host: ai-gateway.PLACEHOLDER_DOMAIN.com

# After
alb.ingress.kubernetes.io/certificate-arn: "CERT_ARN"
...
  - host: GATEWAY_DOMAIN
```

**Validation command:**
```bash
grep -E "certificate-arn|host:" kubernetes/ingress.yaml
```

**Expected output:**
```
alb.ingress.kubernetes.io/certificate-arn: "arn:aws:acm:us-east-1:123456789012:certificate/abc-123"
  - host: ai-gateway.example.com
```

No placeholder strings (`ACCOUNT_ID`, `CERTIFICATE_ID`, `PLACEHOLDER_DOMAIN`) should remain.

---

## Phase 5 — IAM and IRSA

### Step 5.1 — Create the LiteLLM IAM Policy

**Objective:** Create the IAM policy that grants LiteLLM pods permission to invoke Bedrock models and read from Secrets Manager. Do not store `litellm-policy.json` in the repository.

**Command:**
```bash
cat > litellm-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BedrockInvokeModel",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": [
        "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0",
        "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-haiku-20240307-v1:0"
      ]
    },
    {
      "Sid": "SecretsManagerRead",
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:us-east-1:ACCOUNT_ID:secret:ai-gateway-prod/litellm-secrets*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name LiteLLMGatewayPolicy \
  --policy-document file://litellm-policy.json
```

**Validation command:**
```bash
aws iam get-policy \
  --policy-arn arn:aws:iam::ACCOUNT_ID:policy/LiteLLMGatewayPolicy \
  --query "Policy.{Name:PolicyName, Arn:Arn, Created:CreateDate}" \
  --output table
```

**Expected output:**
```
Policy Name: LiteLLMGatewayPolicy
Arn: arn:aws:iam::ACCOUNT_ID:policy/LiteLLMGatewayPolicy
Created: 2026-xx-xx
```

> **Security note:** `litellm-policy.json` is in `.gitignore` and must not be committed.

---

### Step 5.2 — Associate OIDC Provider

**Objective:** Register the EKS cluster's OIDC issuer as a trusted identity provider in IAM. This is the prerequisite for IRSA.

**Command:**
```bash
eksctl utils associate-iam-oidc-provider \
  --cluster ai-gateway-prod \
  --region us-east-1 \
  --approve
```

**Validation command:**
```bash
# Retrieve the OIDC issuer URL from the cluster
OIDC_ISSUER=$(aws eks describe-cluster \
  --name ai-gateway-prod \
  --region us-east-1 \
  --query "cluster.identity.oidc.issuer" \
  --output text | sed 's|https://||')

# Verify the provider exists in IAM
aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn, '${OIDC_ISSUER}')].Arn" \
  --output text
```

**Expected output:**
```
arn:aws:iam::ACCOUNT_ID:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/XXXXXXXXXX
```

The OIDC provider ARN must be non-empty. If it is empty, the `eksctl utils associate-iam-oidc-provider` command did not succeed.

---

### Step 5.3 — Create IRSA Role for LiteLLM

**Objective:** Create an IAM role with a trust policy scoped to the LiteLLM Kubernetes ServiceAccount. eksctl handles the trust policy automatically.

**Command:**
```bash
eksctl create iamserviceaccount \
  --cluster ai-gateway-prod \
  --namespace ai-gateway \
  --name litellm-sa \
  --attach-policy-arn arn:aws:iam::ACCOUNT_ID:policy/LiteLLMGatewayPolicy \
  --approve \
  --override-existing-serviceaccounts
```

**Validation command:**
```bash
# Retrieve the IAM role ARN that was created and annotated on the ServiceAccount
kubectl get serviceaccount litellm-sa -n ai-gateway \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
```

**Expected output:**
```
arn:aws:iam::ACCOUNT_ID:role/eksctl-ai-gateway-prod-addon-iamserviceaccount-ai-gateway-litellm-sa-Role1-XXXXXXXXXXXX
```

Record this ARN as `IRSA_ROLE_ARN`.

---

### Step 5.4 — Update serviceaccount.yaml with Real ARN

**Objective:** Replace the placeholder ARN in `kubernetes/serviceaccount.yaml` with the real IRSA role ARN retrieved in Step 5.3.

**Command:**
```bash
# View the current placeholder
grep "role-arn" kubernetes/serviceaccount.yaml
```

Edit `kubernetes/serviceaccount.yaml`: replace the annotation value `arn:aws:iam::ACCOUNT_ID:role/ROLE_NAME` with `IRSA_ROLE_ARN`.

**Validation command:**
```bash
grep "role-arn" kubernetes/serviceaccount.yaml
```

**Expected output:**
```
eks.amazonaws.com/role-arn: "arn:aws:iam::123456789012:role/eksctl-ai-gateway-prod-..."
```

No placeholder strings must remain. Commit this change to the repository before proceeding to Phase 6.

---

## Phase 6 — Secrets

### Step 6.1 — Create Secret in AWS Secrets Manager

**Objective:** Store the LiteLLM master key and any optional provider API keys in AWS Secrets Manager.

**Command:**
```bash
# Generate a cryptographically random master key
MASTER_KEY="sk-$(openssl rand -hex 32)"
echo "Generated master key — save this value securely: $MASTER_KEY"

aws secretsmanager create-secret \
  --name "ai-gateway-prod/litellm-secrets" \
  --region us-east-1 \
  --description "LiteLLM master key and AI provider credentials for ai-gateway-prod" \
  --secret-string "{\"LITELLM_MASTER_KEY\": \"${MASTER_KEY}\"}"
```

**Validation command:**
```bash
aws secretsmanager describe-secret \
  --secret-id "ai-gateway-prod/litellm-secrets" \
  --region us-east-1 \
  --query "{ Name:Name, ARN:ARN, Created:CreatedDate }" \
  --output table
```

**Expected output:**
```
Name: ai-gateway-prod/litellm-secrets
ARN:  arn:aws:secretsmanager:us-east-1:ACCOUNT_ID:secret:ai-gateway-prod/litellm-secrets-XXXXXX
```

> **Security note:** Do not print or log the secret value after this step. The master key is now in Secrets Manager only.

---

### Step 6.2 — Create Kubernetes Secret for LiteLLM

**Objective:** Inject the master key from Secrets Manager into a Kubernetes Secret so that the LiteLLM Deployment can reference it as an environment variable.

**Command:**
```bash
# Retrieve the master key from Secrets Manager (in-memory only — not logged)
MASTER_KEY=$(aws secretsmanager get-secret-value \
  --secret-id "ai-gateway-prod/litellm-secrets" \
  --region us-east-1 \
  --query "SecretString" \
  --output text | python3 -c "import sys,json; print(json.load(sys.stdin)['LITELLM_MASTER_KEY'])")

# Create the Kubernetes Secret
kubectl create secret generic litellm-secrets \
  --namespace ai-gateway \
  --from-literal=LITELLM_MASTER_KEY="$MASTER_KEY"

# Clear the variable from the shell session
unset MASTER_KEY
```

**Validation command:**
```bash
kubectl get secret litellm-secrets -n ai-gateway \
  -o jsonpath='{.metadata.name} {.type} {.data.LITELLM_MASTER_KEY}' | \
  awk '{print "Name:", $1, "Type:", $2, "Key present:", ($3 != "" ? "YES" : "NO")}'
```

**Expected output:**
```
Name: litellm-secrets  Type: Opaque  Key present: YES
```

The value must never be decoded or logged. `Key present: YES` confirms the key exists without revealing its content.

---

## Phase 7 — Kubernetes Deployment

### Step 7.1 — Apply Namespace

**Objective:** Create the `ai-gateway` namespace. All subsequent Kubernetes resources depend on this namespace existing first.

**Command:**
```bash
kubectl apply -f kubernetes/namespace.yaml
```

**Validation command:**
```bash
kubectl get namespace ai-gateway \
  -o jsonpath='{.metadata.name} {.status.phase}'
```

**Expected output:**
```
ai-gateway Active
```

---

### Step 7.2 — Apply ConfigMap

**Objective:** Create the `litellm-config` ConfigMap that contains the LiteLLM configuration file. This is mounted at `/app/config.yaml` in the pod.

**Command:**
```bash
kubectl apply -f kubernetes/configmap.yaml
```

**Validation command:**
```bash
kubectl get configmap litellm-config -n ai-gateway \
  -o jsonpath='{.data}' | python3 -c "import sys,json; d=json.load(sys.stdin); print('Keys:', list(d.keys())); print('config.yaml length:', len(d.get('config.yaml','')),'chars')"
```

**Expected output:**
```
Keys: ['config.yaml']
config.yaml length: 950 chars   (or similar non-zero value)
```

The ConfigMap must contain the key `config.yaml` with a non-empty value.

---

### Step 7.3 — Apply ServiceAccount

**Objective:** Create the `litellm-sa` ServiceAccount with the IRSA annotation. The annotation must contain the real role ARN (set in Step 5.4 — not a placeholder).

**Command:**
```bash
# Confirm there are no placeholders before applying
grep "ACCOUNT_ID\|ROLE_NAME" kubernetes/serviceaccount.yaml && \
  echo "ERROR: Placeholder ARN found — update serviceaccount.yaml before applying" || \
  kubectl apply -f kubernetes/serviceaccount.yaml
```

**Validation command:**
```bash
kubectl get serviceaccount litellm-sa -n ai-gateway \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
```

**Expected output:**
```
arn:aws:iam::123456789012:role/eksctl-ai-gateway-prod-...
```

If the command returns an empty string or the placeholder ARN, do not proceed to Step 7.4.

---

### Step 7.4 — Apply Deployment

**Objective:** Deploy LiteLLM with 2 replicas, the ConfigMap volume mount, and the IRSA ServiceAccount.

**Command:**
```bash
kubectl apply -f kubernetes/deployment.yaml
```

**Validation command:**
```bash
kubectl rollout status deployment/litellm -n ai-gateway --timeout=120s
kubectl get pods -n ai-gateway -o wide
```

**Expected output:**
```
deployment "litellm" successfully rolled out
NAME              READY   STATUS    RESTARTS   AGE   IP           NODE
litellm-xxx-yyy   1/1     Running   0          60s   10.0.1.xx    ip-10-0-1-x
litellm-xxx-zzz   1/1     Running   0          60s   10.0.2.xx    ip-10-0-2-x
```

Both pods must be `1/1 Running` with `0` restarts. If either pod is in `CrashLoopBackOff`, run `kubectl logs -n ai-gateway deployment/litellm` and consult [91-troubleshooting.md](91-troubleshooting.md) Section 1.

---

### Step 7.5 — Apply Service

**Objective:** Create the ClusterIP Service that exposes the LiteLLM pods internally on port 80 (forwarded to container port 4000).

**Command:**
```bash
kubectl apply -f kubernetes/service.yaml
```

**Validation command:**
```bash
kubectl get svc litellm -n ai-gateway \
  -o jsonpath='{.spec.type} {.spec.clusterIP} {.spec.ports[0].port}->{.spec.ports[0].targetPort}'
```

**Expected output:**
```
ClusterIP 10.100.x.x 80->4000
```

---

### Step 7.6 — Apply Ingress

**Objective:** Create the ALB Ingress. The AWS Load Balancer Controller will provision an Application Load Balancer in response to this resource. ACM certificate ARN and domain must already be correct (Step 4.3).

**Command:**
```bash
# Confirm no placeholder values remain before applying
grep -E "ACCOUNT_ID|CERTIFICATE_ID|PLACEHOLDER_DOMAIN" kubernetes/ingress.yaml && \
  echo "ERROR: Placeholders found — do not apply" || \
  kubectl apply -f kubernetes/ingress.yaml
```

**Validation command:**
```bash
# Poll until ADDRESS is populated (ALB takes 2–5 minutes to provision)
kubectl get ingress litellm -n ai-gateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

**Expected output:**
```
k8s-aigatew-litellm-abc123def456.us-east-1.elb.amazonaws.com
```

If the hostname is empty after 5 minutes, check the ALB controller logs: `kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50`. See [91-troubleshooting.md](91-troubleshooting.md) Section 2.

---

### Step 7.7 — Apply NetworkPolicy, HPA, and PDB

**Objective:** Apply the remaining manifests — NetworkPolicy (traffic isolation), HPA (autoscaling), and PDB (disruption budget).

**Command:**
```bash
kubectl apply -f kubernetes/networkpolicy.yaml
kubectl apply -f kubernetes/hpa.yaml
kubectl apply -f kubernetes/pdb.yaml
```

**Validation command:**
```bash
echo "=== NetworkPolicies ===" && \
kubectl get networkpolicy -n ai-gateway && \
echo "=== HPA ===" && \
kubectl get hpa -n ai-gateway && \
echo "=== PDB ===" && \
kubectl get pdb -n ai-gateway
```

**Expected output:**
```
=== NetworkPolicies ===
NAME                        POD-SELECTOR   AGE
allow-aws-https-egress      ...            Xs
allow-dns-egress            ...            Xs
allow-kube-system-ingress   ...            Xs
default-deny-all            ...            Xs

=== HPA ===
NAME      REFERENCE            TARGETS                     MINPODS   MAXPODS   REPLICAS
litellm   Deployment/litellm   cpu: 5%/70%, memory: X%/80%   2         10        2

=== PDB ===
NAME          MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
litellm-pdb   1               N/A               1                     Xs
```

For the HPA, `TARGETS` must show actual percentage values (not `<unknown>`). If it shows `<unknown>`, the Metrics Server is not ready yet — wait 2 minutes and re-run.

---

### Step 7.8 — Create DNS Record for Gateway Domain

**Objective:** Create a Route 53 CNAME (or alias) record pointing `GATEWAY_DOMAIN` to the ALB DNS name.

**Command:**
```bash
# Retrieve the ALB DNS name
ALB_DNS=$(kubectl get ingress litellm -n ai-gateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "ALB DNS: $ALB_DNS"
echo "Create a CNAME record: GATEWAY_DOMAIN → $ALB_DNS"
# Create in Route 53 console or with the aws route53 CLI using your hosted zone ID
```

**Validation command:**
```bash
# DNS propagation check (run from your local machine)
nslookup GATEWAY_DOMAIN
```

**Expected output:**
```
Name: GATEWAY_DOMAIN
Address: x.x.x.x   (ALB IP address — may vary per DNS query due to ALB's multiple IPs)
```

---

## Phase 8 — End-to-End Validation

### Step 8.1 — Gateway Health Check

**Objective:** Confirm the LiteLLM health endpoint is reachable and returns healthy status.

**Command:**
```bash
# Via port-forward (does not require DNS or ALB to be ready)
kubectl port-forward svc/litellm -n ai-gateway 8080:80 &
PF_PID=$!
sleep 2
curl -s http://localhost:8080/health
kill $PF_PID
```

**Validation command:**
```bash
curl -s http://localhost:8080/health | python3 -m json.tool
```

**Expected output:**
```json
{
  "status": "healthy",
  "litellm_version": "1.88.1"
}
```

---

### Step 8.2 — Model List

**Objective:** Confirm both Bedrock models are registered and visible via the gateway's model listing endpoint.

**Command:**
```bash
kubectl port-forward svc/litellm -n ai-gateway 8080:80 &
PF_PID=$!
sleep 2

curl -s -H "Authorization: Bearer $MASTER_KEY" \
  http://localhost:8080/v1/models | \
  python3 -c "import sys,json; models=json.load(sys.stdin)['data']; [print(m['id']) for m in models]"

kill $PF_PID
```

**Validation command:**
```bash
curl -s -H "Authorization: Bearer $MASTER_KEY" \
  http://localhost:8080/v1/models | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print('Model count:', len(d['data'])); [print(' -', m['id']) for m in d['data']]"
```

**Expected output:**
```
Model count: 2
 - claude-sonnet
 - claude-haiku
```

---

### Step 8.3 — Chat Completion via Claude Haiku

**Objective:** Send a real inference request through the gateway to Bedrock Claude 3 Haiku. This validates the full path: gateway → IRSA → Bedrock.

**Command:**
```bash
kubectl port-forward svc/litellm -n ai-gateway 8080:80 &
PF_PID=$!
sleep 2

curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku","messages":[{"role":"user","content":"Reply with exactly one word: OPERATIONAL"}],"max_tokens":10}'

kill $PF_PID
```

**Validation command:**
```bash
curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku","messages":[{"role":"user","content":"Reply with exactly one word: OPERATIONAL"}],"max_tokens":10}' | \
  python3 -c "import sys,json; r=json.load(sys.stdin); print('HTTP 200'); print('Response:', r['choices'][0]['message']['content']); print('Input tokens:', r['usage']['prompt_tokens']); print('Output tokens:', r['usage']['completion_tokens'])"
```

**Expected output:**
```
HTTP 200
Response: OPERATIONAL
Input tokens: 28
Output tokens: 1
```

---

### Step 8.4 — Chat Completion via Claude Sonnet

**Objective:** Validate Claude 3.5 Sonnet access through the same path.

**Command:**
```bash
kubectl port-forward svc/litellm -n ai-gateway 8080:80 &
PF_PID=$!
sleep 2

curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet","messages":[{"role":"user","content":"Reply with exactly one word: OPERATIONAL"}],"max_tokens":10}' | \
  python3 -c "import sys,json; r=json.load(sys.stdin); print('Response:', r['choices'][0]['message']['content'])"

kill $PF_PID
```

**Validation command:**
```bash
# Confirm HTTP 200 and non-empty content
curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8080/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet","messages":[{"role":"user","content":"ping"}],"max_tokens":5}'
```

**Expected output:**
```
200
```

---

### Step 8.5 — Authentication Enforcement

**Objective:** Verify the gateway correctly rejects requests without a valid API key.

**Command:**
```bash
kubectl port-forward svc/litellm -n ai-gateway 8080:80 &
PF_PID=$!
sleep 2

# Test 1: No Authorization header
echo -n "No auth header: HTTP "
curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku","messages":[{"role":"user","content":"test"}]}'

# Test 2: Wrong API key
echo ""
echo -n "Wrong key: HTTP "
curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8080/v1/chat/completions \
  -H "Authorization: Bearer INVALID_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku","messages":[{"role":"user","content":"test"}]}'

kill $PF_PID
```

**Validation command:**
Both responses above serve as their own validation. Check the output.

**Expected output:**
```
No auth header: HTTP 401
Wrong key: HTTP 401
```

---

### Step 8.6 — HPA and Autoscaling Readiness

**Objective:** Confirm the HPA can read pod metrics and is ready to scale.

**Command:**
```bash
kubectl get hpa litellm -n ai-gateway
```

**Validation command:**
```bash
kubectl describe hpa litellm -n ai-gateway | grep -E "Metrics:|Current|Min|Max|Conditions"
```

**Expected output:**
```
Min replicas:   2
Max replicas:   10
Current Metrics: cpu 5% / 70%,  memory X% / 80%
Conditions:
  AbleToScale   True    ReadyForNewScale
  ScalingActive True    ValidMetricFound
```

`TARGETS` must not show `<unknown>`. Both CPU and memory metrics must be visible.

---

## Completion Checklist

All steps must pass before the gateway is considered production-ready.

| Phase | Step | Description | Pass |
|---|---|---|---|
| 1 | 1.1 | AWS CLI identity confirmed | ☐ |
| 1 | 1.2 | All local tools installed and versioned | ☐ |
| 1 | 1.3 | Bedrock models active in us-east-1 | ☐ |
| 2 | 2.1–2.6 | VPC, subnets, IGW, NAT, route tables created | ☐ |
| 3 | 3.2 | EKS cluster ACTIVE | ☐ |
| 3 | 3.3 | kubectl connected, 3 nodes Ready | ☐ |
| 3 | 3.4 | VPC CNI network policy enforcement enabled | ☐ |
| 3 | 3.5 | ALB controller 2/2 replicas ready | ☐ |
| 3 | 3.6 | Metrics Server ready, `kubectl top nodes` works | ☐ |
| 4 | 4.1–4.3 | ACM certificate ISSUED, Ingress updated | ☐ |
| 5 | 5.1 | LiteLLMGatewayPolicy created | ☐ |
| 5 | 5.2 | OIDC provider associated | ☐ |
| 5 | 5.3–5.4 | IRSA role created, serviceaccount.yaml updated | ☐ |
| 6 | 6.1 | Secret created in Secrets Manager | ☐ |
| 6 | 6.2 | Kubernetes Secret `litellm-secrets` created | ☐ |
| 7 | 7.1 | Namespace `ai-gateway` Active | ☐ |
| 7 | 7.2 | ConfigMap `litellm-config` present | ☐ |
| 7 | 7.3 | ServiceAccount has real IRSA ARN | ☐ |
| 7 | 7.4 | Deployment 2/2 pods Running, 0 restarts | ☐ |
| 7 | 7.5 | Service ClusterIP 80→4000 | ☐ |
| 7 | 7.6 | Ingress ADDRESS populated (ALB DNS name) | ☐ |
| 7 | 7.7 | NetworkPolicy, HPA, PDB applied | ☐ |
| 7 | 7.8 | DNS record pointing to ALB | ☐ |
| 8 | 8.1 | Health endpoint returns `{"status": "healthy"}` | ☐ |
| 8 | 8.2 | Model list returns 2 models | ☐ |
| 8 | 8.3 | Claude Haiku returns HTTP 200 with content | ☐ |
| 8 | 8.4 | Claude Sonnet returns HTTP 200 with content | ☐ |
| 8 | 8.5 | Unauthenticated requests return HTTP 401 | ☐ |
| 8 | 8.6 | HPA shows real metric values (not `<unknown>`) | ☐ |

**29 checks total. All must pass.**

---

## See Also

- [91-troubleshooting.md](91-troubleshooting.md) — Remediation for failed steps
- [90-testing.md](90-testing.md) — Detailed validation commands by category
- [95-irsa-and-iam-design.md](95-irsa-and-iam-design.md) — IRSA architecture and IAM policy design
- [94-secrets-management-strategy.md](94-secrets-management-strategy.md) — Secrets strategy and rotation
- [93-eks-build-plan.md](93-eks-build-plan.md) — Full phase-by-phase narrative build plan
