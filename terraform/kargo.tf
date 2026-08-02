# Kargo's controller polls ECR for new sample-api images (freight discovery).
# Runs on the staging cluster; auth via IRSA.
data "aws_iam_policy_document" "kargo_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks["staging"].oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks["staging"].oidc_provider}:sub"
      values   = ["system:serviceaccount:kargo:kargo-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks["staging"].oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "kargo_controller" {
  name               = "kargo-controller-swiftwad-staging"
  assume_role_policy = data.aws_iam_policy_document.kargo_trust.json
}

data "aws_iam_policy_document" "kargo_ecr_read" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr:DescribeImages",
      "ecr:ListImages",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = [aws_ecr_repository.sample_api.arn]
  }
}

resource "aws_iam_role_policy" "kargo_ecr_read" {
  name   = "ecr-read-sample-api"
  role   = aws_iam_role.kargo_controller.id
  policy = data.aws_iam_policy_document.kargo_ecr_read.json
}

output "kargo_controller_role_arn" {
  value = aws_iam_role.kargo_controller.arn
}
