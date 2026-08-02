# The OIDC provider for token.actions.githubusercontent.com already exists in
# this account, so it's referenced, not created.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# Role assumable only by the sample-api repo's main branch. This is the entire
# blast radius of a compromised vendor CI workflow: push to one ECR repo.
data "aws_iam_policy_document" "gh_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.sample_app_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "gh_actions_sample_api" {
  name               = "gh-actions-swiftwad-sample-api"
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
