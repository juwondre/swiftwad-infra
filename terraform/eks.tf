module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.37"

  for_each = toset(var.environments)

  cluster_name    = "${var.cluster_prefix}-${each.key}"
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  # Creator-based admin is caller-dependent: every alternation between local
  # and Atlantis applies flipped the access entries and locked someone out.
  # Disabled in favor of operator entries declared below — identical config
  # no matter which identity runs terraform.
  enable_cluster_creator_admin_permissions = false
  access_entries = {
    for idx, arn in var.operator_principal_arns :
    "operator-${idx}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.medium"]
      ami_type       = "AL2023_x86_64_STANDARD"
      min_size       = var.node_group_sizes[each.key].min
      max_size       = var.node_group_sizes[each.key].max
      desired_size   = var.node_group_sizes[each.key].desired
      disk_size      = 20
    }
  }

  tags = {
    Environment = each.key
  }
}

# The ArgoCD hub on staging talks to the dev API server across the VPC.
resource "aws_vpc_security_group_ingress_rule" "hub_to_dev_api" {
  security_group_id = module.eks["dev"].cluster_primary_security_group_id
  description       = "ArgoCD hub (staging) to dev API server"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "10.20.0.0/16"
}
