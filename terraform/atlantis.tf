# Atlantis runs terraform plan/apply for this repo from PRs. Lives on the
# staging cluster; auth via IRSA.
#
# POC grants AdministratorAccess because this terraform manages IAM, VPC, and
# EKS. In the real project, scope this to the services terraform actually
# touches plus a permissions boundary.
data "aws_iam_policy_document" "atlantis_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks["staging"].oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks["staging"].oidc_provider}:sub"
      values   = ["system:serviceaccount:atlantis:atlantis"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks["staging"].oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "atlantis" {
  name               = "atlantis-swiftwad-staging"
  assume_role_policy = data.aws_iam_policy_document.atlantis_trust.json
}

resource "aws_iam_role_policy_attachment" "atlantis_admin" {
  role       = aws_iam_role.atlantis.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "atlantis_role_arn" {
  value = aws_iam_role.atlantis.arn
}
