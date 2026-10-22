# ─────────────────────────────────────────────────────────────
# ALB in the public subnets.
#   :80   → frontend
#   :1337 → backend (Parse); the browser calls Parse directly
#
# Blue/green (ECS built-in): each service has a BLUE and a GREEN target group.
# A listener RULE forwards to both with weights (100 / 0). During a deployment
# ECS flips the weights (0 / 100). That flip IS the traffic switch.
# ─────────────────────────────────────────────────────────────
resource "aws_lb" "this" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "blue" {
  for_each = local.services

  name                 = "${var.project}-${each.key}-blue"
  port                 = each.value.container_port
  protocol             = "HTTP"
  target_type          = "ip" # Fargate tasks are registered by IP
  vpc_id               = aws_vpc.this.id
  deregistration_delay = 30

  health_check {
    path                = each.value.health_path
    matcher             = each.value.health_matcher
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group" "green" {
  for_each = local.services

  name                 = "${var.project}-${each.key}-green"
  port                 = each.value.container_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.this.id
  deregistration_delay = 30

  health_check {
    path                = each.value.health_path
    matcher             = each.value.health_matcher
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# Listener: the default action is only a fallback. Real traffic goes through the rule below.
resource "aws_lb_listener" "prod" {
  for_each = local.services

  load_balancer_arn = aws_lb.this.arn
  port              = each.value.listener_port
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "No matching rule"
      status_code  = "404"
    }
  }
}

# Production listener rule: ECS shifts traffic by changing these weights.
resource "aws_lb_listener_rule" "prod" {
  for_each = local.services

  listener_arn = aws_lb_listener.prod[each.key].arn
  priority     = 100

  action {
    type = "forward"
    forward {
      target_group {
        arn    = aws_lb_target_group.blue[each.key].arn
        weight = 100
      }
      target_group {
        arn    = aws_lb_target_group.green[each.key].arn
        weight = 0
      }
    }
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }

  # ECS changes the weights on every deployment. Terraform must not reset them.
  lifecycle {
    ignore_changes = [action]
  }
}
