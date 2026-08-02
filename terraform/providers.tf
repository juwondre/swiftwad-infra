provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "vendor-platform-poc"
      ManagedBy = "terraform"
    }
  }
}
