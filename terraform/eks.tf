# ─────────────────────────────────────────────────────────────────────────────
# eks.tf — EKS cluster, OIDC provider, IAM roles, and managed node group
# ─────────────────────────────────────────────────────────────────────────────
#
# Resources created in dependency order:
#
#   1.  aws_cloudwatch_log_group         — receives control plane logs
#   2.  aws_iam_role.eks_cluster         — assumed by the EKS control plane
#   3.  aws_iam_role_policy_attachment × 2  — attach AWS managed policies to cluster role
#   4.  aws_eks_cluster                  — the EKS control plane
#   5.  data.tls_certificate             — fetches OIDC endpoint certificate thumbprint
#   6.  aws_iam_openid_connect_provider  — registers EKS OIDC endpoint with IAM
#   7.  aws_iam_role.eks_node            — assumed by EC2 worker nodes
#   8.  aws_iam_role_policy_attachment × 3  — attach AWS managed policies to node role
#   9.  aws_eks_node_group               — managed node group (t3.small × 2)
#
# OIDC / IRSA explanation:
#   IRSA (IAM Roles for Service Accounts) is the AWS-native mechanism for
#   giving individual Kubernetes pods access to AWS services without storing
#   long-lived access keys. It works as follows:
#
#     1. The EKS cluster exposes an OIDC endpoint.
#     2. aws_iam_openid_connect_provider registers that endpoint with IAM.
#     3. Kubernetes projects a short-lived signed JWT into each pod.
#     4. The pod's AWS SDK calls sts:AssumeRoleWithWebIdentity with the JWT.
#     5. IAM validates the JWT against the registered OIDC provider.
#     6. STS returns short-lived credentials scoped to the target IAM role.
#
#   Phase 1 creates the OIDC provider. The IRSA role for LiteLLM (with
#   Bedrock and Secrets Manager permissions) is provisioned in a later phase.
#   See docs/95-irsa-and-iam-design.md for the complete IRSA architecture.
#
# IAM role strategy:
#   Two separate IAM roles are required:
#     - Cluster role (eks_cluster): assumed by the EKS SERVICE PRINCIPAL
#       (eks.amazonaws.com). Grants the control plane permission to manage
#       VPC interfaces, security groups, and CloudWatch logs.
#     - Node role   (eks_node):    assumed by EC2 INSTANCES (ec2.amazonaws.com).
#       Grants worker nodes permission to join the cluster, configure pod
#       networking via the VPC CNI, and pull images from Amazon ECR.
#
# CloudWatch logging:
#   All five EKS control plane log streams are enabled:
#     api             — Kubernetes API server requests (useful for audit)
#     audit           — who did what to which resource and when
#     authenticator   — token authentication (aws-iam-authenticator)
#     controllerManager — reconciliation loops (node, replication, etc.)
#     scheduler       — pod scheduling decisions
#
#   The log group is pre-created with a 7-day retention to control cost.
#   Without explicit creation, EKS creates the group with no expiration.
# ─────────────────────────────────────────────────────────────────────────────


# ─────────────────────────────────────────────────────────────────────────────
# CLOUDWATCH LOG GROUP
# ─────────────────────────────────────────────────────────────────────────────
# Pre-create the CloudWatch log group that EKS writes control plane logs to.
# EKS follows the convention /aws/eks/<cluster_name>/cluster automatically.
# Creating it here lets Terraform manage retention — if EKS creates it first,
# the default retention is "Never expire", which accumulates cost indefinitely.

resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.cloudwatch_retention_days

  tags = {
    Name = "${var.cluster_name}-logs"
  }
}


# ─────────────────────────────────────────────────────────────────────────────
# IAM: EKS CLUSTER ROLE
# ─────────────────────────────────────────────────────────────────────────────
# The EKS control plane assumes this role to make AWS API calls on behalf of
# the cluster. Without it, EKS cannot create ENIs in your VPC or write
# CloudWatch logs.

data "aws_iam_policy_document" "eks_cluster_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.cluster_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume_role.json

  tags = {
    Name = "${var.cluster_name}-cluster-role"
  }
}

# AmazonEKSClusterPolicy — grants the EKS control plane permissions to manage
# Auto Scaling groups, EC2 instances, ELBs, and CloudWatch log groups.
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# AmazonEKSVPCResourceController — required for EKS to manage VPC resources
# including Elastic Network Interfaces (ENIs) and security groups used for
# pod networking (VPC CNI).
resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}


