# ─────────────────────────────────────────────────────────────────────────────
# outputs.tf — Terraform output values
# ─────────────────────────────────────────────────────────────────────────────
#
# Purpose:
#   Outputs expose resource attributes after a successful `terraform apply`.
#   They serve three purposes:
#     1. Displayed in the terminal at the end of apply for quick reference.
#     2. Queryable individually: terraform output -raw cluster_name
#     3. Referenceable by other Terraform configurations via
#        data.terraform_remote_state if a remote backend is configured.
#
# Usage — configure kubectl after apply:
#   aws eks update-kubeconfig \
#     --region $(terraform output -raw aws_region) \
#     --name   $(terraform output -raw cluster_name)
#
#   Or use the pre-built command:
#   $(terraform output -raw kubeconfig_command)
#
# Sensitive outputs:
#   cluster_certificate_authority is marked sensitive = true because it
#   contains the cluster's CA data. It will not appear in plan/apply output
#   but can still be read with: terraform output cluster_certificate_authority
# ─────────────────────────────────────────────────────────────────────────────


# ─────────────────────────────────────────────────────────────────────────────
# EKS CLUSTER
# ─────────────────────────────────────────────────────────────────────────────

output "cluster_name" {
  description = "Name of the EKS cluster. Pass to 'aws eks update-kubeconfig --name' to configure kubectl."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "HTTPS endpoint of the EKS Kubernetes API server. Used by kubectl and the Kubernetes Terraform provider."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_oidc_issuer" {
  description = "OIDC issuer URL for the EKS cluster (e.g. https://oidc.eks.us-east-1.amazonaws.com/id/...). Required when constructing the condition in IRSA trust policies for pod IAM roles."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "cluster_certificate_authority" {
  description = "Base64-encoded certificate authority data for the EKS cluster. Used by kubectl and the Kubernetes Terraform provider to verify the API server TLS certificate."
  value       = aws_eks_cluster.this.certificate_authority[0].data
  sensitive   = true
}

output "cluster_version" {
  description = "Kubernetes version running on the EKS control plane."
  value       = aws_eks_cluster.this.version
}


# ─────────────────────────────────────────────────────────────────────────────
# OIDC / IRSA
# ─────────────────────────────────────────────────────────────────────────────

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider. Used as the Principal in IRSA IAM role trust policies when scoping which pods can assume a given role."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  description = "URL of the IAM OIDC provider (without https:// prefix). Used in the StringEquals condition of IRSA trust policies."
  value       = replace(aws_iam_openid_connect_provider.this.url, "https://", "")
}


# ─────────────────────────────────────────────────────────────────────────────
# NETWORKING
# ─────────────────────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "ID of the VPC. Reference this when creating additional resources (security groups, VPC endpoints, etc.) in subsequent phases."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "IDs of the two public subnets (one per AZ). Used for internet-facing load balancers and the NAT Gateway."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the two private subnets (one per AZ). Used for EKS worker nodes, pod networking, and internal load balancers."
  value       = aws_subnet.private[*].id
}

output "nat_gateway_public_ip" {
  description = "Public IP address of the NAT Gateway. All outbound internet traffic from worker nodes originates from this IP. Useful for IP-allowlisting in external services."
  value       = aws_eip.nat.public_ip
}


# ─────────────────────────────────────────────────────────────────────────────
# IAM
# ─────────────────────────────────────────────────────────────────────────────

output "cluster_iam_role_arn" {
  description = "ARN of the IAM role assumed by the EKS control plane."
  value       = aws_iam_role.eks_cluster.arn
}

output "node_iam_role_arn" {
  description = "ARN of the IAM role assumed by EKS worker nodes. Additional policies (Bedrock, Secrets Manager) will be attached to this role in later phases via IRSA service account roles."
  value       = aws_iam_role.eks_node.arn
}


# ─────────────────────────────────────────────────────────────────────────────
# CONVENIENCE
# ─────────────────────────────────────────────────────────────────────────────

output "aws_region" {
  description = "AWS region where all resources were deployed."
  value       = var.aws_region
}

output "kubeconfig_command" {
  description = "AWS CLI command to configure kubectl to connect to this cluster. Run this immediately after 'terraform apply'."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.this.name}"
}
