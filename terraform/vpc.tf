# Permanent egress IP: the Cloudflare API token is IP-filtered to this
# address, so it must survive NAT gateway (and full platform) rebuilds.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.cluster_prefix}-poc-nat"
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.vpc_name
  cidr = "10.20.0.0/16"

  azs             = ["${var.region}a", "${var.region}b"]
  private_subnets = ["10.20.1.0/24", "10.20.2.0/24"]
  public_subnets  = ["10.20.101.0/24", "10.20.102.0/24"]

  # One NAT gateway for the whole POC — cost over availability.
  enable_nat_gateway  = true
  single_nat_gateway  = true
  reuse_nat_ips       = true
  external_nat_ip_ids = [aws_eip.nat.id]

  enable_dns_hostnames = true
}