# ─────────────────────────────────────────────────────────────────────────────
# EKS CLUSTER
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    # Include both public and private subnets. EKS uses this list to determine
    # which subnets to create cross-account ENIs in so the managed control
    # plane can communicate with worker nodes.
    subnet_ids = concat(
      aws_subnet.public[*].id,
      aws_subnet.private[*].id,
    )

    # endpoint_public_access = true allows kubectl on developer workstations
    # to reach the API server via its public endpoint. This is appropriate for
    # a lab. For production, restrict public_access_cidrs to known corporate
    # CIDR ranges, or set endpoint_public_access = false and connect via VPN.
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  # Forward all five control plane log streams to CloudWatch Logs.
  # Each stream provides distinct visibility:
  #   api              → request-level audit trail
  #   audit            → who changed what (RBAC-level audit)
  #   authenticator    → aws-iam-authenticator decisions
  #   controllerManager→ reconciliation loop events
  #   scheduler        → pod scheduling decisions and reasons
  enabled_cluster_log_types = var.cluster_log_types

  # Ordering guarantees:
  #   - IAM policies must be attached before the cluster attempts to use them.
  #   - The log group must exist so EKS writes to it with the managed
  #     retention policy rather than creating a new group with no expiration.
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller,
    aws_cloudwatch_log_group.eks_cluster,
  ]

  tags = {
    Name = var.cluster_name

    # Required by the AWS Load Balancer Controller and the cluster autoscaler
    # to identify which cluster owns this infrastructure.
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}


# ─────────────────────────────────────────────────────────────────────────────
# OIDC PROVIDER
# ─────────────────────────────────────────────────────────────────────────────
# Registers the EKS cluster's OIDC endpoint with AWS IAM. This is the
# prerequisite for IRSA (IAM Roles for Service Accounts).
#
# How the thumbprint is obtained:
#   1. data.tls_certificate fetches the TLS certificate presented by the OIDC
#      endpoint (https://oidc.eks.<region>.amazonaws.com/id/<hash>).
#   2. It extracts the SHA-1 fingerprint of the root CA certificate.
#   3. aws_iam_openid_connect_provider registers this fingerprint with IAM so
#      that STS can validate JWT signatures from this OIDC provider.
#
# Note: AWS now auto-validates OIDC JWT signatures using the provider's JWKS
# endpoint, making the thumbprint a formality for Amazon-operated endpoints.
# It is still required by the resource schema.

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  # sts.amazonaws.com is the expected audience claim in the JWT. All EKS OIDC
  # providers use this audience to scope tokens to AWS STS.
  client_id_list = ["sts.amazonaws.com"]

  # SHA-1 fingerprint of the OIDC provider's root CA certificate.
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]

  # The OIDC issuer URL is stable for the lifetime of the cluster.
  # Format: https://oidc.eks.<region>.amazonaws.com/id/<cluster_hash>
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = {
    Name = "${var.cluster_name}-oidc-provider"
  }
}


# ─────────────────────────────────────────────────────────────────────────────
# IAM: EKS NODE GROUP ROLE
# ─────────────────────────────────────────────────────────────────────────────
# EC2 worker nodes assume this role at launch. It provides the minimum
# permissions required for nodes to:
#   - Join and communicate with the EKS cluster (WorkerNodePolicy)
#   - Configure pod networking via the VPC CNI (CNI_Policy)
#   - Pull container images from Amazon ECR (ContainerRegistryReadOnly)

data "aws_iam_policy_document" "eks_node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${var.cluster_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume_role.json

  tags = {
    Name = "${var.cluster_name}-node-role"
  }
}

# AmazonEKSWorkerNodePolicy — allows nodes to register with the EKS cluster
# and to describe EC2 resources needed for node lifecycle management.
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

# AmazonEKS_CNI_Policy — required by the aws-node DaemonSet (VPC CNI plugin)
# to assign and manage Elastic Network Interfaces and secondary private IPs
# for pod-level VPC networking.
resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# AmazonEC2ContainerRegistryReadOnly — allows nodes to authenticate with and
# pull images from Amazon ECR repositories in this account. Required when
# using private ECR repositories for any workload container images.
resource "aws_iam_role_policy_attachment" "eks_container_registry_policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}


# ─────────────────────────────────────────────────────────────────────────────
# EKS MANAGED NODE GROUP
# ─────────────────────────────────────────────────────────────────────────────
# A managed node group delegates node provisioning, AMI updates, and lifecycle
# management to AWS. Nodes are created as EC2 instances in an Auto Scaling Group
# managed by EKS. This is the recommended approach over self-managed node groups.
#
# Node placement: private subnets only.
#   Worker nodes have no public IP addresses and are not directly reachable
#   from the internet. Outbound traffic (ECR pulls, Bedrock calls) flows
#   through the NAT Gateway.
#
# AMI type: AL2023_x86_64_STANDARD
#   Amazon Linux 2023 is the current-generation EKS-optimised AMI. It uses
#   containerd as the container runtime (replacing Docker) and provides
#   improved security defaults and faster boot times compared to AL2.
#
# update_config:
#   max_unavailable = 1 means EKS replaces nodes one at a time during updates,
#   keeping min_size nodes available throughout the operation.

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.eks_node.arn

  # Worker nodes run exclusively in private subnets.
  subnet_ids = aws_subnet.private[*].id

  # AL2023 is the recommended AMI type for new EKS node groups.
  ami_type = "AL2023_x86_64_STANDARD"

  instance_types = [var.node_instance_type]

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  # Replace nodes one at a time during node group updates to maintain capacity.
  update_config {
    max_unavailable = 1
  }

  # Ensure all three IAM policies are fully attached before EKS attempts to
  # provision nodes — missing policies cause nodes to fail to join the cluster.
  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry_policy,
  ]

  tags = {
    Name = "${var.cluster_name}-nodes"
  }
}
