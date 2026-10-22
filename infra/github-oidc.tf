# ─────────────────────────────────────────────────────────────────────
# Pipeline role for Week 8 (trusts the Week 3 app repo, where the pipeline runs).
#
# Why a new role: keeps Week 8 self-contained (the Week 7 role lives in the
# Week 7 repo's Terraform state). Destroying Week 8 never touches Week 7.
# Same OIDC pattern as Weeks 5–7: no AWS keys stored in GitHub.
# ─────────────────────────────────────────────────────────────────────

variable "github_owner" {
  type    = string
  default = "EbotProg"
}

variable "github_repo" {
  description = "Repo whose pipeline may assume this role (the Week 3 app repo)"
  type        = string
}

variable "github_owner_id" {
  description = "Numeric owner ID: gh api repos/<owner>/<repo> --jq .owner.id"
  type        = string
}

variable "github_repo_id" {
  description = "Numeric repo ID: gh api repos/<owner>/<repo> --jq .id"
  type        = string
}

# Created once per AWS account in Week 5. Looked up, not recreated.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "github_actions" {
  name = "${var.project}-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            # Your account's ID-suffixed format (confirmed in Weeks 5–7)
            "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}:*",
            # Standard format, in case GitHub sends this one
            "repo:${var.github_owner}/${var.github_repo}:*",
          ]
        }
      }
    }]
  })
}

# 1. Push images to the two existing ECR repos (same as Week 7)
resource "aws_iam_role_policy" "github_ecr_push" {
  name = "ecr-push"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
        ]
        Resource = [
          for s in local.services :
          "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${s.repo}"
        ]
      },
    ]
  })
}

# 2. NEW for Week 8: register task definitions + start CodeDeploy blue/green
resource "aws_iam_role_policy" "github_ecs_deploy" {
  name = "ecs-codedeploy-deploy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TaskDefinitionsAndServices"
        Effect = "Allow"
        Action = [
          "ecs:DescribeTaskDefinition",
          "ecs:RegisterTaskDefinition",
          "ecs:DescribeServices",
        ]
        Resource = "*" # these actions don't support resource-level scoping
      },
      {
        Sid    = "CodeDeployBlueGreen"
        Effect = "Allow"
        Action = [
          "codedeploy:CreateDeployment",
          "codedeploy:GetDeployment",
          "codedeploy:GetDeploymentConfig",
          "codedeploy:GetDeploymentGroup",
          "codedeploy:GetApplication",
          "codedeploy:GetApplicationRevision",
          "codedeploy:RegisterApplicationRevision",
        ]
        Resource = [
          aws_codedeploy_app.this.arn,
          "arn:aws:codedeploy:${var.region}:${data.aws_caller_identity.current.account_id}:deploymentgroup:${aws_codedeploy_app.this.name}/*",
          "arn:aws:codedeploy:${var.region}:${data.aws_caller_identity.current.account_id}:deploymentconfig:*",
        ]
      },
      {
        # A task definition names the execution role. Registering it means
        # "handing" that role to ECS, which needs iam:PassRole.
        Sid       = "PassExecutionRoleToEcs"
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = aws_iam_role.execution.arn
        Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
      },
    ]
  })
}

output "github_actions_role_arn" {
  description = "Set as GitHub repository variable AWS_ROLE_ARN in the Week 8 repo"
  value       = aws_iam_role.github_actions.arn
}
