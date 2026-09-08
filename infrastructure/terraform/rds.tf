# ==============================================================================
# RDS PostgreSQL 16 — Multi-AZ, encrypted, PITR, deletion-protected.
# Master password is AWS-managed (manage_master_user_password = true): never
# leaves AWS, auto-rotates. The ECS task reads it via Secrets Manager ARN
# referenced from SSM (var.db_password_ssm).
# ==============================================================================

resource "aws_db_subnet_group" "db" {
  count = var.create_rds ? 1 : 0

  name       = "mm-bet-${var.environment}-db"
  subnet_ids = var.private_subnet_ids
}

resource "aws_db_parameter_group" "app" {
  count       = var.create_rds ? 1 : 0
  name        = "mm-bet-${var.environment}-postgres16"
  family      = "postgres16"
  description = "Production tuning"
  parameter {
    name  = "log_statement"
    value = "ddl"
  }
  parameter {
    name  = "idle_in_transaction_session_timeout"
    value = "300000"
  }
}

resource "aws_db_instance" "app" {
  count = var.create_rds ? 1 : 0

  identifier = "mm-bet-${var.environment}-db"

  engine                      = "postgres"
  engine_version              = "16.1"
  db_name                     = var.db_name
  username                    = var.db_username
  manage_master_user_password = true # AWS-managed + rotated

  instance_class         = var.db_instance_class
  allocated_storage      = var.db_allocated_storage
  max_allocated_storage  = var.db_allocated_storage * 2
  storage_type           = "gp3"
  storage_encrypted      = true
  db_subnet_group_name   = aws_db_subnet_group.db[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]
  parameter_group_name   = aws_db_parameter_group.app[0].name

  multi_az                = true                      # zero-data-loss synchronous standby
  backup_retention_period = var.backup_retention_days # PITR window
  backup_window           = "03:00-03:30"             # scripts/dr/enable-pitr.sh default
  maintenance_window      = "sun:04:00-sun:04:30"

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "mm-bet-${var.environment}-final"

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  enabled_cloudwatch_logs_exports       = ["postgresql"]

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring[0].arn

  apply_immediately = false
}

data "aws_iam_policy_document" "rds_monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_monitoring" {
  count              = var.create_rds ? 1 : 0
  name               = "mm-bet-${var.environment}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.rds_monitoring_assume.json
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  count      = var.create_rds ? 1 : 0
  role       = aws_iam_role.rds_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# Alarm: DB CPU > 80% while settling bets = scale instance or add read replica
# (decision gate from the load-test spec).
resource "aws_cloudwatch_metric_alarm" "db_cpu" {
  count               = var.create_rds ? 1 : 0
  alarm_name          = "mm-bet-${var.environment}-db-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "3"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = "60"
  statistic           = "Average"
  threshold           = "80"
  dimensions = {
    DBInstanceIdentifier = aws_db_instance.app[0].id
  }
  alarm_description  = "RDS CPU sustained > 80% -> upsize instance or add read replica."
  treat_missing_data = "notBreaching"
}