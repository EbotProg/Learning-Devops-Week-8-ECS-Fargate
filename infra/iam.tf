# ─────────────────────────────────────────────────────────────
# Execution role: used by ECS BEFORE your code runs
# (pull from ECR, write logs, read SSM secrets)
# No task role: neither app calls AWS APIs itself.
# ─────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.project}-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_ssm" {
  name = "read-app-secrets"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParameters"]
      Resource = [
        aws_ssm_parameter.database_uri.arn,
        aws_ssm_parameter.master_key.arn,
      ]
    }]
  })
}

# ─────────────────────────────────────────────────────────────
# ECS infrastructure role for load balancers (replaces the CodeDeploy role).
# Lets ECS itself change the listener rule weights (blue ↔ green)
# and register targets during a blue/green deployment.
# ─────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "ecs_infra_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_lb_infra" {
  name               = "${var.project}-ecs-lb-infra-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_infra_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_lb_infra" {
  role       = aws_iam_role.ecs_lb_infra.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForLoadBalancers"
}
