# A fresh account has no GitHub OIDC provider (create_github_oidc_provider =
# true); the POC account already had one, so the default references it.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# Role assumable only by the sample-api repo's main branch. This is the entire
# blast radius of a compromised vendor CI workflow: push to one ECR repo.
data "aws_iam_policy_document" "gh_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # GitHub now issues ID-pinned sub claims (owner@id/repo@id) so trust
    # survives neither rename nor repo recreation. Both forms accepted.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.sample_app_repo}:*",
        "repo:${var.sample_app_repo_id_pinned}:*",
      ]
    }
  }
}

resource "aws_iam_role" "gh_actions_sample_api" {
  name               = "gh-actions-${var.service_name}"
  assume_role_policy = data.aws_iam_policy_document.gh_trust.json
}

data "aws_iam_policy_document" "ecr_push" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.sample_api.arn]
  }
}

resource "aws_iam_role_policy" "gh_actions_ecr_push" {
  name   = "ecr-push-sample-api"
  role   = aws_iam_role.gh_actions_sample_api.id
  policy = data.aws_iam_policy_document.ecr_push.json
}
