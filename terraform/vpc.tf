# ─────────────────────────────────────────────────────────────────────────────
# vpc.tf — VPC, subnets, Internet Gateway, NAT Gateway, and route tables
# ─────────────────────────────────────────────────────────────────────────────
#
# Network topology created by this file:
#
#   VPC  10.0.0.0/16
#   │
#   ├── Public Subnet  us-east-1a  10.0.0.0/24   ──┐
#   ├── Public Subnet  us-east-1b  10.0.1.0/24   ──┤── Route: 0.0.0.0/0 → IGW
#   │                                               │
#   ├── Internet Gateway                            │
#   │   (attached to VPC)                           │
#   │                                               │
#   ├── Elastic IP  (for NAT)                       │
#   ├── NAT Gateway  (in Public Subnet us-east-1a)  │
#   │   Single NAT — cost-optimised for lab         │
#   │                                               │
#   ├── Private Subnet  us-east-1a  10.0.10.0/24 ──┐
#   └── Private Subnet  us-east-1b  10.0.11.0/24 ──┴── Route: 0.0.0.0/0 → NAT GW
#
# Kubernetes subnet tags:
#   Public  subnets → kubernetes.io/role/elb = 1
#     Required by the AWS Load Balancer Controller to provision
#     internet-facing Application Load Balancers (Phase 2).
#
#   Private subnets → kubernetes.io/role/internal-elb = 1
#     Required by the AWS Load Balancer Controller to provision
#     internal Application Load Balancers (Phase 2).
#
#   All subnets → kubernetes.io/cluster/<cluster_name> = shared
#     Required by EKS to discover subnets for ENI attachment when
#     placing pods that need a VPC IP address.
#
# NAT Gateway strategy:
#   This lab uses a single NAT Gateway (one EIP, one gateway in AZ-a).
#   All private subnets share one route table pointing to this gateway.
#
#   Lab trade-off accepted:
#     Single NAT = ~$32/month base + data charges. AZ failure in us-east-1a
#     would break outbound connectivity from private subnets until manually
#     recovered. Acceptable for a non-production lab.
#
#   Production recommendation:
#     Deploy one NAT Gateway per AZ (one EIP + one gateway per AZ).
#     Use one private route table per AZ, each pointing to its local gateway.
#     This eliminates cross-AZ data transfer charges and provides AZ-local
#     outbound resilience.
# ─────────────────────────────────────────────────────────────────────────────


# ─────────────────────────────────────────────────────────────────────────────
# VPC
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # DNS hostnames must be enabled for EKS nodes to receive internal DNS names
  # (e.g. ip-10-0-10-5.us-east-1.compute.internal). The Kubernetes API server
  # uses these names for internal node-to-node communication.
  enable_dns_hostnames = true

  # DNS support is required for CoreDNS (in-cluster DNS resolver), Route 53
  # private hosted zones, and VPC Endpoint DNS resolution.
  enable_dns_support = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC SUBNETS
# ─────────────────────────────────────────────────────────────────────────────
# One public subnet per AZ. These subnets host:
#   - The NAT Gateway (requires a public subnet with an IGW route)
#   - Future internet-facing ALBs (tagged for ALB Controller discovery)
#
# count = 2 creates:
#   index 0 → 10.0.0.0/24  in us-east-1a
#   index 1 → 10.0.1.0/24  in us-east-1b

resource "aws_subnet" "public" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # Assign a public IPv4 address to instances launched into this subnet.
  # Required for the NAT Gateway to receive an EIP and for any future
  # bastion hosts or public-facing resources.
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.cluster_name}-public-${var.availability_zones[count.index]}"

    # Required by the AWS Load Balancer Controller (Phase 2) to discover this
    # subnet when provisioning an internet-facing Application Load Balancer.
    "kubernetes.io/role/elb" = "1"

    # Required by EKS to discover and use this subnet for pod ENI placement.
    # "shared" means multiple EKS clusters could share this subnet.
    # Use "owned" if this subnet is dedicated to a single cluster.
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}


# ─────────────────────────────────────────────────────────────────────────────
# PRIVATE SUBNETS
# ─────────────────────────────────────────────────────────────────────────────
# One private subnet per AZ. These subnets host:
#   - EKS worker nodes (t3.small, no public IP)
#   - Kubernetes pods (VPC CNI assigns pod IPs from these CIDRs)
#
# count = 2 creates:
#   index 0 → 10.0.10.0/24  in us-east-1a
#   index 1 → 10.0.11.0/24  in us-east-1b

