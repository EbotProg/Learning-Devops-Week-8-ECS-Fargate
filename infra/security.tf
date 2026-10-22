# ALB: open to the internet on each listener port (80 frontend, 1337 backend)
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "Public access to the ALB listeners"
  vpc_id      = aws_vpc.this.id

  dynamic "ingress" {
    for_each = local.services
    content {
      description = "${ingress.key} listener"
      from_port   = ingress.value.listener_port
      to_port     = ingress.value.listener_port
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Tasks: ONLY reachable from the ALB security group (no IP ranges to maintain)
resource "aws_security_group" "tasks" {
  name        = "${var.project}-tasks-sg"
  description = "Fargate tasks, reachable only from the ALB"
  vpc_id      = aws_vpc.this.id

  dynamic "ingress" {
    for_each = local.services
    content {
      description     = "${ingress.key} from ALB"
      from_port       = ingress.value.container_port
      to_port         = ingress.value.container_port
      protocol        = "tcp"
      security_groups = [aws_security_group.alb.id]
    }
  }

  egress {
    description = "Outbound via NAT (ECR, CloudWatch, SSM, MongoDB Atlas)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
