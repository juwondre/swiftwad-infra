module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "swiftwad-poc"
  cidr = "10.20.0.0/16"

  azs             = ["${var.region}a", "${var.region}b"]
  private_subnets = ["10.20.1.0/24", "10.20.2.0/24"]
  public_subnets  = ["10.20.101.0/24", "10.20.102.0/24"]

  # One NAT gateway for the whole POC — cost over availability.
  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
}