resource "aws_subnet" "private" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # map_public_ip_on_launch is false by default. Worker nodes must NOT receive
  # public IPs — they reach the internet exclusively through the NAT Gateway.
  # This enforces the security boundary between the data plane and the internet.

  tags = {
    Name = "${var.cluster_name}-private-${var.availability_zones[count.index]}"

    # Required by the AWS Load Balancer Controller (Phase 2) to discover this
    # subnet when provisioning an internal (VPC-only) Application Load Balancer.
    "kubernetes.io/role/internal-elb" = "1"

    # Required by EKS to discover and use this subnet for pod ENI placement.
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}


# ─────────────────────────────────────────────────────────────────────────────
# INTERNET GATEWAY
# ─────────────────────────────────────────────────────────────────────────────
# Provides the VPC with a route to the internet. Required for:
#   - Public subnets to send/receive internet traffic
#   - The NAT Gateway to forward outbound traffic from private subnets
#
# Only one Internet Gateway can be attached to a VPC at a time.

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}


# ─────────────────────────────────────────────────────────────────────────────
# ELASTIC IP FOR NAT GATEWAY
# ─────────────────────────────────────────────────────────────────────────────
# A static public IPv4 address allocated to the NAT Gateway. EKS nodes use this
# IP for all outbound internet traffic (pulling container images, calling AWS
# APIs, etc.). Knowing this IP in advance is useful for IP-allowlisting
# in external services.

resource "aws_eip" "nat" {
  domain = "vpc"

  # Ensure the Internet Gateway exists before allocating the EIP — the EIP
  # is only usable once the VPC has internet connectivity.
  depends_on = [aws_internet_gateway.this]

  tags = {
    Name = "${var.cluster_name}-nat-eip"
  }
}


# ─────────────────────────────────────────────────────────────────────────────
# NAT GATEWAY
# ─────────────────────────────────────────────────────────────────────────────
# Provides outbound internet access for resources in private subnets.
# EKS worker nodes use the NAT Gateway to:
#   - Pull container images from Amazon ECR and Docker Hub
#   - Call Amazon Bedrock and AWS Secrets Manager regional endpoints
#   - Download OS patches
#
# Placement: first public subnet (us-east-1a).
# A NAT Gateway must live in a public subnet that has a route to the IGW.
#
# Lab cost note:
#   NAT Gateways incur an hourly charge (~$0.045/hour = ~$32/month) plus
#   a per-GB data processing charge ($0.045/GB). For a lab with minimal
#   traffic, the monthly cost is typically $33–$35.

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id

  # Place in the first public subnet only (cost-optimised single NAT).
  subnet_id = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.this]

  tags = {
    Name = "${var.cluster_name}-nat"
  }
}


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC ROUTE TABLE
# ─────────────────────────────────────────────────────────────────────────────
# Routes all internet-bound traffic from public subnets to the IGW.
# Both public subnets share this single route table.

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    # Default route: send all non-VPC traffic to the Internet Gateway.
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.cluster_name}-public-rt"
  }
}


# ─────────────────────────────────────────────────────────────────────────────
# PRIVATE ROUTE TABLE
# ─────────────────────────────────────────────────────────────────────────────
# Routes all internet-bound traffic from private subnets to the NAT Gateway.
# Both private subnets share this single route table (lab simplification).
#
# Production note:
#   In a multi-NAT-Gateway setup, create one private route table per AZ and
#   point each to the AZ-local NAT Gateway. This avoids cross-AZ data transfer
#   charges and ensures private subnets remain functional if one AZ is impaired.

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    # Default route: send all non-VPC traffic from private subnets
    # to the NAT Gateway, which forwards it to the Internet Gateway.
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = {
    Name = "${var.cluster_name}-private-rt"
  }
}


# ─────────────────────────────────────────────────────────────────────────────
# ROUTE TABLE ASSOCIATIONS
# ─────────────────────────────────────────────────────────────────────────────
# Associates each subnet with its route table. Without these associations,
# subnets use the VPC's implicit main route table, which has no IGW or NAT
# routes and would block all internet traffic.

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
