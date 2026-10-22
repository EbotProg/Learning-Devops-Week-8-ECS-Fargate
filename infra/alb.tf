# ─────────────────────────────────────────────────────────────
# ALB in the public subnets.
#   :80   → frontend
#   :1337 → backend (Parse); the browser calls Parse directly
# Each service gets TWO target groups (blue + green) for CodeDeploy.
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

resource "aws_lb_listener" "prod" {
  for_each = local.services

  load_balancer_arn = aws_lb.this.arn
  port              = each.value.listener_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue[each.key].arn
  }

  # CodeDeploy flips this between blue and green on every deployment.
  # Without this, the next terraform apply would flip it back.
  lifecycle {
    ignore_changes = [default_action]
  }
}
