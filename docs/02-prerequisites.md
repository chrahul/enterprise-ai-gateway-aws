# Prerequisites

Before deploying the Enterprise AI Gateway platform, ensure that all required AWS services, permissions and local tools are available.

This chapter validates the environment and prevents common deployment issues later in the tutorial.

## AWS Account Requirements

You need an AWS account that can create infrastructure, access managed AI services and incur usage-based charges.

| Requirement                     | Purpose                   |
| ------------------------------- | ------------------------- |
| AWS Account                     | Infrastructure deployment |
| Administrator Access (Lab Only) | Simplify setup            |
| Billing Enabled                 | EKS and Bedrock usage     |
| Supported AWS Region            | Bedrock availability      |

For production environments, follow least-privilege IAM practices instead of administrator access.

## Recommended AWS Region

For this tutorial:

```text
us-east-1
```

This region is recommended because it usually provides the lowest-friction path for this lab:

- Bedrock support
- Claude support
- Most examples available
- Lowest friction

Verify Bedrock model availability before selecting a region.

## Amazon Bedrock Access

Amazon Bedrock requires explicit model access before applications can invoke foundation models.

Before invoking any model, open the AWS Console and request model access:

```text
AWS Console
-> Amazon Bedrock
-> Model Access
```

Request access to:

```text
Claude
Amazon Nova
Titan
```

Without model access approval, Bedrock API calls will fail even if IAM permissions are correct.

## Local Workstation Requirements

Install the following tools on your local workstation before starting the deployment chapters.

| Tool       | Purpose               |
| ---------- | --------------------- |
| AWS CLI v2 | AWS access            |
| kubectl    | Kubernetes management |
| eksctl     | EKS cluster creation  |
| Docker     | Container testing     |
| Git        | Source control        |

Verify the tools are installed:

```bash
aws --version
kubectl version --client
eksctl version
docker --version
git --version
```

If any command fails, install or repair that tool before continuing.

## AWS CLI Configuration

Configure the AWS CLI with credentials for the AWS account you will use for this tutorial.

```bash
aws configure
```

Validate the active identity:

```bash
aws sts get-caller-identity
```

This confirms that AWS credentials are correctly configured.

The command should return the AWS account ID, user or role ARN and user ID associated with the active credentials.

## IAM Permissions Required

IAM exists because without it, workloads cannot securely access AWS services.

This tutorial creates infrastructure and connects Kubernetes workloads to AWS services. The identity running the setup commands must be allowed to create, configure and manage the required resources.

Required capabilities:

```text
EKS
EC2
IAM
CloudFormation
Bedrock
Load Balancers
VPC
```

For a lab environment, administrator access is the simplest path. For production, split permissions by responsibility and apply least-privilege IAM policies.

## Service Quotas

Check service quotas before creating the cluster.

Common quota areas to validate:

```text
EKS
EC2
Elastic IPs
Load Balancers
```

Insufficient service quotas are a common cause of deployment failures.

If cluster creation fails due to limits, review AWS Service Quotas and request an increase before retrying.

## Estimated Costs

This tutorial creates billable AWS resources.

| Service           | Approximate Cost |
| ----------------- | ---------------- |
| EKS Control Plane | ~$0.10/hour      |
| EC2 Nodes         | Depends on size  |
| Bedrock Usage     | Pay per token    |
| ALB               | Hourly + traffic |

Destroy resources after completing the lab to avoid unnecessary charges.

## Environment Validation Checklist

Before moving to the next chapter, confirm each item below:

- AWS Account Available
- Billing Enabled
- AWS CLI Installed
- kubectl Installed
- eksctl Installed
- Docker Installed
- Git Installed
- Bedrock Access Approved
- AWS CLI Authenticated
- Correct Region Selected

## What We Will Build

```text
User
 |
API Gateway
 |
LiteLLM
 |
Amazon Bedrock
 |
Claude
```

After completing the prerequisites, the next chapter creates the Amazon EKS cluster that will host the AI Gateway.
