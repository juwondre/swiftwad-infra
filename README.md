# swiftwad-infra

Terraform for the vendor platform POC in the swiftwad AWS account (905418331655, us-east-1). Vendors never see this repo.

Creates:

- One VPC (2 AZs, single NAT gateway)
- Two EKS clusters: `swiftwad-dev` and `swiftwad-staging` (1.34, 2x t3.medium each)
- ECR repo `sample-api` — immutable tags, scan on push
- IAM role `gh-actions-swiftwad-sample-api` — assumable only by `juwondre/swiftwad-sample-api@main` via GitHub OIDC, can only push to that one ECR repo

State lives in `s3://swiftwad-tf-state-905418331655` (created out-of-band, versioned).

```sh
cd terraform
terraform init
terraform plan
terraform apply
```

Rough cost while running: ~$150/mo control planes, ~$120/mo nodes, ~$35/mo NAT. `terraform destroy` when done — nothing here is precious.

In the real project this runs from CI (plan on PR, apply on merge with approval), not laptops.
