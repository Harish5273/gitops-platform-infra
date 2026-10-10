# =============================================================================
# ecr.tf - Image registry (ECR Public) + keyless GitHub Actions access (OIDC)
# =============================================================================

locals {
  github_user = "Harish5273"
  app_repo    = "demo-app-source"
}

# ECR Public only exists in us-east-1
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

resource "aws_ecrpublic_repository" "app" {
  provider        = aws.us_east_1
  repository_name = "demo-app"
}

# Lets GitHub Actions prove its identity to AWS without stored access keys
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only the main branch of the app repo may assume this role
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.github_user}/${local.app_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.project_name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
}

data "aws_iam_policy_document" "ecr_push" {
  statement {
    actions   = ["ecr-public:GetAuthorizationToken", "sts:GetServiceBearerToken"]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr-public:BatchCheckLayerAvailability",
      "ecr-public:InitiateLayerUpload",
      "ecr-public:UploadLayerPart",
      "ecr-public:CompleteLayerUpload",
      "ecr-public:PutImage",
    ]
    resources = [aws_ecrpublic_repository.app.arn]
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  name   = "ecr-public-push"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.ecr_push.json
}

output "ecr_repository_uri" {
  value = aws_ecrpublic_repository.app.repository_uri
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}
