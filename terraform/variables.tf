# ─────────────────────────────────────────────────────────────────────────────
# variables.tf — Input variable declarations
# ─────────────────────────────────────────────────────────────────────────────
#
# Purpose:
#   All configurable input variables are declared here with descriptions,
#   types, defaults, and validation rules. Centralising variables in one file
#   makes it easy to see every dial that can be turned for a given deployment.
#
# Pattern:
#   - Defaults are set to lab-appropriate values.
#   - Override defaults by creating a terraform.tfvars file
#     (see terraform.tfvars.example — never commit the real tfvars file).
#   - Sensitive values (credentials, account IDs) are NEVER stored here.
#     Inject them via environment variables at plan/apply time:
#       export TF_VAR_my_secret="value"
#
# Sections:
#   1. AWS / Region
#   2. Naming and Tagging
#   3. EKS Cluster
#   4. Networking
#   5. EKS Node Group
# ─────────────────────────────────────────────────────────────────────────────


# ═══════════════════════════════════════════════════════════════════════════════
# 1. AWS / REGION
# ═══════════════════════════════════════════════════════════════════════════════

variable "aws_region" {
  description = "AWS region where all resources will be deployed. us-east-1 is recommended for this lab because Amazon Bedrock has the broadest foundation model availability there."
  type        = string
  default     = "us-east-1"
}


# ═══════════════════════════════════════════════════════════════════════════════
# 2. NAMING AND TAGGING
# ═══════════════════════════════════════════════════════════════════════════════

variable "environment" {
  description = "Deployment environment. Used in resource names and cost-allocation tags. Must be one of: lab, staging, prod."
  type        = string
  default     = "lab"

  validation {
    condition     = contains(["lab", "staging", "prod"], var.environment)
    error_message = "environment must be one of: lab, staging, prod."
  }
}

variable "project" {
  description = "Project identifier applied to all resource tags for cost allocation and resource discovery in the AWS Console."
  type        = string
  default     = "enterprise-ai-gateway"
}


# ═══════════════════════════════════════════════════════════════════════════════
# 3. EKS CLUSTER
# ═══════════════════════════════════════════════════════════════════════════════

variable "cluster_name" {
  description = "Name of the EKS cluster. Also used as a prefix for dependent resources such as IAM roles, the CloudWatch log group, and VPC subnet tags."
  type        = string
  default     = "ai-gateway-lab"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS control plane. Use the latest stable version supported by the AWS provider. Current versions: https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html"
  type        = string
  default     = "1.32"
}

variable "cluster_log_types" {
  description = "EKS control plane log types forwarded to CloudWatch Logs. Enabling all five types provides full observability into API activity, authentication, and controller behaviour."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "cloudwatch_retention_days" {
  description = "CloudWatch Logs retention period in days for EKS control plane logs. 7 days balances lab observability against CloudWatch storage cost."
  type        = number
  default     = 7
}


# ═══════════════════════════════════════════════════════════════════════════════
# 4. NETWORKING
# ═══════════════════════════════════════════════════════════════════════════════

variable "vpc_cidr" {
  description = "IPv4 CIDR block for the dedicated VPC. Must not overlap with other VPCs if VPC peering is planned. /16 provides 65,536 addresses — adequate headroom for subnets, nodes, and pods."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones for subnet distribution. Two AZs are the minimum for EKS high availability. Both AZs must be within var.aws_region."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]

  validation {
    condition     = length(var.availability_zones) == 2
    error_message = "Exactly 2 availability zones are required for this lab configuration."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ). Public subnets host the Internet Gateway route, the NAT Gateway, and future internet-facing load balancers."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ). EKS worker nodes run exclusively in private subnets — they reach the internet via the NAT Gateway and are never directly reachable from the public internet."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}


# ═══════════════════════════════════════════════════════════════════════════════
# 5. EKS NODE GROUP
# ═══════════════════════════════════════════════════════════════════════════════

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes. t3.small (2 vCPU, 2 GiB) is sufficient for lab use: it can run the LiteLLM pod plus system pods (CoreDNS, kube-proxy, VPC CNI). For production, consider m5.large or c5.large based on observed CPU/memory profiles."
  type        = string
  default     = "t3.small"
}

variable "node_desired_size" {
  description = "Desired number of worker nodes at steady state. Must be >= node_min_size and <= node_max_size."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes. The cluster autoscaler will not scale below this value."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes. The cluster autoscaler will not scale above this value."
  type        = number
  default     = 4
}
