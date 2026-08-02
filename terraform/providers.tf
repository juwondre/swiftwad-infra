provider "aws" {
  region  = var.region
  profile = "swiftwad"

  default_tags {
    tags = {
      Project   = "vendor-platform-poc"
      ManagedBy = "terraform"
    }
  }
}
