# ==============================================================================
# Security groups + VPC wiring for the ECS/ALB/RDS/Redis topology.
# Tasks live in private subnets (no public IP) and are reached only through
# the ALB; RDS/Redis accept traffic only from the ECS SG.
# ==============================================================================

data "aws_vpc" "this" {
  id = var.vpc_id
}

# --- ALB: inbound 80/443 from anywhere --------------------------------------
resource "aws_security_group" "alb" {
  name        = "mm-bet-${var.environment}-alb"
  description = "ALB ingress (HTTP/HTTPS), egress to ECS only"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = var.api_port
    to_port     = var.api_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # targets are private; egress via VPC
  }
}

# --- ECS tasks: 8080 from ALB only ------------------------------------------
resource "aws_security_group" "ecs" {
  name        = "mm-bet-${var.environment}-ecs"
  description = "Fargate task ingress"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = var.api_port
    to_port         = var.api_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- RDS: 5432 from ECS SG only ---------------------------------------------
resource "aws_security_group" "rds" {
  count = var.create_rds ? 1 : 0

  name        = "mm-bet-${var.environment}-rds"
  description = "Postgres access from ECS only"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- Redis: 6379 from ECS SG only -------------------------------------------
resource "aws_security_group" "redis" {
  count = var.create_redis ? 1 : 0

  name        = "mm-bet-${var.environment}-redis"
  description = "ElastiCache access from ECS only"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}