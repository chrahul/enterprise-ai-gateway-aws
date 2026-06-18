# ─────────────────────────────────────────────────────────────────────────────
# provider.tf — AWS provider configuration
# ─────────────────────────────────────────────────────────────────────────────
#
# Purpose:
#   Configures the AWS provider with the target region and a production-style
#   default_tags block. Default tags are automatically merged onto every AWS
#   resource that supports tags, eliminating the need to repeat tag blocks
#   throughout individual resource definitions.
#
# Authentication:
#   This configuration does NOT hardcode credentials. The AWS provider reads
#   credentials from the standard credential chain in priority order:
#     1. Environment variables: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
#     2. Shared credentials file: ~/.aws/credentials
#     3. IAM instance profile (when running on EC2 or ECS)
#     4. ECS/EKS task role or Web Identity token
#
#   For lab use, configure a named profile and set:
#     export AWS_PROFILE=your-profile
#   For CI/CD, inject credentials as environment variables.
#   NEVER hardcode credentials in this file.
#
# Default tags strategy:
#   Tags applied here appear on every resource and serve four purposes:
#     1. Cost allocation  — filter AWS Cost Explorer by Project + Environment
#     2. Ownership        — identify who manages the resource (ManagedBy)
#     3. Auditability     — trace resources back to the source repository
#     4. Automation       — tag-based policies and automation scripts can
#                           target resources without enumerating resource IDs
#
#   Resource-level tags override default tags when the same key appears in both.
# ─────────────────────────────────────────────────────────────────────────────

provider "aws" {
  region = var.aws_region

  # default_tags are applied to every AWS resource that supports tagging.
  # This is the recommended approach: it guarantees consistent tagging without
  # requiring each resource block to repeat a tags argument.
  default_tags {
    tags = {
      # Project groups all resources belonging to this workload for cost
      # reporting and resource search in the AWS Console.
      Project = var.project

      # Environment separates resources by deployment tier.
      # Useful for cost allocation and for scoping automation (e.g., "only
      # clean up resources where Environment = lab").
      Environment = var.environment

      # ManagedBy signals that this resource should not be modified manually
      # in the AWS Console — changes must go through Terraform.
      ManagedBy = "terraform"

      # Repository enables engineers to find the source code that manages
      # this resource, even when viewing it in the AWS Console months later.
      Repository = "enterprise-ai-gateway-aws"
    }
  }
}
