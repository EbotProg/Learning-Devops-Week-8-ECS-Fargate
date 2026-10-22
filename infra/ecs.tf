resource "aws_ecs_cluster" "this" {
  name = "${var.project}-cluster"
}

resource "aws_cloudwatch_log_group" "svc" {
  for_each = local.services

  name              = "/ecs/${var.project}/${each.key}"
  retention_in_days = 7
}

# ─────────────────────────────────────────────────────────────
# Per-service env vars and secrets (translated from docker-compose.yml)
# ─────────────────────────────────────────────────────────────
locals {
  container_env = {
    frontend = [
      { name = "PORT", value = "3000" },
      { name = "HOSTNAME", value = "0.0.0.0" },
      { name = "NEXT_PUBLIC_PARSE_APP_ID", value = var.parse_app_id },
      { name = "NEXT_PUBLIC_PARSE_SERVER_URL", value = local.public_parse_url },
    ]
    backend = [
      { name = "PORT", value = "1337" },
      { name = "APP_ID", value = var.parse_app_id },
      { name = "SERVER_URL", value = "http://localhost:1337/parse" },
      { name = "MASTER_KEY_IPS", value = "0.0.0.0/0,::0" },
    ]
  }

  container_secrets = {
    frontend = []
    backend = [
      { name = "DATABASE_URI", valueFrom = aws_ssm_parameter.database_uri.arn },
      { name = "MASTER_KEY", valueFrom = aws_ssm_parameter.master_key.arn },
    ]
  }
}

# ─────────────────────────────────────────────────────────────
# Task definitions: the recipes. Container name = service key
# ("frontend" / "backend"); the pipeline and appspec rely on that.
# ─────────────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "svc" {
  for_each = local.services

  family                   = "${var.project}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn

  # Keep old revisions ACTIVE when Terraform registers a new one,
  # so rollbacks always have something to roll back to.
  skip_destroy = true

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name         = each.key
      image        = "${local.ecr_registry}/${each.value.repo}:${var.image_tags[each.key]}"
      essential    = true
      portMappings = [{ containerPort = each.value.container_port, protocol = "tcp" }]
      environment  = local.container_env[each.key]
      secrets      = local.container_secrets[each.key]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.svc[each.key].name
          awslogs-region        = var.region
          awslogs-stream-prefix = each.key
        }
      }
    }
  ])
}

# ─────────────────────────────────────────────────────────────
# Services: the supervisors. Blue/green via CodeDeploy.
# ─────────────────────────────────────────────────────────────
resource "aws_ecs_service" "svc" {
  for_each = local.services

  name                              = "${var.project}-${each.key}"
  cluster                           = aws_ecs_cluster.this.id
  task_definition                   = aws_ecs_task_definition.svc[each.key].arn
  desired_count                     = var.min_tasks
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 120
  force_delete                      = true

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.blue[each.key].arn
    container_name   = each.key
    container_port   = each.value.container_port
  }

  # CodeDeploy changes task_definition + target group on every deploy;
  # autoscaling changes desired_count. Terraform must not undo those.
  lifecycle {
    ignore_changes = [task_definition, load_balancer, desired_count]
  }

  depends_on = [
    aws_lb_listener.prod,
    aws_iam_role_policy_attachment.execution,
    aws_iam_role_policy.execution_ssm,
    aws_route_table_association.private,
  ]
}
