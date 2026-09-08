# ==============================================================================
# Application Load Balancer terminating HTTPS + websocket upgrade.
# HTTP:80 redirects to 443; ALB drives the Fargate health checks (/health).
# ==============================================================================

resource "aws_lb" "main" {
  name               = "mm-bet-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = true
  idle_timeout               = 60
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "api" {
  name        = "mm-bet-${var.environment}-tg"
  port        = var.api_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # Fargate awsvpc

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  deregistration_delay = 30
  stickiness {
    type            = "lb_cookie"
    cookie_duration = 3600
    enabled         = false # no server affinity needed (stateless API)
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# CloudWatch alarm: 5xx spike signals an ALB/conn storm -> human + auto-scale.
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "mm-bet-${var.environment}-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = "60"
  statistic           = "Sum"
  threshold           = "50"
  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }
  alarm_description  = "ALB is returning elevated 5xx responses."
  treat_missing_data = "notBreaching"
}