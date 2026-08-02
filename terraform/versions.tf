terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # No AWS profile here: Atlantis authenticates via IRSA, laptops via
  # AWS_PROFILE=swiftwad in the environment.
  backend "s3" {
    bucket       = "swiftwad-tf-state-905418331655"
    key          = "poc/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}
