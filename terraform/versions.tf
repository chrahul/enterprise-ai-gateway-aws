# ─────────────────────────────────────────────────────────────────────────────
# versions.tf — Terraform CLI and provider version constraints
# ─────────────────────────────────────────────────────────────────────────────
#
# Purpose:
#   Pins the minimum Terraform CLI version and the required provider sources
#   and version ranges. This file is committed to source control so that every
#   developer and CI run uses a compatible provider set.
#
# Why version constraints matter:
#   Without version pins, `terraform init` may download a newer provider that
#   introduces breaking changes or deprecations. The `~> 5.0` constraint (also
#   written as `>= 5.0, < 6.0`) allows any AWS provider 5.x release while
#   blocking a future 6.x major version that could include breaking changes.
#
# Updating providers:
#   Run `terraform init -upgrade` to pull the latest version within these
#   constraints. Review the provider changelog before upgrading in shared
#   environments. Commit the resulting .terraform.lock.hcl to lock the exact
#   provider hash across all machines.
#
# Note: .terraform.lock.hcl is NOT in .gitignore for this repo — commit it
#   after the first `terraform init` to ensure reproducible provider downloads.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  # Require Terraform CLI 1.6 or later.
  # 1.6 introduced the native test framework (`terraform test`) and improved
  # plan performance for large configurations.
  required_version = ">= 1.6"

  required_providers {
    # AWS provider — manages all AWS resources in this configuration.
    # Source: https://registry.terraform.io/providers/hashicorp/aws
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    # TLS provider — used to retrieve the OIDC certificate thumbprint for the
    # EKS OIDC identity provider registration with IAM (see eks.tf).
    # The thumbprint is required when creating aws_iam_openid_connect_provider.
    # Source: https://registry.terraform.io/providers/hashicorp/tls
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
